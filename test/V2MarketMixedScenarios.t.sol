// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HedgeFunBondingCurve as Curve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter as Router} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

/// @notice Competing buy/sell orders are sequential EVM transactions at one timestamp.
/// @dev Uses the real V2 curve, router, Hook and V4 PoolManager with mock stock/feed.
contract V2MarketMixedScenariosTest is V2FactoryFixture {
    address private constant BUYER_A = address(0xBA1);
    address private constant BUYER_B = address(0xBA2);
    address private constant SELLER_A = address(0x5E11);
    address private constant SELLER_B = address(0x5E12);

    Curve private curve;
    IERC20 private fun;
    Router private router;
    uint256 private id;

    struct Outcome {
        uint256 sellerAStock;
        uint256 sellerBStock;
        uint256 buyerATokens;
        uint256 buyerBTokens;
        uint256 sellTaxStock;
        uint256 stockReserve;
    }

    function setUp() public {
        _setUpV2(18);
        (id, curve,) = _launchV2(true);
        vm.warp(curve.launchedAt() + curve.snipeSeconds()); // ordinary trading after the opening window
        fun = IERC20(curve.token());
        router = new Router(factory);
        address[4] memory actors = [BUYER_A, BUYER_B, SELLER_A, SELLER_B];
        for (uint256 i; i < actors.length; ++i) {
            stock.mint(actors[i], 1_000e18);
            vm.startPrank(actors[i]);
            stock.approve(address(curve), type(uint256).max);
            stock.approve(address(router), type(uint256).max);
            fun.approve(address(curve), type(uint256).max);
            fun.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(SELLER_A); curve.buy(10e18, 1, SELLER_A, block.timestamp);
        vm.prank(SELLER_B); curve.buy(10e18, 1, SELLER_B, block.timestamp);
    }

    function _curveBuy(address who) private returns (uint256 out) {
        vm.prank(who);
        (, out) = curve.buy(20e18, 1, who, block.timestamp);
    }

    function _curveSell(address who, uint256 amount) private returns (uint256 out) {
        vm.prank(who);
        out = curve.sell(amount, 1, who, block.timestamp);
    }

    function _route(uint256 amount, uint8 stage) private view returns (Router.TradeParams memory p) {
        p = Router.TradeParams(id, address(stock), amount, 0, 1, block.timestamp, stage, true);
    }

    function _empty() private pure returns (Router.Hop[] memory path) { path = new Router.Hop[](0); }

    function _v4Buy(address who) private returns (uint256 out) {
        vm.prank(who);
        (out,) = router.buy(_route(20e18, 2), _empty());
    }

    function _v4Sell(address who, uint256 amount) private returns (uint256 out) {
        uint256 refund;
        vm.prank(who);
        (out, refund) = router.sell(_route(amount, 2), _empty());
        assertEq(refund, 0, "small seller order should fill in the full-range V4 pool");
    }

    function _curveOrder(bool buyersFirst, uint256 sellA, uint256 sellB) private returns (Outcome memory o) {
        uint256 aBefore = stock.balanceOf(SELLER_A);
        uint256 bBefore = stock.balanceOf(SELLER_B);
        uint256 feeBefore = curve.totalFees();
        if (buyersFirst) {
            o.buyerATokens = _curveBuy(BUYER_A);
            _curveSell(SELLER_A, sellA);
            o.buyerBTokens = _curveBuy(BUYER_B);
            _curveSell(SELLER_B, sellB);
        } else {
            _curveSell(SELLER_A, sellA);
            o.buyerATokens = _curveBuy(BUYER_A);
            _curveSell(SELLER_B, sellB);
            o.buyerBTokens = _curveBuy(BUYER_B);
        }
        o.sellerAStock = stock.balanceOf(SELLER_A) - aBefore;
        o.sellerBStock = stock.balanceOf(SELLER_B) - bBefore;
        o.sellTaxStock = curve.totalFees() - feeBefore;
        o.stockReserve = curve.realStockReserve();
        assertEq(uint256(curve.status()), uint256(Curve.Status.Active));
        assertEq(stock.balanceOf(address(curve)), curve.realStockReserve() + curve.totalFees());
        assertEq(fun.balanceOf(address(curve)), curve.tokenReserve());
    }

    function _v4Order(bool buyersFirst, uint256 sellA, uint256 sellB) private returns (Outcome memory o) {
        uint256 aBefore = stock.balanceOf(SELLER_A);
        uint256 bBefore = stock.balanceOf(SELLER_B);
        if (buyersFirst) {
            o.buyerATokens = _v4Buy(BUYER_A);
            _v4Sell(SELLER_A, sellA);
            o.buyerBTokens = _v4Buy(BUYER_B);
            _v4Sell(SELLER_B, sellB);
        } else {
            _v4Sell(SELLER_A, sellA);
            o.buyerATokens = _v4Buy(BUYER_A);
            _v4Sell(SELLER_B, sellB);
            o.buyerBTokens = _v4Buy(BUYER_B);
        }
        o.sellerAStock = stock.balanceOf(SELLER_A) - aBefore;
        o.sellerBStock = stock.balanceOf(SELLER_B) - bBefore;
        assertEq(stock.balanceOf(address(router)), 0);
        assertEq(fun.balanceOf(address(router)), 0);
        assertEq(uint256(curve.status()), uint256(Curve.Status.Graduated));
    }

    function test_mixedCurveSameTimestampOrdering() public {
        uint256 sellA = fun.balanceOf(SELLER_A) / 10;
        uint256 sellB = fun.balanceOf(SELLER_B) / 10;
        uint256 snapshot = vm.snapshotState();
        Outcome memory afterBuy = _curveOrder(true, sellA, sellB);
        vm.revertToState(snapshot);
        Outcome memory beforeBuy = _curveOrder(false, sellA, sellB);
        assertGt(afterBuy.sellerAStock, beforeBuy.sellerAStock, "first seller benefits when a buy lands first");
        assertGt(afterBuy.sellerBStock, beforeBuy.sellerBStock, "second seller benefits when a buy lands first");
        assertGt(afterBuy.sellTaxStock, 0);
        assertGt(beforeBuy.sellTaxStock, 0);
        console2.log("Scenario mixed-curve sellerA-after-buy raw:", afterBuy.sellerAStock);
        console2.log("Scenario mixed-curve sellerA-before-buy raw:", beforeBuy.sellerAStock);
        console2.log("Scenario mixed-curve sellerB-after-buy raw:", afterBuy.sellerBStock);
        console2.log("Scenario mixed-curve sellerB-before-buy raw:", beforeBuy.sellerBStock);
        console2.log("Scenario mixed-curve sell-tax-after-buy raw:", afterBuy.sellTaxStock);
        console2.log("Scenario mixed-curve sell-tax-before-buy raw:", beforeBuy.sellTaxStock);
    }

    function test_mixedV4SameTimestampOrdering() public {
        _graduateV2(curve);
        uint256 sellA = fun.balanceOf(SELLER_A) / 20;
        uint256 sellB = fun.balanceOf(SELLER_B) / 20;
        uint256 snapshot = vm.snapshotState();
        Outcome memory afterBuy = _v4Order(true, sellA, sellB);
        vm.revertToState(snapshot);
        Outcome memory beforeBuy = _v4Order(false, sellA, sellB);
        assertGt(afterBuy.sellerAStock, beforeBuy.sellerAStock, "V4 first seller benefits when a buy lands first");
        assertGt(afterBuy.sellerBStock, beforeBuy.sellerBStock, "V4 second seller benefits when a buy lands first");
        console2.log("Scenario mixed-v4 sellerA-after-buy raw:", afterBuy.sellerAStock);
        console2.log("Scenario mixed-v4 sellerA-before-buy raw:", beforeBuy.sellerAStock);
        console2.log("Scenario mixed-v4 sellerB-after-buy raw:", afterBuy.sellerBStock);
        console2.log("Scenario mixed-v4 sellerB-before-buy raw:", beforeBuy.sellerBStock);
    }
}
