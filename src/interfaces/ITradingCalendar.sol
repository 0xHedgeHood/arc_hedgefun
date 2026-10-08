// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITradingCalendar {
    function isClosed(uint256 ts) external view returns (bool);
    function isScheduledClosure(uint256 ts) external view returns (bool);
    /// the US trading date `ts` belongs to, as days since 1970-01-01: it rolls at 20:00 New York time, DST included
    function tradingDate(uint256 ts) external view returns (uint256);
}
