// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TradingCalendar} from "../src/TradingCalendar.sol";

/// The calendar decides when the rule may price off the pool instead of Chainlink, so being wrong about a date is
/// not cosmetic: a day it wrongly calls CLOSED is a day the treasury trades on the pool's word alone while the
/// real feed is live and disagreeing. There is no on-chain NYSE calendar to import, so this checks the arithmetic
/// against dates looked up independently -- real NYSE closures, real DST boundaries, and the session rule that
/// makes 20:00 ET the start of the next trading day.
contract TradingCalendarTest is Test {
    TradingCalendar cal;

    function setUp() public { cal = new TradingCalendar(address(this)); }

    /// @dev noon ET on a given UTC date, safely inside one session whichever way DST falls
    function _noonET(uint256 y, uint256 m, uint256 d) internal pure returns (uint256) {
        return _ts(y, m, d) + 17 hours;
    }

    function _ts(uint256 y, uint256 m, uint256 d) internal pure returns (uint256) {
        // days from civil (Howard Hinnant), the same algorithm the contract inverts
        y -= m <= 2 ? 1 : 0;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return (era * 146097 + doe - 719468) * 1 days;
    }

    function test_weekendsAreClosedAndWeekdaysAreNot() public view {
        assertFalse(cal.isClosed(_noonET(2026, 9, 17)), "Thursday 2026-09-17");
        assertFalse(cal.isClosed(_noonET(2026, 9, 18)), "Friday 2026-09-18");
        assertTrue(cal.isClosed(_noonET(2026, 9, 19)), "Saturday 2026-09-19");
        assertTrue(cal.isClosed(_noonET(2026, 9, 20)), "Sunday 2026-09-20");
        assertFalse(cal.isClosed(_noonET(2026, 9, 21)), "Monday 2026-09-21");
    }

    /// Fixed-date holidays, and the weekend-observance rule that moves them.
    function test_fixedHolidays() public view {
        assertTrue(cal.isClosed(_noonET(2027, 1, 1)), "New Year 2027-01-01 (Friday)");
        assertTrue(cal.isClosed(_noonET(2026, 7, 3)), "Independence observed 2026-07-03 (Jul 4 is Saturday)");
        assertTrue(cal.isClosed(_noonET(2026, 6, 19)), "Juneteenth 2026-06-19 (Friday)");
        assertTrue(cal.isClosed(_noonET(2026, 12, 25)), "Christmas 2026-12-25 (Friday)");
        assertFalse(cal.isClosed(_noonET(2026, 12, 24)), "Christmas Eve is a trading day");
    }

    /// Floating holidays: nth-weekday rules rather than dates.
    function test_floatingHolidays() public view {
        assertTrue(cal.isClosed(_noonET(2027, 1, 18)), "MLK: 3rd Monday Jan 2027");
        assertTrue(cal.isClosed(_noonET(2027, 2, 15)), "Presidents: 3rd Monday Feb 2027");
        assertTrue(cal.isClosed(_noonET(2026, 5, 25)), "Memorial: last Monday May 2026");
        assertTrue(cal.isClosed(_noonET(2026, 9, 7)), "Labor: 1st Monday Sep 2026");
        assertTrue(cal.isClosed(_noonET(2026, 11, 26)), "Thanksgiving: 4th Thursday Nov 2026");
        assertFalse(cal.isClosed(_noonET(2026, 11, 27)), "the Friday after is a (short) trading day");
    }

    /// Good Friday moves with Easter, which is computed rather than listed.
    function test_goodFriday() public view {
        assertTrue(cal.isClosed(_noonET(2026, 4, 3)), "Good Friday 2026-04-03");
        assertTrue(cal.isClosed(_noonET(2027, 3, 26)), "Good Friday 2027-03-26");
        assertFalse(cal.isClosed(_noonET(2026, 4, 6)), "Easter Monday is a trading day in the US");
    }

    /// The session boundary is 20:00 ET, not midnight: past it, the timestamp belongs to the NEXT trading date.
    /// That is what makes Friday evening closed and Sunday evening open.
    function test_theSessionRollsAtTwentyHundredEastern() public view {
        uint256 friday = _ts(2026, 9, 18);
        assertFalse(cal.isClosed(friday + 23 hours), "Friday 19:00 ET is still open");   // 19:00 EDT = 23:00 UTC
        assertTrue(cal.isClosed(friday + 24 hours + 1), "Friday 20:00 ET has rolled into Saturday");

        uint256 sunday = _ts(2026, 9, 20);
        assertTrue(cal.isClosed(sunday + 23 hours), "Sunday 19:00 ET is still the weekend");
        assertFalse(cal.isClosed(sunday + 24 hours + 1), "Sunday 20:00 ET opens Monday's session");
    }

    /// A Sunday evening before a Monday holiday must stay closed: the session has rolled onto the holiday.
    function test_sundayEveningBeforeAHolidayStaysClosed() public view {
        uint256 sundayBeforeLabor = _ts(2026, 9, 6);
        assertTrue(cal.isClosed(sundayBeforeLabor + 24 hours + 1), "rolls into Labor Day, which is closed");
    }

    /// DST: the same wall-clock hour is a different UTC offset either side of the boundary, and the session rule
    /// is stated in ET. 2026: DST starts Mar 8, ends Nov 1.
    function test_daylightSavingMovesTheBoundary() public view {
        uint256 janFri = _ts(2026, 1, 9);                                   // EST, UTC-5
        assertFalse(cal.isClosed(janFri + 24 hours), "19:00 EST = 00:00 UTC next day, still open");
        uint256 julFri = _ts(2026, 7, 10);                                  // EDT, UTC-4
        assertFalse(cal.isClosed(julFri + 23 hours), "19:00 EDT = 23:00 UTC, still open");
        assertTrue(cal.isClosed(julFri + 24 hours + 1), "20:00 EDT has rolled");
    }

    /// The owner may force a date either way, for the closures no rule predicts -- and cannot do anything else.
    function test_overrideBothWays() public {
        uint256 ordinaryThursday = _noonET(2026, 9, 17);
        assertFalse(cal.isClosed(ordinaryThursday));
        cal.setOverride(cal.tradingDate(ordinaryThursday), 1);
        assertTrue(cal.isClosed(ordinaryThursday), "a day of mourning can be forced closed");

        uint256 christmas = _noonET(2026, 12, 25);
        assertTrue(cal.isClosed(christmas));
        cal.setOverride(cal.tradingDate(christmas), 2);
        assertFalse(cal.isClosed(christmas), "and a holiday can be forced open");

        // read the date BEFORE arming the prank: a prank is spent on the next call, and `tradingDate` is one
        uint256 day = cal.tradingDate(ordinaryThursday);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        cal.setOverride(day, 0);
    }
}
