// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Every rate in the launchpad is in basis points of this.
uint256 constant BPS = 10_000;

/// The arithmetic the rule shares, on OpenZeppelin's 512-bit `mulDiv`: no product here can overflow, and every
/// rounding direction is named. A threshold is met or not EXACTLY -- `reached`, `fellTo` and `exceeds` are the
/// cross-multiplied comparisons (`p * BPS >= ref * (BPS + rate)` and so on) with the division rounded the way that
/// keeps them equivalent.
library HedgeFunMath {
    /// `rate` basis points of `x`, rounded down
    function bps(uint256 x, uint256 rate) internal pure returns (uint256) { return Math.mulDiv(x, rate, BPS); }

    /// is `p` at least `rate` above `ref`? (take-profit)
    function reached(uint256 p, uint256 ref, uint256 rate) internal pure returns (bool) { return p >= Math.mulDiv(ref, BPS + rate, BPS, Math.Rounding.Ceil); }

    /// is `p` at least `rate` below `ref`? (stop, dip)
    function fellTo(uint256 p, uint256 ref, uint256 rate) internal pure returns (bool) { return p <= Math.mulDiv(ref, BPS - rate, BPS); }

    /// is `gap` more than `rate` of `ref`? (deviation gates)
    function exceeds(uint256 gap, uint256 ref, uint256 rate) internal pure returns (bool) { return gap > Math.mulDiv(ref, rate, BPS); }

    /// is `got` short of `rate` of `whole`? (`got * BPS < whole * rate`, the slippage floor)
    function short(uint256 got, uint256 whole, uint256 rate) internal pure returns (bool) { return got < Math.mulDiv(whole, rate, BPS, Math.Rounding.Ceil); }

    /// `x` moved `rate` up, or down, rounded down
    function shift(uint256 x, uint256 rate, bool up) internal pure returns (uint256) { return Math.mulDiv(x, up ? BPS + rate : BPS - rate, BPS); }
}
