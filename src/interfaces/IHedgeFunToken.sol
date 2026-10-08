// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// the one thing the hook and the treasury ask of a strategy token: burn what they hold
interface IHedgeFunToken { function burn(uint256 amount) external; }
