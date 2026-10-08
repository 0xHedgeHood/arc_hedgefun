// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {EngineBinding} from "../src/v2/HedgeFunV2EngineTreasury.sol";
import {
    HedgeFunV2TradablePercentEngineTreasury,
    HedgeFunV2TradablePercentEngineTreasuryLogic,
    HedgeFunV2TradablePercentEngineTreasuryCore
} from "../src/v2/HedgeFunV2TradablePercentEngineTreasury.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {V2TreasuryUpgradeController} from "../src/v2/V2TreasuryUpgradeController.sol";
import {TradablePercentEngineConfig} from "../src/v2/strategy/TradablePercentEngineConfig.sol";
import {V2TradablePercentRebalancePolicy} from "../src/v2/strategy/V2TradablePercentRebalancePolicy.sol";
import {EngineConfig, PolicyManifest, StrategyAction} from "../src/v2/strategy/IStrategyPolicy.sol";
import {V2StrategyEngineAccountingFixture} from "./V2StrategyEngineAccounting.t.sol";

contract TradablePercentConfigHarness {
    function valid(bytes32[3] memory words) external pure returns (bool) {
        return TradablePercentEngineConfig.valid(words, 0);
    }
}

/// @dev Small appended-storage migration fixture; the whole production trade implementation is retained.
contract TradablePercentMigrationLogic is HedgeFunV2TradablePercentEngineTreasuryLogic {
    uint256 public migrationMarker;
    error MigrationRejected();
    error OnlyController();

    constructor(
        address u,
        address s,
        address v,
        address o,
        address t,
        address pm,
        address f,
        Params memory p,
        EngineBinding memory binding
    ) HedgeFunV2TradablePercentEngineTreasuryLogic(u, s, v, o, t, pm, f, p, binding) {}

    function migrate(uint256 marker, bool fail) external {
        if (
            msg.sender
                != address(HedgeFunV2TradablePercentEngineTreasury(payable(address(this))).treasuryUpgradeController())
        ) {
            revert OnlyController();
        }
        migrationMarker = marker;
        if (fail) revert MigrationRejected();
    }
}

