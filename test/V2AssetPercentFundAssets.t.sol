// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2AssetPercentEngineTreasury} from "../src/v2/HedgeFunV2AssetPercentEngineTreasury.sol";
import {V2FundAssetReader} from "../src/v2/V2FundAssetReader.sol";
import {V2LiquidityVault} from "../src/v2/V2LiquidityVault.sol";
import {StrategyAction} from "../src/v2/strategy/IStrategyPolicy.sol";
import {V2AssetPercentEngineFixture} from "./V2AssetPercentEngine.t.sol";
import {FundAssetMath} from "./utils/FundAssetMath.sol";

contract FundAssetUnlockProbe is IUnlockCallback {
    IPoolManager private immutable manager;
    HedgeFunV2AssetPercentEngineTreasury private immutable treasury;
    bool public observed;
    constructor(IPoolManager m, HedgeFunV2AssetPercentEngineTreasury t) { manager = m; treasury = t; }
    function run() external { manager.unlock(""); }
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (bool healthy, uint256 nav, uint256 trade, uint256 daily, uint256 remaining,,) = treasury.riskLimits();
        require(!healthy && nav == 0 && trade == 0 && daily == 0 && remaining == 0);
        (bool due, StrategyAction action, uint256 amount) = treasury.preview();
        require(!due && action == StrategyAction.Hold && amount == 0);
        (bool ok, bytes memory reason) = address(treasury).call(abi.encodeCall(treasury.execute, ()));
        require(!ok && bytes4(reason) == HedgeFunTreasuryBase.Unhealthy.selector);
        observed = true;
        return "";
    }
}

