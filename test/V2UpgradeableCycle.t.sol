// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";
import {V2CycleBase} from "./V2CycleTreasury.t.sol";
import {MisleadingDelayController} from "./V2TradablePercentRegistration.t.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunV2CycleTreasury} from "../src/v2/HedgeFunV2CycleTreasury.sol";
import {
    HedgeFunV2UpgradeableCycleTreasury, HedgeFunV2UpgradeableCycleTreasuryLogic
} from "../src/v2/HedgeFunV2UpgradeableCycleTreasury.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {V2TreasuryUpgradeController} from "../src/v2/V2TreasuryUpgradeController.sol";
import {RegisterV2UpgradeableCycle} from "../script/RegisterV2UpgradeableCycle.s.sol";
import {ReviewedTreasuryRegistry} from "../script/helpers/ReviewedTreasuryRegistry.sol";

/// The cycle rule's tests, and the scheduler tests they inherit, against the upgradeable logic deployed directly:
/// the same rule, on real concentrated-liquidity fills, in both asset orders. Thirteen of the inherited scheduler
/// tests deploy a plain `HedgeFunV2Treasury` of their own and so say nothing about this kind; the rest run the
/// logic's code over the logic's own storage. `V2UpgradeableCycleThroughProxyBase` runs them through the proxy.
abstract contract V2UpgradeableCycleRuleBase is V2CycleBase {
    /// @dev the directly deployed contract with the same constructor arguments, so the same immutables
    HedgeFunV2CycleTreasury private twin;

    function _deployCycle(HedgeFunTreasuryBase.Params memory p) internal override {
        cycle = HedgeFunV2CycleTreasury(address(new HedgeFunV2UpgradeableCycleTreasuryLogic(
            address(usdg), address(stock), address(mirror), address(oracle), address(token), address(pm), address(this), p)));
        twin = new HedgeFunV2CycleTreasury(
            address(usdg), address(stock), address(mirror), address(oracle), address(token), address(pm), address(this), p);
        treasury = cycle;
        cycle.wire(_tokenKey());
    }

    function _pending() internal view override returns (bool) { return cycle.reentrySaleAt() != 0; }

    /// @dev The logic has no `recoveryDue()`. The directly deployed contract is the same core with that view
    ///      added, so its code is run, for this one read, over the logic's storage, and then put back.
    function _due() internal override returns (bool due) {
        bytes memory logic = address(cycle).code;
        vm.etch(address(cycle), address(twin).code);
        due = cycle.recoveryDue();
        vm.etch(address(cycle), logic);
    }
}

contract V2UpgradeableCycleRuleStock0Test is V2UpgradeableCycleRuleBase {
    function stockIsCurrency0() internal pure override returns (bool) { return true; }
}

contract V2UpgradeableCycleRuleStock1Test is V2UpgradeableCycleRuleBase {
    function stockIsCurrency0() internal pure override returns (bool) { return false; }
}

/// The same suite with every call made THROUGH the proxy, which is how a launched treasury is reached: the rule
/// runs by delegatecall over the proxy's storage, on the parameters the proxy's constructor packed as raw words,
/// with the reentrancy status the proxy never initialised, and the stock pool's swap callback arrives at the
/// proxy's fallback. Take-profit, stop, dip and recovery all execute this way.
abstract contract V2UpgradeableCycleThroughProxyBase is V2CycleBase {
    HedgeFunV2CycleTreasury private twin;
    V2TreasuryUpgradeController private proxyController;

    /// @dev the proxy asks its deployer, in place of the registry, for the controller
    function upgradeController() external view returns (V2TreasuryUpgradeController) { return proxyController; }

    function _deployCycle(HedgeFunTreasuryBase.Params memory p) internal override {
        if (address(proxyController) == address(0)) proxyController = new V2TreasuryUpgradeController();
        HedgeFunV2UpgradeableCycleTreasury proxy = new HedgeFunV2UpgradeableCycleTreasury(
            address(usdg), address(stock), address(mirror), address(oracle), address(token), address(pm), address(this), p);
        assertEq(proxy.implementation(), proxy.initialImplementation());
        cycle = HedgeFunV2CycleTreasury(address(proxy));
        twin = new HedgeFunV2CycleTreasury(
            address(usdg), address(stock), address(mirror), address(oracle), address(token), address(pm), address(this), p);
        treasury = cycle;
        cycle.wire(_tokenKey());
    }

    function _pending() internal view override returns (bool) { return cycle.reentrySaleAt() != 0; }

    /// @dev As in `V2UpgradeableCycleRuleBase`: the direct contract's view, for this one read, over the storage
    ///      the proxy holds.
    function _due() internal override returns (bool due) {
        bytes memory proxyCode = address(cycle).code;
        vm.etch(address(cycle), address(twin).code);
        due = cycle.recoveryDue();
        vm.etch(address(cycle), proxyCode);
    }
}

