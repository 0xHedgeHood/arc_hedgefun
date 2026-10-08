// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunTreasuryBase} from "../../HedgeFunTreasuryBase.sol";
import {PriceOracle} from "../../PriceOracle.sol";
import {TradablePercentEngineConfig} from "./TradablePercentEngineConfig.sol";
import {EngineConfig, StrategyContext, StrategyIntent, StrategyAction, StrategyCapabilities, IStrategyPolicy} from "./IStrategyPolicy.sol";

interface ITradablePercentPreview {
    function health() external view returns (bool, uint256);
    function oracle() external view returns (PriceOracle);
    function engineConfig() external view returns (EngineConfig memory);
    function params() external view returns (HedgeFunTreasuryBase.Params memory);
    function bookedStock() external view returns (uint256);
    function unbookedStock() external view returns (uint256);
    function reserveUsdg() external view returns (uint256);
    function buybackStock() external view returns (uint256);
    function lastStrategyAt() external view returns (uint256);
    function strategyNonce() external view returns (uint64);
    function configHash() external view returns (bytes32);
    function policyState() external view returns (bytes32);
    function policyImplementation() external view returns (address);
    function policyRuntimeCodeHash() external view returns (bytes32);
    function policyGasLimit() external view returns (uint32);
    function policyCapabilities() external view returns (uint256);
    function dailyRiskLimits() external view returns (uint64, uint256, uint256, uint256, uint256, uint256);
}

