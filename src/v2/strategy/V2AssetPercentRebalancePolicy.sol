// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AssetPercentEngineConfig} from "./AssetPercentEngineConfig.sol";
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
///      `words[1]` and `words[2]` are maximum action / daily turnover percentages of the fund's total external assets,
///      in basis points. The core independently clips by the listing chunk, minLot, and actual daily spend.
///      Allocation uses tradable stockValueUsdg + usdgInventory. The shared context omits LP assets,
///      so this policy proposes the target gap; only the core applies total-asset percentage caps.
contract V2AssetPercentRebalancePolicy is IStrategyPolicy {
    uint256 private constant BPS = 10_000;

    struct RebalanceConfig {
        uint16 targetBps;
        uint16 deadbandBps;
        uint32 cooldown;
    }

    error BadConfig();

    function policyMetadata() external pure returns (uint32 engineVersion, uint32 configSchema, uint256 capabilities) {
        return (
            StrategyCapabilities.SPOT_ENGINE_V1,
            AssetPercentEngineConfig.CONFIG_SCHEMA,
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
            amountIn = targetValue - context.stockValueUsdg;
            amountIn = Math.min(amountIn, context.usdgInventory);
            return amountIn == 0 ? (StrategyAction.Hold, 0) : (StrategyAction.BuyStock, amountIn);
        }

        if (context.stockValueUsdg > upperValue && context.stockInventory != 0) {
            uint256 tradeValue = context.stockValueUsdg - targetValue;
            amountIn = Math.mulDiv(tradeValue, context.stockInventory, context.stockValueUsdg);
            amountIn = Math.min(amountIn, context.stockInventory);
            return amountIn == 0 ? (StrategyAction.Hold, 0) : (StrategyAction.SellStock, amountIn);
        }
        return (StrategyAction.Hold, 0);
    }

    function _validate(EngineConfig calldata config) private pure returns (RebalanceConfig memory policyConfig) {
        if (
            config.engineVersion != StrategyCapabilities.SPOT_ENGINE_V1
                || config.schema != AssetPercentEngineConfig.CONFIG_SCHEMA
        ) revert BadConfig();

        if (!AssetPercentEngineConfig.valid(config.words, 0)) revert BadConfig();
        uint256 packed = uint256(config.words[0]);
        policyConfig.targetBps = uint16(packed);
        policyConfig.deadbandBps = uint16(packed >> 16);
        policyConfig.cooldown = uint32(packed >> 32);
    }
}
