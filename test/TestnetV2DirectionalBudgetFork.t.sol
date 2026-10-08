// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TestnetMarket} from "../script/testnet/TestnetMarket.sol";
import {StrategyAction} from "../src/v2/strategy/IStrategyPolicy.sol";
import {TestnetV2BuybackForkFixture} from "./TestnetV2WeekendBuybackFork.t.sol";

/// Fork only: use the deployed controller, real stock/USDG V3 pool and TestnetMarket swaps.
/// No etching, balance overrides or mocked feeds in these directional-budget regressions.
contract TestnetV2DirectionalBudgetForkTest is TestnetV2BuybackForkFixture {
    TestnetMarket constant MARKET = TestnetMarket(0xc1AF2f52980F8A7AA4E90A8E30D5c3FaF0375f21);

    function _market(uint256 price) private {
        address venue = address(treasury.pool());
        vm.prank(MARKET.owner()); MARKET.setPrice(venue, price);
        vm.warp(block.timestamp + 601);
        vm.prank(MARKET.owner()); MARKET.poke(venue);
        (bool healthy,) = treasury.health();
        assertTrue(healthy, "genuine venue and fresh oracle must agree");
    }

    function test_forkSameDayDipBudgetSurvivesPriorSales() public {
        vm.prank(controller.owner()); controller.schedule(address(proxy), address(next), "");
        vm.warp(block.timestamp + controller.UPGRADE_DELAY());
        controller.execute(address(proxy), "");
        uint256 price = 358e18;
        _market(price);
        for (uint256 i; i < 3; ++i) {
            (bool due, StrategyAction action,) = treasury.preview();
            assertTrue(due);
            assertEq(uint256(action), uint256(StrategyAction.SellStock));
            treasury.execute();
            vm.warp(block.timestamp + 601);
            address venue = address(treasury.pool());
            vm.prank(MARKET.owner()); MARKET.syncFeed(venue);
        }
        (, uint256 basis,,, uint256 bought, uint256 sold) = treasury.dailyRiskLimits();
        assertEq(bought, 0);
        _market(price * 60 / 100);
        (bool due, StrategyAction action, uint256 offered) = treasury.preview();
        assertTrue(due, "same-day independent buy budget is still available");
        assertEq(uint256(action), uint256(StrategyAction.BuyStock));
        uint256 live = Math.mulDiv(treasury.bookedStock(), treasury.oracle().price(), 1e30) + treasury.reserveUsdg();
        assertGt(sold, live / 2, "old shared dynamic 50% cap would block this dip buy");
        uint256 cash = treasury.reserveUsdg();
        treasury.execute();
        (, uint256 afterBasis,,, uint256 boughtAfter, uint256 soldAfter) = treasury.dailyRiskLimits();
        assertEq(afterBasis, basis);
        assertEq(soldAfter, sold);
        assertEq(boughtAfter, cash - treasury.reserveUsdg());
        assertLe(boughtAfter, offered);
        assertGt(boughtAfter, 0);
        emit log_named_uint("pinned basis USDG raw", basis);
        emit log_named_uint("prior sells USDG raw", sold);
        emit log_named_uint("old dynamic shared cap USDG raw", live / 2);
        emit log_named_uint("new dip buy actual USDG raw", boughtAfter);
    }

    function test_forkLegacySameDayUseSurvivesRealControllerUpgrade() public {
        vm.prank(controller.owner()); controller.schedule(address(proxy), address(next), "");
        vm.warp(block.timestamp + controller.UPGRADE_DELAY() + 3 hours);
        _market(358e18);
        treasury.execute(); // still running the actual deployed old implementation
        uint256 used = treasury.turnoverInEpoch();
        uint64 epoch = treasury.turnoverEpoch();
        assertGt(used, 0);
        vm.warp(block.timestamp + 600);
        controller.execute(address(proxy), "");
        (uint64 current,,,, uint256 bought, uint256 sold) = treasury.dailyRiskLimits();
        assertEq(current, epoch);
        assertEq(bought, used);
        assertEq(sold, used);
        assertEq(treasury.turnoverInEpoch(), used);
        assertEq(proxy.implementation(), address(next));
    }
}
