// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ITradingCalendar} from "./interfaces/ITradingCalendar.sol";

/// @notice A crypto asset's session: open every second of every day, unless the owner halts it.
/// @dev Nothing is ever a scheduled closure, so a treasury never takes the stock market's closure band here, and
///      the engine treasuries' daily turnover rolls at 00:00 UTC. The halt is the only lever: while it is set every
///      oracle reading this calendar answers false, which stops strategy execution. It does not stop curve or pool
///      trading.
contract CryptoCalendar is Ownable2Step, ITradingCalendar {
    bool public halted;

    event HaltedSet(bool halted);

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setHalted(bool value) external onlyOwner {
        halted = value;
        emit HaltedSet(value);
    }

    function isClosed(uint256) external view returns (bool) { return halted; }
    function isScheduledClosure(uint256) external pure returns (bool) { return false; }
    function tradingDate(uint256 ts) external pure returns (uint256) { return ts / 1 days; }
}
