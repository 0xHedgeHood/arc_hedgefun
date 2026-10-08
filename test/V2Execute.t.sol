// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunV2AllInTreasury} from "../src/v2/HedgeFunV2AllInTreasury.sol";
import {PoolTrader} from "../src/PoolTrader.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {MockToken, MockFeed, AlwaysOpen, SwitchableCalendar} from "./mocks/Mocks.sol";
import {MirrorV3Pool, NoopHook} from "./InteractVenueParity.t.sol";

/// The V2 scheduler runs against the same real concentrated-liquidity mirror as the V1 unit suite.
abstract contract V2ExecuteBase is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 constant SCALE = 1e18 * 1e18 / 1e6;
    uint24 constant FEE = 3000;
    int24 constant SPACING = 60;
    IPoolManager pm;
    MockToken usdg;
    MockToken stock;
    HedgeFunToken token;
    MockFeed stockFeed;
    MockFeed usdgFeed;
    PriceOracle oracle;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    PoolKey stockKey;
    MirrorV3Pool mirror;
    HedgeFunV2Treasury treasury;

    function stockIsCurrency0() internal pure virtual returns (bool);

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        pm = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(pm);
        lpRouter = new PoolModifyLiquidityTest(pm);
        usdg = new MockToken("USDG", 6);
        stock = _mineStock();
        token = new HedgeFunToken("Strategy", "STR", 1_000_000_000e18, address(this), address(0));
        stockFeed = new MockFeed(8);
        usdgFeed = new MockFeed(8);
        usdgFeed.set(1e8);
        stockFeed.set(100e8);
        oracle = new PriceOracle(address(stock), address(stockFeed), address(usdgFeed), address(new AlwaysOpen()), 26 hours, 26 hours);
        (Currency s0, Currency s1) = stockIsCurrency0()
            ? (Currency.wrap(address(stock)), Currency.wrap(address(usdg)))
            : (Currency.wrap(address(usdg)), Currency.wrap(address(stock)));
        stockKey = PoolKey(s0, s1, FEE, SPACING, IHooks(address(0)));
        pm.initialize(stockKey, _sqrtFor(100e18));
        usdg.mint(address(this), 1e18 * 1e6);
        stock.mint(address(this), 1e12 ether);
        usdg.approve(address(lpRouter), type(uint256).max);
        stock.approve(address(lpRouter), type(uint256).max);
        usdg.approve(address(swapRouter), type(uint256).max);
        stock.approve(address(swapRouter), type(uint256).max);
        (, int24 tick,,) = pm.getSlot0(stockKey.toId());
        int24 lo = ((tick - 1800) / SPACING) * SPACING;
        int24 hi = ((tick + 1800) / SPACING) * SPACING;
        lpRouter.modifyLiquidity(stockKey, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: 1e18, salt: 0}), "");
        mirror = new MirrorV3Pool(pm, stockKey);
        HedgeFunTreasuryBase.Params memory p = _params(500);
        p.sellChunkUsdg = 20e6;
        treasury = new HedgeFunV2Treasury(address(usdg), address(stock), address(mirror),
            address(oracle), address(token), address(pm), address(this), p);
        // A nonzero hook address is the V2 activation marker. No token-pool swap is made here.
        vm.etch(address(0x40), address(new NoopHook()).code);
        PoolKey memory key = _tokenKey();
        pm.initialize(key, uint160(1 << 96));
        treasury.wire(key);
    }

    function _tokenKey() internal view returns (PoolKey memory) {
        (Currency c0, Currency c1) = address(stock) < address(token)
            ? (Currency.wrap(address(stock)), Currency.wrap(address(token)))
            : (Currency.wrap(address(token)), Currency.wrap(address(stock)));
        return PoolKey(c0, c1, FEE, SPACING, IHooks(address(0x40)));
    }

    function _closureTreasury(uint16 stop) internal returns (SwitchableCalendar cal) {
        cal = new SwitchableCalendar();
        oracle = new PriceOracle(address(stock), address(stockFeed), address(usdgFeed), address(cal), 26 hours, 26 hours);
        HedgeFunTreasuryBase.Params memory p = _params(stop);
        p.bandBpsPerHour = 200;
        treasury = new HedgeFunV2Treasury(address(usdg), address(stock), address(mirror),
            address(oracle), address(token), address(pm), address(this), p);
        treasury.wire(_tokenKey());
    }

    function _mineStock() internal returns (MockToken) {
        bytes32 h = keccak256(abi.encodePacked(type(MockToken).creationCode, abi.encode("STK", uint8(18))));
        for (uint256 i; i < 1000; ++i) {
            if ((vm.computeCreate2Address(bytes32(i), h, address(this)) < address(usdg)) == stockIsCurrency0()) {
                return new MockToken{salt: bytes32(i)}("STK", 18);
            }
        }
        revert("stock address");
    }

    function _params(uint16 stop) internal pure returns (HedgeFunTreasuryBase.Params memory p) {
        p.tp1Bps = 500; p.tp2Bps = 1000; p.dipBps = 500; p.stopBps = stop;
        p.lotBps = 2000; p.bountyBps = 50; p.maxSlippageBps = 100;
        p.maxDeviationBps = 50; p.maxBuybackImpactBps = 300;
        p.buybackCooldown = 60; p.minLotUsdg = 5e6;
        p.buybackChunkUsdg = 500e6; p.sellChunkUsdg = 20e6;
    }

    function _sqrtFor(uint256 p) internal pure returns (uint160) {
        return uint160(Math.sqrt(stockIsCurrency0() ? Math.mulDiv(p, 1 << 192, SCALE) : Math.mulDiv(SCALE, 1 << 192, p)));
    }

    function _px(uint256 p) internal {
        uint160 target = _sqrtFor(p);
        (uint160 cur,,,) = pm.getSlot0(stockKey.toId());
        if (target != cur) {
            swapRouter.swap(stockKey, SwapParams({zeroForOne: target < cur, amountSpecified: -int256(1e30), sqrtPriceLimitX96: target}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        }
        stockFeed.set(int256(p / 1e10));
    }

    function _fundAndBook(uint256 amount) internal {
        stock.mint(address(treasury), amount);
        assertTrue(treasury.book());
    }

    function _v2() internal view returns (HedgeFunV2Treasury) {
        return treasury;
    }

    function test_cannotBypassExecuteThroughOldSelectors() public {
        _fundAndBook(1 ether);
        _px(94e18);
        vm.expectRevert(HedgeFunV2Treasury.UseExecute.selector); treasury.stopLoss(0);
        vm.expectRevert(HedgeFunV2Treasury.UseExecute.selector); treasury.takeProfit(0);
        vm.expectRevert(HedgeFunV2Treasury.UseExecute.selector); treasury.buyDip();
    }

    function test_stopWinsOverProfitAndDip_andShortFillStillBlocksBuy() public {
        _fundAndBook(1 ether); // cost 100
        _px(90e18);
        _fundAndBook(1 ether); // cost 90
        _px(95e18); // first lot stops, second lot takes profit, dip from the first reference is due
        uint256 before = treasury.bookedStock();
        (HedgeFunV2Treasury.Action a, uint256 id) = _v2().execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.Stop));
        assertEq(id, 0);
        assertLt(treasury.bookedStock(), before);
        assertEq(treasury.lotCount(), 2, "the bounded first stop leaves an old-lot remainder");
        assertEq(_v2().lastStopPrice(), 95e18);
        _px(95e18);
        (a, id) = _v2().execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.Stop));
        assertEq(id, 0, "a remaining due stop must beat the other lot's profit and a dip");
    }

    function test_unexecutableStopDustDoesNotBlockLaterStop() public {
        _assertStopDustUnblocks(1);
    }

    function test_minimumOutputRoundingDustDoesNotBlockLaterStop() public {
        // At a value of 2 raw USDG units the pool returns 1, but the minimum
        // output check rounds its required amount up to 2.
        _assertStopDustUnblocks(2);
    }

    function test_widerMinimumOutputRoundingDustDoesNotBlockLaterStop() public {
        _assertStopDustUnblocks(76);
    }

    function test_allInStopDustDoesNotBlockLaterStop() public {
        HedgeFunTreasuryBase.Params memory p = _params(500);
        p.sellChunkUsdg = 20e6;
        treasury = new HedgeFunV2AllInTreasury(address(usdg), address(stock), address(mirror),
            address(oracle), address(token), address(pm), address(this), p);
        treasury.wire(_tokenKey());
        _assertStopDustUnblocks(1);
    }

    function test_stopDustWithoutAnotherDueLotDoesNotClaimASale() public {
        uint256 dust = (SCALE + 90e18 - 1) / 90e18;
        uint256 chunk = Math.mulDiv(20e6, SCALE, 90e18);
        _px(110e18);
        _fundAndBook(chunk + dust);
        _px(90e18);
        treasury.execute();
        _px(90e18);

        uint256 reserveBefore = treasury.reserveUsdg();
        uint256 stockBefore = stock.balanceOf(address(treasury));
        uint256 unbookedBefore = treasury.unbookedStock();
        uint256 salePriceBefore = treasury.lastSalePrice();
        uint256 stopPriceBefore = treasury.lastStopPrice();
        uint256 stopAtBefore = treasury.lastStopAt();
        uint256 stopUpdatedAtBefore = treasury.lastStopStockUpdatedAt();
        uint256 keeperUsdgBefore = usdg.balanceOf(address(this));
        (HedgeFunV2Treasury.Action action, uint256 id) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        assertEq(id, 0);
        assertEq(treasury.lotCount(), 0);
        assertEq(treasury.reserveUsdg(), reserveBefore);
        assertEq(stock.balanceOf(address(treasury)), stockBefore);
        assertEq(treasury.unbookedStock(), unbookedBefore + dust);
        assertEq(treasury.lastSalePrice(), salePriceBefore);
        assertEq(treasury.lastStopPrice(), stopPriceBefore);
        assertEq(treasury.lastStopAt(), stopAtBefore);
        assertEq(treasury.lastStopStockUpdatedAt(), stopUpdatedAtBefore);
        assertEq(usdg.balanceOf(address(this)), keeperUsdgBefore);
    }

    function test_stopDustAndDueDipExecuteInTheSameCall() public {
        uint256 dust = (SCALE + 85e18 - 1) / 85e18;
        uint256 chunk = Math.mulDiv(20e6, SCALE, 90e18);
        _px(110e18);
        _fundAndBook(chunk + dust);
        usdg.mint(address(treasury), 100e6);
        _px(90e18);
        treasury.execute(); // stop sells one chunk and leaves dust
        (uint256 left,,,) = treasury.lots(0);
        assertEq(left, dust);

        vm.warp(block.timestamp + 601);
        _px(85e18); // new oracle report, deeper price and elapsed stop cooldown
        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.BuyDip));
        assertEq(treasury.unbookedStock(), dust);
        assertEq(treasury.lastStopAt(), 0);
        assertEq(treasury.lotCount(), 1);
    }

    function test_rebookingReleasedStopDustDoesNotCountItAsNewStock() public {
        uint256 dust = (SCALE + 90e18 - 1) / 90e18;
        uint256 chunk = Math.mulDiv(20e6, SCALE, 90e18);
        _px(110e18);
        _fundAndBook(chunk + dust);
        _px(90e18);
        treasury.execute(); // sell the economic chunk
        _px(90e18);
        treasury.execute(); // release the unsellable tail
        assertEq(treasury.unbookedStock(), dust);

        uint256 receivedBefore = treasury.totalStockReceived();
        uint256 donation = 0.1 ether;
        stock.mint(address(treasury), donation);
        assertTrue(treasury.book());
        assertEq(treasury.totalStockReceived(), receivedBefore + donation);
        assertEq(treasury.unbookedStock(), 0);
    }

    function test_unexecutableProfitDustDoesNotBlockLaterProfit() public {
        _assertProfitDustUnblocks(false);
    }

    function test_rebookingReleasedProfitDustDoesNotCountItAsNewStock() public {
        HedgeFunTreasuryBase.Params memory p = _params(0);
        p.tp2Bps = 0;
        treasury = new HedgeFunV2Treasury(address(usdg), address(stock), address(mirror),
            address(oracle), address(token), address(pm), address(this), p);
        treasury.wire(_tokenKey());

        uint256 tail = 2 * ((SCALE + 100e18 - 1) / 100e18);
        uint256 chunk = Math.mulDiv(20e6, SCALE, 115e18);
        _fundAndBook(chunk + tail);
        _px(115e18);
        treasury.execute(); // profit sale leaves a microscopic tail
        _px(115e18);
        treasury.execute(); // release tail without another sale
        assertEq(treasury.unbookedStock(), tail);

        uint256 receivedBefore = treasury.totalStockReceived();
        uint256 donation = 0.1 ether;
        stock.mint(address(treasury), donation);
        assertTrue(treasury.book());
        assertEq(treasury.totalStockReceived(), receivedBefore + donation);
        assertEq(treasury.unbookedStock(), 0);
    }

    function test_allInProfitDustDoesNotBlockLaterProfit() public {
        _assertProfitDustUnblocks(true);
    }

    function _assertProfitDustUnblocks(bool allIn) internal {
        HedgeFunTreasuryBase.Params memory p = _params(0);
        p.tp2Bps = 0;
        treasury = allIn
            ? new HedgeFunV2AllInTreasury(address(usdg), address(stock), address(mirror),
                address(oracle), address(token), address(pm), address(this), p)
            : new HedgeFunV2Treasury(address(usdg), address(stock), address(mirror),
                address(oracle), address(token), address(pm), address(this), p);
        treasury.wire(_tokenKey());

        uint256 tail = (SCALE + 100e18 - 1) / 100e18 + 1;
        uint256 chunk = Math.mulDiv(20e6, SCALE, 115e18);
        _fundAndBook(chunk + tail); // cost 100: first priority at the profit trigger
        _px(105e18);
        _fundAndBook(1 ether); // cost 105: also profit-due at 115
        _px(115e18);

        (HedgeFunV2Treasury.Action action, uint256 id) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        assertEq(id, 0);
        (uint256 left,,,) = treasury.lots(0);
        assertEq(left, tail);
        (uint256 victimBefore,,,) = treasury.lots(1);

        _px(115e18);
        (action, id) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        assertEq(id, 0);
        assertEq(treasury.unbookedStock(), tail);
        assertEq(treasury.lotCount(), 1);
        (uint256 victimAfter,,,) = treasury.lots(0);
        assertLt(victimAfter, victimBefore);
    }

    function test_tinyTp1RemainderAdvancesStageWithoutClaimingSale() public {
        HedgeFunTreasuryBase.Params memory p = _params(0);
        p.tp2Bps = 2000;
        treasury = new HedgeFunV2Treasury(address(usdg), address(stock), address(mirror),
            address(oracle), address(token), address(pm), address(this), p);
        treasury.wire(_tokenKey());

        uint256 tail = 2 * ((SCALE + 110e18 - 1) / 110e18);
        uint256 chunk = Math.mulDiv(20e6, SCALE, 110e18);
        _fundAndBook(2 * (chunk + tail));
        _px(110e18);
        treasury.execute(); // TP1 owes the tiny tail after this chunk
        _px(110e18);
        uint256 qtyBefore;
        {
            (uint256 qty,, bool half, uint256 left) = treasury.lots(0);
            qtyBefore = qty;
            assertFalse(half);
            assertEq(left, tail);
        }
        uint256 reserveBefore = treasury.reserveUsdg();
        uint256 stockBefore = stock.balanceOf(address(treasury));
        uint256 salePriceBefore = treasury.lastSalePrice();
        uint256 keeperStockBefore = stock.balanceOf(address(this));

        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        {
            (uint256 qty,, bool half, uint256 left) = treasury.lots(0);
            assertEq(qty, qtyBefore - tail);
            assertTrue(half);
            assertEq(left, 0);
        }
        assertEq(treasury.unbookedStock(), tail);
        assertEq(treasury.reserveUsdg(), reserveBefore);
        assertEq(stock.balanceOf(address(treasury)), stockBefore);
        assertEq(treasury.lastSalePrice(), salePriceBefore);
        assertEq(stock.balanceOf(address(this)), keeperStockBefore);
    }

    function test_stopTailThatReboundsToTp1DoesNotBlockAnotherProfit() public {
        uint256 tail = 3 * ((SCALE + 115e18 - 1) / 115e18);
        uint256 stopChunk = Math.mulDiv(20e6, SCALE, 90e18);
        _fundAndBook(stopChunk + tail); // cost 100
        _px(90e18);
        treasury.execute(); // leave a microscopic tail, then rebound before its next stop
        (uint256 left,,,) = treasury.lots(0);
        assertEq(left, tail);

        _px(105e18);
        _fundAndBook(1 ether); // another lot whose TP1 is due at 115
        _px(115e18);
        uint256 unbookedBefore = treasury.unbookedStock();
        (HedgeFunV2Treasury.Action action, uint256 id) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        assertEq(id, 0);
        assertEq(treasury.unbookedStock(), unbookedBefore + tail);
        assertEq(treasury.lotCount(), 1);
        (uint256 victimAfter,,,) = treasury.lots(0);
        assertLt(victimAfter, 1 ether);
    }

    function test_unrepresentableChunkCannotClaimAStop() public {
        HedgeFunTreasuryBase.Params memory p = _params(500);
        p.sellChunkUsdg = 1; // factory refuses this, but direct construction must not fake a fill
        treasury = new HedgeFunV2Treasury(address(usdg), address(stock), address(mirror),
            address(oracle), address(token), address(pm), address(this), p);
        treasury.wire(_tokenKey());
        _fundAndBook(1 ether);
        _px(90e18);
        uint256 salePrice = treasury.lastSalePrice();
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        treasury.execute();
        assertEq(treasury.bookedStock(), 1 ether);
        assertEq(treasury.lastSalePrice(), salePrice);
        assertEq(treasury.lastStopAt(), 0);
    }

    function test_minimumBookedLotStillExecutesStop() public {
        _fundAndBook(0.05 ether); // $5 at cost 100: exactly the configured booking minimum
        _px(90e18);
        uint256 reserveBefore = treasury.reserveUsdg();
        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        assertEq(treasury.lotCount(), 0);
        assertGt(treasury.reserveUsdg(), reserveBefore);
        assertEq(treasury.unbookedStock(), 0);
    }

    function test_minimumBookedLotStillExecutesTp1() public {
        HedgeFunTreasuryBase.Params memory p = _params(0);
        treasury = new HedgeFunV2Treasury(address(usdg), address(stock), address(mirror),
            address(oracle), address(token), address(pm), address(this), p);
        treasury.wire(_tokenKey());
        _fundAndBook(0.05 ether); // its first half is below the booking minimum, but is a real sale
        _px(106e18);
        uint256 reserveBefore = treasury.reserveUsdg();
        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        (, , bool half, uint256 left) = treasury.lots(0);
        assertTrue(half);
        assertEq(left, 0);
        assertGt(treasury.reserveUsdg(), reserveBefore);
        assertEq(treasury.unbookedStock(), 0);
    }

    function _assertStopDustUnblocks(uint256 rawValue) internal {
        uint256 dust = (rawValue * SCALE + 90e18 - 1) / 90e18;
        assertEq(Math.mulDiv(dust, 90e18, SCALE), rawValue);
        assertLt(Math.mulDiv(Math.mulDiv(dust, 997_000, 1_000_000), 90e18, SCALE), rawValue);
        uint256 chunk = Math.mulDiv(20e6, SCALE, 90e18);

        _px(110e18);
        _fundAndBook(chunk + dust);
        _px(100e18);
        _fundAndBook(1 ether);
        _px(90e18);

        (HedgeFunV2Treasury.Action action, uint256 id) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        assertEq(id, 0);
        (uint256 dustLeft,,,) = treasury.lots(0);
        assertEq(dustLeft, dust);
        (uint256 victimBefore,,,) = treasury.lots(1);

        // The pool is healthy again, while the highest-cost lot still cannot trade.
        _px(90e18);
        uint256 unbookedBefore = treasury.unbookedStock();
        (action, id) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        assertEq(id, 0);
        assertEq(treasury.lotCount(), 1);
        assertEq(treasury.unbookedStock(), unbookedBefore + dust);
        assertEq(stock.balanceOf(address(treasury)),
            treasury.bookedStock() + treasury.buybackStock() + treasury.unbookedStock());

        (uint256 victimAfter,,,) = treasury.lots(0);
        assertLt(victimAfter, victimBefore);
    }

    function test_stopNeedsNewReportCooldownAndDeeperPriceBeforeReentry() public {
        _fundAndBook(0.1 ether);
        usdg.mint(address(treasury), 100e6);
        _px(94e18);
        (HedgeFunV2Treasury.Action a,) = _v2().execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.Stop));
        assertEq(treasury.lotCount(), 0);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector); _v2().execute();
        vm.warp(block.timestamp + 601);
        stockFeed.set(94e8); // new observation, but still the stop price
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector); _v2().execute();
        _px(88e18);
        (a,) = _v2().execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.BuyDip));
        assertEq(treasury.lotCount(), 1);
    }

    /// A stop, then a profit on another lot: the profit is the newer sale, so the dip rung is measured from it
    /// and not from the stop. Before the fix the treasury sat in USDG until price fell dipBps below the STOP.
    function test_profitAfterStopReopensDipAtTheProfitRung() public {
        _fundAndBook(0.1 ether); // cost 100
        _px(90e18);
        _fundAndBook(0.1 ether); // cost 90
        usdg.mint(address(treasury), 100e6);
        _px(95e18);
        (HedgeFunV2Treasury.Action a,) = _v2().execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.Stop));
        assertEq(treasury.lotCount(), 1);
        assertEq(_v2().lastStopPrice(), 95e18);
        _px(100e18); // the second lot's tp1 (94.5) is reached; the first lot is gone
        (a,) = _v2().execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        assertEq(_v2().lastStopAt(), 0, "a later profit retires the stop gate");
        assertEq(treasury.lastSalePrice(), 100e18);
        _px(95e18); // 5% under the profit sale, still ABOVE the stop price: a dip by the rule, never by the old gate
        (a,) = _v2().execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.BuyDip));
    }

    function test_dipAfterStopRetiresTheGateForTheNextRung() public {
        _fundAndBook(0.1 ether);
        usdg.mint(address(treasury), 200e6);
        _px(94e18);
        (HedgeFunV2Treasury.Action a,) = _v2().execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.Stop));
        vm.warp(block.timestamp + 601);
        _px(89e18);
        (a,) = _v2().execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.BuyDip));
        assertEq(_v2().lastStopAt(), 0);
        // The next rung is dipBps under the last BUY, with no cooldown or newer-report demand left. With
        // dipBps == stopBps that rung is also the new lot's stop, and a stop is processed first.
        _px(84.5e18);
        (a,) = _v2().execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.Stop));
        assertEq(_v2().lastStopPrice(), 84.5e18, "the gate is armed again by the new stop");
    }

    function test_tinyStopRejectedBeforeDeployment() public {
        HedgeFunTreasuryBase.Params memory p = _params(1);
        vm.expectRevert(PoolTrader.BadConfig.selector);
        new HedgeFunV2Treasury(address(usdg), address(stock), address(mirror),
            address(oracle), address(token), address(pm), address(this), p);
    }

    function test_closedMarketWithStopConfiguredAllowsProfitButNotDip() public {
        SwitchableCalendar cal = _closureTreasury(500);
        _fundAndBook(1 ether);
        _px(106e18);
        cal.setClosed(true);
        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        _px(94e18);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        treasury.execute(); // stop cannot use a closure-only price, and buy cannot bypass it
        cal.setClosed(false);
        (action,) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
    }

    function test_closedMarketWithoutStopKeepsPoolOnlyDipPolicy() public {
        SwitchableCalendar cal = _closureTreasury(0);
        _fundAndBook(1 ether);
        usdg.mint(address(treasury), 100e6);
        _px(94e18);
        cal.setClosed(true);
        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.BuyDip));
    }

    function test_donatedLotsAtCapacityCoalesceWithoutBlockingBookingOrDip() public {
        HedgeFunTreasuryBase.Params memory p = _params(0);
        treasury = new HedgeFunV2Treasury(address(usdg), address(stock), address(mirror),
            address(oracle), address(token), address(pm), address(this), p);
        treasury.wire(_tokenKey());
        for (uint256 i; i < treasury.MAX_STRATEGY_LOTS(); ++i) _fundAndBook(0.1 ether);
        assertEq(treasury.lotCount(), treasury.MAX_STRATEGY_LOTS());
        uint256 booked = treasury.bookedStock();
        _fundAndBook(0.1 ether); // no arbitrary donor can freeze tax booking at capacity
        assertEq(treasury.lotCount(), treasury.MAX_STRATEGY_LOTS());
        assertEq(treasury.bookedStock(), booked + 0.1 ether);
        usdg.mint(address(treasury), 100e6);
        _px(94e18);
        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.BuyDip));
        assertEq(treasury.lotCount(), treasury.MAX_STRATEGY_LOTS());
        assertEq(treasury.bookedStock(), stock.balanceOf(address(treasury)) - treasury.buybackStock());
    }

    function test_fullBookCannotEraseDistinctCostStopBeforeBuy() public {
        _px(110e18);
        _fundAndBook(0.1 ether);
        _px(100e18);
        for (uint256 i = 1; i < treasury.MAX_STRATEGY_LOTS(); ++i) _fundAndBook(0.1 ether);
        usdg.mint(address(treasury), 100e6);
        _fundAndBook(0.1 ether); // donor fills the last slot again after an exact-cost merge
        assertEq(treasury.lotCount(), treasury.MAX_STRATEGY_LOTS());
        (, uint256 cost,,) = treasury.lots(0);
        assertEq(cost, 110e18, "the stop-due basis must not be averaged away");
        uint256 before = treasury.bookedStock();
        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        assertLt(treasury.bookedStock(), before);
        assertEq(treasury.lastStopPrice(), 100e18);
    }

    function test_fullDistinctCostLotsHaveBoundedStopScanGas() public {
        for (uint256 i; i < treasury.MAX_STRATEGY_LOTS(); ++i) {
            // Distinct feed prints remain within the pool's 50-bps health band.
            stockFeed.set(int256((100e18 + i * 1e14) / 1e10));
            _fundAndBook(0.1 ether);
        }
        assertEq(treasury.lotCount(), treasury.MAX_STRATEGY_LOTS());
        _px(94e18);
        uint256 before = gasleft();
        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        uint256 used = before - gasleft();
        console2.log("Full distinct-cost execute gas:", used);
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        assertLt(used, 10_000_000, "full-cap stop must remain inside a practical transaction gas budget");
    }

    function test_fullDistinctCostLotsRejectBuyWithinGasBudget() public {
        HedgeFunTreasuryBase.Params memory p = _params(0);
        treasury = new HedgeFunV2Treasury(address(usdg), address(stock), address(mirror),
            address(oracle), address(token), address(pm), address(this), p);
        treasury.wire(_tokenKey());
        for (uint256 i; i < treasury.MAX_STRATEGY_LOTS(); ++i) {
            stockFeed.set(int256((100e18 + i * 1e14) / 1e10));
            _fundAndBook(0.1 ether);
        }
        usdg.mint(address(treasury), 100e6);
        _px(94e18);
        uint256 before = gasleft();
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        treasury.execute();
        uint256 used = before - gasleft();
        assertEq(treasury.lotCount(), treasury.MAX_STRATEGY_LOTS());
        assertLt(used, 10_000_000, "full-cap buy rejection must stay within a practical gas budget");
    }

    function test_dustCleanupSurvivesPendingBookingAtLotCapacity() public {
        HedgeFunTreasuryBase.Params memory p = _params(0);
        p.tp2Bps = 0;
        treasury = new HedgeFunV2Treasury(address(usdg), address(stock), address(mirror),
            address(oracle), address(token), address(pm), address(this), p);
        treasury.wire(_tokenKey());

        uint256 tail = 2 * ((SCALE + 100e18 - 1) / 100e18);
        uint256 chunk = Math.mulDiv(20e6, SCALE, 115e18);
        _fundAndBook(chunk + tail);
        _px(115e18);
        treasury.execute(); // realize a profit, leaving a microscopic tail
        (uint256 left,,,) = treasury.lots(0);
        assertEq(left, tail);

        _px(110e18);
        for (uint256 i = 1; i < treasury.MAX_STRATEGY_LOTS(); ++i) {
            stockFeed.set(int256((110e18 + i * 1e14) / 1e10));
            _fundAndBook(0.1 ether);
        }
        assertEq(treasury.lotCount(), treasury.MAX_STRATEGY_LOTS());
        uint256 donation = 0.1 ether;
        stock.mint(address(treasury), donation); // pending at capacity
        usdg.mint(address(treasury), 100e6);
        _px(109e18); // dip is due after the earlier sale

        uint256 receivedBefore = treasury.totalStockReceived();
        uint256 salePriceBefore = treasury.lastSalePrice();
        uint256 keeperUsdgBefore = usdg.balanceOf(address(this));
        uint256 beforeGas = gasleft();
        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        uint256 used = beforeGas - gasleft();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        assertEq(treasury.lotCount(), treasury.MAX_STRATEGY_LOTS());
        assertEq(treasury.unbookedStock(), 0);
        assertEq(treasury.bookedStock(), stock.balanceOf(address(treasury)) - treasury.buybackStock());
        assertEq(treasury.totalStockReceived(), receivedBefore + donation);
        assertEq(treasury.lastSalePrice(), salePriceBefore, "cleanup must not claim a sale");
        assertEq(usdg.balanceOf(address(this)), keeperUsdgBefore, "cleanup must not pay a bounty");
        assertLt(used, 10_000_000, "full-cap cleanup must fit a practical transaction gas budget");
    }
}

contract V2ExecuteStockCurrency0Test is V2ExecuteBase {
    function stockIsCurrency0() internal pure override returns (bool) { return true; }
}

contract V2ExecuteUsdgCurrency0Test is V2ExecuteBase {
    function stockIsCurrency0() internal pure override returns (bool) { return false; }
}
