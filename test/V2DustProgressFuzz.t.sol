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
import {Vm} from "forge-std/Vm.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunV2AllInTreasury} from "../src/v2/HedgeFunV2AllInTreasury.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {MockToken, MockFeed, AlwaysOpen} from "./mocks/Mocks.sol";
import {MirrorV3Pool, NoopHook} from "./InteractVenueParity.t.sol";

/// @notice Randomized correctness properties for the current dust cleanup implementation.
/// @dev All deployments, feeds and balances are local. The stock venue mirrors a real local V4 pool.
///      Each concrete contract fixes both stock ordering and treasury kind, so every property reaches
///      its successful execution path for every fuzz sample instead of relying on random branch choice.
abstract contract V2DustProgressFuzzBase is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant SCALE = 1e30;
    uint24 internal constant FEE = 3000;
    int24 internal constant SPACING = 60;
    bytes32 internal constant STOPPED = keccak256("Stopped(uint256,uint256,uint256)");
    bytes32 internal constant PROFIT_TAKEN = keccak256("ProfitTaken(uint256,uint256,uint256,uint256,uint256)");

    IPoolManager internal pm;
    MockToken internal usdg;
    MockToken internal stock;
    HedgeFunToken internal token;
    MockFeed internal stockFeed;
    PriceOracle internal oracle;
    PoolSwapTest internal swapRouter;
    PoolKey internal stockKey;
    MirrorV3Pool internal mirror;
    HedgeFunV2Treasury internal treasury;

    struct CleanupState {
        uint256 reserve;
        uint256 heldStock;
        uint256 buybackStock;
        uint256 keeperUsdg;
        uint256 keeperStock;
        uint256 salePrice;
        uint256 stopPrice;
        uint256 stopAt;
        uint256 stopReportAt;
        uint256 received;
    }

    function stockIsCurrency0() internal pure virtual returns (bool);
    function allIn() internal pure virtual returns (bool);

    function setUp() public {
        vm.warp(1_700_000_000);
        pm = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(pm);
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(pm);
        usdg = new MockToken("USDG", 6);
        stock = _mineStock();
        token = new HedgeFunToken("Dust Strategy", "DUST", 1_000_000_000e18, address(this), address(0));
        stockFeed = new MockFeed(8);
        MockFeed usdgFeed = new MockFeed(8);
        stockFeed.set(100e8);
        usdgFeed.set(1e8);
        oracle = new PriceOracle(
            address(stock), address(stockFeed), address(usdgFeed), address(new AlwaysOpen()), 26 hours, 26 hours
        );
        (Currency c0, Currency c1) = stockIsCurrency0()
            ? (Currency.wrap(address(stock)), Currency.wrap(address(usdg)))
            : (Currency.wrap(address(usdg)), Currency.wrap(address(stock)));
        stockKey = PoolKey(c0, c1, FEE, SPACING, IHooks(address(0)));
        pm.initialize(stockKey, _sqrtFor(100e18));
        usdg.mint(address(this), 1e24);
        stock.mint(address(this), 1e12 ether);
        usdg.approve(address(lpRouter), type(uint256).max);
        stock.approve(address(lpRouter), type(uint256).max);
        usdg.approve(address(swapRouter), type(uint256).max);
        stock.approve(address(swapRouter), type(uint256).max);
        (, int24 tick,,) = pm.getSlot0(stockKey.toId());
        lpRouter.modifyLiquidity(
            stockKey,
            ModifyLiquidityParams({
                tickLower: ((tick - 1800) / SPACING) * SPACING,
                tickUpper: ((tick + 1800) / SPACING) * SPACING,
                liquidityDelta: 1e18,
                salt: 0
            }),
            ""
        );
        mirror = new MirrorV3Pool(pm, stockKey);
        vm.etch(address(0x40), address(new NoopHook()).code);
        pm.initialize(_tokenKey(), uint160(1 << 96));
        _deployTreasury(false);
    }

    function _deployTreasury(bool profitClosesWholeLot) internal {
        HedgeFunTreasuryBase.Params memory p;
        p.tp1Bps = 500;
        p.tp2Bps = profitClosesWholeLot ? 0 : 1000;
        p.dipBps = 500;
        p.stopBps = 500;
        p.lotBps = 2000;
        p.bountyBps = 50;
        p.maxSlippageBps = 100;
        p.maxDeviationBps = 50;
        p.maxBuybackImpactBps = 300;
        p.buybackCooldown = 60;
        p.minLotUsdg = 5e6;
        p.buybackChunkUsdg = 500e6;
        p.sellChunkUsdg = 20e6;
        treasury = allIn()
            ? new HedgeFunV2AllInTreasury(
                address(usdg),
                address(stock),
                address(mirror),
                address(oracle),
                address(token),
                address(pm),
                address(this),
                p
            )
            : new HedgeFunV2Treasury(
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
    }

    /// Dust retirement has ledger effects only. Rebooking it with a fresh donation counts only that donation.
    function testFuzz_stopCleanupPreservesMoneyGateAndDistinctReceipts(uint256 rawDust, uint256 freshStock) public {
        uint256 dust = _leaveStopTail(bound(rawDust, 1, 9_999));
        CleanupState memory before = _state();
        vm.recordLogs();
        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        _assertCleanupOnly(before, vm.getRecordedLogs());
        assertEq(treasury.lotCount(), 0);
        assertEq(treasury.unbookedStock(), dust);
        _assertPartition();

        uint256 donation = bound(freshStock, 0.06 ether, 2 ether);
        stock.mint(address(treasury), donation);
        assertTrue(treasury.book());
        assertEq(treasury.totalStockReceived(), before.received + donation);
        assertEq(treasury.bookedStock(), donation + dust);
        assertEq(treasury.unbookedStock(), 0);
        _assertPartition();
    }

    /// A real due stop behind the tail executes in the cleanup transaction and earns only its actual bounty.
    function testFuzz_stopCleanupMakesSameCallProgress(uint256 rawDust, uint256 laterStock) public {
        uint256 dust = _dustFor(bound(rawDust, 1, 9_999), 90e18);
        _px(110e18);
        _fundAndBook(Math.mulDiv(20e6, SCALE, 90e18) + dust);
        _px(100e18);
        uint256 laterQty = bound(laterStock, 0.3 ether, 2 ether);
        _fundAndBook(laterQty);
        _px(90e18);
        treasury.execute();
        _px(90e18);
        uint256 beforeBooked = treasury.bookedStock();
        CleanupState memory moneyBefore = _state();
        vm.recordLogs();
        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        assertEq(_paidSaleCount(logs), 1);
        assertEq(treasury.lotCount(), 1);
        (uint256 remaining,,,) = treasury.lots(0);
        assertLt(remaining, laterQty);
        assertEq(treasury.unbookedStock(), dust);
        assertLt(treasury.bookedStock(), beforeBooked - dust);
        assertGt(treasury.reserveUsdg(), moneyBefore.reserve);
        assertGt(usdg.balanceOf(address(this)), moneyBefore.keeperUsdg);
        _assertStopBounty(moneyBefore);
        assertEq(treasury.totalStockReceived(), moneyBefore.received);
        _assertPartition();
    }

    /// Cleanup cannot skip the post-stop price/cooldown/report gates; a later valid dip still succeeds.
    function testFuzz_stopCleanupKeepsGateUntilGenuineReentry(uint256 rawDust, uint256 cooldownAge, uint256 usdFunding)
        public
    {
        uint256 dust = _leaveStopTail(bound(rawDust, 1, 9_999));
        usdg.mint(address(treasury), bound(usdFunding, 50e6, 250e6));
        uint256 stopAt = treasury.lastStopAt();
        vm.warp(stopAt + bound(cooldownAge, 0, 599));
        _px(90e18);
        CleanupState memory before = _state();
        vm.recordLogs();
        treasury.execute();
        _assertCleanupOnly(before, vm.getRecordedLogs());
        assertEq(treasury.unbookedStock(), dust);

        _px(85e18); // even a deeper fresh report cannot bypass the remaining cooldown
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        treasury.execute();
        vm.warp(stopAt + 600);
        _px(85e18);
        stockFeed.setAt(85e8, before.stopReportAt); // a due price with the old observation still cannot reopen
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        treasury.execute();
        _px(90e18); // new report and elapsed cooldown alone cannot reopen at the stop price
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        treasury.execute();
        _px(85e18);
        uint256 reserveBefore = treasury.reserveUsdg();
        uint256 keeperBefore = usdg.balanceOf(address(this));
        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.BuyDip));
        assertEq(treasury.lotCount(), 1);
        assertGt(treasury.bookedStock(), 0);
        assertLt(treasury.reserveUsdg(), reserveBefore);
        assertGt(usdg.balanceOf(address(this)), keeperBefore);
        assertEq(treasury.lastStopPrice(), 0);
        assertEq(treasury.lastStopAt(), 0);
        assertEq(treasury.lastStopStockUpdatedAt(), 0);
        assertEq(treasury.unbookedStock(), dust);
        assertEq(treasury.totalStockReceived(), before.received);
        _assertPartition();
    }

    function testFuzz_profitCleanupPreservesMoneyAndDistinctReceipts(uint256 rawDust, uint256 freshStock) public {
        uint256 dust = _leaveProfitTail(bound(rawDust, 2, 5_000));
        CleanupState memory before = _state();
        vm.recordLogs();
        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        _assertCleanupOnly(before, vm.getRecordedLogs());
        assertEq(treasury.lotCount(), 0);
        assertEq(treasury.unbookedStock(), dust);
        uint256 donation = bound(freshStock, 0.05 ether, 2 ether);
        stock.mint(address(treasury), donation);
        assertTrue(treasury.book());
        assertEq(treasury.totalStockReceived(), before.received + donation);
        assertEq(treasury.bookedStock(), donation + dust);
        assertEq(treasury.unbookedStock(), 0);
        _assertPartition();
    }

    function testFuzz_profitCleanupMakesSameCallProgress(uint256 rawDust, uint256 laterStock) public {
        _deployTreasury(true);
        uint256 dust = _dustFor(bound(rawDust, 2, 5_000), 100e18);
        _fundAndBook(Math.mulDiv(20e6, SCALE, 115e18) + dust);
        _px(105e18);
        uint256 laterQty = bound(laterStock, 0.3 ether, 2 ether);
        _fundAndBook(laterQty);
        _px(115e18);
        treasury.execute();
        _px(115e18);
        CleanupState memory moneyBefore = _state();
        vm.recordLogs();
        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        assertEq(_paidSaleCount(vm.getRecordedLogs()), 1);
        assertEq(treasury.lotCount(), 1);
        (uint256 remaining,,,) = treasury.lots(0);
        assertLt(remaining, laterQty);
        assertGt(treasury.reserveUsdg(), moneyBefore.reserve);
        assertGt(stock.balanceOf(address(this)), moneyBefore.keeperStock);
        _assertProfitBounty(moneyBefore);
        assertEq(treasury.totalStockReceived(), moneyBefore.received);
        assertEq(treasury.unbookedStock(), dust);
        _assertPartition();
    }

    /// At capacity, filling the freed slot may defer a dip but must retain cleanup and correct receipt accounting.
    function testFuzz_capacity128PendingBookingRetainsCleanup(uint256 rawDust, uint256 pendingStock) public {
        uint256 dust = _leaveProfitTail(bound(rawDust, 2, 5_000));
        _px(110e18);
        for (uint256 i = 1; i < treasury.MAX_STRATEGY_LOTS(); ++i) {
            stockFeed.set(int256((110e18 + i * 1e14) / 1e10));
            _fundAndBook(0.1 ether);
        }
        assertEq(treasury.lotCount(), 128);
        uint256 donation = bound(pendingStock, 0.05 ether, 2 ether);
        stock.mint(address(treasury), donation);
        usdg.mint(address(treasury), 100e6);
        _px(109e18);
        CleanupState memory before = _state();
        uint256 bookedBefore = treasury.bookedStock();
        vm.recordLogs();
        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        assertEq(_paidSaleCount(logs), 0);
        assertEq(treasury.lotCount(), 128);
        assertEq(treasury.unbookedStock(), 0);
        assertEq(treasury.bookedStock(), bookedBefore + donation);
        assertEq(treasury.totalStockReceived(), before.received + donation);
        assertEq(treasury.reserveUsdg(), before.reserve);
        assertEq(stock.balanceOf(address(treasury)), before.heldStock);
        assertEq(treasury.buybackStock(), before.buybackStock);
        assertEq(usdg.balanceOf(address(this)), before.keeperUsdg);
        assertEq(stock.balanceOf(address(this)), before.keeperStock);
        assertEq(treasury.lastSalePrice(), before.salePrice);
        assertEq(treasury.lastStopAt(), before.stopAt);
        bool foundRebooked;
        for (uint256 i; i < treasury.lotCount(); ++i) {
            (uint256 qty, uint256 cost,,) = treasury.lots(i);
            if (cost == 109e18) {
                assertEq(qty, donation + dust);
                foundRebooked = true;
            }
        }
        assertTrue(foundRebooked, "the fresh donation and released tail enter the freed slot");
        _assertPartition();
    }

    function _leaveStopTail(uint256 rawDust) internal returns (uint256 dust) {
        dust = _dustFor(rawDust, 90e18);
        _px(110e18);
        _fundAndBook(Math.mulDiv(20e6, SCALE, 90e18) + dust);
        _px(90e18);
        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        (uint256 left,,,) = treasury.lots(0);
        assertEq(left, dust);
        _px(90e18);
    }

    function _leaveProfitTail(uint256 rawDust) internal returns (uint256 dust) {
        _deployTreasury(true);
        dust = _dustFor(rawDust, 100e18);
        _fundAndBook(Math.mulDiv(20e6, SCALE, 115e18) + dust);
        _px(115e18);
        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        (uint256 left,,,) = treasury.lots(0);
        assertEq(left, dust);
        _px(115e18);
    }

    function _state() internal view returns (CleanupState memory s) {
        s = CleanupState(
            treasury.reserveUsdg(),
            stock.balanceOf(address(treasury)),
            treasury.buybackStock(),
            usdg.balanceOf(address(this)),
            stock.balanceOf(address(this)),
            treasury.lastSalePrice(),
            treasury.lastStopPrice(),
            treasury.lastStopAt(),
            treasury.lastStopStockUpdatedAt(),
            treasury.totalStockReceived()
        );
    }

    function _assertCleanupOnly(CleanupState memory before, Vm.Log[] memory logs) internal view {
        assertEq(_paidSaleCount(logs), 0);
        assertEq(treasury.reserveUsdg(), before.reserve);
        assertEq(stock.balanceOf(address(treasury)), before.heldStock);
        assertEq(treasury.buybackStock(), before.buybackStock);
        assertEq(usdg.balanceOf(address(this)), before.keeperUsdg);
        assertEq(stock.balanceOf(address(this)), before.keeperStock);
        assertEq(treasury.lastSalePrice(), before.salePrice);
        assertEq(treasury.lastStopPrice(), before.stopPrice);
        assertEq(treasury.lastStopAt(), before.stopAt);
        assertEq(treasury.lastStopStockUpdatedAt(), before.stopReportAt);
        assertEq(treasury.totalStockReceived(), before.received);
    }

    function _assertStopBounty(CleanupState memory before) internal view {
        uint256 reward = usdg.balanceOf(address(this)) - before.keeperUsdg;
        uint256 grossOutput = treasury.reserveUsdg() - before.reserve + reward;
        assertEq(reward, Math.mulDiv(grossOutput, treasury.params().bountyBps, 10_000));
        assertEq(stock.balanceOf(address(this)), before.keeperStock);
    }

    function _assertProfitBounty(CleanupState memory before) internal view {
        uint256 reward = stock.balanceOf(address(this)) - before.keeperStock;
        uint256 grossGain = treasury.buybackStock() - before.buybackStock + reward;
        assertEq(reward, Math.mulDiv(grossGain, treasury.params().bountyBps, 10_000));
        assertEq(usdg.balanceOf(address(this)), before.keeperUsdg);
    }

    function _paidSaleCount(Vm.Log[] memory logs) internal view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(treasury) && logs[i].topics.length != 0
                    && (logs[i].topics[0] == STOPPED || logs[i].topics[0] == PROFIT_TAKEN)
            ) ++count;
        }
    }

    function _assertPartition() internal view {
        uint256 sum;
        for (uint256 i; i < treasury.lotCount(); ++i) {
            (uint256 qty,,,) = treasury.lots(i);
            sum += qty;
        }
        assertEq(sum, treasury.bookedStock());
        assertEq(
            stock.balanceOf(address(treasury)),
            treasury.bookedStock() + treasury.buybackStock() + treasury.unbookedStock()
        );
        assertLe(treasury.lotCount(), 128);
    }

    function _dustFor(uint256 rawValue, uint256 price) internal pure returns (uint256) {
        return Math.ceilDiv(rawValue * SCALE, price);
    }

    function _fundAndBook(uint256 qty) internal {
        stock.mint(address(treasury), qty);
        assertTrue(treasury.book());
    }

    function _px(uint256 price) internal {
        uint160 target = _sqrtFor(price);
        (uint160 current,,,) = pm.getSlot0(stockKey.toId());
        if (target != current) {
            swapRouter.swap(
                stockKey,
                SwapParams({zeroForOne: target < current, amountSpecified: -int256(1e30), sqrtPriceLimitX96: target}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
        stockFeed.set(int256(price / 1e10));
    }

    function _sqrtFor(uint256 price) internal pure returns (uint160) {
        return uint160(
            Math.sqrt(stockIsCurrency0() ? Math.mulDiv(price, 1 << 192, SCALE) : Math.mulDiv(SCALE, 1 << 192, price))
        );
    }

    function _mineStock() internal returns (MockToken) {
        bytes32 initHash = keccak256(abi.encodePacked(type(MockToken).creationCode, abi.encode("STK", uint8(18))));
        for (uint256 i; i < 1000; ++i) {
            if ((vm.computeCreate2Address(bytes32(i), initHash, address(this)) < address(usdg)) == stockIsCurrency0()) {
                return new MockToken{salt: bytes32(i)}("STK", 18);
            }
        }
        revert("stock address");
    }

    function _tokenKey() internal view returns (PoolKey memory) {
        (Currency c0, Currency c1) = address(stock) < address(token)
            ? (Currency.wrap(address(stock)), Currency.wrap(address(token)))
            : (Currency.wrap(address(token)), Currency.wrap(address(stock)));
        return PoolKey(c0, c1, FEE, SPACING, IHooks(address(0x40)));
    }
}

contract V2DustProgressRegularStock0FuzzTest is V2DustProgressFuzzBase {
    function stockIsCurrency0() internal pure override returns (bool) {
        return true;
    }

    function allIn() internal pure override returns (bool) {
        return false;
    }
}

contract V2DustProgressRegularUsdg0FuzzTest is V2DustProgressFuzzBase {
    function stockIsCurrency0() internal pure override returns (bool) {
        return false;
    }

    function allIn() internal pure override returns (bool) {
        return false;
    }
}

contract V2DustProgressAllInStock0FuzzTest is V2DustProgressFuzzBase {
    function stockIsCurrency0() internal pure override returns (bool) {
        return true;
    }

    function allIn() internal pure override returns (bool) {
        return true;
    }
}

contract V2DustProgressAllInUsdg0FuzzTest is V2DustProgressFuzzBase {
    function stockIsCurrency0() internal pure override returns (bool) {
        return false;
    }

    function allIn() internal pure override returns (bool) {
        return true;
    }
}
