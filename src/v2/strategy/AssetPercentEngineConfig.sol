// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Schema 2 for engine version 1: trading limits are percentages of current fund total external assets.
/// @dev Schema 1 is never reinterpreted. words[0] retains target[0..15], band[16..31], cooldown[32..63],
/// payout[64..79]; reserved bits must be zero. words[1]/[2] are full-width bps words, with no reserved high bits.
/// Percentage caps are floored at preview/execute using Math.mulDiv(NAV, bps, 10000).
/// The listing's sellChunk clips one action; minLot is a runtime floor and cannot inflate a percentage cap.
library AssetPercentEngineConfig {
    uint32 internal constant CONFIG_SCHEMA = 2;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MIN_TARGET_BPS = 2_000;
    uint256 internal constant MAX_TARGET_BPS = 9_000;
    uint256 internal constant MIN_COOLDOWN = 600;
    uint256 internal constant MAX_DAILY_TURNOVER_MULTIPLE = 24;

    function payoutBps(bytes32 word0) internal pure returns (uint256) {
        return uint16(uint256(word0) >> 64);
    }

    /// @param minDeadband Optional caller-supplied minimum for tooling. Protocol core and policy pass zero.
    /// @dev The creator chooses the band, including zero; only target/band geometry constrains it.
    function valid(bytes32[3] memory words, uint256 minDeadband) internal pure returns (bool) {
        uint256 packed = uint256(words[0]);
        uint256 target = uint16(packed);
        uint256 band = uint16(packed >> 16);
        uint256 trade = uint256(words[1]);
        uint256 daily = uint256(words[2]);
        return packed >> 80 == 0 && payoutBps(words[0]) <= BPS
            && target >= MIN_TARGET_BPS && target <= MAX_TARGET_BPS
            && band >= minDeadband && band < target && target + band < BPS
            && uint32(packed >> 32) >= MIN_COOLDOWN && trade >= 1 && trade <= BPS
            && daily >= trade && daily <= BPS && daily <= trade * MAX_DAILY_TURNOVER_MULTIPLE;
    }
}
