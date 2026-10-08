// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {HedgeFunBondingCurve as Curve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter as Router} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

/// Four separate wallets race to sell in consecutive transactions at one block timestamp.
/// The curve and V4 PoolManager are production contracts; only the external stock venue is mocked.
contract V2MarketSellScenariosTest is V2FactoryFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address[4] private sellers = [address(0x5101), address(0x5102), address(0x5103), address(0x5104)];
    Curve private curve;
    IERC20 private token;
    Router private router;
    PoolKey private key;
    uint256 private id;
    uint256 private stockSupply;

    struct Wave {
        uint256 firstOut;
        uint256 lastOut;
        uint256 totalOut;
        uint256 totalTax;
        uint160 priceBefore;
        uint160 priceAfter;
        uint128 liquidityBefore;
    }

    function setUp() public {
        _setUpV2(18);
        (id, curve, key) = _launchV2(true); // token is currency0; falling sqrt price means cheaper token.
        vm.warp(curve.launchedAt() + curve.snipeSeconds()); // ordinary trading after the opening window
        token = IERC20(curve.token());
        router = new Router(factory);
        for (uint256 i; i < sellers.length; ++i) {
            address seller = sellers[i];
            stock.mint(seller, 1_000 ether);
            vm.startPrank(seller);
            stock.approve(address(curve), type(uint256).max);
            token.approve(address(curve), type(uint256).max);
            token.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
        stockSupply = stock.totalSupply();
        _assertConservation();
    }

    function _sum(IERC20 asset) private view returns (uint256 sum) {
        sum += asset.balanceOf(address(this));
        for (uint256 i; i < sellers.length; ++i) sum += asset.balanceOf(sellers[i]);
        sum += asset.balanceOf(address(curve)) + asset.balanceOf(address(factory));
        sum += asset.balanceOf(address(pm)) + asset.balanceOf(address(hook));
        sum += asset.balanceOf(address(router)) + asset.balanceOf(curve.treasury());
        sum += asset.balanceOf(protocol) + asset.balanceOf(address(stockPool));
        sum += asset.balanceOf(hook.liquidityVaultOf(key.toId())); // locked token rounding residue
    }

    function _assertConservation() private view {
        assertEq(stock.totalSupply(), stockSupply, "stock total supply is unchanged by trading");
        assertEq(_sum(IERC20(address(stock))), stockSupply, "stock balances conserve across wallets, curve and V4");
        assertEq(_sum(token), token.totalSupply(), "all live strategy tokens are accounted for");
        assertEq(stock.balanceOf(address(curve)), curve.realStockReserve() + curve.totalFees());
        assertEq(curve.totalFees(), curve.claimable(protocol) + curve.claimable(address(this))
            + curve.claimable(curve.treasury()), "curve stock tax has three booked recipients");
        assertEq(stock.balanceOf(address(router)), 0, "router has no leftover stock");
        assertEq(token.balanceOf(address(router)), 0, "router has no leftover tokens");
    }

    function _seedFourWallets() private returns (uint256 commonAmount) {
        commonAmount = type(uint256).max;
        for (uint256 i; i < sellers.length; ++i) {
            vm.prank(sellers[i]);
            curve.buy(10 ether, 1, sellers[i], block.timestamp);
            commonAmount = Math.min(commonAmount, token.balanceOf(sellers[i]));
        }
        commonAmount /= 8;
        assertGt(commonAmount, 0);
        assertEq(uint256(curve.status()), uint256(Curve.Status.Active));
        _assertConservation();
    }

    function _curveSpot() private view returns (uint256) {
        return Math.mulDiv(curve.virtualStock() + curve.realStockReserve(), 1e18, curve.tokenReserve());
    }

    function _curveWave(uint256 amount, bool reverse) private returns (Wave memory w) {
        uint256 timestamp = block.timestamp;
        uint256 spotBefore = _curveSpot();
        uint256 reserveBefore = curve.realStockReserve();
        uint256 feesBefore = curve.totalFees();
        for (uint256 i; i < sellers.length; ++i) {
            address seller = sellers[reverse ? sellers.length - 1 - i : i];
            uint256 balanceBefore = stock.balanceOf(seller);
            uint256 tokenBefore = token.balanceOf(seller);
            (uint256 quote, uint256 fee) = curve.quoteSell(amount);
            vm.prank(seller);
            uint256 out = curve.sell(amount, quote, seller, timestamp);
            assertEq(out, quote);
            assertEq(stock.balanceOf(seller) - balanceBefore, out);
            assertEq(tokenBefore - token.balanceOf(seller), amount);
            assertEq(block.timestamp, timestamp, "all sells are sequenced in the same timestamp");
            assertGt(fee, 0);
            w.totalOut += out;
            w.totalTax += fee;
            if (i == 0) w.firstOut = out;
            if (i == sellers.length - 1) w.lastOut = out;
        }
        assertGt(w.firstOut, w.lastOut, "first curve seller takes more stock than the last");
        assertLt(_curveSpot(), spotBefore, "curve token spot falls over sell wave");
        assertEq(curve.realStockReserve(), reserveBefore - w.totalOut - w.totalTax);
        assertEq(curve.totalFees(), feesBefore + w.totalTax);
        _assertConservation();
    }

    function _v4Sell(address seller, uint256 amount, uint256 rate) private returns (uint256 out, uint256 tax) {
        uint256 beforeStock = stock.balanceOf(seller);
        uint256 beforeToken = token.balanceOf(seller);
        (, uint256 taxBefore) = hook.accrued(key.toId());
        Router.TradeParams memory p = Router.TradeParams(id, address(stock), amount, 0, 1,
            block.timestamp, 2, false);
        Router.Hop[] memory empty = new Router.Hop[](0);
        vm.prank(seller);
        uint256 refund;
        (out, refund) = router.sell(p, empty);
        (, uint256 taxAfter) = hook.accrued(key.toId());
        tax = taxAfter - taxBefore;
        assertEq(refund, 0, "sells fully fill within the seeded LP range");
        assertEq(stock.balanceOf(seller) - beforeStock, out);
        assertEq(beforeToken - token.balanceOf(seller), amount);
        assertGt(tax, 0);
        assertApproxEqAbs(Math.mulDiv(out + tax, rate, 10_000), tax, 1,
            "V4 stock tax must follow the active spike/flat rate");
    }

    function _v4Wave(uint256 amount, bool reverse, uint256 rate) private returns (Wave memory w) {
        uint256 timestamp = block.timestamp;
        (w.priceBefore,,,) = pm.getSlot0(key.toId());
        w.liquidityBefore = pm.getLiquidity(key.toId());
        for (uint256 i; i < sellers.length; ++i) {
            address seller = sellers[reverse ? sellers.length - 1 - i : i];
            (uint256 out, uint256 tax) = _v4Sell(seller, amount, rate);
            w.totalOut += out;
            w.totalTax += tax;
            if (i == 0) w.firstOut = out;
            if (i == sellers.length - 1) w.lastOut = out;
            assertEq(block.timestamp, timestamp, "all sells are sequenced in the same timestamp");
        }
        (w.priceAfter,,,) = pm.getSlot0(key.toId());
        assertGt(w.firstOut, w.lastOut, "first V4 seller takes more stock than the last");
        assertLt(w.priceAfter, w.priceBefore, "token0 selling lowers the V4 stock/token sqrt price");
        assertEq(pm.getLiquidity(key.toId()), w.liquidityBefore, "trading cannot withdraw locked LP principal");
        _assertConservation();
    }

    function test_fourWalletCurveSellWaveOrderAndConservation() public {
        uint256 amount = _seedFourWallets();
        uint256 checkpoint = vm.snapshotState();
        Wave memory forward = _curveWave(amount, false);
        uint256 forwardFirstBalance = stock.balanceOf(sellers[0]);
        vm.revertToState(checkpoint);
        Wave memory reverse = _curveWave(amount, true);
        assertEq(forward.totalOut, reverse.totalOut, "same fixed input sequence conserves aggregate output");
        assertEq(forward.totalTax, reverse.totalTax, "order changes allocation, not aggregate tax");
        assertEq(forward.firstOut, reverse.firstOut);
        assertEq(forward.lastOut, reverse.lastOut);
        assertGt(forwardFirstBalance, stock.balanceOf(sellers[0]), "wallet loses priority when moved to last");
        console2.log("Scenario sell-wave curve sellers:", sellers.length);
        console2.log("Scenario sell-wave curve per_wallet_token_raw:", amount);
        console2.log("Scenario sell-wave curve first_stock_raw:", forward.firstOut);
        console2.log("Scenario sell-wave curve last_stock_raw:", forward.lastOut);
        console2.log("Scenario sell-wave curve total_stock_raw:", forward.totalOut);
        console2.log("Scenario sell-wave curve total_tax_raw:", forward.totalTax);
    }

    function test_fourWalletV4SellWaveRemainsFlatAfterBuybackNotice() public {
        uint256 amount = _seedFourWallets();
        _graduateV2(curve);
        assertGt(pm.getLiquidity(key.toId()), 0);
        assertEq(hook.sellRateBps(key.toId()), 1000);
        _assertConservation();
        // A treasury notification cannot turn volume-funded buy-backs into a V2 sell spike.
        vm.prank(curve.treasury());
        hook.noteEvent();
        assertEq(hook.sellRateBps(key.toId()), 1000);
        uint256 checkpoint = vm.snapshotState();
        Wave memory notified = _v4Wave(amount, false, 1000);
        vm.revertToState(checkpoint);
        Wave memory notifiedReverse = _v4Wave(amount, true, 1000);
        assertEq(notified.totalOut, notifiedReverse.totalOut);
        assertEq(notified.totalTax, notifiedReverse.totalTax);
        vm.revertToState(checkpoint);
        vm.warp(block.timestamp + 120);
        assertEq(hook.sellRateBps(key.toId()), 1000);
        Wave memory flat = _v4Wave(amount, false, 1000);
        assertEq(flat.totalOut, notified.totalOut, "waiting does not change the V2 sell tax");
        assertEq(flat.totalTax, notified.totalTax);
        assertEq(flat.priceAfter, notified.priceAfter);
        console2.log("Scenario sell-wave v4 sellers:", sellers.length);
        console2.log("Scenario sell-wave v4 per_wallet_token_raw:", amount);
        console2.log("Scenario sell-wave v4 liquidity_raw:", flat.liquidityBefore);
        console2.log("Scenario sell-wave v4 sqrt_before_raw:", uint256(flat.priceBefore));
        console2.log("Scenario sell-wave v4 sqrt_after_raw:", uint256(flat.priceAfter));
        console2.log("Scenario sell-wave v4 notified_first_stock_raw:", notified.firstOut);
        console2.log("Scenario sell-wave v4 notified_last_stock_raw:", notified.lastOut);
        console2.log("Scenario sell-wave v4 notified_total_stock_raw:", notified.totalOut);
        console2.log("Scenario sell-wave v4 notified_tax_raw:", notified.totalTax);
        console2.log("Scenario sell-wave v4 flat_first_stock_raw:", flat.firstOut);
        console2.log("Scenario sell-wave v4 flat_last_stock_raw:", flat.lastOut);
        console2.log("Scenario sell-wave v4 flat_total_stock_raw:", flat.totalOut);
        console2.log("Scenario sell-wave v4 flat_tax_raw:", flat.totalTax);
    }
}
