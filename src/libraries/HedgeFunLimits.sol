// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// The bounds the factory checks a default against and the hook and the treasury check again at birth. One copy, so
// the three can never disagree. Each contract still publishes its own as a `public constant` of the same name.
uint256 constant MAX_TAX_BPS = 1500;
uint256 constant MAX_SPIKE_BPS = 9000;
uint256 constant MAX_TIP_BPS = 100;
uint256 constant MAX_SNIPE_BPS = 9900;               // a buyer inside the launch window always keeps at least 1%
uint256 constant MAX_BOUNTY_BPS = 200;
uint256 constant MAX_SLIPPAGE_BPS = 300;
uint256 constant MAX_BAND_BPS_PER_HOUR = 200;
uint256 constant MAX_BUYBACK_IMPACT_BPS = 1000;

// What a launch may carry in its name and symbol, in bytes
uint256 constant MAX_NAME_BYTES = 64;
uint256 constant MAX_SYMBOL_BYTES = 32;