contract V2UpgradeableCycleThroughProxyStock0Test is V2UpgradeableCycleThroughProxyBase {
    function stockIsCurrency0() internal pure override returns (bool) { return true; }
}

contract V2UpgradeableCycleThroughProxyStock1Test is V2UpgradeableCycleThroughProxyBase {
    function stockIsCurrency0() internal pure override returns (bool) { return false; }
}

/// The proxy: registration, initialisation from raw words, the buy-back share, and upgrades.
contract V2UpgradeableCycleProxyTest is V2FactoryFixture {
    V2TreasuryDeployer internal deployer;
    V2TreasuryUpgradeController internal controller;
    RegisterV2UpgradeableCycle internal tool;
    uint8 internal cycleKind;
    uint96 internal nonce;

    function setUp() public {
        _setUpV2(18);
        deployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        controller = deployer.upgradeController();
        tool = new RegisterV2UpgradeableCycle();
        cycleKind = tool.register(owner, factory);
    }

    /// @dev lets this contract stand in for the registry when a test deploys the proxy directly
    function upgradeController() external view returns (V2TreasuryUpgradeController) { return controller; }

    function _graduated() internal returns (HedgeFunV2UpgradeableCycleTreasuryLogic t, HedgeFunFactory.Request memory q) {
        q = _request();
        q.nonce = ++nonce;
        deployer.setStrategyKind(q.symbol, q.nonce, cycleKind);
        (, address predicted, bytes32 terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        assertEq(curve.treasury(), predicted);
        t = HedgeFunV2UpgradeableCycleTreasuryLogic(curve.treasury());
        stock.approve(address(curve), type(uint256).max);
        vm.warp(curve.launchedAt() + curve.snipeSeconds());
        _graduateV2(curve);
    }

    function _budget(HedgeFunV2Treasury t, uint256 amount) internal {
        address vault = t.liquidityVault();
        stock.mint(vault, amount);
        vm.startPrank(vault);
        stock.approve(address(t), amount);
        t.creditLiquidityFee(amount);
        vm.stopPrank();
    }

    function test_registeredLaunchedAndInitialisedThroughTheFactory() public {
        tool.check(factory, cycleKind);
        (HedgeFunV2UpgradeableCycleTreasuryLogic t, HedgeFunFactory.Request memory q) = _graduated();
        HedgeFunV2UpgradeableCycleTreasury proxy = HedgeFunV2UpgradeableCycleTreasury(payable(address(t)));
        assertEq(address(proxy.treasuryUpgradeController()), address(controller));
        assertEq(proxy.implementation(), proxy.initialImplementation());
        HedgeFunTreasuryBase.Params memory p = t.params();
        assertEq(keccak256(abi.encode(p)),
            keccak256(abi.encode(HedgeFunV2Treasury(proxy.initialImplementation()).params())), "the proxy holds the logic's own parameters");
        assertEq(p.tp1Bps, q.tp1Bps);
        assertEq(p.dipBps, q.dipBps);
        assertGt(p.sellChunkUsdg, 0);
        assertTrue(t.hook() != address(0));
        assertGt(t.bookedStock(), 0, "the graduation stock is booked as the first lot");
        assertEq(t.reentrySaleAt(), 0);

        assertLe(proxy.initialImplementation().code.length, 24_576);
        bytes memory args = abi.encode(address(usdg), address(stock), address(stockPool), address(oracle),
            address(t.token()), address(pm), address(factory), p);
        assertLe(type(HedgeFunV2UpgradeableCycleTreasury).creationCode.length + args.length, 49_152);

        bytes32[5] memory words;
        vm.expectRevert(HedgeFunV2UpgradeableCycleTreasuryLogic.InvalidInitialization.selector);
        t.initializeProxy(words);
        HedgeFunV2UpgradeableCycleTreasuryLogic logic = HedgeFunV2UpgradeableCycleTreasuryLogic(proxy.initialImplementation());
        vm.expectRevert(HedgeFunV2UpgradeableCycleTreasuryLogic.InvalidInitialization.selector);
        logic.initializeProxy(words);
        assertEq(keccak256(abi.encode(t.params())), keccak256(abi.encode(p)));
    }

    /// The proxy's constructor packs `Params` into storage words by hand. Every field, at its extremes.
    function testFuzz_rawWordInitialisationWritesEveryParameter(uint256 seed, uint256 lot, uint256 chunk, uint256 sell)
        public
    {
        HedgeFunTreasuryBase.Params memory p;
        p.maxSlippageBps = uint16(bound(seed, 2, 300));
        p.maxDeviationBps = uint16(bound(seed >> 16, 1, p.maxSlippageBps - 1));
        uint256 floor = 2 * (uint256(p.maxSlippageBps) + 30);
        p.tp1Bps = uint32(bound(seed >> 32, floor, type(uint32).max - 1));
        p.tp2Bps = seed & 1 == 0 ? 0 : uint32(bound(seed >> 64, uint256(p.tp1Bps) + 1, type(uint32).max));
        p.dipBps = uint16(bound(seed >> 96, floor, 9_999));
        p.bountyBps = uint16(bound(seed >> 112, 0, 200));
        uint256 friction = uint256(p.maxSlippageBps) + 30 + p.bountyBps;
        p.stopBps = seed & 2 == 0 ? 0 : uint16(bound(seed >> 128, friction + 1, 9_999));
        p.lotBps = uint16(bound(seed >> 144, 1, 10_000));
        p.maxBuybackImpactBps = uint16(bound(seed >> 160, 1, 300));
        p.buybackCooldown = uint32(seed >> 176);
        p.bandBpsPerHour = uint16(bound(seed >> 208, 0, 200));
        p.minLotUsdg = bound(lot, 1, type(uint256).max);
        p.buybackChunkUsdg = bound(chunk, 1, type(uint256).max);
        p.sellChunkUsdg = bound(sell, 1, type(uint256).max);

        HedgeFunV2UpgradeableCycleTreasury proxy = new HedgeFunV2UpgradeableCycleTreasury(
            address(usdg), address(stock), address(stockPool), address(oracle), address(0xF00D), address(pm), address(factory), p);
        assertEq(keccak256(abi.encode(HedgeFunV2Treasury(address(proxy)).params())), keccak256(abi.encode(p)));
        // and nothing past the fifth word: the next field in the layout is still empty
        assertEq(HedgeFunV2Treasury(address(proxy)).hook(), address(0));
        assertEq(vm.load(address(proxy), bytes32(uint256(_paramsSlot(address(proxy))) + 5)), bytes32(0));
    }

    /// @dev finds where `_params` starts by its first word, which this test knows
    function _paramsSlot(address proxy) private view returns (uint256 slot) {
        HedgeFunTreasuryBase.Params memory p = HedgeFunV2Treasury(proxy).params();
        for (; slot < 40; ++slot) {
            uint256 word = uint256(vm.load(proxy, bytes32(slot)));
            if (word != 0 && uint32(word) == p.tp1Bps && uint32(word >> 32) == p.tp2Bps
                && vm.load(proxy, bytes32(slot + 1)) == bytes32(p.minLotUsdg)) return slot;
        }
        revert("params slot not found");
    }

    function test_buybackOffersATenthOfTheBudget() public {
        (HedgeFunV2UpgradeableCycleTreasuryLogic t,) = _graduated();
        (, uint256 price) = t.health();
        uint256 lot = Math.mulDiv(t.params().minLotUsdg, 1e30, price);
        _budget(t, 400 * lot);
        (uint256 spent,) = t.buyback();
        assertEq(spent, 40 * lot, "a tenth, not the listing's fixed chunk");
        vm.warp(block.timestamp + t.params().buybackCooldown);
        (uint256 second,) = t.buyback();
        assertEq(second, (400 * lot - spent) / 10);
    }

    function test_compatibleUpgradeKeepsTheLedgerAndRefusesAnotherTreasurysLogic() public {
        (HedgeFunV2UpgradeableCycleTreasuryLogic t,) = _graduated();
        (HedgeFunV2UpgradeableCycleTreasuryLogic other,) = _graduated();
        HedgeFunV2UpgradeableCycleTreasury proxy = HedgeFunV2UpgradeableCycleTreasury(payable(address(t)));
        _budget(t, 1e18);
        HedgeFunV2UpgradeableCycleTreasuryLogic next = new HedgeFunV2UpgradeableCycleTreasuryLogic(
            address(usdg), address(stock), address(stockPool), address(oracle), address(t.token()),
            address(pm), address(factory), t.params());
        assertEq(next.upgradeConfigHash(), proxy.upgradeConfigHash());
        uint256 booked = t.bookedStock();
        uint256 lots = t.lotCount();
        uint256 waiting = t.buybackStock();
        bytes32 params = keccak256(abi.encode(t.params()));

        address foreign = HedgeFunV2UpgradeableCycleTreasury(payable(address(other))).initialImplementation();
        vm.startPrank(owner);
        vm.expectRevert(V2TreasuryUpgradeController.InvalidUpgrade.selector);
        controller.schedule(address(t), foreign, "");
        controller.schedule(address(t), address(next), "");
        vm.stopPrank();
        vm.expectRevert(V2TreasuryUpgradeController.NotReady.selector);
        controller.execute(address(t), "");
        vm.warp(block.timestamp + 2 days);
        controller.execute(address(t), "");

        assertEq(proxy.implementation(), address(next));
        assertEq(t.bookedStock(), booked);
        assertEq(t.lotCount(), lots);
        assertEq(t.buybackStock(), waiting);
        assertEq(keccak256(abi.encode(t.params())), params);
        vm.expectRevert(HedgeFunV2UpgradeableCycleTreasury.NotUpgradeController.selector);
        proxy.applyUpgrade("");
    }

    function test_publicRegistryNonceCannotSubstituteOperatorChunks() public {
        vm.setNonce(owner, 51);
        vm.prank(address(0xBAD));
        deployer.makeChunks(hex"60006000");
        uint8 kind = new RegisterV2UpgradeableCycle().register(owner, factory);
        (address a, address b) = deployer.kinds(kind);
        assertEq(a, vm.computeCreateAddress(owner, 51));
        assertEq(b, vm.computeCreateAddress(owner, 52));
        assertEq(vm.getNonce(owner), 54, "three operator transactions");
    }

    function test_registrationRefusesTheWrongOperatorAndAnUnreviewedController() public {
        uint256 count = deployer.kindCount();
        vm.expectRevert(RegisterV2UpgradeableCycle.BadBinding.selector);
        tool.register(address(0xBAD), factory);
        vm.etch(address(controller), address(new MisleadingDelayController()).code);
        vm.expectRevert(ReviewedTreasuryRegistry.IncompatibleTreasuryRegistry.selector);
        tool.register(owner, factory);
        assertEq(deployer.kindCount(), count);
    }
}
