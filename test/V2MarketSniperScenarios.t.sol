// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {HedgeFunBondingCurve as Curve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter as Router} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

/// @notice Replays different transaction orderings against the production V2 curve, V4 manager and hook.
/// @dev No mocked pricing or state edits; a snapshot only restores the identical initial market for comparisons.
contract V2MarketSniperScenariosTest is V2FactoryFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address private constant BOT = address(0xB07);
    address private constant USER = address(0xA11);
    uint256 private constant BOT_BUY = 20e18;
    uint256 private constant USER_BUY = 140e18;

    struct Outcome {
        uint256 botSpent;
        uint256 botSale;
        uint256 botBuyTax;
        uint256 botSellTax;
        uint256 userSpent;
        uint256 userOut;
        uint256 userBuyTax;
    }

    Curve private curve;
    IERC20 private token;
    Router private router;
    PoolKey private key;
    uint256 private id;

    function setUp() public {
        _setUpV2(18);
        (id, curve, key) = _launchV2(true);
        token = IERC20(curve.token());
        router = new Router(factory);
        stock.mint(BOT, 1_000e18);
        stock.mint(USER, 1_000e18);
        vm.startPrank(BOT);
        stock.approve(address(curve), type(uint256).max);
        stock.approve(address(router), type(uint256).max);
        token.approve(address(curve), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(USER);
        stock.approve(address(curve), type(uint256).max);
        stock.approve(address(router), type(uint256).max);
        token.approve(address(curve), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _curveBuy(address who, uint256 budget) private returns (uint256 spent, uint256 received, uint256 burned) {
        (uint256 quoteSpent, uint256 quoteOut, uint256 quoteBurn) = curve.quoteBuy(budget);
        vm.prank(who);
        (spent, received) = curve.buy(budget, 1, who, block.timestamp);
        assertEq(spent, quoteSpent);
        assertEq(received, quoteOut);
        burned = quoteBurn;
    }

    function _curveRun(bool botFirst) private returns (Outcome memory o) {
        uint256 botTokens;
        uint256 userStart = stock.balanceOf(USER);
        if (botFirst) {
            (o.botSpent, botTokens, o.botBuyTax) = _curveBuy(BOT, BOT_BUY);
            (, o.userOut, o.userBuyTax) = _curveBuy(USER, USER_BUY);
        } else {
            (, o.userOut, o.userBuyTax) = _curveBuy(USER, USER_BUY);
            (o.botSpent, botTokens, o.botBuyTax) = _curveBuy(BOT, BOT_BUY);
        }
        (uint256 quoteSale, uint256 quoteTax) = curve.quoteSell(botTokens);
        vm.prank(BOT);
        o.botSale = curve.sell(botTokens, 1, BOT, block.timestamp);
        o.botSellTax = quoteTax;
        o.userSpent = userStart - stock.balanceOf(USER);
        assertEq(o.botSale, quoteSale);
        assertEq(token.balanceOf(BOT), 0);
    }

    function _params(uint256 amount, uint8 stage, uint256 minOut) private view returns (Router.TradeParams memory p) {
        p = Router.TradeParams(id, address(stock), amount, amount, minOut, block.timestamp, stage, true);
    }

    function _empty() private pure returns (Router.Hop[] memory hops) {
        hops = new Router.Hop[](0);
    }

    function _v4Buy(address who, uint256 stockIn, uint256 minOut) private returns (uint256 out, uint256 tokenTax) {
        (uint256 taxBefore,) = hook.accrued(key.toId());
        vm.prank(who);
        (out,) = router.buy(_params(stockIn, 2, minOut), _empty());
        (uint256 taxAfter,) = hook.accrued(key.toId());
        tokenTax = taxAfter - taxBefore;
    }

    function _v4Sell(address who, uint256 tokenIn) private returns (uint256 out, uint256 stockTax) {
        (, uint256 taxBefore) = hook.accrued(key.toId());
        vm.prank(who);
        (out,) = router.sell(_params(tokenIn, 2, 1), _empty());
        (, uint256 taxAfter) = hook.accrued(key.toId());
        stockTax = taxAfter - taxBefore;
    }

    function _v4Run(bool botFirst, uint256 botBudget, uint256 userBudget) private returns (Outcome memory o) {
        uint256 botTokens;
        uint256 botStart = stock.balanceOf(BOT);
        uint256 userStart = stock.balanceOf(USER);
        if (botFirst) {
            (botTokens, o.botBuyTax) = _v4Buy(BOT, botBudget, 1);
            (o.userOut, o.userBuyTax) = _v4Buy(USER, userBudget, 1);
        } else {
            (o.userOut, o.userBuyTax) = _v4Buy(USER, userBudget, 1);
            (botTokens, o.botBuyTax) = _v4Buy(BOT, botBudget, 1);
        }
        o.botSpent = botStart - stock.balanceOf(BOT);
        o.userSpent = userStart - stock.balanceOf(USER);
        (o.botSale, o.botSellTax) = _v4Sell(BOT, botTokens);
        assertEq(token.balanceOf(BOT), 0, "bot must fully exit for PnL comparison");
    }

    function _log(string memory label, Outcome memory o) private pure {
        console2.log(string.concat("Scenario ", label, " bot_spent_stock_raw:"), o.botSpent);
        console2.log(string.concat("Scenario ", label, " bot_sale_stock_raw:"), o.botSale);
        console2.log(string.concat("Scenario ", label, " bot_pnl_stock_raw:"), int256(o.botSale) - int256(o.botSpent));
        console2.log(string.concat("Scenario ", label, " bot_buy_tax_token_raw:"), o.botBuyTax);
        console2.log(string.concat("Scenario ", label, " bot_sell_tax_stock_raw:"), o.botSellTax);
        console2.log(string.concat("Scenario ", label, " user_spent_stock_raw:"), o.userSpent);
        console2.log(string.concat("Scenario ", label, " user_out_token_raw:"), o.userOut);
        console2.log(string.concat("Scenario ", label, " user_buy_tax_token_raw:"), o.userBuyTax);
    }

    function test_openingTaxTimeSweepKeepsQuotesAndLossesVisible() public {
        uint256 launchTime = curve.launchedAt();
        for (uint256 second; second <= 3; ++second) {
            uint256 state = vm.snapshotState();
            vm.warp(launchTime + second);
            Outcome memory botFirst = _curveRun(true);
            if (second == 0) _log("curve_t0", botFirst);
            else if (second == 1) _log("curve_t1", botFirst);
            else if (second == 2) _log("curve_t2", botFirst);
            else _log("curve_t3", botFirst);
            if (second == 0) assertLt(botFirst.botSale, botFirst.botSpent);
            if (second == 1 || second == 2) {
                assertGt(botFirst.botSale, botFirst.botSpent, "decaying buy tax alone still permits this sandwich");
            }
            if (second == 3) assertGt(botFirst.botSale, botFirst.botSpent);
            assertTrue(vm.revertToState(state));
        }
    }

    function _assertSmallSniper(uint256 second, uint256 botBudget, uint256 minOutBps, string memory suffix) private {
        uint256 state = vm.snapshotState();
        vm.warp(curve.launchedAt() + second);
        (, uint256 cleanOut,) = curve.quoteBuy(USER_BUY);
        (uint256 botSpent, uint256 botTokens,) = _curveBuy(BOT, botBudget);
        vm.prank(USER);
        (uint256 userSpent, uint256 userOut) = curve.buy(USER_BUY, cleanOut * minOutBps / 10000, USER, block.timestamp);
        assertApproxEqAbs(userSpent, USER_BUY, 1, "canonical fee rounding refunds at most one stock wei");
        assertLt(userOut, cleanOut, "front-running worsens the fill");
        vm.prank(BOT);
        uint256 botExit = curve.sell(botTokens, 1, BOT, block.timestamp);
        assertGt(botExit, botSpent, "small bot can profit within the victim's slippage limit");
        string memory label = string.concat("Scenario curve_t", vm.toString(second), "_", suffix);
        console2.log(string.concat(label, "_pnl_stock_raw:"), int256(botExit) - int256(botSpent));
        console2.log(
            string.concat(label, "_victim_loss_percent_e18:"), Math.mulDiv(cleanOut - userOut, 100e18, cleanOut)
        );
        assertTrue(vm.revertToState(state));
    }

    function test_smallSnipersStillProfitWithinStrictMinOut() public {
        for (uint256 second = 1; second <= 2; ++second) {
            _assertSmallSniper(second, 0.1e18, 9900, "small_bot");
            _assertSmallSniper(second, 0.01e18, 9990, "tiny_bot");
        }
    }

    function test_postWindowCurveOrderAndTightMinOut() public {
        vm.warp(block.timestamp + 3);
        assertEq(curve.buyRateBps(), curve.taxBps());
        uint256 snapshot = vm.snapshotState();
        Outcome memory botFirst = _curveRun(true);
        assertTrue(vm.revertToState(snapshot));
        snapshot = vm.snapshotState();
        Outcome memory userFirst = _curveRun(false);
        assertTrue(vm.revertToState(snapshot));
        assertLt(botFirst.userOut, userFirst.userOut, "front-running raises the later buyer's execution price");
        assertGt(botFirst.botSale, botFirst.botSpent, "a loose-slippage victim can fund a curve sandwich");
        assertLt(userFirst.botSale, userFirst.botSpent, "buying after the user and unwinding loses to fees");
        _log("curve_bot_first", botFirst);
        _log("curve_user_first", userFirst);
        console2.log("Scenario sniper_curve victim_loss_token_raw:", userFirst.userOut - botFirst.userOut);

        uint256 cleanQuote;
        (, cleanQuote,) = curve.quoteBuy(USER_BUY);
        uint256 state = vm.snapshotState();
        (, uint256 botTokens,) = _curveBuy(BOT, BOT_BUY);
        vm.prank(USER);
        vm.expectRevert(Curve.Slippage.selector);
        curve.buy(USER_BUY, cleanQuote * 99 / 100, USER, block.timestamp);
        assertEq(token.balanceOf(USER), 0, "reverted victim buy must not transfer tokens");
        vm.prank(BOT);
        uint256 botExit = curve.sell(botTokens, 1, BOT, block.timestamp);
        assertLt(botExit, BOT_BUY, "without the victim leg, the bot's taxed round trip loses");
        console2.log("Scenario sniper_curve_protected bot_pnl_stock_raw:", int256(botExit) - int256(BOT_BUY));
        assertTrue(vm.revertToState(state));
    }

    function test_graduatedOpeningHasFlatTaxAndNoLaunchSpike() public {
        _graduateV2(curve);
        assertEq(hook.buyRateBps(key.toId()), curve.taxBps(), "V2 graduation does not start V1 snipe tax");
        assertEq(hook.sellRateBps(key.toId()), curve.taxBps(), "V2 graduation does not start sell spike");
        uint256 snapshot = vm.snapshotState();
        Outcome memory botFirst = _v4Run(true, 2e18, 5e18);
        assertTrue(vm.revertToState(snapshot));
        snapshot = vm.snapshotState();
        Outcome memory userFirst = _v4Run(false, 2e18, 5e18);
        assertTrue(vm.revertToState(snapshot));
        assertLt(botFirst.userOut, userFirst.userOut, "V4 opening order worsens later buyer's output");
        assertLt(botFirst.botSale, botFirst.botSpent, "this V4 opening sandwich loses after ordinary taxes");
        assertGt(botFirst.botSale, userFirst.botSale, "front-running still improves the bot's result");
        _log("v4_bot_first", botFirst);
        _log("v4_user_first", userFirst);
        console2.log("Scenario sniper_v4 victim_loss_token_raw:", userFirst.userOut - botFirst.userOut);

        (uint256 botTokens,) = _v4Buy(BOT, 2e18, 1);
        (uint160 priceBefore,,,) = pm.getSlot0(key.toId());
        (uint256 tokenTaxBefore, uint256 stockTaxBefore) = hook.accrued(key.toId());
        vm.prank(USER);
        vm.expectPartialRevert(Router.TooLittle.selector);
        router.buy(_params(5e18, 2, userFirst.userOut * 99 / 100), _empty());
        (uint160 priceAfter,,,) = pm.getSlot0(key.toId());
        (uint256 tokenTaxAfter, uint256 stockTaxAfter) = hook.accrued(key.toId());
        assertEq(priceAfter, priceBefore, "rejected user order restores V4 spot price");
        assertEq(tokenTaxAfter, tokenTaxBefore, "rejected order restores token-tax accounting");
        assertEq(stockTaxAfter, stockTaxBefore, "rejected order restores stock-tax accounting");
        assertEq(token.balanceOf(USER), 0);
        (uint256 unopposedExit,) = _v4Sell(BOT, botTokens);
        assertLt(unopposedExit, 2e18, "tight slippage removes the profitable victim leg");
        console2.log("Scenario sniper_v4_protected bot_pnl_stock_raw:", int256(unopposedExit) - int256(2e18));
    }

    function test_graduatedOpeningSizeSweep() public {
        _graduateV2(curve);
        uint256[3] memory botBudgets = [uint256(2e18), 5e18, 10e18];
        uint256[3] memory userBudgets = [uint256(10e18), 20e18, 30e18];
        for (uint256 i; i < botBudgets.length; ++i) {
            uint256 state = vm.snapshotState();
            Outcome memory botFirst = _v4Run(true, botBudgets[i], userBudgets[i]);
            assertTrue(vm.revertToState(state));
            state = vm.snapshotState();
            Outcome memory userFirst = _v4Run(false, botBudgets[i], userBudgets[i]);
            assertTrue(vm.revertToState(state));
            assertEq(botFirst.userSpent, userBudgets[i], "victim must get a full fill in attacked order");
            assertEq(userFirst.userSpent, userBudgets[i], "victim must get a full fill in clean order");
            assertLt(botFirst.userOut, userFirst.userOut, "earlier buy worsens victim's rate");
            assertGt(botFirst.botSale, userFirst.botSale, "compare order effects at the same budgets");
            // Surplus launch tokens now deepen this pool. The first two historical fixtures lose after fees;
            // ordering still harms the user's fill, and a positive bot return is not a universal invariant.
            if (i <= 1) assertLt(botFirst.botSale, botFirst.botSpent, "historical fixture loses with locked surplus LP");
            string memory label =
                string.concat("v4_size_", vm.toString(botBudgets[i] / 1e18), "_", vm.toString(userBudgets[i] / 1e18));
            _log(label, botFirst);
            console2.log(
                string.concat("Scenario ", label, " victim_loss_token_raw:"), userFirst.userOut - botFirst.userOut
            );
            if (i == 1) {
                uint256 protectedState = vm.snapshotState();
                (uint256 botTokens,) = _v4Buy(BOT, botBudgets[i], 1);
                vm.prank(USER);
                vm.expectPartialRevert(Router.TooLittle.selector);
                router.buy(_params(userBudgets[i], 2, userFirst.userOut * 99 / 100), _empty());
                (uint256 protectedExit,) = _v4Sell(BOT, botTokens);
                assertLt(protectedExit, botBudgets[i], "min-out rejection leaves only a losing round trip");
                console2.log(
                    "Scenario sniper_v4_size_5_20_protected bot_pnl_stock_raw:",
                    int256(protectedExit) - int256(botBudgets[i])
                );
                assertEq(token.balanceOf(USER), 0);
                assertTrue(vm.revertToState(protectedState));
            }
        }
    }

    function test_buybackNoticeCannotRaiseV2SniperExitTax() public {
        _graduateV2(curve);
        (uint256 botTokens,) = _v4Buy(BOT, 2e18, 1);
        _v4Buy(USER, 5e18, 1);
        uint256 state = vm.snapshotState();
        (uint256 flatExit, uint256 flatTax) = _v4Sell(BOT, botTokens);
        assertTrue(vm.revertToState(state));
        vm.prank(curve.treasury());
        hook.noteEvent();
        assertEq(hook.sellRateBps(key.toId()), curve.taxBps());
        (uint256 afterNoticeExit, uint256 afterNoticeTax) = _v4Sell(BOT, botTokens);
        assertEq(afterNoticeExit, flatExit);
        assertEq(afterNoticeTax, flatTax);
        console2.log("Scenario sniper_v4_flat_exit stock_out_raw:", flatExit);
        console2.log("Scenario sniper_v4_flat_exit tax_stock_raw:", flatTax);
        console2.log("Scenario sniper_v4_after_buyback stock_out_raw:", afterNoticeExit);
        console2.log("Scenario sniper_v4_after_buyback tax_stock_raw:", afterNoticeTax);
        vm.warp(block.timestamp + 120);
        assertEq(hook.sellRateBps(key.toId()), curve.taxBps(), "spike expires after 120 seconds");
    }
}
