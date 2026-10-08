// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The spot engine's `EngineConfig.words` layout (`CONFIG_SCHEMA_V1`) and the floors a launchable config
///         must clear. ONE function, used by `HedgeFunV2EngineTreasury`'s constructor (the authority) and by
///         `V2TreasuryDeployer` (`setEngineConfig`, `predict`, `deploy`), so the deployer refuses -- with a named
///         error, before CREATE2 -- exactly what the constructor would refuse as an opaque `TreasuryDeployFailed`.
///
/// `words[0]` packs `targetBps` (bits 0..15), `deadbandBps` (bits 16..31), `cooldown` seconds (bits 32..63) and
/// `payoutBps` (bits 64..79); bits 80 and up are reserved and must be zero. `words[1]` is `maxTradeUsdg`, the most one
/// action may take out of inventory. `words[2]` is `maxDailyTurnoverUsdg`, the most every action in one turnover epoch
/// may take out together.
///
/// `payoutBps` is the share of a sale's gain over the inventory's average cost that stays in stock and moves to the
/// buy-back instead of being sold: kind 0's profit split, chosen by the creator, 0 to `BPS`. The treasury applies it;
/// the policy is handed the word and ignores it.
///
/// The floors, and why each number (audit round 4, engine and economics lanes):
///  * `targetBps` in [`MIN_TARGET_BPS`, `MAX_TARGET_BPS`]: a treasury graduates 100% stock and sells straight down to
///    target, so under 20% the engine is "liquidate the lot at graduation"; over 90% the band has no room.
///  * `deadbandBps >= DEADBAND_FRICTION_MULTIPLE * (maxSlippageBps + poolFeeBps + bountyBps)`, also used by the new V2
///    ordinary lot strategy's TP/dip floor: a band inside its own execution friction acts on every Chainlink print, and each round trip returns
///    the treasury to the same price with less value. Also `deadband < target` and `target + deadband < BPS`, so
///    both bands are reachable and the arithmetic cannot underflow.
///  * `cooldown >= MIN_COOLDOWN`, 60 seconds. It was one V3 TWAP window, 600 seconds, so that two actions never
///    shared one pinned mean; at 60 a pin held for a window can meet up to ten actions. What bounds the damage is
///    unchanged: each action's size, the day's turnover, and the oracle gate every fill is priced against.
///  * `minLotUsdg <= maxTradeUsdg <= sellChunkUsdg`: an action under the core's minimum lot can never execute (every
///    path ends `NotDue`, the treasury is inert for life -- V1 refuses `sellChunkUsdg < minLotUsdg` for the same
///    reason), and one over the listing's chunk exceeds the owner's per-call sizing.
///  * `maxTradeUsdg <= maxDailyTurnoverUsdg <= MAX_DAILY_TURNOVER_MULTIPLE * maxTradeUsdg`: a daily cap under one
///    action is a cap of zero, and one over 24 actions no longer bounds a day.
///  * `payoutBps <= BPS`: a share of the gain.
///
/// A caller without the listing's `Params` passes `minLotUsdg = 1`, `sellChunkUsdg = type(uint256).max` and
/// `minDeadbandBps = 1`: that keeps the zero checks and defers the listing-dependent limbs to `predict`.
library SpotEngineConfig {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MIN_TARGET_BPS = 2_000;
    uint256 internal constant MAX_TARGET_BPS = 9_000;
    uint256 internal constant DEADBAND_FRICTION_MULTIPLE = 2;
    uint256 internal constant MIN_COOLDOWN = 60;
    uint256 internal constant MAX_DAILY_TURNOVER_MULTIPLE = 24;

    /// @notice the deadband floor for a listing with these gates: twice its worst execution friction
    function minDeadbandBps(uint256 maxSlippageBps, uint256 poolFeeBps, uint256 bountyBps)
        internal pure returns (uint256)
    {
        return DEADBAND_FRICTION_MULTIPLE * (maxSlippageBps + poolFeeBps + bountyBps);
    }

    /// @notice the share of a sale's gain over average cost that moves to the buy-back, from `words[0]`
    function payoutBps(bytes32 word0) internal pure returns (uint256) {
        return uint16(uint256(word0) >> 64);
    }

    /// @notice whether `words` describe a launchable spot rebalance for a listing with these `Params`
    /// @param minLotUsdg the listing's minimum executable lot; `1` when unknown
    /// @param sellChunkUsdg the listing's per-call chunk; `type(uint256).max` when unknown
    /// @param minDeadband `minDeadbandBps(...)` for the listing; `1` when unknown
    function valid(bytes32[3] memory words, uint256 minLotUsdg, uint256 sellChunkUsdg, uint256 minDeadband)
        internal
        pure
        returns (bool)
    {
        uint256 packed = uint256(words[0]);
        uint256 targetBps = uint16(packed);
        uint256 deadbandBps = uint16(packed >> 16);
        uint256 cooldown = uint32(packed >> 32);
        uint256 maxTradeUsdg = uint256(words[1]);
        uint256 maxDailyTurnoverUsdg = uint256(words[2]);
        return packed >> 80 == 0 && payoutBps(words[0]) <= BPS && targetBps >= MIN_TARGET_BPS && targetBps <= MAX_TARGET_BPS
            && deadbandBps >= minDeadband && deadbandBps < targetBps && targetBps + deadbandBps < BPS
            && cooldown >= MIN_COOLDOWN && maxTradeUsdg >= minLotUsdg && maxTradeUsdg <= sellChunkUsdg
            && maxDailyTurnoverUsdg >= maxTradeUsdg && maxTradeUsdg <= type(uint256).max / MAX_DAILY_TURNOVER_MULTIPLE
            && maxDailyTurnoverUsdg <= maxTradeUsdg * MAX_DAILY_TURNOVER_MULTIPLE;
    }
}