/// @dev Independent schema-3 fixture. Existing schema-1 and schema-2 fixtures/registrations remain unchanged.
abstract contract V2TradablePercentEngineFixture is V2StrategyEngineAccountingFixture {
    V2TradablePercentRebalancePolicy internal percentPolicy;
    V2TreasuryUpgradeController internal controller;
    bytes32 internal percentPolicyKey;
    uint8 internal percentKind;

    struct Risk {
        bool healthy;
        uint256 capital;
        uint256 buy;
        uint256 sell;
        uint256 daily;
        uint256 remaining;
        uint64 epoch;
        uint256 used;
    }

    function setUp() public virtual override {
        super.setUp();
        controller = deployer.upgradeController();
        percentPolicy = new V2TradablePercentRebalancePolicy();
        (address a, address b) = deployer.makeChunks(type(HedgeFunV2TradablePercentEngineTreasury).creationCode);
        vm.startPrank(owner);
        percentPolicyKey = deployer.registerPolicy(
            address(percentPolicy),
            150_000,
            160,
            keccak256("tradable-percent-deps-v1"),
            keccak256("tradable-percent-audit-v1")
        );
        percentKind = deployer.registerEngineKind(a, b, 1, 3, 3);
        vm.stopPrank();
    }

    function _percentConfig(uint256 buy, uint256 sell, uint256 daily, uint256 payout)
        internal
        view
        returns (EngineConfig memory c)
    {
        c.schema = 3;
        c.engineVersion = 1;
        c.policyKey = percentPolicyKey;
        c.words[0] = bytes32(uint256(7000) | uint256(500) << 16 | uint256(600) << 32 | payout << 64);
        c.words[1] = bytes32(buy | sell << 16);
        c.words[2] = bytes32(daily);
    }

    function _launchPercent(uint96 nonce, uint256 buy, uint256 sell, uint256 daily, uint256 payout)
        internal
        returns (HedgeFunV2TradablePercentEngineTreasuryCore treasury)
    {
        HedgeFunFactory.Request memory q = _request();
        q.nonce = nonce;
        deployer.setEngineConfig(q.symbol, q.nonce, percentKind, _percentConfig(buy, sell, daily, payout));
        (, address predicted, bytes32 terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        (, address t,,,) = factory.strategies(id);
        assertEq(t, predicted);
        treasury = HedgeFunV2TradablePercentEngineTreasuryCore(t);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        stock.approve(address(curve), type(uint256).max);
        _graduateV2(curve);
    }

    function _risk(HedgeFunV2TradablePercentEngineTreasuryCore t) internal view returns (Risk memory r) {
        (r.healthy, r.capital, r.buy, r.sell, r.daily, r.remaining, r.epoch, r.used) = t.riskLimits();
    }

    function _price(uint256 price) internal {
        venue.setPrice(price);
        stockFeed.set(int256(price / 1e10));
        usdgFeed.set(1e8);
    }

    function _advance(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
        _price(venue.price());
    }

    function _binding(HedgeFunV2TradablePercentEngineTreasuryCore t) internal view returns (EngineBinding memory) {
        return EngineBinding(t.engineConfig(), deployer.policy(t.strategyId()), address(t));
    }

    function _replacement(HedgeFunV2TradablePercentEngineTreasuryCore t)
        internal
        returns (HedgeFunV2TradablePercentEngineTreasuryLogic)
    {
        return _replacement(t, _binding(t));
    }

    function _replacement(HedgeFunV2TradablePercentEngineTreasuryCore t, EngineBinding memory binding)
        internal
        returns (HedgeFunV2TradablePercentEngineTreasuryLogic)
    {
        return new HedgeFunV2TradablePercentEngineTreasuryLogic(
            address(usdg),
            address(stock),
            address(venue),
            address(oracle),
            address(t.token()),
            address(pm),
            address(factory),
            t.params(),
            binding
        );
    }

    function _upgradeDigest(HedgeFunV2TradablePercentEngineTreasuryCore t) internal view returns (bytes32) {
        bytes32 execution = keccak256(
            abi.encode(
                t.strategyNonce(),
                t.policyState(),
                t.lastStrategyAt(),
                t.turnoverEpoch(),
                t.turnoverInEpoch(),
                t.configHash(),
                t.avgCost(),
                t.unrecoveredLossUsdg(),
                t.engineConfig()
            )
        );
        bytes32 custody = keccak256(
            abi.encode(
                t.bookedStock(),
                t.buybackStock(),
                t.totalStockReceived(),
                t.unbookedStock(),
                t.reserveUsdg(),
                t.liquidityVault(),
                stock.balanceOf(address(t)),
                _risk(t)
            )
        );
        return keccak256(abi.encode(execution, custody, t.params()));
    }
}

contract V2TradablePercentEngineTest is V2TradablePercentEngineFixture {
    function test_proxyInitializationCommitmentAndConstructorBytecodeLimits() public {
        HedgeFunV2TradablePercentEngineTreasuryCore t = _launchPercent(2000, 2000, 1000, 5000, 5000);
        HedgeFunV2TradablePercentEngineTreasury proxy = HedgeFunV2TradablePercentEngineTreasury(payable(address(t)));
        HedgeFunV2TradablePercentEngineTreasuryLogic next = _replacement(t);
        assertEq(address(proxy.treasuryUpgradeController()), address(controller));
        assertEq(controller.UPGRADE_DELAY(), 2 days);
        assertEq(proxy.implementation(), proxy.initialImplementation());
        assertEq(next.upgradeConfigHash(), proxy.upgradeConfigHash());
        assertEq(keccak256(abi.encode(t.engineConfig())), keccak256(abi.encode(_percentConfig(2000, 1000, 5000, 5000))));
        assertEq(t.params().tp1Bps, _request().tp1Bps);
        assertEq(t.payoutBps(), 5000);
        assertEq(address(t.tradingCalendar()), address(oracle.calendar()));
        PolicyManifest memory m = deployer.policy(percentPolicyKey);
        assertEq(
            t.configHash(),
            keccak256(
                abi.encode(
                    block.chainid,
                    address(t),
                    address(factory),
                    address(stock),
                    address(usdg),
                    t.engineConfig(),
                    m.implementation,
                    m.runtimeCodeHash,
                    m.capabilities,
                    m.maxGas,
                    m.maxReturnBytes
                )
            )
        );
        assertEq(next.configHash(), t.configHash());
        assertLe(address(proxy).code.length, 24_576);
        assertLe(address(next).code.length, 24_576);
        (address a, address b) = deployer.kinds(percentKind);
        assertLe(a.code.length, 24_576);
        assertLe(b.code.length, 24_576);
        bytes memory args = abi.encode(
            address(usdg),
            address(stock),
            address(venue),
            address(oracle),
            address(t.token()),
            address(pm),
            address(factory),
            t.params(),
            t.engineConfig()
        );
        assertLe(type(HedgeFunV2TradablePercentEngineTreasury).creationCode.length + args.length, 49_152);
        args = abi.encode(
            address(usdg),
            address(stock),
            address(venue),
            address(oracle),
            address(t.token()),
            address(pm),
            address(factory),
            t.params(),
            _binding(t)
        );
        assertLe(type(HedgeFunV2TradablePercentEngineTreasuryLogic).creationCode.length + args.length, 49_152);
        HedgeFunTreasuryBase.Params memory p = t.params();
        EngineConfig memory c = t.engineConfig();
        vm.expectRevert(HedgeFunV2TradablePercentEngineTreasuryLogic.InvalidInitialization.selector);
        HedgeFunV2TradablePercentEngineTreasuryLogic(address(t)).initializeProxy(p, c);
        vm.expectRevert(HedgeFunV2TradablePercentEngineTreasuryLogic.InvalidInitialization.selector);
        next.initializeProxy(p, c);
    }

    function test_limitsUseCashAndStockSeparatelyAndIgnoreFixedChunk() public {
        vm.prank(owner);
        factory.setListingGates(address(stock), 50, 100, 25e6);
        HedgeFunV2TradablePercentEngineTreasuryCore t = _launchPercent(2001, 2000, 1000, 5000, 0);
        Risk memory initial = _risk(t);
        assertTrue(initial.healthy);
        assertEq(initial.buy, 0);
        assertEq(initial.sell, t.bookedStock() / 10);
        assertEq(initial.capital, Math.mulDiv(t.bookedStock(), PRICE, 1e30));
        assertEq(initial.daily, (initial.capital / 2) * 2, "aggregate of the two directional budgets");
        (bool due, StrategyAction action, uint256 offered) = t.preview();
        assertTrue(due);
        assertEq(uint256(action), uint256(StrategyAction.SellStock));
        assertEq(offered, initial.sell);
        assertGt(Math.mulDiv(offered, PRICE, 1e30), t.params().sellChunkUsdg);
        t.execute();
        assertEq(t.turnoverInEpoch(), Math.mulDiv(offered, PRICE, 1e30));
        _advance(600);
        usdg.mint(address(t), 100_000e6);
        Risk memory cash = _risk(t);
        assertEq(cash.buy, t.reserveUsdg() / 5);
        (due, action, offered) = t.preview();
        assertTrue(due);
        assertEq(uint256(action), uint256(StrategyAction.BuyStock));
        assertEq(offered, initial.capital / 2, "new cash cannot enlarge today's pinned buy budget");
        assertGt(offered, 2000e6, "large capital no longer hits a fixed 2000 cap");
        uint256 beforeCash = t.reserveUsdg();
        t.execute();
        assertEq(beforeCash - t.reserveUsdg(), offered);
    }

    function test_upgradePreservesSameDateUsageCustodyAndConfiguration() public {
        HedgeFunV2TradablePercentEngineTreasuryCore t = _launchPercent(2002, 2000, 1000, 5000, 5000);
        HedgeFunV2TradablePercentEngineTreasuryLogic next = _replacement(t);
        vm.prank(owner);
        controller.schedule(address(t), address(next), "");
        _advance(2 days);
        _price(160e18);
        t.execute();
        assertGt(t.buybackStock(), 0);
        bytes32 before_ = _upgradeDigest(t);
        controller.execute(address(t), "");
        assertEq(_upgradeDigest(t), before_);
        assertEq(HedgeFunV2TradablePercentEngineTreasury(payable(address(t))).implementation(), address(next));
        assertEq(next.strategyNonce(), 0, "proxy execution never mutates implementation storage");
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        t.execute();
        uint256 used = t.turnoverInEpoch();
        _advance(600);
        t.execute();
        assertGt(t.turnoverInEpoch(), used);
    }

    function test_changedRatioProxyOrDecimalsCannotUseOriginalUpgradeIdentity() public {
        HedgeFunV2TradablePercentEngineTreasuryCore t = _launchPercent(2003, 2000, 1000, 5000, 0);
        EngineBinding memory binding = _binding(t);
        binding.config.words[1] = bytes32(uint256(2001) | uint256(1000) << 16);
        _reject(t, _replacement(t, binding));
        binding = _binding(t);
        binding.treasury = address(0xDEAD);
        _reject(t, _replacement(t, binding));
        vm.mockCall(address(stock), abi.encodeWithSignature("decimals()"), abi.encode(uint8(17)));
        HedgeFunV2TradablePercentEngineTreasuryLogic next = _replacement(t);
        vm.clearMockedCalls();
        _reject(t, next);
    }

    function _reject(HedgeFunV2TradablePercentEngineTreasuryCore t, HedgeFunV2TradablePercentEngineTreasuryLogic next)
        private
    {
        vm.prank(owner);
        vm.expectRevert(V2TreasuryUpgradeController.InvalidUpgrade.selector);
        controller.schedule(address(t), address(next), "");
    }

    function test_delistingBlocksNewLaunchButAllowsCompatibleUpgrade() public {
        HedgeFunV2TradablePercentEngineTreasuryCore t = _launchPercent(2004, 2000, 1000, 5000, 0);
        vm.prank(owner);
        deployer.disablePolicy(percentPolicyKey);
        HedgeFunV2TradablePercentEngineTreasuryLogic next = _replacement(t);
        vm.prank(owner);
        controller.schedule(address(t), address(next), "");
        _advance(2 days);
        controller.execute(address(t), "");
        t.execute();
        assertEq(t.strategyNonce(), 1);
        EngineConfig memory c = _percentConfig(2000, 1000, 5000, 0);
        vm.expectRevert(V2TreasuryDeployer.BadPolicy.selector);
        deployer.setEngineConfig("BAD", 2005, percentKind, c);
    }

    function test_upgradeEnforcesOwnerNoticeAndControllerOnlyEntrypoint() public {
        HedgeFunV2TradablePercentEngineTreasuryCore t = _launchPercent(2007, 2000, 1000, 5000, 0);
        HedgeFunV2TradablePercentEngineTreasuryLogic next = _replacement(t);
        vm.expectRevert(V2TreasuryUpgradeController.NotOwner.selector);
        controller.schedule(address(t), address(next), "");
        vm.prank(owner);
        controller.schedule(address(t), address(next), "");
        _advance(2 days - 1);
        vm.expectRevert(V2TreasuryUpgradeController.NotReady.selector);
        controller.execute(address(t), "");
        vm.prank(owner);
        vm.expectRevert(HedgeFunV2TradablePercentEngineTreasury.NotUpgradeController.selector);
        HedgeFunV2TradablePercentEngineTreasury(payable(address(t))).applyUpgrade("");
        _advance(1);
        controller.execute(address(t), "");
        assertEq(HedgeFunV2TradablePercentEngineTreasury(payable(address(t))).implementation(), address(next));
    }

    function test_failedMigrationRollsBackPointerStateAndProposalThenCompatibleMigrationSucceeds() public {
        HedgeFunV2TradablePercentEngineTreasuryCore t = _launchPercent(2008, 2000, 1000, 5000, 0);
        TradablePercentMigrationLogic next = new TradablePercentMigrationLogic(
            address(usdg),
            address(stock),
            address(venue),
            address(oracle),
            address(t.token()),
            address(pm),
            address(factory),
            t.params(),
            _binding(t)
        );
        assertLe(address(next).code.length, 24_576, "migration retains all production trading methods");
        bytes memory data = abi.encodeCall(TradablePercentMigrationLogic.migrate, (17, true));
        vm.prank(owner);
        controller.schedule(address(t), address(next), data);
        _advance(2 days);
        t.execute();
        bytes32 before_ = _upgradeDigest(t);
        address previous = HedgeFunV2TradablePercentEngineTreasury(payable(address(t))).implementation();
        vm.expectRevert(TradablePercentMigrationLogic.MigrationRejected.selector);
        controller.execute(address(t), data);
        assertEq(_upgradeDigest(t), before_);
        assertEq(HedgeFunV2TradablePercentEngineTreasury(payable(address(t))).implementation(), previous);
        (address pending,,,, uint256 readyAt) = controller.proposals(address(t));
        assertEq(pending, address(next));
        assertGt(readyAt, 0);
        data = abi.encodeCall(TradablePercentMigrationLogic.migrate, (17, false));
        vm.prank(owner);
        controller.schedule(address(t), address(next), data);
        _advance(2 days);
        before_ = _upgradeDigest(t);
        controller.execute(address(t), data);
        assertEq(_upgradeDigest(t), before_);
        assertEq(TradablePercentMigrationLogic(address(t)).migrationMarker(), 17);
        assertEq(next.migrationMarker(), 0);
        uint256 nonce = t.strategyNonce();
        t.execute();
        assertEq(t.strategyNonce(), nonce + 1);
    }

    /// The words a creator registers are theirs; what the treasury accepts is not. No listing chunk bounds a
    /// schema-3 action, so a band under one trade's cost, or an action over a quarter, is refused at launch.
    function test_launchRefusesBandInsideFrictionAndActionsOverAQuarter() public {
        HedgeFunTreasuryBase.Params memory p = _launchPercent(2020, 2500, 2500, 10_000, 0).params();
        uint256 floor = 30 + p.bountyBps;                           // the venue's 0.3% fee and the keeper reward
        assertEq(floor, 80);
        _expectUndeployable(2021, floor - 1, 2000, 2000);
        _expectUndeployable(2022, 0, 2000, 2000);
        _expectUndeployable(2023, 500, 2501, 2000);
        _expectUndeployable(2024, 500, 2000, 10_000);
        // exactly on both limits
        EngineConfig memory c = _percentConfig(2500, 2500, 10_000, 0);
        c.words[0] = bytes32(uint256(7000) | floor << 16 | uint256(600) << 32);
        HedgeFunFactory.Request memory q = _request();
        q.nonce = 2025;
        deployer.setEngineConfig(q.symbol, q.nonce, percentKind, c);
        (,, bytes32 terms) = factory.predict(q);
        factory.launch(q, terms);
    }

    function _expectUndeployable(uint96 nonce, uint256 band, uint256 buy, uint256 sell) private {
        EngineConfig memory c = _percentConfig(buy, sell, 5000, 0);
        c.words[0] = bytes32(uint256(7000) | band << 16 | uint256(600) << 32);
        HedgeFunFactory.Request memory q = _request();
        q.nonce = nonce;
        deployer.setEngineConfig(q.symbol, q.nonce, percentKind, c);
        (,, bytes32 terms) = factory.predict(q);
        vm.expectRevert(V2TreasuryDeployer.TreasuryDeployFailed.selector);
        factory.launch(q, terms);
    }

    /// The cooldown is bits 32..63 of the first word: 60 seconds is the least a creator may choose.
    function test_schemaThreeCooldownFloorIsSixtySeconds() public {
        TradablePercentConfigHarness h = new TradablePercentConfigHarness();
        EngineConfig memory c = _percentConfig(2000, 1000, 500, 0);
        uint256 rest = uint256(c.words[0]) & ~(uint256(type(uint32).max) << 32);
        uint32[3] memory refused = [uint32(0), 1, 59];
        for (uint256 i; i < refused.length; ++i) {
            c.words[0] = bytes32(rest | uint256(refused[i]) << 32);
            assertFalse(h.valid(c.words));
        }
        uint32[3] memory accepted = [uint32(60), 600, 86_400];
        for (uint256 i; i < accepted.length; ++i) {
            c.words[0] = bytes32(rest | uint256(accepted[i]) << 32);
            assertTrue(h.valid(c.words));
        }
    }

    function test_schemaThreeValidationRejectsReservedBitsAndInvalidPercentages() public {
        TradablePercentConfigHarness h = new TradablePercentConfigHarness();
        EngineConfig memory c = _percentConfig(2000, 1000, 500, 0);
        assertTrue(h.valid(c.words), "daily uses a different denominator and may be smaller than action bps");
        c.words[1] |= bytes32(uint256(1) << 32);
        assertFalse(h.valid(c.words));
        c = _percentConfig(0, 1000, 5000, 0);
        assertFalse(h.valid(c.words));
        c = _percentConfig(10001, 1000, 5000, 0);
        assertFalse(h.valid(c.words));
        c = _percentConfig(2500, 2500, 10_000, 0);
        assertTrue(h.valid(c.words), "a quarter per action is the ceiling, and daily may still be everything");
        c = _percentConfig(2501, 1000, 5000, 0);
        assertFalse(h.valid(c.words), "one action may not take more than a quarter of the cash");
        c = _percentConfig(2000, 2501, 5000, 0);
        assertFalse(h.valid(c.words), "one action may not take more than a quarter of the stock");
        c = _percentConfig(2000, 0, 5000, 0);
        assertFalse(h.valid(c.words));
        c = _percentConfig(2000, 10001, 5000, 0);
        assertFalse(h.valid(c.words));
        c = _percentConfig(2000, 1000, 0, 0);
        assertFalse(h.valid(c.words));
        c = _percentConfig(2000, 1000, 10001, 0);
        assertFalse(h.valid(c.words));
        c = _percentConfig(2000, 1000, 5000, 0);
        c.words[0] |= bytes32(uint256(1) << 80);
        assertFalse(h.valid(c.words));
    }

    function testFuzz_upgradeAfterPartialFillPreservesAllRiskAndAccounting(uint16 rawFill, uint16 rawPrice) public {
        HedgeFunV2TradablePercentEngineTreasuryCore t = _launchPercent(2006, 2000, 1000, 5000, 5000);
        HedgeFunV2TradablePercentEngineTreasuryLogic next = _replacement(t);
        vm.prank(owner);
        controller.schedule(address(t), address(next), "");
        _advance(2 days);
        _price(bound(rawPrice, 110, 200) * 1e18);
        venue.setFillBps(uint16(bound(rawFill, 1000, 10_000)));
        t.execute();
        assertGt(t.buybackStock(), 0);
        bytes32 before_ = _upgradeDigest(t);
        controller.execute(address(t), "");
        assertEq(_upgradeDigest(t), before_);
        assertEq(t.bookedStock() + t.buybackStock(), stock.balanceOf(address(t)));
    }
}
