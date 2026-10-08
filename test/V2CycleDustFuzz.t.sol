// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunV2CycleTreasury} from "../src/v2/HedgeFunV2CycleTreasury.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {MockToken, MockFeed, AlwaysOpen} from "./mocks/Mocks.sol";
import {MirrorV3Pool, NoopHook} from "./InteractVenueParity.t.sol";

/// @notice Cycle recovery and the current dust retirement rules must compose without losing progress.
/// @dev Prices, actors and balances are local; actual fills use a local V4 concentrated-liquidity pool.
///      Both asset orders execute every property, rather than making order a random reachability choice.
abstract contract V2CycleDustFuzzBase is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant SCALE = 1e30;
    uint24 internal constant FEE = 3000;
    int24 internal constant SPACING = 60;
    bytes32 internal constant STOPPED = keccak256("Stopped(uint256,uint256,uint256)");
    bytes32 internal constant PROFIT_TAKEN = keccak256("ProfitTaken(uint256,uint256,uint256,uint256,uint256)");
    bytes32 internal constant ARMED = keccak256("RecoveryArmed(uint256,uint256,uint256)");
    bytes32 internal constant CONSUMED = keccak256("RecoveryConsumed(bool)");

    IPoolManager internal pm;
    MockToken internal usdg;
    MockToken internal stock;
    HedgeFunToken internal token;
    MockFeed internal stockFeed;
    PriceOracle internal oracle;
    PoolSwapTest internal swapRouter;
    PoolKey internal stockKey;
    MirrorV3Pool internal mirror;
    HedgeFunV2CycleTreasury internal cycle;

    struct Snapshot {
        uint256 cash;
        uint256 stockHeld;
        uint256 buyback;
        uint256 keeperUsdg;
        uint256 keeperStock;
        uint256 received;
        uint256 salePrice;
        uint256 stopPrice;
        uint256 stopAt;
        uint256 stopReport;
        uint256 reentryPrice;
        uint256 reentryAt;
        uint256 reentryReport;
    }

    function stockIsCurrency0() internal pure virtual returns (bool);

    function setUp() public {
        vm.warp(1_700_000_000);
        pm = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(pm);
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(pm);
        usdg = new MockToken("USDG", 6);
        stock = _mineStock();
        token = new HedgeFunToken("Cycle dust", "CYCLE", 1_000_000_000e18, address(this), address(0));
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
        _deployCycle(false, 20e6);
    }

    function _deployCycle(bool wholeProfit, uint256 chunk) internal {
        HedgeFunTreasuryBase.Params memory p;
        p.tp1Bps = 500;
        p.tp2Bps = wholeProfit ? 0 : 1000;
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
        p.sellChunkUsdg = chunk;
        cycle = new HedgeFunV2CycleTreasury(
            address(usdg), address(stock), address(mirror), address(oracle), address(token), address(pm), address(this), p
        );
        cycle.wire(_tokenKey());
    }

    /// Genuine sub-minimum fills cannot arm recovery; their later ledger-only cleanup cannot arm it either.
    function testFuzz_cyclePureStopCleanupCannotArmRecovery(uint256 rawDust, uint256 cleanupAge) public {
        _deployCycle(false, 1e6);
        uint256 dust = _dustFor(bound(rawDust, 1, 9_999), 90e18);
        _px(110e18);
        _fundAndBook(5 * Math.mulDiv(1e6, SCALE, 90e18) + dust);
        for (uint256 i; i < 5; ++i) {
            _px(90e18);
            (HedgeFunV2Treasury.Action action,) = cycle.execute();
            assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
            assertFalse(cycle.reentryPending());
        }
        (uint256 left,,,) = cycle.lots(0);
        assertEq(left, dust);
        vm.warp(block.timestamp + bound(cleanupAge, 1, 599));
        _px(90e18);
        Snapshot memory before = _snapshot();
        vm.recordLogs();
        (HedgeFunV2Treasury.Action action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        _assertCleanupOnly(before, vm.getRecordedLogs());
        assertFalse(cycle.reentryPending());
        assertEq(cycle.lotCount(), 0);
        assertEq(cycle.unbookedStock(), dust);
        _assertPartition();
    }

    /// Cleanup must not invoke the stop observation hook: recovery still opens at the original 600s boundary.
    function testFuzz_cycleCleanupDoesNotRenewRecoveryCooldown(uint256 rawDust, uint256 cleanupAge, uint256 funding)
        public
    {
        // It must remain below the 0.01-USDG retirement threshold even at the 5% recovery rise.
        uint256 dust = _leaveStopTail(bound(rawDust, 1, 9_000));
        usdg.mint(address(cycle), bound(funding, 50e6, 250e6));
        vm.warp(cycle.lastStopAt() + bound(cleanupAge, 1, 599));
        _px(94.5e18);
        Snapshot memory before = _snapshot();
        assertFalse(cycle.recoveryDue());
        vm.recordLogs();
        (HedgeFunV2Treasury.Action action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        _assertCleanupOnly(before, vm.getRecordedLogs());
        assertEq(cycle.unbookedStock(), dust);

        vm.warp(before.stopAt + 600);
        _px(94.5e18);
        assertTrue(cycle.recoveryDue(), "ledger-only cleanup must not postpone the original observation");
        (action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.BuyRecovery));
        assertFalse(cycle.reentryPending());
        assertEq(cycle.lastStopAt(), 0);
        assertEq(cycle.unbookedStock(), dust);
        assertEq(cycle.totalStockReceived(), before.received);
        _assertPartition();
    }

    /// A mature recovery executes alongside cleanup, without a fake sale, new recovery anchor or receipt.
    function testFuzz_cycleDustCleanupMakesSameCallRecoveryProgress(uint256 rawDust, uint256 elapsed, uint256 funding)
        public
    {
        uint256 dust = _leaveStopTail(bound(rawDust, 1, 9_000));
        usdg.mint(address(cycle), bound(funding, 50e6, 250e6));
        vm.warp(cycle.lastStopAt() + bound(elapsed, 600, 1_800));
        _px(94.5e18);
        Snapshot memory before = _snapshot();
        assertTrue(cycle.recoveryDue());
        vm.recordLogs();
        (HedgeFunV2Treasury.Action action,) = cycle.execute();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.BuyRecovery));
        assertEq(_saleCount(logs), 0);
        assertEq(_eventCount(logs, ARMED), 0);
        assertEq(_eventCount(logs, CONSUMED), 1);
        assertEq(cycle.lotCount(), 1);
        assertFalse(cycle.reentryPending());
        assertLt(cycle.reserveUsdg(), before.cash);
        assertGt(stock.balanceOf(address(cycle)), before.stockHeld);
        assertEq(cycle.buybackStock(), before.buyback);
        assertEq(cycle.unbookedStock(), dust);
        assertEq(cycle.totalStockReceived(), before.received);
        assertGt(usdg.balanceOf(address(this)), before.keeperUsdg);
        assertEq(stock.balanceOf(address(this)), before.keeperStock);
        _assertPartition();
    }

    /// Another actual stop behind the tail updates both the recovery anchor and stop gate exactly once.
    function testFuzz_cycleCleanupBeforeRealStopUsesOnlyActualFill(uint256 rawDust, uint256 laterStock) public {
        uint256 dust = _dustFor(bound(rawDust, 1, 9_999), 90e18);
        _px(110e18);
        _fundAndBook(Math.mulDiv(20e6, SCALE, 90e18) + dust);
        _px(100e18);
        uint256 laterQty = bound(laterStock, 0.3 ether, 2 ether);
        _fundAndBook(laterQty);
        _px(90e18);
        cycle.execute();
        vm.warp(block.timestamp + 1);
        _px(89e18);
        Snapshot memory before = _snapshot();
        vm.recordLogs();
        (HedgeFunV2Treasury.Action action,) = cycle.execute();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        assertEq(_eventCount(logs, STOPPED), 1);
        assertEq(_eventCount(logs, ARMED), 1);
        assertEq(cycle.reentrySalePrice(), 89e18);
        assertEq(cycle.reentrySaleAt(), block.timestamp);
        assertEq(cycle.reentryStockUpdatedAt(), block.timestamp);
        assertEq(cycle.lastStopAt(), block.timestamp);
        assertEq(cycle.lastStopStockUpdatedAt(), block.timestamp);
        assertEq(cycle.lotCount(), 1);
        (uint256 remaining,,,) = cycle.lots(0);
        assertLt(remaining, laterQty);
        assertEq(cycle.unbookedStock(), dust);
        assertEq(cycle.totalStockReceived(), before.received);
        uint256 reward = usdg.balanceOf(address(this)) - before.keeperUsdg;
        uint256 gross = cycle.reserveUsdg() - before.cash + reward;
        assertGt(gross, 0);
        assertEq(reward, Math.mulDiv(gross, cycle.params().bountyBps, 10_000));
        assertEq(stock.balanceOf(address(this)), before.keeperStock);
        _assertPartition();
    }

    /// Ordinary dip still needs the stop cooldown, a newer report, and a deeper price after cleanup.
    function testFuzz_cycleDustCleanupPreservesOriginalDipGates(uint256 rawDust, uint256 cleanupAge, uint256 funding)
        public
    {
        uint256 dust = _leaveStopTail(bound(rawDust, 1, 9_999));
        usdg.mint(address(cycle), bound(funding, 50e6, 250e6));
        Snapshot memory before = _snapshot();
        vm.warp(before.stopAt + bound(cleanupAge, 1, 599));
        _px(90e18);
        cycle.execute();
        _px(85e18);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        cycle.execute();
        vm.warp(before.stopAt + 600);
        _px(85e18);
        stockFeed.setAt(85e8, before.stopReport);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        cycle.execute();
        _px(90e18);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        cycle.execute();
        _px(85e18);
        (HedgeFunV2Treasury.Action action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.BuyDip));
        assertEq(cycle.lotCount(), 1);
        assertFalse(cycle.reentryPending());
        assertEq(cycle.lastStopAt(), 0);
        assertEq(cycle.unbookedStock(), dust);
        assertEq(cycle.totalStockReceived(), before.received);
        _assertPartition();
    }

    /// A fresh booking can reuse the one freed slot; preserving it cannot consume the old recovery signal.
    function testFuzz_cycleCapacity128BookingPreservesCleanupAndPending(uint256 rawDust, uint256 pendingStock) public {
        _deployCycle(true, 20e6);
        uint256 dust = _dustFor(bound(rawDust, 2, 5_000), 100e18);
        _fundAndBook(Math.mulDiv(20e6, SCALE, 115e18) + dust);
        _px(115e18);
        cycle.execute();
        (uint256 left,,,) = cycle.lots(0);
        assertEq(left, dust);
        assertTrue(cycle.reentryPending());
        _px(110e18);
        for (uint256 i = 1; i < cycle.MAX_STRATEGY_LOTS(); ++i) {
            stockFeed.set(int256((110e18 + i * 1e14) / 1e10));
            _fundAndBook(0.1 ether);
        }
        assertEq(cycle.lotCount(), 128);
        uint256 donation = bound(pendingStock, 0.05 ether, 2 ether);
        stock.mint(address(cycle), donation);
        usdg.mint(address(cycle), 100e6);
        _px(109e18);
        Snapshot memory before = _snapshot();
        uint256 bookedBefore = cycle.bookedStock();
        vm.recordLogs();
        (HedgeFunV2Treasury.Action action,) = cycle.execute();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        assertEq(_saleCount(logs), 0);
        assertEq(_eventCount(logs, ARMED), 0);
        assertEq(_eventCount(logs, CONSUMED), 0);
        _assertMoneyAndReferences(before);
        assertEq(cycle.lotCount(), 128);
        assertEq(cycle.unbookedStock(), 0);
        assertEq(cycle.bookedStock(), bookedBefore + donation);
        assertEq(cycle.totalStockReceived(), before.received + donation);
        bool found;
        for (uint256 i; i < cycle.lotCount(); ++i) {
            (uint256 qty, uint256 cost,,) = cycle.lots(i);
            if (cost == 109e18) {
                assertEq(qty, donation + dust);
                found = true;
            }
        }
        assertTrue(found, "pending stock and the released tail reuse the freed capacity");
        _assertPartition();
    }

    function _leaveStopTail(uint256 rawDust) internal returns (uint256 dust) {
        dust = _dustFor(rawDust, 90e18);
        _px(110e18);
        _fundAndBook(Math.mulDiv(20e6, SCALE, 90e18) + dust);
        _px(90e18);
        (HedgeFunV2Treasury.Action action,) = cycle.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        (uint256 left,,,) = cycle.lots(0);
        assertEq(left, dust);
        assertTrue(cycle.reentryPending());
        assertEq(cycle.reentrySalePrice(), 90e18);
        _px(90e18);
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s = Snapshot(
            cycle.reserveUsdg(), stock.balanceOf(address(cycle)), cycle.buybackStock(),
            usdg.balanceOf(address(this)), stock.balanceOf(address(this)), cycle.totalStockReceived(),
            cycle.lastSalePrice(), cycle.lastStopPrice(), cycle.lastStopAt(), cycle.lastStopStockUpdatedAt(),
            cycle.reentrySalePrice(), cycle.reentrySaleAt(), cycle.reentryStockUpdatedAt()
        );
    }

    function _assertMoneyAndReferences(Snapshot memory before) internal view {
        assertEq(cycle.reserveUsdg(), before.cash);
        assertEq(stock.balanceOf(address(cycle)), before.stockHeld);
        assertEq(cycle.buybackStock(), before.buyback);
        assertEq(usdg.balanceOf(address(this)), before.keeperUsdg);
        assertEq(stock.balanceOf(address(this)), before.keeperStock);
        assertEq(cycle.lastSalePrice(), before.salePrice);
        assertEq(cycle.lastStopPrice(), before.stopPrice);
        assertEq(cycle.lastStopAt(), before.stopAt);
        assertEq(cycle.lastStopStockUpdatedAt(), before.stopReport);
        assertEq(cycle.reentrySalePrice(), before.reentryPrice);
        assertEq(cycle.reentrySaleAt(), before.reentryAt);
        assertEq(cycle.reentryStockUpdatedAt(), before.reentryReport);
    }

    function _assertCleanupOnly(Snapshot memory before, Vm.Log[] memory logs) internal view {
        _assertMoneyAndReferences(before);
        assertEq(cycle.totalStockReceived(), before.received);
        assertEq(_saleCount(logs), 0);
        assertEq(_eventCount(logs, ARMED), 0);
        assertEq(_eventCount(logs, CONSUMED), 0);
    }

    function _eventCount(Vm.Log[] memory logs, bytes32 signature) internal view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(cycle) && logs[i].topics.length != 0 && logs[i].topics[0] == signature) {
                ++count;
            }
        }
    }

    function _saleCount(Vm.Log[] memory logs) internal view returns (uint256) {
        return _eventCount(logs, STOPPED) + _eventCount(logs, PROFIT_TAKEN);
    }

    function _assertPartition() internal view {
        uint256 sum;
        for (uint256 i; i < cycle.lotCount(); ++i) {
            (uint256 qty,,,) = cycle.lots(i);
            sum += qty;
        }
        assertEq(sum, cycle.bookedStock());
        assertEq(stock.balanceOf(address(cycle)), cycle.bookedStock() + cycle.buybackStock() + cycle.unbookedStock());
        assertLe(cycle.lotCount(), 128);
    }

    function _dustFor(uint256 rawValue, uint256 price) internal pure returns (uint256) {
        return Math.ceilDiv(rawValue * SCALE, price);
    }

    function _fundAndBook(uint256 amount) internal {
        stock.mint(address(cycle), amount);
        assertTrue(cycle.book());
    }

    function _px(uint256 price) internal {
        uint160 target = _sqrtFor(price);
        (uint160 current,,,) = pm.getSlot0(stockKey.toId());
        if (target != current) {
            swapRouter.swap(
                stockKey,
                SwapParams({zeroForOne: target < current, amountSpecified: -int256(1e30), sqrtPriceLimitX96: target}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
            );
        }
        stockFeed.set(int256(price / 1e10));
    }

    function _sqrtFor(uint256 price) internal pure returns (uint160) {
        return uint160(Math.sqrt(stockIsCurrency0()
            ? Math.mulDiv(price, 1 << 192, SCALE) : Math.mulDiv(SCALE, 1 << 192, price)));
    }

    function _mineStock() internal returns (MockToken) {
        bytes32 hash = keccak256(abi.encodePacked(type(MockToken).creationCode, abi.encode("STK", uint8(18))));
        for (uint256 i; i < 1000; ++i) {
            if ((vm.computeCreate2Address(bytes32(i), hash, address(this)) < address(usdg)) == stockIsCurrency0()) {
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

contract V2CycleDustStock0FuzzTest is V2CycleDustFuzzBase {
    function stockIsCurrency0() internal pure override returns (bool) { return true; }
}

contract V2CycleDustUsdg0FuzzTest is V2CycleDustFuzzBase {
    function stockIsCurrency0() internal pure override returns (bool) { return false; }
}
