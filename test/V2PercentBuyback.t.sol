// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {V2TreasuryUpgradeController} from "../src/v2/V2TreasuryUpgradeController.sol";
import {HedgeFunV2UpgradeableTreasury} from "../src/v2/HedgeFunV2UpgradeableTreasury.sol";
import {
    HedgeFunV2PercentBuybackTreasury, HedgeFunV2PercentBuybackTreasuryLogic
} from "../src/v2/HedgeFunV2PercentBuybackTreasury.sol";
import {RegisterV2PercentBuyback} from "../script/RegisterV2PercentBuyback.s.sol";
import {SetV2KeeperReward, VerifyV2KeeperReward} from "../script/SetV2KeeperReward.s.sol";
import {ReviewedTreasuryRegistry} from "../script/helpers/ReviewedTreasuryRegistry.sol";
import {MisleadingDelayController} from "./V2TradablePercentRegistration.t.sol";

/// The strategy kind whose buy-back offers a tenth of its budget per call instead of the listing's fixed chunk.
contract V2PercentBuybackTest is V2FactoryFixture {
    V2TreasuryDeployer internal deployer;
    V2TreasuryUpgradeController internal controller;
    RegisterV2PercentBuyback internal tool;
    uint8 internal percentKind;
    uint96 internal nonce;

    function setUp() public {
        _setUpV2(18);
        deployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        controller = deployer.upgradeController();
        tool = new RegisterV2PercentBuyback();
        percentKind = tool.register(owner, factory);
    }

    function _graduated(uint8 kind) internal returns (HedgeFunV2Treasury t) {
        HedgeFunFactory.Request memory q = _request();
        q.nonce = ++nonce;
        if (kind != 0) deployer.setStrategyKind(q.symbol, q.nonce, kind);
        (,, bytes32 terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        t = HedgeFunV2Treasury(curve.treasury());
        stock.approve(address(curve), type(uint256).max);
        vm.warp(curve.launchedAt() + curve.snipeSeconds());
        _graduateV2(curve);
    }

    /// @dev LP stock fees are the one income that goes straight to the buy-back budget in every strategy kind.
    function _budget(HedgeFunV2Treasury t, uint256 amount) internal {
        address vault = t.liquidityVault();
        stock.mint(vault, amount);
        vm.prank(vault);
        stock.approve(address(t), amount);
        vm.prank(vault);
        t.creditLiquidityFee(amount);
    }

    function _lot(HedgeFunV2Treasury t) internal view returns (uint256) {
        (bool ok, uint256 p) = t.health();
        assertTrue(ok);
        return Math.mulDiv(t.params().minLotUsdg, 1e30, p);
    }

    function _next(HedgeFunV2Treasury t) internal {
        vm.warp(block.timestamp + t.params().buybackCooldown);
    }

    function test_registeredAsAnOrdinaryKindWithItsOwnCode() public view {
        tool.check(factory, percentKind);
        assertEq(percentKind, 1, "appended after kind 0");
        (uint32 version, uint32 schema, bytes32 hash,) = deployer.kindManifest(percentKind);
        assertEq(version, 0);
        assertEq(schema, 0);
        assertEq(hash, keccak256(type(HedgeFunV2PercentBuybackTreasury).creationCode));
        (,, bytes32 kindZero,) = deployer.kindManifest(0);
        assertTrue(hash != kindZero);
    }

    function test_eachBuybackOffersATenthOfWhatIsWaiting_kindZeroOffersTheFixedChunk() public {
        HedgeFunV2Treasury percent = _graduated(percentKind);
        HedgeFunV2Treasury fixedChunk = _graduated(0);
        uint256 budget = 400 * _lot(percent);                       // 2,000 USDG of stock: four fixed chunks
        _budget(percent, budget);
        _budget(fixedChunk, budget);

        (uint256 spent,) = percent.buyback();
        assertEq(spent, budget / 10, "a tenth of the budget");
        // Kind 0 offers the listing's whole chunk, a quarter of this budget. This pool cannot take that much inside
        // the impact cap, so the call fills short; the tenth above fitted.
        (uint256 spentFixed,) = fixedChunk.buyback();
        assertLe(spentFixed, Math.mulDiv(fixedChunk.params().buybackChunkUsdg, 1e30, _price(fixedChunk)), "kind 0: the chunk");
        assertGt(spentFixed, spent, "more than a tenth in one call");

        _next(percent);
        (uint256 second,) = percent.buyback();
        assertEq(second, (budget - spent) / 10, "then a tenth of what is left");
        assertEq(percent.buybackStock(), budget - spent - second);
    }

    function _price(HedgeFunV2Treasury t) internal view returns (uint256 p) {
        (, p) = t.health();
    }

    function test_aShareUnderTheMinimumLotIsRaisedToIt_andTheLastRemainderGoesWhole() public {
        HedgeFunV2Treasury t = _graduated(percentKind);
        uint256 lot = _lot(t);
        _budget(t, lot * 3 / 2);
        (uint256 spent,) = t.buyback();
        assertEq(spent, lot, "a tenth would be 0.15 lots; the call offers a whole lot");
        _next(t);
        (spent,) = t.buyback();
        assertEq(spent, lot / 2, "half a lot is left and goes whole");
        assertEq(t.buybackStock(), 0);
        _next(t);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        t.buyback();
    }

    function testFuzz_anyBudgetLeavesInBoundedSteps(uint96 raw) public {
        HedgeFunV2Treasury t = _graduated(percentKind);
        uint256 lot = _lot(t);
        uint256 budget = bound(raw, 1, 2_000 * lot);                // up to 10,000 USDG of stock
        _budget(t, budget);
        uint256 calls;
        uint256 waits;
        while (t.buybackStock() != 0) {
            uint256 waiting = t.buybackStock();
            try t.buyback() returns (uint256 spent, uint256) {
                assertLe(spent, Math.max(waiting / 10, lot), "never more than a tenth, or one lot");
                assertEq(t.buybackStock(), waiting - spent);
                ++calls;
                _next(t);
            } catch (bytes memory reason) {
                // The token pool is past what the price limit allows against its own recent mean: the buy-back
                // waits for the mean, as kind 0's does. Sizing changes how much is offered, not that limit.
                assertEq(bytes4(reason), HedgeFunTreasuryBase.NotDue.selector);
                assertEq(t.buybackStock(), waiting, "a refused call spends nothing");
                ++waits;
                vm.warp(block.timestamp + 10 minutes);
            }
            assertLt(calls, 400, "the tail ends");
            assertLt(waits, 400, "and the price limit lets it through in time");
        }
    }

    function test_isACompatibleUpgradeForALiveKindZeroTreasury() public {
        HedgeFunV2Treasury t = _graduated(0);
        uint256 budget = 400 * _lot(t);
        _budget(t, budget);
        (uint256 before,) = t.buyback();
        HedgeFunV2PercentBuybackTreasuryLogic next = new HedgeFunV2PercentBuybackTreasuryLogic(
            address(usdg), address(stock), address(stockPool), address(oracle), address(t.token()),
            address(pm), address(factory), t.params());
        HedgeFunV2UpgradeableTreasury proxy = HedgeFunV2UpgradeableTreasury(payable(address(t)));
        assertEq(next.upgradeConfigHash(), proxy.upgradeConfigHash(), "kind 0's own identity");
        assertLe(address(next).code.length, 24_576);
        uint256 booked = t.bookedStock();
        uint256 lots = t.lotCount();
        uint256 waiting = t.buybackStock();
        uint256 burned = t.totalBurned();

        vm.prank(owner);
        controller.schedule(address(t), address(next), "");
        vm.expectRevert(V2TreasuryUpgradeController.NotReady.selector);
        controller.execute(address(t), "");
        vm.warp(block.timestamp + 2 days);
        usdgFeed.set(1e8);
        stockFeed.set(stockFeed.answer());
        controller.execute(address(t), "");

        assertEq(proxy.implementation(), address(next));
        assertEq(t.bookedStock(), booked);
        assertEq(t.lotCount(), lots);
        assertEq(t.buybackStock(), waiting);
        assertEq(t.totalBurned(), burned);
        (uint256 spent,) = t.buyback();
        assertEq(spent, waiting / 10, "the same treasury now offers a tenth");
        assertLt(spent, before);
    }

    function test_launchFitsTheCodeSizeLimits() public {
        HedgeFunV2Treasury t = _graduated(percentKind);
        HedgeFunV2PercentBuybackTreasury proxy = HedgeFunV2PercentBuybackTreasury(payable(address(t)));
        assertLe(proxy.implementation().code.length, 24_576);
        bytes memory args = abi.encode(address(usdg), address(stock), address(stockPool), address(oracle),
            address(t.token()), address(pm), address(factory), t.params());
        assertLe(type(HedgeFunV2PercentBuybackTreasury).creationCode.length + args.length, 49_152);
        assertLe(type(HedgeFunV2PercentBuybackTreasuryLogic).creationCode.length + args.length, 49_152);
        assertEq(HedgeFunV2PercentBuybackTreasuryLogic(address(t)).BUYBACK_BPS(), 1000);
    }

    function test_keeperRewardChangesForNewLaunchesOnly() public {
        HedgeFunV2Treasury live = _graduated(0);
        assertEq(live.params().bountyBps, 50);
        SetV2KeeperReward setter = new SetV2KeeperReward();
        bytes32 others = _defaultsWithoutReward();
        bytes32 reviewed = keccak256(abi.encode(factory.getDefaults()));
        (uint16 before, uint16 afterwards, bytes32 nextHash) = setter.set(owner, factory, 10, reviewed);
        assertEq(before, 50);
        assertEq(afterwards, 10);
        assertEq(factory.getDefaults().bountyBps, 10);
        assertEq(_defaultsWithoutReward(), others, "no other default moved");
        assertEq(keccak256(abi.encode(factory.getDefaults())), nextHash);
        new VerifyV2KeeperReward().check(factory, 10, nextHash);
        assertEq(live.params().bountyBps, 50, "a live treasury keeps the reward it launched with");
        assertEq(_graduated(percentKind).params().bountyBps, 10, "a new launch takes the new one");
        vm.expectRevert(SetV2KeeperReward.BadBinding.selector);
        setter.set(address(0xBAD), factory, 5, nextHash);
    }

    /// `setDefaults` replaces the whole struct. A change built from a snapshot that is no longer the factory's
    /// would write the old values of every other default back, so it is refused before anything is sent.
    function test_keeperRewardRefusesASnapshotTheFactoryNoLongerHas() public {
        SetV2KeeperReward setter = new SetV2KeeperReward();
        bytes32 reviewed = keccak256(abi.encode(factory.getDefaults()));
        HedgeFunFactory.Defaults memory moved = factory.getDefaults();
        moved.maxCreatorBps = 1000;
        vm.prank(owner);
        factory.setDefaults(moved);

        vm.expectRevert(SetV2KeeperReward.DefaultsChanged.selector);
        setter.set(owner, factory, 10, reviewed);
        assertEq(factory.getDefaults().bountyBps, 50);
        assertEq(factory.getDefaults().maxCreatorBps, 1000, "the other owner change is still there");

        (,, bytes32 nextHash) = setter.set(owner, factory, 10, keccak256(abi.encode(moved)));
        assertEq(factory.getDefaults().maxCreatorBps, 1000);
        VerifyV2KeeperReward verifier = new VerifyV2KeeperReward();
        verifier.check(factory, 10, nextHash);

        // what the verifier is for: a competing change that landed after the simulation
        moved = factory.getDefaults();
        moved.maxCreatorBps = 3000;
        vm.prank(owner);
        factory.setDefaults(moved);
        vm.expectRevert(VerifyV2KeeperReward.BadReadback.selector);
        verifier.check(factory, 10, nextHash);
        vm.expectRevert(VerifyV2KeeperReward.BadReadback.selector);
        verifier.check(factory, 50, keccak256(abi.encode(moved)));
    }

    function _defaultsWithoutReward() private view returns (bytes32) {
        HedgeFunFactory.Defaults memory d = factory.getDefaults();
        d.bountyBps = 0;
        return keccak256(abi.encode(d));
    }

    function test_publicRegistryNonceCannotSubstituteOperatorChunks() public {
        vm.setNonce(owner, 41);
        vm.prank(address(0xBAD));
        deployer.makeChunks(hex"60006000");
        uint8 kind = new RegisterV2PercentBuyback().register(owner, factory);
        (address a, address b) = deployer.kinds(kind);
        assertEq(a, vm.computeCreateAddress(owner, 41));
        assertEq(b, vm.computeCreateAddress(owner, 42));
        assertEq(vm.getNonce(owner), 44, "three operator transactions");
    }

    function test_registrationRefusesTheWrongOperatorAndAnUnreviewedController() public {
        uint256 count = deployer.kindCount();
        vm.expectRevert(RegisterV2PercentBuyback.BadBinding.selector);
        tool.register(address(0xBAD), factory);
        vm.etch(address(controller), address(new MisleadingDelayController()).code);
        vm.expectRevert(ReviewedTreasuryRegistry.IncompatibleTreasuryRegistry.selector);
        tool.register(owner, factory);
        assertEq(deployer.kindCount(), count);
    }
}
