// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunBondingCurve as Curve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter as Router} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

/// @dev Twelve distinct recipients in one Foundry test block. These calls are sequential EVM
/// calls, not twelve separate chain transactions; the Anvil runner covers transaction ordering.
contract V2TSLAStressTest is V2FactoryFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    Router private router;
    Curve private curve;
    PoolKey private key;
    IERC20 private strategy;
    address[12] private wallets;
    uint256 private id;

    function setUp() public {
        creatorSaleBps = 4400; // the sale share this replay was written against; a deployment's, fixed at construction
        _setUpV2(18);
        router = new Router(HedgeFunFactory(address(factory)));
        for (uint256 i; i < wallets.length; ++i) {
            wallets[i] = address(uint160(0x1000 + i));
            stock.mint(wallets[i], 50e18);
            vm.prank(wallets[i]);
            stock.approve(address(router), type(uint256).max);
        }
        HedgeFunFactory.Request memory q = _request();
        while (factory.predictToken(q) >= address(stock)) q.nonce++;
        factory.curveDeployer().setCurveConfig(q.symbol, q.nonce, 4400, 180);
        address[] memory exempt = new address[](1);
        exempt[0] = wallets[0];
        factory.curveDeployer().setOpeningTaxExemptions(q.symbol, q.nonce, exempt);
        (,, bytes32 terms) = factory.predict(q);
        id = factory.launch(q, terms);
        curve = Curve(factory.curves(id));
        strategy = IERC20(curve.token());
        (key,) = factory.graduationConfig(id);
    }

    function _buy(address who, uint256 stockIn, bool allowPartial) private returns (uint256 tokens, uint256 refund) {
        (uint256 canonical, uint256 minTokens,) = curve.quoteBuyFor(stockIn, who);
        // Strict input uses the canonical quoted payment; a fee-rounding refund remains a partial fill.
        if (!allowPartial) stockIn = canonical;
        Router.TradeParams memory p = Router.TradeParams(
            id, address(stock), stockIn, stockIn, minTokens, block.timestamp, 0, allowPartial
        );
        vm.prank(who);
        return router.buy(p, new Router.Hop[](0));
    }

    function _sell(address who, uint256 tokens, uint256 floor) private returns (uint256 stockOut) {
        vm.prank(who);
        strategy.approve(address(router), tokens);
        Router.TradeParams memory p = Router.TradeParams(
            id, address(stock), tokens, 0, floor, block.timestamp, 0, false
        );
        vm.prank(who);
        (stockOut,) = router.sell(p, new Router.Hop[](0));
    }

    function _remaining() private view returns (uint256) {
        (uint256 gross,,) = curve.quoteBuyFor(type(uint256).max, wallets[4]);
        return gross;
    }

    function testTwelveBuyersWhitelistSniperAndConcentratedDump() public {
        assertEq(curve.buyRateBpsFor(wallets[0]), curve.taxBps());
        assertEq(curve.buyRateBpsFor(wallets[1]), curve.snipeBps());
        (, uint256 exemptQuote,) = curve.quoteBuyFor(0.1e18, wallets[0]);
        (, uint256 sniperQuote,) = curve.quoteBuyFor(0.1e18, wallets[1]);
        assertGt(exemptQuote, sniperQuote);
        _buy(wallets[0], 0.1e18, false);
        _buy(wallets[1], 0.1e18, false);
        vm.warp(block.timestamp + 180);
        assertEq(curve.buyRateBpsFor(wallets[1]), curve.taxBps());
        for (uint256 i = 2; i < 5; ++i) _buy(wallets[i], 5e18, false);
        for (uint256 i = 5; i < wallets.length; ++i) _buy(wallets[i], 0.1e18, false);

        uint256 whales;
        uint256 participants;
        for (uint256 i; i < wallets.length; ++i) {
            uint256 held = strategy.balanceOf(wallets[i]);
            participants += held;
            if (i >= 2 && i < 5) whales += held;
        }
        assertGe(whales * 100, participants * 80, "three whales below 80% participant holdings");

        uint256 victimSell = strategy.balanceOf(wallets[3]) / 2;
        (uint256 oldFloor,) = curve.quoteSell(victimSell);
        uint256 frontRunSell = strategy.balanceOf(wallets[2]) / 2;
        _sell(wallets[2], frontRunSell, 1);
        uint256 reserveBefore = curve.realStockReserve();
        uint256 victimBefore = strategy.balanceOf(wallets[3]);
        vm.prank(wallets[3]);
        strategy.approve(address(router), victimSell);
        Router.TradeParams memory stale = Router.TradeParams(
            id, address(stock), victimSell, 0, oldFloor, block.timestamp, 0, false
        );
        vm.prank(wallets[3]);
        vm.expectPartialRevert(Router.TooLittle.selector);
        router.sell(stale, new Router.Hop[](0));
        assertEq(curve.realStockReserve(), reserveBefore);
        assertEq(strategy.balanceOf(wallets[3]), victimBefore);
        (uint256 freshFloor,) = curve.quoteSell(victimSell);
        assertLt(freshFloor, oldFloor);
        _sell(wallets[3], victimSell, freshFloor);
        assertEq(strategy.balanceOf(address(router)), 0);
        assertEq(stock.balanceOf(address(router)), 0);
    }

    function testExactFinishRaiseOverfillAtomicRollbackAndV4Boundary() public {
        _buy(wallets[0], 0.1e18, false);
        vm.warp(block.timestamp + 180);
        _buy(wallets[1], 2e18, false);
        uint256 cap = _remaining();
        (uint256 spent, uint256 out,) = curve.quoteBuyFor(cap, wallets[4]);
        assertEq(spent, cap, "terminal quote must consume exact stock cap");
        (uint256 requoted,,) = curve.quoteBuyFor(spent, wallets[4]);
        assertEq(requoted, spent, "canonical spend must be stable");

        Router.TradeParams memory p = Router.TradeParams(
            id, address(stock), cap + 1, cap + 1, out, block.timestamp, 0, false
        );
        uint256 reserveBefore = curve.realStockReserve();
        vm.prank(wallets[4]);
        vm.expectPartialRevert(Router.PartialFill.selector);
        router.buy(p, new Router.Hop[](0));
        assertEq(curve.realStockReserve(), reserveBefore);

        p.amountIn = spent;
        p.minStockReceived = spent;
        stock.blockRecipient(address(pm));
        vm.prank(wallets[4]);
        vm.expectRevert(bytes("blocked recipient"));
        router.buy(p, new Router.Hop[](0));
        assertEq(curve.realStockReserve(), reserveBefore);
        assertEq(uint8(curve.status()), 0);
        stock.blockRecipient(address(0));

        vm.prank(wallets[4]);
        (uint256 got, uint256 refund) = router.buy(p, new Router.Hop[](0));
        assertEq(got, out);
        assertEq(refund, 0);
        assertEq(uint8(curve.status()), 2);
        assertGt(pm.getLiquidity(key.toId()), 0);
        assertEq(stock.balanceOf(address(router)), 0);
        assertEq(strategy.balanceOf(address(router)), 0);

        vm.prank(wallets[4]);
        vm.expectRevert(abi.encodeWithSelector(Router.StageChanged.selector, uint8(2)));
        router.buy(p, new Router.Hop[](0));

        Router.TradeParams memory v4 = Router.TradeParams(
            id, address(stock), 0.01e18, 0.01e18, 1, block.timestamp, 2, true
        );
        vm.prank(wallets[5]);
        (uint256 v4Got,) = router.buy(v4, new Router.Hop[](0));
        assertGt(v4Got, 0);

        // The full-range pool can accept a huge input while returning very few tokens.
        // An absolute output floor, rather than partial-fill consent, protects the user.
        stock.mint(wallets[5], 1_000_000_000e18);
        Router.TradeParams memory large = Router.TradeParams(
            id, address(stock), 1_000_000_000e18, 1_000_000_000e18,
            strategy.totalSupply(), block.timestamp, 2, false
        );
        uint256 beforeLarge = stock.balanceOf(wallets[5]);
        vm.prank(wallets[5]);
        vm.expectPartialRevert(Router.TooLittle.selector);
        router.buy(large, new Router.Hop[](0));
        assertEq(stock.balanceOf(wallets[5]), beforeLarge);
        assertEq(stock.balanceOf(address(router)), 0);
        assertEq(strategy.balanceOf(address(router)), 0);
    }
}
