// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";
import {TradingCalendar} from "../src/TradingCalendar.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";

/// @dev V2 extension of the emergency runbook: launch controls do not freeze curve reserves,
/// and the calendar still gates the stock strategy after graduation activates its treasury.
contract V2EmergencyTest is V2FactoryFixture {
    function test_haltAndDelistDoNotTrapCurveFundsOrBlockGraduation() public {
        _setUpV2(18);
        TradingCalendar calendar = new TradingCalendar(owner);
        oracle = new PriceOracle(address(stock), address(oracle.stockFeed()), address(oracle.usdgFeed()),
            address(calendar), 26 hours, 26 hours);
        vm.prank(owner);
        factory.list(address(stock), address(oracle), address(stockPool), openPrice, true);
        (, HedgeFunBondingCurve curve,) = _launchV2(true);
        HedgeFunTreasuryBase treasury = HedgeFunTreasuryBase(curve.treasury());
        stock.transfer(address(treasury), 10 ether);
        assertFalse(treasury.book(), "pre-graduation strategy is inactive");
        uint256 day = calendar.tradingDate(block.timestamp);
        vm.startPrank(owner);
        calendar.setOverride(day, 1);
        factory.setPublicLaunch(false);
        factory.list(address(stock), address(oracle), address(stockPool), openPrice, false);
        vm.stopPrank();

        (, uint256 got) = curve.buy(10 ether, 1, address(this), block.timestamp);
        assertGt(curve.sell(got / 2, 1, address(this), block.timestamp), 0);
        _graduateV2(curve);
        assertEq(treasury.hook(), address(hook));
        (bool healthy,) = treasury.health();
        assertFalse(healthy);
        assertFalse(treasury.book(), "calendar halt survives activation");
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        HedgeFunV2Treasury(address(treasury)).execute();

        vm.prank(owner); calendar.setOverride(day, 0);
        assertTrue(treasury.book(), "resume restores booking for existing strategies despite delisting");
    }
}
