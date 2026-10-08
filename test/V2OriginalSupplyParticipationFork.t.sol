// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {V2LiquidityVault} from "../src/v2/V2LiquidityVault.sol";
import {HedgeFunHook} from "../src/hooks/HedgeFunHook.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2TradeRouter as Router} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TestnetMarket} from "../script/testnet/TestnetMarket.sol";
import {V2CapitalSimulationForkTest} from "./V2CapitalSimulationFork.t.sol";

/// Extends the prior fork with ORIGINAL-supply ownership, independent outside holders,
/// real testnet V3 market/feed moves and real kind-0 treasury execute/buyback calls.
/// Only local fork owner impersonation tightens listing gates; no deployment changes.
contract V2OriginalSupplyParticipationForkTest is V2CapitalSimulationForkTest {
    using PoolIdLibrary for PoolKey;
    TestnetMarket constant MARKET = TestnetMarket(0xc1AF2f52980F8A7AA4E90A8E30D5c3FaF0375f21);
    address constant KEEPER = address(0xCA300);
    uint256 constant OUTSIDERS = 10;
    uint256 private pricingFork;
    uint160 private initialPricingSqrt;
    uint256 private outsideIn;
    uint256 private outsideOut;
    uint256 private strategyProfitStock;
    uint256 private strategyBuybackSpent;
    uint256 internal strategyBurned;
    uint256 private strategyActions;
    bool internal onePercentRule;
    bool private openingBundle;
    HedgeFunV2Treasury internal treasury;

    function setUp() public override {
        super.setUp();
        pricingFork = vm.createFork("https://rpc.testnet.chain.robinhood.com", forkBlock);
        initialPricingSqrt = _poolSqrt();
    }

    function _ruleRequest(HedgeFunFactory.Request memory q)
        internal
        view
        override
        returns (HedgeFunFactory.Request memory)
    {
        if (onePercentRule) {
            q.tp1Bps = 100;
            q.tp2Bps = 0;
            q.dipBps = 100;
            q.stopBps = 0;
        }
        return q;
    }

    function _outsideHeld() private view returns (uint256 total) {
        for (uint256 i; i < OUTSIDERS; ++i) {
            total += token.balanceOf(_wallet(N + i));
        }
    }

    function _measure() internal virtual override returns (Measurement memory m) {
        m.spend = spent;
        m.fdvBeforeSweep = _fdv();
        m.supplyBeforeSweep = token.totalSupply();
        HedgeFunHook hook = FACTORY.hook();
        vm.prank(SWEEPER);
        hook.sweep(key.toId());
        (uint256 tax,) = hook.accrued(key.toId());
        assertEq(tax, 0);
        m.supply = token.totalSupply();
        m.held = _held();
        m.fdv = _fdv();
        assertEq(
            m.supply,
            m.held + _outsideHeld() + token.balanceOf(address(FACTORY.poolManager())) + token.balanceOf(SWEEPER)
                + token.balanceOf(KEEPER),
            "all surviving strategy tokens accounted"
        );
    }

    function _fundingCost(uint256 amount) internal override returns (uint256 cost) {
        if (amount == 0) return 0;
        uint256 tradingFork = vm.activeFork();
        vm.selectFork(pricingFork);
        assertEq(_poolSqrt(), initialPricingSqrt, "pricing fork must remain initial");
        cost = super._fundingCost(amount);
        vm.selectFork(tradingFork);
    }

    function _poolSqrt() private view returns (uint160 value) {
        (value,,,,,,) = FUNDING_POOL.slot0();
    }

    function _outsideBuy(uint256 who, uint256 amount, uint8 stage) private {
        uint256 operatorSpent = spent;
        _buy(N + who, amount, stage);
        outsideIn += spent - operatorSpent;
        spent = operatorSpent;
    }

    function _outsideTokens(uint256 wanted) private {
        for (uint256 i; i < OUTSIDERS; ++i) {
            uint256 goal = wanted / OUTSIDERS;
            // Solve the actual recipient-aware curve quote; no assumed AMM allocation.
            uint256 lo;
            uint256 hi = curve.terminalStock() - curve.virtualStock() - curve.realStockReserve();
            while (hi - lo > 1) {
                uint256 mid = (hi + lo) / 2;
                (, uint256 out,) = curve.quoteBuyFor(mid, _wallet(N + i));
                if (out >= goal) hi = mid;
                else lo = mid;
            }
            (uint256 canonical, uint256 out,) = curve.quoteBuyFor(hi, _wallet(N + i));
            assertGe(out, goal);
            _outsideBuy(i, canonical, 0);
        }
    }

    function _start(uint16 sale, bool strategy, uint256 earlyOutsideBps) private {
        onePercentRule = strategy;
        if (strategy) {
            address factoryOwner = FACTORY.owner();
            // Current 100-bps slippage + 30-bps V3 fee implies >=260-bps triggers.
            // Counterfactual listing: deviation 5 bps, slippage 10 bps, existing chunk unchanged.
            vm.prank(factoryOwner);
            FACTORY.setListingGates(address(STOCK), 5, 10, 0);
        }
        _launch(sale, openingBundle ? 32 : 0, 300);
        treasury = HedgeFunV2Treasury(curve.treasury());
        for (uint256 i; i < OUTSIDERS; ++i) {
            deal(address(STOCK), _wallet(N + i), 1_000_000e18);
            vm.prank(_wallet(N + i));
            STOCK.approve(address(ROUTER), type(uint256).max);
        }
        if (!openingBundle) vm.warp(block.timestamp + curve.snipeSeconds());
        uint256 fullRaise = curve.terminalStock() - curve.virtualStock();
        uint256 each = fullRaise / N;
        for (uint256 i; i < N / 4; ++i) {
            _buy(i, each, 0);
        }
        if (earlyOutsideBps != 0) _outsideTokens(initialSupply * earlyOutsideBps / 10_000);
        uint256 rest = curve.terminalStock() - curve.virtualStock() - curve.realStockReserve();
        each = rest / (N - N / 4);
        for (uint256 i = N / 4; i < N; ++i) {
            uint256 amount = i + 1 == N ? curve.terminalStock() - curve.virtualStock() - curve.realStockReserve() : each;
            _buy(i, amount, 0);
        }
        assertEq(uint256(curve.status()), 2);
        assertEq(spent + outsideIn, fullRaise);
        if (strategy) {
            HedgeFunTreasuryBase.Params memory p = treasury.params();
            assertEq(p.tp1Bps, 100);
            assertEq(p.dipBps, 100);
            assertEq(p.maxSlippageBps, 10);
            assertEq(p.maxDeviationBps, 5);
            assertEq(p.stopBps, 0);
            assertGt(treasury.bookedStock(), 0, "graduation stock must be booked");
        }
        _measure();
    }

    function _target(bool ownership, uint256 fdvGoal) private returns (bool) {
        Measurement memory m = _measure();
        return ownership ? m.held * 100 >= initialSupply * 80 : m.fdv >= fdvGoal;
    }

    function _reachOriginal(bool ownership, uint256 fdvGoal) internal returns (Measurement memory) {
        if (_target(ownership, fdvGoal)) return _measure();
        // If all other held/burned inventory already leaves <80% original, no amount can succeed.
        if (ownership) {
            assertGe(
                token.totalSupply() - _outsideHeld() - token.balanceOf(SWEEPER) - token.balanceOf(KEEPER),
                initialSupply * 80 / 100,
                "original-supply target has insufficient inventory"
            );
        }
        uint256 checkpoint = vm.snapshotState();
        uint256 lo;
        uint256 hi = 1e18;
        while (true) {
            _buy(0, hi, 2);
            bool enough = _target(ownership, fdvGoal);
            assertTrue(vm.revertToState(checkpoint));
            if (enough) break;
            hi *= 2;
            require(hi <= 100_000e18, "target not bracketed");
        }
        while (hi - lo > 1e10) {
            uint256 mid = (hi + lo) / 2;
            _buy(0, mid, 2);
            bool enough = _target(ownership, fdvGoal);
            assertTrue(vm.revertToState(checkpoint));
            if (enough) hi = mid;
            else lo = mid;
        }
        vm.deleteStateSnapshot(checkpoint);
        _buy(0, hi, 2);
        Measurement memory m = _measure();
        assertTrue(ownership ? m.held * 100 >= initialSupply * 80 : m.fdv >= fdvGoal);
        return m;
    }

    function _moveStock(uint256 price) private {
        address operator = MARKET.owner();
        vm.prank(operator);
        MARKET.setPrice(address(FUNDING_POOL), price);
        vm.warp(block.timestamp + 601);
        vm.prank(operator);
        MARKET.poke(address(FUNDING_POOL));
        stockPrice = price;
        (bool healthy, uint256 livePrice) = treasury.health();
        assertTrue(healthy, "oracle, live V3 spot and 600-second mean must agree");
        assertEq(livePrice, price, "FDV uses the actual moved stock oracle reference");
    }

    function _cycle() internal {
        uint256 profitBefore = treasury.buybackStock();
        uint256 lots = treasury.lotCount();
        assertGt(lots, 0, "a completed cycle requires a real stock lot");
        (, uint256 cost,,) = treasury.lots(0);
        uint256 high = Math.ceilDiv(Math.ceilDiv(cost * 101, 100), 1e10) * 1e10;
        _moveStock(high);
        uint256 attempts;
        while (treasury.lotCount() != 0) {
            require(attempts++ < 128, "profit chunks must finish");
            vm.prank(KEEPER);
            (HedgeFunV2Treasury.Action action,) = treasury.execute();
            assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
            ++strategyActions;
            // Model external arbitrage restoring the moved stock's price, with actual swaps.
            _moveStock(high);
        }
        strategyProfitStock += treasury.buybackStock() - profitBefore;
        uint256 low = treasury.lastSalePrice() * 99 / 100 / 1e10 * 1e10;
        _moveStock(low);
        vm.prank(KEEPER);
        (HedgeFunV2Treasury.Action dip,) = treasury.execute();
        assertEq(uint256(dip), uint256(HedgeFunV2Treasury.Action.BuyDip));
        ++strategyActions;
        // LP stock fees also fund the token buyback; record them separately from TP profit.
        V2LiquidityVault(treasury.liquidityVault()).collectFees();
        vm.warp(block.timestamp + 61);
        vm.prank(KEEPER);
        (uint256 used, uint256 burned) = treasury.buyback();
        assertGt(used, 0);
        assertGt(burned, 0);
        strategyBuybackSpent += used;
        strategyBurned += burned;
        _measure();
    }

    function _lateOutside(uint256 referenceUsd) private {
        uint256 amount = referenceUsd * 1e36 / 358e18 / OUTSIDERS;
        for (uint256 i; i < OUTSIDERS; ++i) {
            _outsideBuy(i, amount, 2);
        }
        _measure();
    }

    function _outsideSell(uint256 fractionBps) private {
        for (uint256 i; i < OUTSIDERS; ++i) {
            uint256 amount = token.balanceOf(_wallet(N + i)) * fractionBps / 10_000;
            if (amount == 0) continue;
            vm.prank(_wallet(N + i));
            token.approve(address(ROUTER), amount);
            // Use the deployed router's graduated stock exit, with actual sell taxes and fees.
            Router.TradeParams memory p =
                Router.TradeParams(id, address(STOCK), amount, 0, 1, block.timestamp, 2, false);
            vm.prank(_wallet(N + i));
            (uint256 got, uint256 refund) = ROUTER.sell(p, new Router.Hop[](0));
            assertEq(refund, 0);
            outsideOut += got;
        }
        _measure();
    }

    function _row(string memory name, uint16 sale, uint256 earlyBps, uint256 lateUsd, uint256 cycles, uint256 sellBps)
        private
    {
        _start(sale, cycles != 0, earlyBps);
        for (uint256 i; i < cycles; ++i) {
            _cycle();
        }
        uint256 openingHeldAt2m;
        if (openingBundle && sale == 8000) {
            uint256 checkpoint = vm.snapshotState();
            Measurement memory twoMillion = _reachOriginal(false, TARGET_FDV);
            openingHeldAt2m = twoMillion.held;
            assertLt(openingHeldAt2m, initialSupply * 80 / 100);
            assertTrue(vm.revertToState(checkpoint));
            vm.deleteStateSnapshot(checkpoint);
        }
        Measurement memory original80 = _reachOriginal(true, 0);
        if (lateUsd != 0) _lateOutside(lateUsd);
        if (sellBps != 0) {
            _reachOriginal(false, 1_000_000e18);
            _outsideSell(sellBps);
        }
        Measurement memory finalM = _reachOriginal(false, TARGET_FDV);
        assertGe(finalM.held * 100, initialSupply * 80);
        vm.serializeString(name, "scenario", name);
        vm.serializeUint(name, "forkBlock", forkBlock);
        vm.serializeUint(name, "forkTimestamp", forkTimestamp);
        vm.serializeBytes32(name, "forkParentHash", forkHash);
        vm.serializeUint(name, "saleBps", sale);
        vm.serializeBool(name, "openingBundle", openingBundle);
        vm.serializeUint(name, "openingExemptions", openingBundle ? 32 : 0);
        vm.serializeUint(name, "cycles", cycles);
        vm.serializeUint(name, "earlyOutsideOriginalBps", earlyBps);
        vm.serializeUint(name, "lateOutsideReferenceUsd", lateUsd);
        vm.serializeUint(name, "outsideSaleFractionBps", sellBps);
        vm.serializeUint(name, "initialSupplyRaw", initialSupply);
        vm.serializeUint(name, "operatorHeldRaw", finalM.held);
        vm.serializeUint(name, "openingHeldAt2mRaw", openingHeldAt2m);
        vm.serializeBool(name, "overshot2mForOriginal80", original80.fdv > TARGET_FDV + 1e18);
        vm.serializeUint(name, "heldOriginalBps", finalM.held * 10_000 / initialSupply);
        vm.serializeUint(name, "heldSurvivingBps", finalM.held * 10_000 / finalM.supply);
        vm.serializeUint(name, "outsideHeldRaw", _outsideHeld());
        vm.serializeUint(name, "operatorStockInRaw", spent);
        vm.serializeUint(name, "outsideStockInRaw", outsideIn);
        vm.serializeUint(name, "outsideStockOutRaw", outsideOut);
        vm.serializeUint(name, "strategyProfitStockRaw", strategyProfitStock);
        vm.serializeUint(name, "strategyBuybackStockRaw", strategyBuybackSpent);
        vm.serializeUint(name, "strategyBurnedRaw", strategyBurned);
        vm.serializeUint(name, "strategyActions", strategyActions);
        vm.serializeUint(name, "strategyCashUsdgRaw", treasury.reserveUsdg());
        vm.serializeUint(name, "strategyBookedStockRaw", treasury.bookedStock());
        vm.serializeUint(name, "strategyBuybackPendingStockRaw", treasury.buybackStock());
        vm.serializeUint(name, "finalStockPriceE18", stockPrice);
        vm.serializeUint(name, "stockAtOriginal80Raw", original80.spend);
        vm.serializeUint(name, "fdvAtOriginal80E18", original80.fdv);
        vm.serializeUint(name, "operatorInitialV3UsdgRaw", _fundingCost(spent) + launchFee);
        vm.serializeUint(name, "outsideInitialV3UsdgRaw", _fundingCost(outsideIn));
        vm.serializeUint(name, "combinedInitialV3UsdgRaw", _fundingCost(spent + outsideIn) + launchFee);
        vm.serializeUint(name, "finalSupplyRaw", finalM.supply);
        vm.serializeUint(name, "finalInitialSupplyFdvE18", Math.mulDiv(finalM.fdv, initialSupply, finalM.supply));
        string memory json = vm.serializeUint(name, "finalFdvE18", finalM.fdv);
        console2.log("PARTICIPATION_RESULT", json);
    }

    function testParticipants_Sale80_Baseline() public {
        _row("sale80_baseline", 8000, 0, 0, 0, 0);
    }

    function testParticipants_Sale80_OneCycle() public {
        _row("sale80_cycle1", 8000, 0, 0, 1, 0);
    }

    function testParticipants_Sale80_TenCycles() public {
        _row("sale80_cycle10", 8000, 0, 0, 10, 0);
    }

    function testParticipants_Sale80_LateBuy5000() public {
        _row("sale80_late5000_cycle1", 8000, 0, 5000, 1, 0);
    }

    function testParticipants_Sale80_LateBuy20000() public {
        _row("sale80_late20000_cycle1", 8000, 0, 20000, 1, 0);
    }

    function testParticipants_Sale80_Early1Percent() public {
        _row("sale80_early1_cycle1", 8000, 100, 0, 1, 0);
    }

    function testParticipants_Sale80_Early2Percent() public {
        _row("sale80_early2_cycle1", 8000, 200, 0, 1, 0);
    }

    function testParticipants_Sale80_Early1PercentHalfExit() public {
        _row("sale80_early1_halfexit_cycle1", 8000, 100, 0, 1, 5000);
    }

    function testParticipants_Sale80_Early3Percent() public {
        _row("sale80_early3_cycle1", 8000, 300, 0, 1, 0);
    }

    function testParticipants_Sale90_Early5Percent() public {
        _row("sale90_early5_cycle1", 9000, 500, 0, 1, 0);
    }

    function testParticipants_Sale90_Early8Percent() public {
        _row("sale90_early8_cycle1", 9000, 800, 0, 1, 0);
    }

    function testParticipants_Sale80_Opening32OneCycle() public {
        openingBundle = true;
        _row("sale80_opening32_cycle1", 8000, 0, 0, 1, 0);
    }

    function testParticipants_Sale90_Opening32OneCycle() public {
        openingBundle = true;
        _row("sale90_opening32_cycle1", 9000, 0, 0, 1, 0);
    }

    function testParticipants_Sale90_Opening32Late5000() public {
        openingBundle = true;
        _row("sale90_opening32_late5000_cycle1", 9000, 0, 5000, 1, 0);
    }

    function launchWithCurrentGates() external {
        require(msg.sender == address(this), "test self-call only");
        onePercentRule = true;
        _launch(8000, 0, 300);
    }

    function testConstraint_DefaultGatesRejectOnePercent() public {
        // The deployed CREATE2 deployer wraps the constructor's BadConfig failure.
        vm.expectRevert(bytes4(keccak256("TreasuryDeployFailed()")));
        this.launchWithCurrentGates();
    }

    function testConstraint_DefaultSaleCannotHoldOriginal80() public {
        _start(4400, false, 0);
        // Graduation has already destroyed enough unallocated supply that no holder
        // can ever own 80% of the original mint, even before further tax burns.
        assertLt(token.totalSupply(), initialSupply * 80 / 100);
        assertLt(_held(), initialSupply * 80 / 100);
    }
}
