// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Schema 3: input-asset percentages and daily turnover of tradable stock plus available USDG.
/// @dev words[0]: target[0..15], band[16..31], cooldown[32..63], payout[64..79].
/// words[1]: buyBps[0..15], sellBps[16..31]. words[2]: daily buy bps[0..15], sell bps[16..31].
/// A zero high half preserves the old encoding by applying the low half to both directions.
/// Distinct denominators mean dailyBps need not be greater than buyBps or sellBps. The execution core floors
/// each percentage and rejects sub-minimum trades rather than increasing a cap. Schemas 1 and 2 are unchanged.
///
/// The percentages are the creator's, under two protocol limits. Schema 3 has no listing chunk, so nothing else
/// bounds one action: `MAX_ACTION_BPS` does, and it scales with the treasury where a fixed amount could not.
/// And the allocation band is at least what one trade costs on the listing, its pool fee plus the keeper
/// reward. That is a floor against churn, not a break-even: a narrower band only trades more often for slightly
/// less, with no point under which it starts to lose, so the floor is one trade's cost and not a multiple of
/// the listing's slippage LIMIT, which is a bound on a fill and not a cost. The treasury's constructor knows
/// the listing and passes the floor; a caller without it (the policy, tooling) passes zero.
library TradablePercentEngineConfig {
    uint32 internal constant CONFIG_SCHEMA = 3;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MIN_TARGET_BPS = 2_000;
    uint256 internal constant MAX_TARGET_BPS = 9_000;
    /// @notice 60 seconds; it was one 600-second V3 TWAP window. The per-action and daily shares still bound a day.
    uint256 internal constant MIN_COOLDOWN = 60;
    /// @notice the most one action may take: a quarter of the available cash (a buy) or of the tradable stock (a sale)
    uint256 internal constant MAX_ACTION_BPS = 2_500;

    function payoutBps(bytes32 word0) internal pure returns (uint256) {
        return uint16(uint256(word0) >> 64);
    }

    function buyBps(bytes32 word1) internal pure returns (uint256) {
        return uint16(uint256(word1));
    }

    function sellBps(bytes32 word1) internal pure returns (uint256) {
        return uint16(uint256(word1) >> 16);
    }

    function dailyBps(bytes32 word2, bool buy) internal pure returns (uint256) {
        uint256 sell = uint16(uint256(word2) >> 16);
        return buy || sell == 0 ? uint16(uint256(word2)) : sell;
    }

    function valid(bytes32[3] memory words, uint256 minDeadband) internal pure returns (bool) {
        uint256 packed = uint256(words[0]);
        uint256 target = uint16(packed);
        uint256 band = uint16(packed >> 16);
        uint256 buy = buyBps(words[1]);
        uint256 sell = sellBps(words[1]);
        uint256 dailyBuy = dailyBps(words[2], true);
        uint256 dailySell = dailyBps(words[2], false);
        return packed >> 80 == 0 && payoutBps(words[0]) <= BPS && target >= MIN_TARGET_BPS && target <= MAX_TARGET_BPS
            && band >= minDeadband && band < target && target + band < BPS && uint32(packed >> 32) >= MIN_COOLDOWN
            && uint256(words[1]) >> 32 == 0 && buy >= 1 && buy <= MAX_ACTION_BPS && sell >= 1 && sell <= MAX_ACTION_BPS
            && uint256(words[2]) >> 32 == 0 && dailyBuy >= 1 && dailyBuy <= BPS && dailySell >= 1 && dailySell <= BPS;
    }
}