/// @notice Immutable, read-only preview component. It has no custody, approvals, or write entry points.
/// Execution independently computes its bounds in the treasury. This component only removes view code from
/// the implementation's EIP-170 budget; it cannot authorize a trade or supply execution parameters.
contract V2TradablePercentPreview {
    struct Quote {
        uint256 total;
        uint256 target;
        uint256 band;
        uint256 buyCap;
        uint256 sellCap;
        uint256 bought;
        uint256 sold;
        uint256 capabilities;
        uint256 minimum;
    }
    struct Risk {
        bool healthy;
        uint256 capital;
        uint256 buy;
        uint256 sell;
        uint256 daily;
        uint256 remaining;
        uint64 epoch;
        uint256 used;
    }

    uint256 private immutable scale;
    error PolicyUnavailable();
    error PolicyFailure();
    error BadPolicyReturn();

    constructor(uint256 scale_) { scale = scale_; }

    function riskLimits(ITradablePercentPreview t) external view
        returns (bool, uint256, uint256, uint256, uint256, uint256, uint64, uint256)
    {
        Risk memory r = _risk(t);
        return (r.healthy, r.capital, r.buy, r.sell, r.daily, r.remaining, r.epoch, r.used);
    }

    function _risk(ITradablePercentPreview t) private view returns (Risk memory r) {
        Quote memory q;
        (r.epoch,, q.buyCap, q.sellCap, q.bought, q.sold) = t.dailyRiskLimits();
        r.used = Math.saturatingAdd(q.bought, q.sold);
        (bool healthy, uint256 p) = t.health();
        (bool live,) = t.oracle().tryPrice();
        if (!healthy || !live) return r;
        uint256 stock = t.bookedStock() + t.unbookedStock();
        uint256 cash = t.reserveUsdg();
        uint256 value = Math.mulDiv(stock, p, scale);
        if (value > type(uint256).max - cash) return r;
        r.capital = value + cash;
        EngineConfig memory c = t.engineConfig();
        r.buy = Math.mulDiv(cash, TradablePercentEngineConfig.buyBps(c.words[1]), 10_000);
        r.sell = Math.mulDiv(stock, TradablePercentEngineConfig.sellBps(c.words[1]), 10_000);
        r.daily = Math.saturatingAdd(q.buyCap, q.sellCap);
        r.remaining = Math.saturatingAdd(q.buyCap > q.bought ? q.buyCap - q.bought : 0,
            q.sellCap > q.sold ? q.sellCap - q.sold : 0);
        r.healthy = true;
    }

    function preview(ITradablePercentPreview t) external view returns (bool due, StrategyAction action, uint256 amount) {
        (bool healthy, uint256 price) = t.health();
        (bool live,) = t.oracle().tryPrice();
        if (!healthy || !live) return (false, StrategyAction.Hold, 0);
        EngineConfig memory c = t.engineConfig();
        StrategyContext memory context;
        context.price = price;
        context.stockInventory = t.bookedStock() + t.unbookedStock();
        context.stockValueUsdg = Math.mulDiv(context.stockInventory, price, scale);
        context.usdgInventory = t.reserveUsdg();
        context.buybackStock = t.buybackStock();
        context.lastActionAt = t.lastStrategyAt();
        context.nonce = t.strategyNonce();
        context.configHash = t.configHash();
        StrategyIntent memory intent = _intent(t, context, c);
        if (intent.configHash != context.configHash || intent.nonce != context.nonce
            || context.stockValueUsdg > type(uint256).max - context.usdgInventory
            || (context.lastActionAt != 0 && block.timestamp < context.lastActionAt + uint32(uint256(c.words[0]) >> 32)))
            return (false, StrategyAction.Hold, 0);
        amount = _amount(t, context, c, intent);
        return amount == 0 ? (false, StrategyAction.Hold, 0) : (true, intent.action, amount);
    }

    function _amount(ITradablePercentPreview t, StrategyContext memory x, EngineConfig memory c, StrategyIntent memory intent)
        private view returns (uint256 amount)
    {
        Quote memory q;
        q.total = x.stockValueUsdg + x.usdgInventory;
        if (q.total == 0) return 0;
        q.target = uint16(uint256(c.words[0]));
        q.band = uint16(uint256(c.words[0]) >> 16);
        (,, q.buyCap, q.sellCap, q.bought, q.sold) = t.dailyRiskLimits();
        q.capabilities = t.policyCapabilities();
        q.minimum = t.params().minLotUsdg;
        if (intent.action == StrategyAction.BuyStock) {
            if (q.capabilities & StrategyCapabilities.SPOT_BUY == 0 || q.bought >= q.buyCap
                || x.stockValueUsdg >= Math.mulDiv(q.total, q.target - q.band, 10_000)) return 0;
            amount = Math.min(intent.amountIn, Math.min(q.buyCap - q.bought, Math.mulDiv(q.total, q.target, 10_000) - x.stockValueUsdg));
            amount = Math.min(amount, Math.mulDiv(x.usdgInventory, TradablePercentEngineConfig.buyBps(c.words[1]), 10_000));
            if (amount < q.minimum) return 0;
        } else if (intent.action == StrategyAction.SellStock) {
            if (q.capabilities & StrategyCapabilities.SPOT_SELL == 0 || q.sold >= q.sellCap
                || x.stockValueUsdg <= Math.mulDiv(q.total, q.target + q.band, 10_000)) return 0;
            uint256 value = Math.min(q.sellCap - q.sold, x.stockValueUsdg - Math.mulDiv(q.total, q.target, 10_000));
            amount = Math.min(intent.amountIn, Math.min(Math.mulDiv(value, scale, x.price),
                Math.mulDiv(x.stockInventory, TradablePercentEngineConfig.sellBps(c.words[1]), 10_000)));
            if (Math.mulDiv(amount, x.price, scale) < q.minimum) return 0;
        }
    }

    /// @notice Shared bounded policy read, so preview and execution expose the same caller to the policy.
    function intent(ITradablePercentPreview t, StrategyContext calldata x) external view returns (StrategyIntent memory) {
        return _intent(t, x, t.engineConfig());
    }

    /// @notice Income accounting only: no transfers or storage writes. Net proceeds include venue fees and
    /// executor rewards. Recover realized losses first; reserve at most the initially withheld stock.
    /// For retained stock B, its marked gain also belongs to the sale: B*price = payout*(netGain+B*(price-cost)).
    /// Rounding the denominator up and the stock down keeps the resulting reserve conservative.
    function saleIncome(uint256 cost, uint256 price, uint256 sold, uint256 netCash,
        uint256 maximumReserve, uint256 payout, uint256 loss)
        external view returns (uint256 reserve, uint256 lossAfter, uint256 eligibleCash)
    {
        uint256 principal = Math.mulDiv(sold, cost, scale, Math.Rounding.Ceil);
        if (netCash < principal) return (0, loss + principal - netCash, 0);
        uint256 gain = netCash - principal;
        if (gain <= loss) return (0, loss - gain, 0);
        eligibleCash = gain - loss;
        if (maximumReserve != 0 && price > cost && payout != 0) {
            uint256 denominator = price - Math.mulDiv(price - cost, payout, 10_000);
            reserve = Math.min(maximumReserve, Math.mulDiv(Math.mulDiv(eligibleCash, scale, denominator), payout, 10_000));
        }
    }

    function _intent(ITradablePercentPreview t, StrategyContext memory x, EngineConfig memory c)
        private view returns (StrategyIntent memory intent)
    {
        address policy = t.policyImplementation();
        if (policy.codehash != t.policyRuntimeCodeHash()) revert PolicyUnavailable();
        bytes memory data = abi.encodeCall(IStrategyPolicy.decide, (x, c, t.policyState()));
        uint256 gasLimit = t.policyGasLimit();
        bool success;
        uint256 size;
        assembly ("memory-safe") {
            success := staticcall(gasLimit, policy, add(data, 32), mload(data), 0, 0)
            size := returndatasize()
        }
        if (!success) revert PolicyFailure();
        if (size != 160) revert BadPolicyReturn();
        bytes memory result = new bytes(160);
        uint256 action;
        assembly ("memory-safe") {
            returndatacopy(add(result, 32), 0, 160)
            action := mload(add(result, 96))
        }
        if (action > uint256(type(StrategyAction).max)) revert BadPolicyReturn();
        return abi.decode(result, (StrategyIntent));
    }
}
