// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// The 24/5 US equity calendar, on chain and self-contained: the trading day runs Sunday 20:00 ET to Friday
/// 20:00 ET continuously; the weekend gap and NYSE holidays are the closures. A session that has rolled past 20:00
/// belongs to the NEXT calendar date, so Sunday 21:00 before a Monday holiday is closed and Friday 19:00 is open.
///
/// Nothing here needs a keeper. US daylight saving (second Sunday of March 02:00 to first Sunday of November
/// 02:00, local) and the NYSE holidays (rules, not a list: MLK, Presidents, Good Friday, Memorial, Juneteenth,
/// Independence, Labor, Thanksgiving, Christmas, New Year, weekend holidays observed on the adjacent weekday) are
/// computed from the timestamp. The owner may add or remove a date for the closures no rule predicts (a day of
/// mourning) but never has to -- and an override can only ever stop trading, never widen what trades: see
/// `isScheduledClosure`.
///
/// Why a calendar and not the feed's age: the Chainlink stock feeds update on a 0.5% deviation only, so a quiet
/// weekday night can leave a gap of many hours, and age alone cannot tell that from a closed market. Age stays as
/// the fail-closed check in `PriceOracle`.
contract TradingCalendar is Ownable2Step {
    mapping(uint256 => uint8) public override_;   // trading-date index -> 0 none, 1 forced closed, 2 forced open

    event OverrideSet(uint256 day, uint8 mode);

    constructor(address owner_) Ownable(owner_) {}

    function setOverride(uint256 day, uint8 mode) external onlyOwner { require(mode <= 2, "mode"); override_[day] = mode; emit OverrideSet(day, mode); }

    // ------------------------------------------------------------------------------------------ civil dates
    /// @dev days since 1970-01-01 -> (y, m, d). Howard Hinnant's civil_from_days.
    function civil(uint256 day) public pure returns (uint256 y, uint256 m, uint256 d) {
        int256 z = int256(day) + 719468;
        int256 era = (z >= 0 ? z : z - 146096) / 146097;
        uint256 doe = uint256(z - era * 146097);
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        int256 yy = int256(yoe) + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        y = uint256(yy + (m <= 2 ? int256(1) : int256(0)));
    }

    /// @dev (y, m, d) -> days since epoch. days_from_civil.
    function dayOf(uint256 y, uint256 m, uint256 d) public pure returns (uint256) {
        int256 yy = int256(y) - (m <= 2 ? int256(1) : int256(0));
        int256 era = (yy >= 0 ? yy : yy - 399) / 400;
        uint256 yoe = uint256(yy - era * 400);
        uint256 mp = m > 2 ? m - 3 : m + 9;
        uint256 doy = (153 * mp + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return uint256(era * 146097 + int256(doe) - 719468);
    }

    /// @dev 0 = Sunday .. 6 = Saturday (1970-01-01 was a Thursday)
    function dayOfWeek(uint256 day) public pure returns (uint256) { return (day + 4) % 7; }

    /// @dev the n-th (1-based) given weekday of a month, as a day index
    function nthWeekday(uint256 y, uint256 m, uint256 weekday, uint256 n) public pure returns (uint256) {
        uint256 first = dayOf(y, m, 1);
        uint256 off = (weekday + 7 - dayOfWeek(first)) % 7;
        return first + off + (n - 1) * 7;
    }

    /// @dev the last given weekday of a month
    function lastWeekday(uint256 y, uint256 m, uint256 weekday) public pure returns (uint256) {
        uint256 nextFirst = m == 12 ? dayOf(y + 1, 1, 1) : dayOf(y, m + 1, 1);
        uint256 last = nextFirst - 1;
        return last - (dayOfWeek(last) + 7 - weekday) % 7;
    }

    // ------------------------------------------------------------------------------------------ Eastern time
    /// @dev US DST in force at `ts` (UTC): from the second Sunday of March 07:00 UTC to the first Sunday of November 06:00 UTC
    function isDst(uint256 ts) public pure returns (bool) {
        (uint256 y, , ) = civil(ts / 1 days);
        uint256 start = nthWeekday(y, 3, 0, 2) * 1 days + 7 hours;
        uint256 end = nthWeekday(y, 11, 0, 1) * 1 days + 6 hours;
        return ts >= start && ts < end;
    }

    /// @notice Seconds to add to UTC to get Eastern time at `ts`: -4h (EDT) or -5h (EST).
    function utcOffset(uint256 ts) public pure returns (int256) { return isDst(ts) ? int256(-4 hours) : int256(-5 hours); }

    function _local(uint256 ts) internal pure returns (uint256 day, uint256 hour) {
        uint256 l = uint256(int256(ts) + utcOffset(ts));
        day = l / 1 days; hour = (l % 1 days) / 1 hours;
    }

    /// @notice Trading date a moment belongs to: after 20:00 ET it is the next date's session.
    function tradingDate(uint256 ts) public pure returns (uint256 d) { (uint256 day, uint256 hour) = _local(ts); d = hour >= 20 ? day + 1 : day; }

    // ------------------------------------------------------------------------------------------ holidays
    /// @dev Anonymous Gregorian computus: Easter Sunday as a day index; Good Friday is two days earlier.
    function easter(uint256 y) public pure returns (uint256) {
        uint256 a = y % 19; uint256 b = y / 100; uint256 c = y % 100;
        uint256 h = (19 * a + b - b / 4 - (b - (b + 8) / 25 + 1) / 3 + 15) % 30;
        uint256 l = (32 + 2 * (b % 4) + 2 * (c / 4) - h - c % 4) % 7;
        uint256 n = h + l - 7 * ((a + 11 * h + 22 * l) / 451) + 114;
        return dayOf(y, n / 31, n % 31 + 1);
    }

    /// @dev weekend holidays move to the adjacent weekday, the way the exchange takes them
    function observed(uint256 day) public pure returns (uint256) {
        uint256 w = dayOfWeek(day);
        if (w == 6) return day - 1;
        if (w == 0) return day + 1;
        return day;
    }

    /// @notice Is `day` (a day index) an NYSE full-day closure by rule?
    function isHoliday(uint256 day) public pure returns (bool) {
        (uint256 y, uint256 m, ) = civil(day);
        if (m == 1) {
            // New Year: a Sunday Jan 1 closes Monday; a Saturday Jan 1 closes nothing (NYSE does not take the Friday)
            uint256 ny = dayOf(y, 1, 1); if (dayOfWeek(ny) == 0) ny += 1;
            if ((dayOfWeek(ny) != 6 && day == ny) || day == nthWeekday(y, 1, 1, 3)) return true;                 // New Year, MLK
        }
        if (m == 12 && day == observed(dayOf(y, 12, 25))) return true;                                            // Christmas
        if (m == 2 && day == nthWeekday(y, 2, 1, 3)) return true;                                                 // Presidents
        if ((m == 3 || m == 4) && day == easter(y) - 2) return true;                                              // Good Friday
        if (m == 5 && day == lastWeekday(y, 5, 1)) return true;                                                   // Memorial
        if ((m == 6 || m == 7) && (day == observed(dayOf(y, 6, 19)) || day == observed(dayOf(y, 7, 4)))) return true;   // Juneteenth, Independence
        if (m == 9 && day == nthWeekday(y, 9, 1, 1)) return true;                                                 // Labor
        if (m == 11 && day == nthWeekday(y, 11, 4, 4)) return true;                                               // Thanksgiving
        return false;
    }

    function dateClosed(uint256 day) public view returns (bool) {
        uint8 o = override_[day];
        if (o == 1) return true;
        if (o == 2) return false;
        return dateClosedByRule(day);
    }

    /// @notice the same question with the owner's overrides left out: weekends and the computed NYSE holidays only.
    /// @dev This is what bounds the owner. An override may HALT -- everything priced through `isClosed` stops on a
    ///      day forced shut -- but a consumer that does something MORE on a closure, as the treasury does when it
    ///      lets the pool's own mean pull the price inside a widening band, asks `isScheduledClosure`, which is built
    ///      on this. So forcing a live trading day "closed" parks the rule; it cannot swap the open-market gate for
    ///      the wider closed-market one. The owner can stop the rule trading, and cannot change what price it
    ///      trades at.
    function dateClosedByRule(uint256 day) public pure returns (bool) {
        uint256 w = dayOfWeek(day);
        return w == 0 || w == 6 || isHoliday(day);
    }

    function isClosedByRule(uint256 ts) public pure returns (bool) { return dateClosedByRule(tradingDate(ts)); }

    /// @notice a closure the schedule predicts AND the owner has left alone. This is the question a consumer asks
    ///         before doing anything MORE on a closure than it does on a trading day.
    /// @dev Both halves matter. The rule alone keeps an override from OPENING the closed-market path on a live
    ///      day; requiring no override as well lets the owner SHUT that path on a weekend. So `setOverride(day, 1)`
    ///      halts whatever `day` is, a weekend included, and `setOverride(day, 2)` hands the day to the live-feed
    ///      path and its ordinary gates.
    function isScheduledClosure(uint256 ts) public view returns (bool) {
        uint256 day = tradingDate(ts);
        return override_[day] == 0 && dateClosedByRule(day);
    }

    /// @notice Are US equities shut at `ts` (weekend or holiday)?
    function isClosed(uint256 ts) public view returns (bool) { return dateClosed(tradingDate(ts)); }

    /// @dev 20:00 ET on the day before trading date `d`, as a UTC timestamp: the session boundary
    function _sessionStart(uint256 d) internal pure returns (uint256) {
        uint256 approx = (d - 1) * 1 days + 20 hours + 5 hours;            // as if EST
        return uint256(int256((d - 1) * 1 days + 20 hours) - utcOffset(approx));
    }

    /// @notice First moment at or after `ts` when the market is open. Bounded: at most 14 days ahead.
    function nextOpen(uint256 ts) public view returns (uint256) {
        if (!isClosed(ts)) return ts;
        uint256 d = tradingDate(ts);
        for (uint256 i = 0; i < 14 && dateClosed(d); i++) d++;
        return _sessionStart(d);
    }

    /// @notice First moment at or after `ts` when the market is closed. Bounded: at most 14 days ahead.
    function nextClose(uint256 ts) public view returns (uint256) {
        if (isClosed(ts)) return ts;
        uint256 d = tradingDate(ts);
        for (uint256 i = 0; i < 14 && !dateClosed(d); i++) d++;
        return _sessionStart(d);
    }
}
