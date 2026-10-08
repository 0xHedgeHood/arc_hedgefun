// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunV2TradablePercentEngineTreasuryCore as Treasury} from "../src/v2/HedgeFunV2TradablePercentEngineTreasury.sol";
import {HedgeFunV2TradeRouter as Router} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {V2LiquidityVault} from "../src/v2/V2LiquidityVault.sol";
import {V2TradablePercentEngineFixture} from "./V2TradablePercentEngine.t.sol";

/// Controlled production V4 curve/LP/router/fee/buyback comparison. Only stock/USDG price is mocked ($100).
/// Same 79.31% curve sale, supply, opening price, 1% tax, 0.3% LP fee and order sizes in both runs.
contract V2DirectionalLpComparisonTest is V2TradablePercentEngineFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    struct Launch { Treasury t; Router r; V2LiquidityVault vault; PoolKey key; uint160 initial; }

    function _request() internal view override returns (HedgeFunFactory.Request memory q) {
        q = super._request();
        q.taxBps = 100;
    }

    function _launch(uint16 share) private returns (Launch memory l) {
        vm.prank(owner); deployer.setLpBps(address(stock), share);
        uint256 pmStock = stock.balanceOf(address(pm));
        l.t = _launchPercent(5200, 2000, 2000, 5000, 5000);
        l.r = new Router(factory);
        (l.key,) = factory.graduationConfig(0);
        l.vault = V2LiquidityVault(l.t.liquidityVault());
        (l.initial,,,) = pm.getSlot0(l.key.toId());
        stock.approve(address(l.r), type(uint256).max);
        l.t.token().approve(address(l.r), type(uint256).max);
        assertEq(l.t.token().totalSupply(), factory.getDefaults().supply, "graduation does not burn FUN");
        assertEq(l.t.buybackStock(), 0, "graduation principal cannot fund buybacks");
        emit log_named_uint("LP share bps", share);
        emit log_named_uint("LP stock value USDG raw", (stock.balanceOf(address(pm)) - pmStock) / 1e10);
        emit log_named_uint("treasury principal USDG raw", stock.balanceOf(address(l.t)) / 1e10);
        emit log_named_uint("base liquidity", _base(l));
        emit log_named_uint("surplus liquidity", l.vault.surplusLiquidity());
    }

    function _base(Launch memory l) private view returns (uint128 value) {
        (value,,) = pm.getPositionInfo(l.key.toId(), address(l.vault),
            TickMath.minUsableTick(l.key.tickSpacing), TickMath.maxUsableTick(l.key.tickSpacing), bytes32(0));
    }

    function _priceRatio(Launch memory l) private view returns (uint256) {
        (uint160 after_,,,) = pm.getSlot0(l.key.toId());
        uint256 ratio = Math.mulDiv(after_, 1e18, l.initial);
        ratio = Math.mulDiv(ratio, ratio, 1e18);
        return l.t.stockIsCurrency0InTokenPool() ? 1e36 / ratio : ratio;
    }

    function _buy(Launch memory l, uint256 cash) private returns (uint256 received) {
        Router.Hop[] memory empty = new Router.Hop[](0);
        (received,) = l.r.buy(Router.TradeParams(0, address(stock), cash * 1e10, 0, 1, block.timestamp, 2, true), empty);
    }

    function test_compare50And70PercentLpAtEqualOrderflow() public {
        for (uint256 i; i < 2; ++i) {
            uint256 clean = vm.snapshotState();
            Launch memory l = _launch(i == 0 ? 5000 : 7000);
            uint256[3] memory buys = [uint256(100e6), 1000e6, 5000e6];
            for (uint256 j; j < buys.length; ++j) {
                uint256 snap = vm.snapshotState();
                uint256 received = _buy(l, buys[j]);
                emit log_named_uint("buy input USDG raw", buys[j]);
                emit log_named_uint("buy FUN received", received);
                emit log_named_uint("buy ending price / graduation 1e18", _priceRatio(l));
                assertGt(received, 0);
                vm.revertToState(snap);
            }
            // Existing holders sell identical quantities, independent of any preceding buy.
            uint256[3] memory sales = [uint256(1000e18), 10_000e18, 50_000e18];
            for (uint256 j; j < sales.length; ++j) {
                uint256 snap = vm.snapshotState();
                Router.Hop[] memory empty = new Router.Hop[](0);
                (uint256 out,) = l.r.sell(Router.TradeParams(0, address(stock), sales[j], 0, 1, block.timestamp, 2, true), empty);
                emit log_named_uint("sell FUN input", sales[j]);
                emit log_named_uint("sell output USDG raw", out / 1e10);
                emit log_named_uint("sell ending price / graduation 1e18", _priceRatio(l));
                assertGt(out, 0);
                vm.revertToState(snap);
            }
            // Real earned fees from identical $10,000 volume; no manufactured buyback reserve.
            _buy(l, 10_000e6);
            uint256 supply = l.t.token().totalSupply();
            uint256 principal = l.t.bookedStock();
            uint128 base = _base(l);
            uint128 extra = l.vault.surplusLiquidity();
            (uint256 fee,) = l.vault.collectFees();
            assertGt(fee, 0);
            assertEq(l.t.buybackStock(), fee);
            _advance(601);
            uint256 beforePrice = _priceRatio(l);
            (uint256 spent, uint256 burned) = l.t.buyback();
            emit log_named_uint("earned LP fees USDG raw", fee / 1e10);
            emit log_named_uint("buyback spent USDG raw", spent / 1e10);
            emit log_named_uint("buyback burned FUN raw", burned);
            emit log_named_uint("buyback price increase bps", Math.mulDiv(_priceRatio(l) - beforePrice, 10000, beforePrice));
            assertEq(l.t.bookedStock(), principal);
            assertEq(l.t.buybackStock(), fee - spent);
            assertEq(l.t.token().totalSupply(), supply - burned);
            assertEq(_base(l), base);
            assertEq(l.vault.surplusLiquidity(), extra);
            vm.revertToState(clean);
        }
    }
}
