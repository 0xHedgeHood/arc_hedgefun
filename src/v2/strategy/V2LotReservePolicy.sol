// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    EngineConfig,
    IStrategyPolicy,
    StrategyContext,
    StrategyIntent,
    StrategyCapabilities
} from "./IStrategyPolicy.sol";

/// @notice Opt-in opening reserve and lifetime dip limits; the original word-0-only encoding remains valid.
/// @dev word0: reserveBps (0..5000). word1: cashFloorBps in bits 0..15, dipBudgetBps in 16..31,
///      maxDipBuys in 32..47. Zero disables that individual limit. Unused bits and word2 must be zero.
///      Floor and budget are percentages of the exact graduation stock's frozen USDG value, not NAV.
///      Engine version 3, schema 4.
library LotReserveConfig {
    uint32 internal constant ENGINE_VERSION = 3;
    uint32 internal constant SCHEMA = 4;
    uint16 internal constant MAX_RESERVE_BPS = 5000;
    uint256 internal constant CAPABILITIES = StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL;

    error BadReserveConfig();

    function reserveBps(EngineConfig memory c) internal pure returns (uint16) {
        if (!valid(c)) revert BadReserveConfig();
        return uint16(uint256(c.words[0]));
    }

    function valid(EngineConfig memory c) internal pure returns (bool) {
        uint256 limits = uint256(c.words[1]);
        return c.engineVersion == ENGINE_VERSION && c.schema == SCHEMA && c.policyKey != bytes32(0)
            && uint256(c.words[0]) <= MAX_RESERVE_BPS && limits >> 48 == 0 && uint16(limits) <= 10_000
            && uint16(limits >> 16) <= 10_000 && c.words[2] == bytes32(0);
    }
}

/// @notice The registered identity of the lot-with-reserve kind's config. The registry pairs every config-taking
///         kind with a policy; this one only names the schema and validates a config off chain. The treasury's own
///         rule decides every action, so `decide` is never called and refuses if it is.
contract V2LotReservePolicy is IStrategyPolicy {
    error NotAPolicyEngine();

    function policyMetadata() external pure returns (uint32, uint32, uint256) {
        return (LotReserveConfig.ENGINE_VERSION, LotReserveConfig.SCHEMA, LotReserveConfig.CAPABILITIES);
    }

    /// @notice whether `c` is a config this kind accepts: what a front end checks before `setEngineConfig`
    function validConfig(EngineConfig calldata c) external pure returns (bool) {
        return LotReserveConfig.valid(c);
    }

    function decide(StrategyContext calldata, EngineConfig calldata, bytes32)
        external
        pure
        returns (StrategyIntent memory)
    {
        revert NotAPolicyEngine();
    }
}
