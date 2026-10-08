// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HedgeFunV2CycleTreasury} from "../src/v2/HedgeFunV2CycleTreasury.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {PoolTrader} from "../src/PoolTrader.sol";
import {SwitchableCalendar} from "./mocks/Mocks.sol";
import {V2ExecuteBase} from "./V2Execute.t.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// These tests use real concentrated-liquidity fills through the shared V3-ABI mirror, in both asset orders.
/// The inherited scheduler tests also run against this kind, pinning the original stop/profit/dip behavior.
abstract contract V2CycleBase is V2ExecuteBase {
    HedgeFunV2CycleTreasury cycle;

    function setUp() public virtual override {
        super.setUp();
        _useOriginalParams();
    }

    /// @dev The two convenience views, through hooks: the upgradeable logic has no room for them, and its suite
    ///      answers the same questions another way.
    function _pending() internal virtual returns (bool) { return cycle.reentryPending(); }
    function _due() internal virtual returns (bool) { return cycle.recoveryDue(); }

    function _cycleParams() internal pure returns (HedgeFunTreasuryBase.Params memory p) {
        p = _params(500);
        p.tp2Bps = 0;
        p.sellChunkUsdg = 2000e6;
    }

    function _deployCycle(HedgeFunTreasuryBase.Params memory p) internal virtual {
        cycle = new HedgeFunV2CycleTreasury(
            address(usdg),
            address(stock),
            address(mirror),
            address(oracle),
            address(token),
            address(pm),
            address(this),
            p
        );
        treasury = cycle;
        cycle.wire(_tokenKey());
    }

    // Inherited cases expect the shipped two-level TP and 20-USDG chunk. Set those for their fixture.
    function _useOriginalParams() internal {
        HedgeFunTreasuryBase.Params memory p = _params(500);
        p.sellChunkUsdg = 20e6;
        _deployCycle(p);
    }

    function _profitSale() internal returns (uint256 at) {
        HedgeFunTreasuryBase.Params memory p = cycle.params();
        p.tp2Bps = 0;
        _deployCycle(p);
        _fundAndBook(0.1 ether);
        usdg.mint(address(cycle), 100e6);
        _px(106e18);
        (HedgeFunV2Treasury.Action action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        assertEq(cycle.lotCount(), 0);
        assertTrue(_pending());
        assertEq(cycle.reentrySalePrice(), 106e18);
        at = cycle.reentrySaleAt();
    }

    function test_cycleRequiresSaleBeforeRecoveryAndUsesNoInitialRiseEntry() public {
        HedgeFunTreasuryBase.Params memory p = _cycleParams();
        p.tp1Bps = 10000;
        _deployCycle(p);
        _fundAndBook(0.1 ether);
        usdg.mint(address(cycle), 100e6);
        vm.warp(block.timestamp + 601);
        _px(106e18);
        assertFalse(_pending());
        assertFalse(_due());
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        cycle.execute();
    }

    function test_recoveryNeedsCooldownNewStockReportAndExactRiseThreshold() public {
        uint256 at = _profitSale();
        vm.warp(at + 599);
        _px(111.3e18);
        assertFalse(_due());
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        cycle.execute();
        vm.warp(at + 600);
        stockFeed.setAt(111.3e8, at);
        assertFalse(_due(), "a changed price with the same stock report time is not a new report");
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        cycle.execute();
        _px(111.299e18);
        assertFalse(_due());
        _px(111.3e18);
        assertTrue(_due());
        (HedgeFunV2Treasury.Action action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.BuyRecovery));
        assertFalse(_pending());
        assertEq(cycle.lotCount(), 1);
    }

    function test_recoveryConsumesOnceAndUsesActualCostWithoutSpendingBuybackStock() public {
        uint256 at = _profitSale();
        uint256 burnStock = cycle.buybackStock();
        assertGt(burnStock, 0);
        vm.warp(at + 601);
        _px(111.3e18);
        uint256 stockBefore = stock.balanceOf(address(cycle));
        uint256 cashBefore = cycle.reserveUsdg();
        uint256 callerBefore = usdg.balanceOf(address(this));
        cycle.execute();
        uint256 spent = cashBefore - cycle.reserveUsdg() - (usdg.balanceOf(address(this)) - callerBefore);
        (uint256 qty, uint256 cost,,) = cycle.lots(0);
        assertEq(qty, stock.balanceOf(address(cycle)) - stockBefore);
        assertEq(cost, spent * SCALE / qty);
        assertEq(cycle.buybackStock(), burnStock);
        assertEq(cycle.reentrySalePrice(), 0);
        assertEq(cycle.reentryStockUpdatedAt(), 0);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        cycle.execute();
        assertEq(cycle.lotCount(), 1, "a repeated keeper call cannot buy a second recovery lot");
    }

    function test_twoFullCyclesRearmOnlyOnLaterActualSale() public {
        _addHigherPriceLiquidity();
        _deployCycle(_cycleParams());
        uint256 at = _profitSale();
        vm.warp(at + 601);
        _px(111.3e18);
        cycle.execute();
        assertFalse(_pending());
        vm.warp(at + 1202);
        _px(120e18);
        (HedgeFunV2Treasury.Action action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        assertEq(cycle.lotCount(), 0);
        assertEq(cycle.reentrySalePrice(), 120e18);
        uint256 secondAt = cycle.reentrySaleAt();
        vm.warp(secondAt + 601);
        _px(126e18);
        (action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.BuyRecovery));
        assertFalse(_pending());
        assertEq(cycle.lotCount(), 1);
    }

    function test_stopCanRecoverUpAfterCooldownInsteadOfOnlyBuyingDeeperDip() public {
        _fundAndBook(0.1 ether);
        usdg.mint(address(cycle), 100e6);
        _px(94e18);
        cycle.execute();
        assertEq(cycle.lotCount(), 0);
        uint256 at = cycle.reentrySaleAt();
        vm.warp(at + 601);
        _px(98.7e18);
        assertTrue(_due());
        (HedgeFunV2Treasury.Action action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.BuyRecovery));
        assertEq(cycle.lastStopAt(), 0);
        assertFalse(_pending());
    }

    function test_dueProfitStillWinsOverAnEligibleRecovery() public {
        _fundAndBook(0.2 ether);
        usdg.mint(address(cycle), 100e6);
        _px(106e18); // TP1 leaves half the lot for TP2
        cycle.execute();
        uint256 at = cycle.reentrySaleAt();
        assertTrue(_pending());
        vm.warp(at + 601);
        _px(112e18);
        assertTrue(_due(), "the signal alone is deliberately not an execution preview");
        (HedgeFunV2Treasury.Action action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        assertEq(cycle.lotCount(), 0);
        assertTrue(_pending());
        assertEq(cycle.reentrySalePrice(), 112e18, "the real TP refreshes the waiting reference");
    }

    function test_originalDipLadderStillWorksAfterRecoveryIsConsumed() public {
        HedgeFunTreasuryBase.Params memory p = _cycleParams();
        p.stopBps = 0;
        _deployCycle(p);
        uint256 at = _profitSale();
        vm.warp(at + 601);
        _px(111.3e18);
        cycle.execute();
        assertFalse(_pending());
        _px(105.735e18);
        (HedgeFunV2Treasury.Action action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.BuyDip));
        assertEq(cycle.lotCount(), 2);
        assertFalse(_pending(), "an ordinary later rung cannot arm recovery");
    }

    function test_forgedSwapCallbackCannotSpendTreasury() public {
        _profitSale();
        uint256 cash = cycle.reserveUsdg();
        vm.expectRevert(PoolTrader.NotPool.selector);
        cycle.uniswapV3SwapCallback(10e6, 10e6, "");
        assertEq(cycle.reserveUsdg(), cash);
        assertTrue(_pending());
    }

    function test_originalProfitDipNeedsNoNewCooldownAndConsumesRecovery() public {
        _profitSale();
        _px(100.7e18); // exactly 5% below 106, in the same timestamp as the TP
        (HedgeFunV2Treasury.Action action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.BuyDip));
        assertFalse(_pending());
    }

    function test_recoveryBudgetUsesBothCashFractionAndSellChunk() public {
        HedgeFunTreasuryBase.Params memory p = _cycleParams();
        p.sellChunkUsdg = 20e6;
        _deployCycle(p);
        uint256 at = _profitSale();
        usdg.mint(address(cycle), 10000e6);
        vm.warp(at + 601);
        _px(111.3e18);
        uint256 cash = cycle.reserveUsdg();
        cycle.execute();
        assertLe(cash - cycle.reserveUsdg(), 20e6, "the recovery must not spend the uncapped cash fraction");
        assertGt(cash - cycle.reserveUsdg(), 19e6);
    }

    function test_noCashAndZeroFillDoNotConsumePendingOrChangeLedger() public {
        uint256 at = _profitSale();
        vm.warp(at + 601);
        _px(111.3e18);
        uint256 cash = cycle.reserveUsdg();
        deal(address(usdg), address(cycle), 0);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        cycle.execute();
        assertEq(cycle.reentrySaleAt(), at);
        assertTrue(_pending());
        deal(address(usdg), address(cycle), cash);
        vm.mockCall(
            address(mirror),
            abi.encodeWithSignature("swap(address,bool,int256,uint160,bytes)"),
            abi.encode(int256(0), int256(0))
        );
        vm.expectRevert(PoolTrader.Slippage.selector);
        cycle.execute();
        assertEq(cycle.reserveUsdg(), cash);
        assertEq(cycle.bookedStock(), 0);
        assertEq(cycle.lotCount(), 0);
        assertEq(cycle.reentrySaleAt(), at);
        vm.clearMockedCalls();
        cycle.execute();
        assertFalse(_pending(), "a later actual fill can still use the pending entry");
    }

    function _thinLiquidity(uint256 remaining) internal {
        int24 tick = TickMath.getTickAtSqrtPrice(_sqrtFor(100e18));
        lpRouter.modifyLiquidity(
            stockKey,
            ModifyLiquidityParams({
                tickLower: ((tick - 1800) / SPACING) * SPACING,
                tickUpper: ((tick + 1800) / SPACING) * SPACING,
                liquidityDelta: -int256(1e18 - remaining),
                salt: 0
            }),
            ""
        );
    }

    function _addHigherPriceLiquidity() internal {
        int24 tick = TickMath.getTickAtSqrtPrice(_sqrtFor(126e18));
        lpRouter.modifyLiquidity(
            stockKey,
            ModifyLiquidityParams({
                tickLower: ((tick - 1800) / SPACING) * SPACING,
                tickUpper: ((tick + 1800) / SPACING) * SPACING,
                liquidityDelta: 1e18,
                salt: bytes32("cycle-higher-prices")
            }),
            ""
        );
    }

    function test_realPartialRecoveryConsumesOneEntryAndBooksOnlyActualFill() public {
        uint256 at = _profitSale();
        vm.warp(at + 601);
        _px(111.3e18);
        _thinLiquidity(2e14);
        uint256 cash = cycle.reserveUsdg();
        uint256 bounty = usdg.balanceOf(address(this));
        cycle.execute();
        uint256 spent = cash - cycle.reserveUsdg() - (usdg.balanceOf(address(this)) - bounty);
        assertGt(spent, 5e6);
        assertLt(spent, cash * 2000 / 10000, "the concentrated pool should fill short at the price limit");
        (uint256 qty, uint256 cost,,) = cycle.lots(0);
        assertEq(cost, spent * SCALE / qty);
        assertFalse(_pending());
    }

    function test_realDustRecoveryRollsBackPoolTransfersAndState() public {
        uint256 at = _profitSale();
        vm.warp(at + 601);
        _px(111.3e18);
        _thinLiquidity(1e12);
        uint256 cash = cycle.reserveUsdg();
        uint256 poolCash = usdg.balanceOf(address(pm));
        uint256 held = stock.balanceOf(address(cycle));
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        cycle.execute();
        assertEq(cycle.reserveUsdg(), cash);
        assertEq(usdg.balanceOf(address(pm)), poolCash);
        assertEq(stock.balanceOf(address(cycle)), held);
        assertEq(cycle.lotCount(), 0);
        assertEq(cycle.reentrySaleAt(), at);
    }

    function test_subMinimumStopDoesNotArmAndCannotBypassLatestStopGate() public {
        _addHigherPriceLiquidity();
        _fundAndBook(0.1 ether);
        usdg.mint(address(cycle), 100e6);
        _px(94e18);
        cycle.execute();
        uint256 at = cycle.reentrySaleAt();
        vm.warp(at + 601);
        _px(120e18);
        _fundAndBook(0.05 ether); // $6, eligible for booking
        _px(126e18); // TP1's half has only $3 of actual principal, so it cannot renew recovery
        cycle.execute();
        assertEq(cycle.reentrySalePrice(), 94e18);
        assertEq(cycle.reentrySaleAt(), at);
        _px(113e18); // the remaining $2.825 stock stops, renewing only the inherited stop gate
        cycle.execute();
        uint256 stoppedAt = cycle.lastStopAt();
        assertEq(cycle.lotCount(), 0);
        assertEq(cycle.reentrySaleAt(), at);
        assertFalse(_due(), "the old recovery must respect the newer sub-minimum stop");
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        cycle.execute();
        vm.warp(stoppedAt + 600);
        assertFalse(_due(), "the cooldown alone does not replace the newer-report requirement");
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        cycle.execute();
        _px(113e18);
        assertTrue(_due());
        (HedgeFunV2Treasury.Action action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.BuyRecovery));
        assertFalse(_pending());
    }

    function test_subMinimumProfitAfterLaterStopCannotEraseRecoveryCooldownOrReportGate() public {
        _addHigherPriceLiquidity();
        _fundAndBook(0.1 ether);
        usdg.mint(address(cycle), 100e6);
        _px(94e18);
        cycle.execute(); // Qualifying stop opens the old recovery at 94.
        uint256 saleAt = cycle.reentrySaleAt();

        vm.warp(saleAt + 601);
        _px(120e18);
        _fundAndBook(0.05 ether); // $6 booked normally.
        _px(126e18);
        cycle.execute(); // TP1 leaves a $3-cost tail; its principal sale cannot reanchor recovery.
        assertEq(cycle.reentrySalePrice(), 94e18);
        assertEq(cycle.reentrySaleAt(), saleAt);

        vm.warp(block.timestamp + 1);
        _px(100e18);
        _fundAndBook(0.06 ether); // A different, low-cost $6 lot, using only public booking.
        (HedgeFunV2Treasury.Action action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        uint256 stoppedAt = cycle.lastStopAt();
        uint256 stoppedReportAt = cycle.lastStopStockUpdatedAt();
        assertEq(cycle.lotCount(), 1);
        assertEq(cycle.reentrySaleAt(), saleAt, "the $2.50 stop must retain the old recovery anchor");

        // A changed price in the same timestamp is still the same report time as the stop.
        vm.warp(stoppedAt);
        _px(106e18);
        (action,) = cycle.execute(); // Its $3 TP1 principal is also below the recovery minimum.
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        assertEq(cycle.reentrySaleAt(), saleAt);
        assertFalse(_due(), "a small TP1 must not erase the later stop's recovery cooldown");
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        cycle.execute();

        _px(112e18); // Same execution/report time; clear the remaining lot through another small real TP.
        (action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        assertEq(cycle.lotCount(), 0);
        assertEq(cycle.reentrySaleAt(), saleAt);
        assertFalse(_due(), "a small TP2 must not erase the later stop's recovery cooldown");
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        cycle.execute();

        vm.warp(stoppedAt + 599);
        _px(112e18);
        assertFalse(_due(), "a new report cannot bypass the latest stop's full 600 seconds");
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        cycle.execute();
        vm.warp(stoppedAt + 600);
        stockFeed.setAt(112e8, stoppedReportAt);
        assertFalse(_due(), "the old stop report remains insufficient after its cooldown");
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        cycle.execute();
        _px(98.69e18);
        assertFalse(_due(), "a fresh report also needs the independent sale's rise threshold");
        _px(112e18);
        assertTrue(_due());
        (action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.BuyRecovery));
        assertFalse(_pending());
    }

    function test_oneWeiProfitAfterLaterStopCannotEraseRecoveryCooldownOrReportGate() public {
        _addHigherPriceLiquidity();
        // A real chunked stop leaves exactly one wei in a normally booked lot, still before TP1.
        uint256 stopChunk = 20e6 * SCALE / 94e18;
        _fundAndBook(stopChunk + 1);
        usdg.mint(address(cycle), 100e6);
        _px(94e18);
        (HedgeFunV2Treasury.Action action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        (uint256 qty, uint256 cost, bool half,) = cycle.lots(0);
        assertEq(qty, 1);
        assertEq(cost, 100e18);
        assertFalse(half);
        uint256 saleAt = cycle.reentrySaleAt();

        vm.warp(saleAt + 601);
        _px(120e18);
        _fundAndBook(0.042 ether); // Book at $5.04, then make a real sub-minimum stop without retiring the old tail.
        _px(113e18);
        (action,) = cycle.execute(); // Highest-cost lot stops first, below $5, leaving the one-wei lot.
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        uint256 stoppedAt = cycle.lastStopAt();
        uint256 stoppedReportAt = cycle.lastStopStockUpdatedAt();
        assertEq(cycle.reentrySaleAt(), saleAt);
        assertEq(cycle.lotCount(), 1);

        // Exercise the zero-sale branch with neither elapsed time nor a newer report.
        vm.warp(stoppedAt);
        _px(106e18);
        uint256 held = stock.balanceOf(address(cycle));
        uint256 cash = cycle.reserveUsdg();
        uint256 burnStock = cycle.buybackStock();
        (action,) = cycle.execute(); // TP1 has no half-wei to sell: it only marks the lot half=true.
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        (qty,, half,) = cycle.lots(0);
        assertEq(qty, 1);
        assertTrue(half);
        assertEq(stock.balanceOf(address(cycle)), held);
        assertEq(cycle.reserveUsdg(), cash);
        assertEq(cycle.buybackStock(), burnStock);
        assertEq(cycle.reentrySaleAt(), saleAt);
        assertFalse(_due(), "a zero-sale TP1 must not erase the later stop's recovery cooldown");
        _px(112e18); // TP2 is due, while the ordinary 5% dip from the $113 stop is not.
        (action,) = cycle.execute(); // The current scheduler retires the microscopic TP2 tail without a sale.
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        assertEq(cycle.lotCount(), 0);
        assertEq(cycle.reentrySaleAt(), saleAt);
        assertFalse(_due());
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        cycle.execute();

        vm.warp(stoppedAt + 599);
        _px(112e18);
        assertFalse(_due());
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        cycle.execute();
        vm.warp(stoppedAt + 600);
        stockFeed.setAt(112e8, stoppedReportAt);
        assertFalse(_due(), "a zero-sale TP cannot remove the latest stop's newer-report requirement");
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        cycle.execute();
        _px(112e18);
        assertTrue(_due());
        (action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.BuyRecovery));
        assertFalse(_pending());
    }

    function test_smallProfitAfterLaterStopStillAllowsImmediateOriginalDipAndConsumesRecovery() public {
        _addHigherPriceLiquidity();
        _fundAndBook(0.1 ether);
        usdg.mint(address(cycle), 100e6);
        _px(94e18);
        cycle.execute();
        uint256 saleAt = cycle.reentrySaleAt();

        vm.warp(saleAt + 601);
        _px(120e18);
        _fundAndBook(0.05 ether);
        _px(126e18);
        cycle.execute(); // The small TP1 leaves a high-cost tail without refreshing recovery.
        vm.warp(block.timestamp + 1);
        _px(100e18);
        _fundAndBook(0.06 ether);
        (HedgeFunV2Treasury.Action action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        uint256 stoppedAt = cycle.lastStopAt();
        assertEq(cycle.reentrySaleAt(), saleAt);

        _px(106e18);
        (action,) = cycle.execute(); // A real sub-minimum TP still opens the original profit-to-dip rung.
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        assertEq(cycle.lastStopAt(), 0);
        assertFalse(_due(), "the separate recovery gate still remembers the latest stop");
        assertTrue(_pending());

        uint256 cashBefore = cycle.reserveUsdg();
        uint256 stockBefore = stock.balanceOf(address(cycle));
        _px(100.7e18); // Exactly 5% below the actual TP, with no elapsed time after the stop or TP.
        (action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.BuyDip));
        assertEq(block.timestamp, stoppedAt, "the original dip must not inherit recovery's 600-second delay");
        assertGt(stock.balanceOf(address(cycle)), stockBefore);
        assertLt(cycle.reserveUsdg(), cashBefore);
        assertFalse(_pending(), "a successful original dip consumes the old recovery entry");
        assertEq(cycle.reentrySalePrice(), 0);
        assertEq(cycle.reentryStockUpdatedAt(), 0);
    }

    function test_closedProfitCancelsOldRecoveryAndClosedRecoveryCannotBuy() public {
        SwitchableCalendar calendar = new SwitchableCalendar();
        oracle = new PriceOracle(
            address(stock), address(stockFeed), address(usdgFeed), address(calendar), 26 hours, 26 hours
        );
        HedgeFunTreasuryBase.Params memory p = _cycleParams();
        p.bandBpsPerHour = 200;
        _deployCycle(p);
        uint256 at = _profitSale();
        vm.warp(at + 601);
        _px(100e18);
        _fundAndBook(0.1 ether);
        _px(106e18);
        calendar.setClosed(true);
        assertFalse(_due());
        (HedgeFunV2Treasury.Action action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        assertFalse(_pending(), "a closure sale cannot reuse an older live anchor");
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        cycle.execute();
    }

    function test_pausedOrStaleReportCannotRecoverAndPendingSurvives() public {
        uint256 at = _profitSale();
        vm.warp(at + 601);
        _px(111.3e18);
        stock.setOraclePaused(true);
        assertFalse(_due());
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        cycle.execute();
        assertEq(cycle.reentrySaleAt(), at);
        stock.setOraclePaused(false);
        stockFeed.setAt(111.3e8, block.timestamp - 27 hours);
        assertFalse(_due());
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        cycle.execute();
        assertEq(cycle.reentrySaleAt(), at);
    }
}

contract V2CycleStock0Test is V2CycleBase {
    function stockIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract V2CycleStock1Test is V2CycleBase {
    function stockIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

contract V2CycleKindTest is V2FactoryFixture {
    function _kindCodeHash(V2TreasuryDeployer deployer) private view returns (bytes32) {
        (address a, address b) = deployer.kinds(0);
        return keccak256(abi.encode(a, b));
    }

    function test_newKindUsesExistingConstructorLaunchAndGraduationWithoutChangingKindZero() public {
        _setUpV2(18);
        V2TreasuryDeployer deployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        bytes32 originalCode = _kindCodeHash(deployer);
        uint8 kind;
        {
            (address a, address b) = deployer.makeChunks(type(HedgeFunV2CycleTreasury).creationCode);
            vm.prank(owner);
            kind = deployer.registerKind(a, b);
        }
        HedgeFunFactory.Request memory request = _request();
        address predicted;
        bytes32 terms;
        {
            (, address oldAddress, bytes32 oldTerms) = factory.predict(request);
            deployer.setStrategyKind(request.symbol, request.nonce, kind);
            (, predicted, terms) = factory.predict(request);
            assertTrue(predicted != oldAddress);
            vm.expectRevert(HedgeFunFactory.Restated.selector);
            factory.launch(request, oldTerms);
        }
        uint256 id = factory.launch(request, terms);
        (, address created,,,) = factory.strategies(id);
        assertEq(created, predicted);
        assertFalse(HedgeFunV2CycleTreasury(created).reentryPending());
        assertEq(HedgeFunV2CycleTreasury(created).params().dipBps, request.dipBps);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        stock.approve(address(curve), type(uint256).max);
        _graduateV2(curve);
        assertTrue(HedgeFunV2CycleTreasury(created).hook() != address(0));
        assertEq(_kindCodeHash(deployer), originalCode);
        assertLe(created.code.length, deployer.MAX_RUNTIME_CODE_SIZE());
    }
}