contract V2AssetPercentFundAssetsTest is V2AssetPercentEngineFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct Assets { uint256 held; uint256 parked; uint256 principal; uint256 fees; uint256 cash; }
    function _assets(HedgeFunV2AssetPercentEngineTreasury t) private view returns (Assets memory a) {
        (a.held, a.parked, a.principal, a.fees, a.cash) = t.assetReader().assetBalances();
    }
    function _ordered(bool stockFirst, uint96 nonce) private returns (HedgeFunV2AssetPercentEngineTreasury t) {
        HedgeFunFactory.Request memory q = _request(); q.nonce = nonce;
        while ((address(stock) < factory.predictToken(q)) != stockFirst) ++q.nonce;
        t = _launchPercent(q.nonce, 1000, 5000, 0);
        assertEq(address(stock) < address(t.token()), stockFirst);
    }
    function _donate(HedgeFunV2AssetPercentEngineTreasury t, uint256 stockQty, uint256 funQty) private {
        PoolDonateTest router = new PoolDonateTest(pm);
        stock.approve(address(router), type(uint256).max);
        t.token().approve(address(router), type(uint256).max);
        PoolKey memory key = V2LiquidityVault(t.liquidityVault()).poolKey();
        bool first = Currency.unwrap(key.currency0) == address(stock);
        router.donate(key, first ? stockQty : funQty, first ? funQty : stockQty, "");
    }
    function _swapStockIntoLp(HedgeFunV2AssetPercentEngineTreasury t) private {
        _advance(300); // past the production hook's launch protection
        PoolSwapTest router = new PoolSwapTest(pm);
        stock.approve(address(router), type(uint256).max);
        t.token().approve(address(router), type(uint256).max);
        PoolKey memory key = V2LiquidityVault(t.liquidityVault()).poolKey();
        bool first = Currency.unwrap(key.currency0) == address(stock);
        router.swap(key, SwapParams(first, -int256(1e18), first ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false), "");
    }

    function testFuzz_realLpBothStockOrdersUseCurrentOwnedPrincipalAndStockFees(bool stockFirst) public {
        HedgeFunV2AssetPercentEngineTreasury t = _ordered(stockFirst, 1500);
        Assets memory before_ = _assets(t);
        assertGt(before_.principal, 0); assertEq(before_.fees, 0);
        _swapStockIntoLp(t);
        Assets memory after_ = _assets(t);
        assertGt(after_.principal, before_.principal); assertGt(after_.fees, 0);
        assertEq(_risk(t).nav, FundAssetMath.nav(t, stock, PRICE, 1e30));
        uint256 nav = _risk(t).nav; uint256 bb = t.buybackStock();
        (uint256 fee,) = V2LiquidityVault(t.liquidityVault()).collectFees();
        assertGt(fee, 0); assertEq(t.buybackStock(), bb + fee);
        assertEq(_assets(t).fees, 0); assertEq(_assets(t).parked, 0);
        assertEq(_risk(t).nav, nav, "uncollected fee -> treasury buyback, exactly once");
    }

    function test_feeDeliveryFailureParkedBalanceAndRetryPreserveFullNav() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(1501, 1000, 5000, 0);
        _donate(t, 2e18, 0);
        uint256 nav = _risk(t).nav; uint256 fees = _assets(t).fees; assertGt(fees, 0);
        stock.blockRecipient(address(t));
        (uint256 delivered,) = V2LiquidityVault(t.liquidityVault()).collectFees();
        assertEq(delivered, 0); assertEq(_assets(t).parked, fees); assertEq(_assets(t).fees, 0);
        assertEq(_risk(t).nav, nav); assertEq(t.buybackStock(), 0);
        stock.blockRecipient(address(0));
        (delivered,) = V2LiquidityVault(t.liquidityVault()).collectFees();
        assertEq(delivered, fees); assertEq(_assets(t).parked, 0);
        assertEq(t.buybackStock(), fees); assertEq(_risk(t).nav, nav);
    }

    function test_funHoldingsAndFunFeesHaveZeroExternalAssetValue() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(1502, 1000, 5000, 0);
        uint256 nav = _risk(t).nav;
        t.token().transfer(address(t), 100e18); t.token().transfer(t.liquidityVault(), 200e18);
        _donate(t, 0, 10e18);
        assertEq(_risk(t).nav, nav); assertEq(_assets(t).fees, 0);
        V2LiquidityVault(t.liquidityVault()).collectFees();
        assertEq(_risk(t).nav, nav);
    }

    function test_otherFundAndPoolManagerBalancesCannotInflateThisFund() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(1503, 1000, 5000, 0);
        uint256 nav = _risk(t).nav;
        HedgeFunV2AssetPercentEngineTreasury other = _launchPercent(1504, 1000, 5000, 0);
        stock.mint(address(other), 10e18); stock.mint(other.liquidityVault(), 20e18);
        stock.mint(address(pm), 100e18); _donate(other, 1e18, 0);
        assertEq(_risk(t).nav, nav);
        assertGt(_risk(other).nav, nav);
    }

    function test_fullNavCapActuallyExceedsTradableCapButTargetRemainsTradable() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(1505, 1000, 5000, 0);
        uint256 tradable = Math.mulDiv(t.bookedStock(), PRICE, 1e30);
        Risk memory r = _risk(t); assertGt(r.trade, tradable / 10);
        (bool due, StrategyAction action, uint256 offered) = t.preview(); assertTrue(due);
        assertEq(uint256(action), uint256(StrategyAction.SellStock));
        uint256 turnover = Math.mulDiv(offered, PRICE, 1e30);
        assertGt(turnover, tradable / 10); assertLe(turnover, r.trade);
        t.execute(); assertEq(t.turnoverInEpoch(), turnover);
        _advance(600);
        // Locked LP and buyback reserves enlarge only the caps, never the 70% target or available inventory.
        stock.mint(t.liquidityVault(), 1000e18);
        vm.prank(t.liquidityVault()); stock.approve(address(t), type(uint256).max);
        vm.prank(t.liquidityVault()); t.creditLiquidityFee(1000e18);
        uint256 nav = _risk(t).nav;
        (due, action, offered) = t.preview(); assertTrue(due);
        uint256 held = t.bookedStock(); uint256 value = Math.mulDiv(held, PRICE, 1e30);
        uint256 target = Math.mulDiv(value + t.reserveUsdg(), 7000, 10000);
        assertLe(Math.mulDiv(offered, PRICE, 1e30), value - target);
        t.execute(); assertLe(held - t.bookedStock(), offered);
        assertGt(t.buybackStock(), 0); assertLt(_risk(t).nav, nav); // real swap costs, no LP/BB spend
    }

    function test_bbRelocationIsConservedAndDailyUsedDoesNotReset() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(1506, 1000, 1000, 0);
        t.execute(); _advance(600);
        uint256 used = t.turnoverInEpoch(); uint64 epoch = t.turnoverEpoch();
        assertEq(_risk(t).remaining, 0);
        stock.mint(t.liquidityVault(), 10e18);
        Risk memory added = _risk(t); assertGt(added.remaining, 0);
        vm.prank(t.liquidityVault()); stock.approve(address(t), 10e18);
        vm.prank(t.liquidityVault()); t.creditLiquidityFee(10e18);
        Risk memory moved = _risk(t); assertEq(moved.nav, added.nav);
        assertEq(moved.remaining, added.remaining); assertEq(moved.used, used); assertEq(moved.epoch, epoch);
        assertEq(t.turnoverInEpoch(), used);
    }

    function test_unlockedManagerWaitsAndExecuteRollsBackWithoutConsumingState() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(1507, 1000, 5000, 0);
        stock.mint(address(t), 1e18); uint256 pending = t.unbookedStock(); uint256 held = t.bookedStock();
        FundAssetUnlockProbe probe = new FundAssetUnlockProbe(pm, t); probe.run(); assertTrue(probe.observed());
        assertEq(t.unbookedStock(), pending); assertEq(t.bookedStock(), held);
        assertEq(t.strategyNonce(), 0); assertEq(t.turnoverInEpoch(), 0); assertTrue(_risk(t).healthy);
        t.execute(); assertEq(t.strategyNonce(), 1);
    }

    function _assertUnavailable(HedgeFunV2AssetPercentEngineTreasury t) private {
        Risk memory r = _risk(t); assertFalse(r.healthy); assertEq(r.nav, 0); assertEq(r.remaining, 0);
        (bool due,,) = t.preview(); assertFalse(due);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector); t.execute();
        assertEq(t.strategyNonce(), 0); assertEq(t.turnoverInEpoch(), 0);
    }
    function test_missingUnseededOrMisboundVaultFailsClosedWithNoSmallerNavFallback() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(1508, 1000, 5000, 0);
        address vault = t.liquidityVault();
        vm.mockCall(address(t), abi.encodeWithSignature("liquidityVault()"), abi.encode(address(0)));
        _assertUnavailable(t); vm.clearMockedCalls();
        bytes4[6] memory selectors = [bytes4(keccak256("factory()")), bytes4(keccak256("treasury()")),
            bytes4(keccak256("stock()")), bytes4(keccak256("token()")), bytes4(keccak256("poolManager()")),
            bytes4(keccak256("seeded()"))];
        for (uint256 i; i < selectors.length; ++i) {
            vm.mockCall(vault, abi.encodeWithSelector(selectors[i]), abi.encode(uint256(0)));
            _assertUnavailable(t); vm.clearMockedCalls();
        }
        PoolKey memory bad = V2LiquidityVault(vault).poolKey(); ++bad.fee;
        vm.mockCall(vault, abi.encodeCall(V2LiquidityVault.poolKey, ()), abi.encode(bad));
        _assertUnavailable(t); vm.clearMockedCalls(); assertTrue(_risk(t).healthy);
    }

    function test_stockQuantityOrNavOverflowFailsClosedBeforeBooking() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(1509, 1000, 5000, 0);
        deal(address(stock), address(t), type(uint256).max);
        _assertUnavailable(t);
        assertEq(t.avgCost(), PRICE);
    }
}
