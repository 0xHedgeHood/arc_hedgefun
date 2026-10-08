// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TradingCalendar} from "../src/TradingCalendar.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2AssetPercentEngineTreasury} from "../src/v2/HedgeFunV2AssetPercentEngineTreasury.sol";
import {V2AssetPercentEngineFixture} from "./V2AssetPercentEngine.t.sol";

contract V2AssetPercentTradingDayTest is V2AssetPercentEngineFixture {
    TradingCalendar private calendar;
    uint96 private nonce = 1300;
    uint256 private constant WINTER_ROLL = 1_768_438_800;
    uint256 private constant SUMMER_ROLL = 1_784_160_000;

    function setUp() public override {
        super.setUp();
        calendar = new TradingCalendar(owner);
        oracle = new PriceOracle(address(stock), address(stockFeed), address(usdgFeed), address(calendar), 26 hours, 26 hours);
        vm.prank(owner); factory.list(address(stock), address(oracle), address(venue), openPrice, true);
    }

    function _at(uint256 ts) private { vm.warp(ts); _price(PRICE); }
    function _start(uint256 ts) private returns (HedgeFunV2AssetPercentEngineTreasury t) {
        _at(ts); t = _launchPercent(nonce++, 1000, 1000, 0);
        assertEq(address(t.tradingCalendar()), address(calendar));
    }
    function _fill(HedgeFunV2AssetPercentEngineTreasury t, uint256 ts) private {
        _at(ts); Risk memory before_ = _risk(t);
        assertEq(before_.used, 0);
        (bool due,,) = t.preview(); assertTrue(due); t.execute();
        assertEq(t.turnoverEpoch(), calendar.tradingDate(ts));
        assertLe(t.turnoverInEpoch(), before_.daily); assertGe(t.turnoverInEpoch(), 5e6);
    }
    function _spent(HedgeFunV2AssetPercentEngineTreasury t, uint256 ts) private {
        _at(ts); assertEq(t.turnoverEpoch(), calendar.tradingDate(ts));
        assertEq(_risk(t).remaining, 0); _assertWait(t);
    }
    function _roll(uint256 roll) private {
        HedgeFunV2AssetPercentEngineTreasury t = _start(roll - 6 hours);
        _fill(t, roll - 15 minutes); _spent(t, roll - 5 minutes); _fill(t, roll + 5 minutes);
    }

    function test_realWinterSessionDoesNotResetAtUtcMidnight() public {
        HedgeFunV2AssetPercentEngineTreasury t = _start(WINTER_ROLL - 10 hours);
        _fill(t, WINTER_ROLL - 65 minutes); _spent(t, WINTER_ROLL - 55 minutes);
        _spent(t, WINTER_ROLL - 5 minutes); _fill(t, WINTER_ROLL + 5 minutes);
    }
    function test_realSummerSessionRollsAtTwentyNewYork() public { _roll(SUMMER_ROLL); }
    function test_dstMovesSessionRollAndDoesNotResetHistoryWithinASession() public {
        _roll(1_772_758_800); // 2026-03-05 20:00 EST
        _roll(1_773_100_800); // 2026-03-09 20:00 EDT
        _roll(1_793_318_400); // 2026-10-29 20:00 EDT
        _roll(1_793_667_600); // 2026-11-02 20:00 EST
    }
    function test_realMarketClosureWaitsWithoutReportingLiveCapacity() public {
        HedgeFunV2AssetPercentEngineTreasury t = _start(WINTER_ROLL - 10 hours);
        _at(WINTER_ROLL + 3 days); // Saturday
        assertTrue(calendar.isClosed(block.timestamp));
        assertFalse(_risk(t).healthy); assertEq(_risk(t).remaining, 0);
        (bool due,,) = t.preview(); assertFalse(due);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector); t.execute();
        assertEq(t.strategyNonce(), 0); assertEq(t.turnoverInEpoch(), 0);
    }
}
