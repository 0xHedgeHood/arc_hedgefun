// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunV2AllInTreasury} from "../src/v2/HedgeFunV2AllInTreasury.sol";
import {HedgeFunV2UpgradeableTreasury} from "../src/v2/HedgeFunV2UpgradeableTreasury.sol";
import {HedgeFunV2BuybackTreasury} from "../src/v2/HedgeFunV2BuybackTreasury.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {V2CreatorParams} from "../src/v2/strategy/V2CreatorParams.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";
import {V2ExecuteBase} from "./V2Execute.t.sol";

/// All three entry points agree on basic rung bounds. Execution costs do not set ordinary strategy rungs.
contract V2CreatorParametersTest is V2FactoryFixture {
    V2TreasuryDeployer private deployer;
    address private constant TOKEN = address(0x70CE);

    function setUp() public {
        _setUpV2(18);
        deployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
    }

    function _params(uint32 tp, uint16 dip, uint16 bounty) private pure returns (HedgeFunTreasuryBase.Params memory p) {
        p.tp1Bps = tp; p.dipBps = dip; p.lotBps = 2000; p.bountyBps = bounty;
        p.maxSlippageBps = 100; p.maxDeviationBps = 50; p.maxBuybackImpactBps = 300;
        p.buybackCooldown = 60; p.minLotUsdg = 5e6; p.buybackChunkUsdg = 500e6;
        p.sellChunkUsdg = type(uint128).max;
    }

    function _args(HedgeFunTreasuryBase.Params memory p) private view returns (bytes memory) {
        return abi.encode(address(usdg), address(stock), address(stockPool), address(oracle), TOKEN, address(pm), address(factory), p);
    }

    function _new(HedgeFunTreasuryBase.Params memory p) private returns (HedgeFunV2AllInTreasury) {
        return new HedgeFunV2AllInTreasury(address(usdg), address(stock), address(stockPool), address(oracle), TOKEN, address(pm), address(factory), p);
    }

    function _refused(HedgeFunTreasuryBase.Params memory p) private {
        bytes memory args = _args(p);
        vm.expectRevert(V2CreatorParams.BadConfig.selector); _new(p);
        vm.expectRevert(V2CreatorParams.BadConfig.selector); deployer.predict(bytes32(0), args);
        vm.prank(address(factory)); vm.expectRevert(V2CreatorParams.BadConfig.selector); deployer.deploy(bytes32(0), args);
    }

    function _accepted(HedgeFunTreasuryBase.Params memory p) private {
        HedgeFunV2AllInTreasury direct = _new(p);
        assertEq(keccak256(abi.encode(direct.params())), keccak256(abi.encode(p)), "direct original rule restored");
        bytes memory args = _args(p);
        address predicted = deployer.predict(bytes32(0), args);
        vm.prank(address(factory)); address actual = deployer.deploy(bytes32(0), args);
        assertEq(actual, predicted);
        assertEq(keccak256(abi.encode(HedgeFunTreasuryBase(actual).params())), keccak256(abi.encode(p)), "registry original rule restored");
    }

    function test_defaultKindBindsExactCreatorSelectedCode() public view {
        (,, bytes32 codeHash,) = deployer.kindManifest(0);
        assertEq(codeHash, keccak256(type(HedgeFunV2UpgradeableTreasury).creationCode));
        assertEq(deployer.allInTriggerCodeHash(), keccak256(type(HedgeFunV2UpgradeableTreasury).creationCode));
    }

    function test_oneBpsTpDipAndStopAreAccepted_evenWithMaximumBounty() public {
        HedgeFunTreasuryBase.Params memory p = _params(1, 1, 200);
        p.stopBps = 1; p.tp2Bps = 2;
        _accepted(p);
    }

    function test_zeroStopAndMaximumBasicRungsAreAccepted() public {
        _accepted(_params(type(uint32).max, 9999, 0));
        HedgeFunTreasuryBase.Params memory p = _params(1, 9999, 200);
        p.stopBps = 9999; _accepted(p);
    }

    function test_zeroOrMalformedOriginalRungsRejectedAcrossAllEntries() public {
        _refused(_params(0, 1, 50)); _refused(_params(1, 0, 50)); _refused(_params(1, 10000, 50));
        HedgeFunTreasuryBase.Params memory p = _params(2, 1, 50); p.tp2Bps = 1; _refused(p);
        p.tp2Bps = 2; _refused(p); p.tp2Bps = 3; p.stopBps = 10000; _refused(p);
    }

    function test_constructorAdapterPreservesEveryNonEconomicBound() public {
        HedgeFunTreasuryBase.Params memory p = _params(1, 1, 50); p.lotBps = 0;
        vm.expectRevert(); _new(p);
        p = _params(1, 1, 201); vm.expectRevert(); _new(p);
        p = _params(1, 1, 50); p.bandBpsPerHour = 201; vm.expectRevert(); _new(p);
        p = _params(1, 1, 50); p.maxSlippageBps = 301; vm.expectRevert(); _new(p);
        p = _params(1, 1, 50); p.maxSlippageBps = 0; vm.expectRevert(); _new(p);
        p = _params(1, 1, 50); p.maxDeviationBps = 100; vm.expectRevert(); _new(p);
        p = _params(1, 1, 50); p.maxDeviationBps = 0; vm.expectRevert(); _new(p);
        p = _params(1, 1, 50); p.maxBuybackImpactBps = 0; vm.expectRevert(); _new(p);
        p = _params(1, 1, 50); p.minLotUsdg = 0; vm.expectRevert(); _new(p);
        p = _params(1, 1, 50); p.buybackChunkUsdg = 0; vm.expectRevert(); _new(p);
        p = _params(1, 1, 50); p.sellChunkUsdg = 0; vm.expectRevert(); _new(p);
    }

    function testFuzz_allValidCreatorRungsSurviveAdapterAndAllThreeEntries(uint32 tp, uint16 dip, uint16 stop, uint16 bounty) public {
        tp = uint32(bound(tp, 1, type(uint32).max)); dip = uint16(bound(dip, 1, 9999));
        stop = uint16(bound(stop, 0, 9999)); bounty = uint16(bound(bounty, 0, 200));
        HedgeFunTreasuryBase.Params memory p = _params(tp, dip, bounty); p.stopBps = stop;
        _accepted(p);
    }

    function test_listingSlippageAndMaximumBountyDoNotImposeOrdinaryRungFloors() public {
        vm.prank(owner); factory.setListingGates(address(stock), 60, 120, 0);
        HedgeFunFactory.Defaults memory d = factory.getDefaults(); d.bountyBps = 200;
        vm.prank(owner); factory.setDefaults(d);
        HedgeFunFactory.Request memory q = _request();
        q.tp1Bps = 1; q.tp2Bps = 2; q.dipBps = 1; q.stopBps = 1;
        (address token, address treasury, bytes32 terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        (address actualToken, address actualTreasury,,,) = factory.strategies(id);
        assertEq(actualToken, token); assertEq(actualTreasury, treasury);
        HedgeFunTreasuryBase.Params memory saved = HedgeFunTreasuryBase(treasury).params();
        assertEq(saved.tp1Bps, 1); assertEq(saved.tp2Bps, 2); assertEq(saved.dipBps, 1); assertEq(saved.stopBps, 1);
        assertEq(saved.maxSlippageBps, 120); assertEq(saved.bountyBps, 200);
    }

    function test_sameCodeRegisteredAtAnotherKindAlsoUsesCreatorRungs() public {
        (address a, address b) = deployer.makeChunks(type(HedgeFunV2UpgradeableTreasury).creationCode);
        vm.prank(owner); uint8 kind = deployer.registerKind(a, b);
        deployer.setStrategyKind("REPEAT", 0, kind);
        bytes32 salt = keccak256(abi.encode("REPEAT", address(this), uint96(0)));
        HedgeFunTreasuryBase.Params memory p = _params(1, 1, 200); p.stopBps = 1;
        address predicted = deployer.predict(salt, _args(p));
        vm.prank(address(factory)); address actual = deployer.deploy(salt, _args(p));
        assertEq(actual, predicted); assertEq(HedgeFunTreasuryBase(actual).params().stopBps, 1);
    }

    function test_legacyConstructorAndRegistryKeepTheirImmutableEconomicBounds() public {
        HedgeFunTreasuryBase.Params memory p = _params(1, 1, 200); p.stopBps = 1;
        vm.expectRevert(); new HedgeFunV2Treasury(address(usdg), address(stock), address(stockPool), address(oracle), TOKEN, address(pm), address(factory), p);
        (address a, address b) = deployer.makeChunks(type(HedgeFunV2Treasury).creationCode);
        vm.prank(owner); uint8 kind = deployer.registerKind(a, b); deployer.setStrategyKind("LEGACY", 0, kind);
        bytes32 salt = keccak256(abi.encode("LEGACY", address(this), uint96(0)));
        bytes memory args = _args(p);
        vm.expectRevert(abi.encodeWithSelector(V2TreasuryDeployer.StopInsideExecutionFriction.selector, 1, 330)); deployer.predict(salt, args);
        vm.prank(address(factory)); vm.expectRevert(abi.encodeWithSelector(V2TreasuryDeployer.StopInsideExecutionFriction.selector, 1, 330)); deployer.deploy(salt, args);
        p.stopBps = 0; p.tp1Bps = 260; p.dipBps = 260;
        assertGt(address(new HedgeFunV2Treasury(address(usdg), address(stock), address(stockPool), address(oracle), TOKEN, address(pm), address(factory), p)).code.length, 0);
    }

    function test_pureBuybackKeepsItsOriginalRegistryStopBoundary() public {
        (address a, address b) = deployer.makeChunks(type(HedgeFunV2BuybackTreasury).creationCode);
        vm.prank(owner); uint8 kind = deployer.registerKind(a, b); deployer.setStrategyKind("BUYBACK", 0, kind);
        bytes32 salt = keccak256(abi.encode("BUYBACK", address(this), uint96(0)));
        HedgeFunTreasuryBase.Params memory p = _params(260, 260, 200); p.stopBps = 1;
        bytes memory args = _args(p);
        vm.expectRevert(abi.encodeWithSelector(V2TreasuryDeployer.StopInsideExecutionFriction.selector, 1, 330)); deployer.predict(salt, args);
        p.stopBps = 0; args = _args(p); address predicted = deployer.predict(salt, args);
        vm.prank(address(factory)); assertEq(deployer.deploy(salt, args), predicted);
    }
}

/// A healthy partial buy and TP preserve legacy fill-cost and actual-input keeper bookkeeping.
abstract contract V2CreatorTradeEconomicsBase is V2ExecuteBase {
    function test_partialBuyAndHealthyTakeProfitConserveActualFillInventory() public {
        HedgeFunTreasuryBase.Params memory p = _params(0);
        p.tp1Bps = 330;
        p.tp2Bps = 0;
        p.dipBps = 330;
        p.bountyBps = 200;
        p.lotBps = 10000;
        p.sellChunkUsdg = type(uint128).max;
        treasury = new HedgeFunV2AllInTreasury(
            address(usdg),
            address(stock),
            address(mirror),
            address(oracle),
            address(token),
            address(pm),
            address(this),
            p
        );
        treasury.wire(_tokenKey());
        stock.mint(address(treasury), 0.1 ether);
        assertTrue(treasury.book());
        usdg.mint(address(treasury), 5_000_000e6);
        _px(90e18);
        vm.warp(block.timestamp + 600);
        uint256 beforeCash = treasury.reserveUsdg();
        uint256 beforeStock = stock.balanceOf(address(treasury));
        address keeper = address(0xB07);
        vm.prank(keeper);
        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        assertEq(uint8(action), uint8(HedgeFunV2Treasury.Action.BuyDip));
        uint256 afterBuy = treasury.reserveUsdg();
        uint256 bounty = usdg.balanceOf(keeper);
        uint256 actualSpent = beforeCash - afterBuy - bounty;
        assertGt(bounty, 0);
        assertEq(bounty, actualSpent * 200 / 10000);
        assertLt(actualSpent, beforeCash * 9800 / 10000, "this must exercise a genuinely short fill");
        (uint256 qty, uint256 cost,,) = treasury.lots(1);
        assertEq(qty, stock.balanceOf(address(treasury)) - beforeStock);
        assertEq(cost, Math.mulDiv(actualSpent, SCALE, qty), "lot cost remains its actual V3 fill price");
        assertEq(treasury.bookedStock(), stock.balanceOf(address(treasury)));
        uint256 salePrice = Math.ceilDiv(Math.mulDiv(cost, 10330, 10000, Math.Rounding.Ceil), 1e10) * 1e10;
        uint256 calls;
        while (treasury.lotCount() > 1) {
            _px(salePrice);
            vm.warp(block.timestamp + 600);
            vm.prank(keeper);
            (action,) = treasury.execute();
            assertEq(uint8(action), uint8(HedgeFunV2Treasury.Action.TakeProfit));
            assertLt(++calls, 10);
        }
        uint256 recovered = treasury.reserveUsdg() - afterBuy;
        uint256 retainedGainValue = Math.mulDiv(treasury.buybackStock(), salePrice, SCALE);
        assertGt(treasury.buybackStock(), 0);
        assertGt(stock.balanceOf(keeper), 0, "the TP reward must also leave the retained inventory");
        assertGe(recovered + retainedGainValue, beforeCash - afterBuy, "TP lost value against the all-in purchase");
        assertEq(treasury.bookedStock() + treasury.buybackStock(), stock.balanceOf(address(treasury)));
    }
}

contract V2CreatorTradeEconomicsStock0Test is V2CreatorTradeEconomicsBase {
    function stockIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract V2CreatorTradeEconomicsUsdg0Test is V2CreatorTradeEconomicsBase {
    function stockIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
