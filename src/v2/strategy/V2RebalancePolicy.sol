// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    EngineConfig,
    IStrategyPolicy,
    StrategyAction,
    StrategyCapabilities,
    StrategyContext,
    StrategyIntent
} from "./IStrategyPolicy.sol";

/// @notice A stateless, fixed-width stock/USDG allocation policy for the spot strategy engine.
/// @dev `words[0]` packs targetBps in bits 0..15, deadbandBps in bits 16..31 and cooldown in bits 32..63.
///      `words[1]` is the maximum USDG notional proposed by one action and `words[2]` is the daily USDG
///      turnover ceiling. The execution core enforces prices, balances, cumulative turnover and every transfer.
contract V2RebalancePolicy is IStrategyPolicy {
    uint256 private constant BPS = 10_000;

    struct RebalanceConfig {
        uint16 targetBps;
        uint16 deadbandBps;
        uint32 cooldown;
        uint256 maxTradeUsdg;
    }

    error BadConfig();

    function policyMetadata() external pure returns (uint32 engineVersion, uint32 configSchema, uint256 capabilities) {
        return (
            StrategyCapabilities.SPOT_ENGINE_V1,
            StrategyCapabilities.CONFIG_SCHEMA_V1,
            StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL
        );
    }

    function decide(StrategyContext calldata context, EngineConfig calldata config, bytes32 state)
        external
        view
        returns (StrategyIntent memory intent)
    {
        RebalanceConfig memory policyConfig = _validate(config);
        intent = StrategyIntent(context.configHash, context.nonce, StrategyAction.Hold, 0, state);
        if (
            context.lastActionAt != 0
                && (block.timestamp < context.lastActionAt
                    || block.timestamp - context.lastActionAt < policyConfig.cooldown)
        ) {
            return intent;
        }
        (intent.action, intent.amountIn) = _action(context, policyConfig);
    }

    function _action(StrategyContext calldata context, RebalanceConfig memory config)
        private
        pure
        returns (StrategyAction action, uint256 amountIn)
    {
        if (context.price == 0 || context.stockValueUsdg > type(uint256).max - context.usdgInventory) {
            return (StrategyAction.Hold, 0);
        }

        uint256 totalValue = context.stockValueUsdg + context.usdgInventory;
        if (totalValue == 0) return (StrategyAction.Hold, 0);

        uint256 targetValue = Math.mulDiv(totalValue, config.targetBps, BPS);
        uint256 lowerValue = Math.mulDiv(totalValue, config.targetBps - config.deadbandBps, BPS);
        uint256 upperValue = Math.mulDiv(totalValue, config.targetBps + config.deadbandBps, BPS);

        if (context.stockValueUsdg < lowerValue) {
            amountIn = Math.min(targetValue - context.stockValueUsdg, config.maxTradeUsdg);
            amountIn = Math.min(amountIn, context.usdgInventory);
            return amountIn == 0 ? (StrategyAction.Hold, 0) : (StrategyAction.BuyStock, amountIn);
        }

        if (context.stockValueUsdg > upperValue && context.stockInventory != 0) {
            uint256 tradeValue = Math.min(context.stockValueUsdg - targetValue, config.maxTradeUsdg);
            amountIn = Math.mulDiv(tradeValue, context.stockInventory, context.stockValueUsdg);
            amountIn = Math.min(amountIn, context.stockInventory);
            return amountIn == 0 ? (StrategyAction.Hold, 0) : (StrategyAction.SellStock, amountIn);
        }
        return (StrategyAction.Hold, 0);
    }

    function _validate(EngineConfig calldata config) private pure returns (RebalanceConfig memory policyConfig) {
        if (
            config.engineVersion != StrategyCapabilities.SPOT_ENGINE_V1
                || config.schema != StrategyCapabilities.CONFIG_SCHEMA_V1
        ) revert BadConfig();

        uint256 packed = uint256(config.words[0]);
        // bits 64..79 are the engine's `payoutBps`, which the treasury applies and this policy ignores
        if (packed >> 80 != 0) revert BadConfig();
        policyConfig.targetBps = uint16(packed);
        policyConfig.deadbandBps = uint16(packed >> 16);
        policyConfig.cooldown = uint32(packed >> 32);
        policyConfig.maxTradeUsdg = uint256(config.words[1]);
        uint256 maxDailyTurnoverUsdg = uint256(config.words[2]);

        if (
            policyConfig.targetBps == 0 || policyConfig.targetBps >= BPS
                || policyConfig.deadbandBps > policyConfig.targetBps
                || policyConfig.targetBps + policyConfig.deadbandBps > BPS || policyConfig.maxTradeUsdg == 0
                || maxDailyTurnoverUsdg == 0 || maxDailyTurnoverUsdg < policyConfig.maxTradeUsdg
        ) revert BadConfig();
    }
}
