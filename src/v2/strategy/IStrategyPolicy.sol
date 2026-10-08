// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Capability bits are descriptive commitments made when a policy is registered.
///         A treasury still enforces every capability at execution time.
library StrategyCapabilities {
    uint32 internal constant SPOT_ENGINE_V1 = 1;
    uint32 internal constant OPTIONS_ENGINE_V1 = 2;
    uint32 internal constant CONFIG_SCHEMA_V1 = 1;

    uint256 internal constant SPOT_BUY = 1 << 0;
    uint256 internal constant SPOT_SELL = 1 << 1;
    uint256 internal constant BUYBACK_BURN = 1 << 2;
    uint256 internal constant OPTIONS_WRITE = 1 << 64;
    uint256 internal constant OPTIONS_BUY = 1 << 65;
    uint256 internal constant OPTIONS_EXERCISE = 1 << 66;
    uint256 internal constant OPTIONS_SETTLE = 1 << 67;
}

/// @dev Fixed-width by design. `words` are interpreted by the committed policy schema.
///      No dynamic bytes may enter CREATE2 initcode or policy returndata.
struct EngineConfig {
    uint32 schema;
    uint32 engineVersion;
    bytes32 policyKey;
    bytes32[3] words;
}

enum StrategyAction {
    Hold,
    BuyStock,
    SellStock,
    BuybackBurn
}

/// @dev Everything here is an observation. The policy never receives a caller, route,
///      pool, recipient, allowance or arbitrary calldata to influence execution.
struct StrategyContext {
    bytes32 configHash;
    uint256 price;
    uint256 stockInventory;
    uint256 stockValueUsdg;
    uint256 usdgInventory;
    uint256 buybackStock;
    uint256 lastActionAt;
    uint64 nonce;
}

/// @dev A policy proposes one bounded action. The treasury revalidates the nonce,
///      config hash, capability, amount, market data and cumulative risk limits.
struct StrategyIntent {
    bytes32 configHash;
    uint64 nonce;
    StrategyAction action;
    uint256 amountIn;
    bytes32 nextState;
}

interface IStrategyPolicy {
    function policyMetadata() external pure returns (uint32 engineVersion, uint32 configSchema, uint256 capabilities);

    function decide(StrategyContext calldata context, EngineConfig calldata config, bytes32 state)
        external
        view
        returns (StrategyIntent memory intent);
}

struct PolicyManifest {
    address implementation;
    bytes32 runtimeCodeHash;
    uint32 engineVersion;
    uint32 configSchema;
    uint32 maxGas;
    uint16 maxReturnBytes;
    uint256 capabilities;
    bool enabledForNewLaunches;
}

interface IV2StrategyRegistry {
    function policy(bytes32 key) external view returns (PolicyManifest memory manifest);
}
