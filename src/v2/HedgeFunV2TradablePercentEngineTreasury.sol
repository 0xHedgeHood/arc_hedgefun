// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ITradingCalendar} from "../interfaces/ITradingCalendar.sol";
import {PriceOracle} from "../PriceOracle.sol";
import {HedgeFunV2Treasury} from "./HedgeFunV2Treasury.sol";
import {
    EngineConfig,
    IStrategyPolicy,
    IV2StrategyRegistry,
    PolicyManifest,
    StrategyAction,
    StrategyCapabilities,
    StrategyContext,
    StrategyIntent
} from "./strategy/IStrategyPolicy.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {HedgeFunTreasuryBase} from "../HedgeFunTreasuryBase.sol";
import {EngineBinding} from "./HedgeFunV2EngineTreasury.sol";
import {V2TreasuryUpgradeController} from "./V2TreasuryUpgradeController.sol";
import {IV2UpgradeRegistry} from "./HedgeFunV2UpgradeableTreasury.sol";
import {V2TradablePercentPreview, ITradablePercentPreview} from "./strategy/V2TradablePercentPreview.sol";
import {TradablePercentEngineConfig} from "./strategy/TradablePercentEngineConfig.sol";

/// @notice Schema-3 rebalance: input-asset percentages and daily limits based only on tradable capital.
/// @dev Its registry kind is assigned at registration. Existing schemas 1 and 2 retain their original semantics.
///
/// The policy is advisory only. It is called with `STATICCALL`, has no custody and can propose one fixed-width
/// action. This treasury independently rechecks the policy code hash, nonce, config commitment, live oracle,
/// cooldown, allocation direction, per-action size and daily turnover before it calls the inherited bounded V3
/// swap. Routes, pools, recipients, approvals and callbacks never come from the policy or keeper.
///
/// Engine version 1 deliberately supports only a stock/USDG fixed-weight rebalance policy. Options capabilities
/// are reserved in the shared interface but rejected here: collateral, expiry, exercise and settlement require a
/// different engine version and different solvency invariants.
///
/// Inventory carries one average cost, including acquisition fees and executor rewards. Net cash from sales
/// first covers sold inventory's cost and recovers tracked realized strategy losses. Only the remaining gain
/// can fund the creator's frozen `payoutBps` share, conservatively retained in stock for the separate FUN buyback.
/// Retained stock's own cost/gain is included in the payout calculation. Loss history starts at this accounting
/// upgrade and persists across trading dates. `payoutBps = 0` funds buybacks from LP fees alone.
abstract contract HedgeFunV2TradablePercentEngineTreasuryCore is HedgeFunV2Treasury {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant INTENT_RETURN_BYTES = 160;
    uint256 public constant MAX_POLICY_GAS = 500_000;
    uint256 private constant SPOT_CAPABILITIES = StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL;

    EngineConfig internal _engineConfig;
    address public immutable policyImplementation;
    bytes32 public immutable policyRuntimeCodeHash;
    uint256 public immutable policyCapabilities;
    V2TradablePercentPreview public immutable previewReader;
    uint32 public immutable policyGasLimit;
    uint16 public immutable policyReturnLimit;
    bytes32 public immutable configHash;
    /// @notice the share of a sale's gain over `avgCost` that moves to the buy-back instead of being sold, in bps
    uint16 public immutable payoutBps;
    /// @notice the listing oracle's own calendar, whose `tradingDate` is the daily turnover cap's day
    ITradingCalendar public immutable tradingCalendar;

    bytes32 public policyState;
    /// @notice the average cost of `bookedStock`, in the oracle's price units (USDG per whole stock token, 1e18-scaled)
    uint256 public avgCost;
    uint64 public strategyNonce;
    uint256 public lastStrategyAt;
    /// @notice the US trading date of the last action, as days since 1970-01-01: `tradingCalendar.tradingDate`, which
    ///         rolls at 20:00 New York time (DST included), the same session boundary the oracle's calendar keeps
    uint64 public turnoverEpoch;
    /// @notice what the actions of trading date `turnoverEpoch` have taken out of inventory, in USDG
    uint256 public turnoverInEpoch;

    /// @dev Separate namespace leaves existing proxy and successor storage untouched. An old same-day total
    ///      has no directional history, so its entire value is conservatively charged to BOTH directions.
    struct DailyBudget {
        uint64 epoch;
        uint256 capital;
        uint256 legacyUsed;
        uint256 bought;
        uint256 unrecoveredLossUsdg;
    }

    function _dailyBudget() private pure returns (DailyBudget storage b) {
        bytes32 slot = keccak256("hedgefun.v2.tradable-percent.directional-budget.v1");
        assembly ("memory-safe") { b.slot := slot }
    }

    /// @notice Realized strategy losses since this accounting upgrade, net of subsequent realized gains.
    function unrecoveredLossUsdg() external view returns (uint256) { return _dailyBudget().unrecoveredLossUsdg; }

    struct ExecutionLimits {
        uint256 targetBps;
        uint256 deadbandBps;
        uint256 maxBuy;
        uint256 maxSell;
        uint256 remainingDaily;
        uint256 totalValue;
        uint64 epoch;
        uint256 used;
    }

    struct ExecutionResult {
        Action action;
        uint256 actualInput;
        uint256 actualOutput;
        uint256 turnover;
        uint256 keeperReward;
        /// what the action filled, in USDG: for a sale, the stock swapped plus the stock withheld alongside it,
        /// before income accounting decides how much of the withheld stock is reserved
        uint256 filled;
    }

    error BadEngineConfig();
    error PolicyUnavailable();
    error PolicyFailure();
    error BadPolicyReturn();
    error BadIntent();

    event InventoryBooked(uint256 amount, uint256 stockInventory);
    /// @notice Compatibility event: `gain` is the gross oracle-marked stock gain before venue fees, executor
    ///         reward and loss recovery; `toBuyback` is the actual net-income-funded reserve. See StrategyIncomeAccounted.
    event GainToBuyback(uint256 gain, uint256 toBuyback, uint256 avgCost, uint256 price);
    event StrategyIncomeAccounted(uint256 eligibleCashUsdg, uint256 lossCarryforwardUsdg, uint256 buybackStockAdded);
    event StrategyExecuted(
        uint64 indexed nonce,
        StrategyAction indexed action,
        uint256 requestedInput,
        uint256 actualInput,
        uint256 actualOutput,
        uint256 price,
        uint256 turnoverUsdg,
        bytes32 nextState
    );
    /// @notice Paid to the successful executor from this action's actual output, after all effects are committed.
    ///         `StrategyExecuted.actualOutput` remains the gross swap output; retained output is gross minus reward.
    event KeeperRewardPaid(uint64 indexed nonce, address indexed executor, address indexed asset, uint256 amount);

    constructor(
        address usdg_,
        address stock_,
        address v3Pool_,
        address oracle_,
        address token_,
        address poolManager_,
        address factory_,
        Params memory p,
        EngineBinding memory binding
    ) HedgeFunV2Treasury(usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p) {
        previewReader = new V2TradablePercentPreview(_SCALE);
        EngineConfig memory c = binding.config;
        PolicyManifest memory manifest = binding.manifest;
        if (binding.treasury == address(0)) revert BadEngineConfig();
        // The band floor is what one trade costs on this listing, which only this constructor sees.
        _validateEngineConfig(c, manifest, poolFeeBps + p.bountyBps);
        _engineConfig = c;
        payoutBps = uint16(TradablePercentEngineConfig.payoutBps(c.words[0]));
        tradingCalendar = PriceOracle(oracle_).calendar();
        policyImplementation = manifest.implementation;
        policyRuntimeCodeHash = manifest.runtimeCodeHash;
        policyCapabilities = manifest.capabilities;
        policyGasLimit = manifest.maxGas;
        policyReturnLimit = manifest.maxReturnBytes;
        configHash = keccak256(
            abi.encode(
                block.chainid,
                binding.treasury,
                factory_,
                stock_,
                usdg_,
                c,
                manifest.implementation,
                manifest.runtimeCodeHash,
                manifest.capabilities,
                manifest.maxGas,
                manifest.maxReturnBytes
            )
        );
    }

    /// @dev Schema 3 validation is authoritative here; existing factories need no code change to append this kind.
    /// The mutable policy listing flag is checked by the proxy only at initial creation, not during an upgrade.
    /// An upgrade's replacement logic runs this again on the same frozen config and listing, so it passes again.
    function _validateEngineConfig(EngineConfig memory c, PolicyManifest memory manifest, uint256 minDeadband)
        private
        view
    {
        bytes32 actualCodeHash = manifest.implementation.codehash;
        if (
            c.schema != TradablePercentEngineConfig.CONFIG_SCHEMA
                || c.engineVersion != StrategyCapabilities.SPOT_ENGINE_V1 || manifest.engineVersion != c.engineVersion
                || manifest.configSchema != c.schema || manifest.implementation == address(0)
                || actualCodeHash == bytes32(0) || actualCodeHash != manifest.runtimeCodeHash || manifest.maxGas == 0
                || manifest.maxGas > MAX_POLICY_GAS || manifest.maxReturnBytes != INTENT_RETURN_BYTES
                || manifest.capabilities & SPOT_CAPABILITIES == 0 || manifest.capabilities & ~SPOT_CAPABILITIES != 0
                || !TradablePercentEngineConfig.valid(c.words, minDeadband)
        ) revert BadEngineConfig();
    }

    function engineVersion() external pure returns (uint32) {
        return StrategyCapabilities.SPOT_ENGINE_V1;
    }

    function strategyId() external view returns (bytes32) {
        return _engineConfig.policyKey;
    }

    function engineConfig() external view returns (EngineConfig memory) {
        return _engineConfig;
    }

    /// @notice Buy cap is a percentage of cash; sell cap is a percentage of tradable stock units; neither
    /// percentage is over `TradablePercentEngineConfig.MAX_ACTION_BPS`.
    /// Daily capital is booked + bookable stock valued at the live oracle, plus available USDG.
    /// Locked LP, parked LP assets, unclaimed LP fees and already reserved buyback stock are excluded.
    /// Daily capital is fixed immediately before the date's first successful action. Buy and sell budgets each
    /// use their respective percentage of that basis. Aggregate remaining capacity cannot all be spent in one direction.
    /// Healthy describes only the price snapshot; use preview() to check cooldown and executable allocation.
    function riskLimits()
        external
        view
        returns (
            bool healthy,
            uint256 tradableValueUsdg,
            uint256 maxBuyUsdg,
            uint256 maxSellStock,
            uint256 maxDailyTurnoverUsdg,
            uint256 remainingDailyUsdg,
            uint64 epoch,
            uint256 usedUsdg
        )
    {
        return previewReader.riskLimits(ITradablePercentPreview(address(this)));
    }

    /// @notice Per-direction daily cap, charged buys and charged sells. Before the first successful action,
    ///         basis is a live preview; later price changes or donations cannot reopen today's capacity.
    function dailyRiskLimits() external view returns (uint64 epoch, uint256 basis, uint256 buyCap, uint256 sellCap, uint256 bought, uint256 sold) {
        epoch = _tradingDate();
        DailyBudget storage b = _dailyBudget();
        basis = b.epoch == epoch ? b.capital : 0;
        if (basis == 0) {
            (bool ok, uint256 p) = health();
            (bool live,) = _oracle.tryPrice();
            if (ok && live) basis = _ruleValue(bookedStock + unbookedStock(), p) + reserveUsdg();
        }
        buyCap = _dailyCap(basis, true);
        sellCap = _dailyCap(basis, false);
        bought = _usedDaily(epoch, StrategyAction.BuyStock);
        sold = _usedDaily(epoch, StrategyAction.SellStock);
    }

    function _remaining(uint256 cap, uint256 used) private pure returns (uint256) { return cap > used ? cap - used : 0; }

    function _usedDaily(uint64 epoch, StrategyAction action) private view returns (uint256) {
        uint256 total = turnoverEpoch == epoch ? turnoverInEpoch : 0;
        DailyBudget storage b = _dailyBudget();
        if (b.epoch != epoch || b.capital == 0) return total;
        return action == StrategyAction.BuyStock ? b.legacyUsed + b.bought : total - b.bought;
    }

    /// @dev Engine inventory is a balance bucket, not a collection of cost-basis lots.
    function _canAddLot() internal pure override returns (bool) {
        return false;
    }

    /// @notice Classify newly arrived graduation/tax stock as rebalance inventory, at the live oracle price, which
    ///         becomes part of its average cost -- the price kind 0 books a lot at. Out of hours there is no price to
    ///         book it at, so it waits; `execute()` books it first. LP stock fees still enter the separate inherited
    ///         `buybackStock` bucket through `creditLiquidityFee`.
    function book() public override nonReentrant returns (bool) {
        (bool ok, uint256 p) = health();
        (bool live,) = _oracle.tryPrice();
        return ok && live && _bookInventory(p);
    }

    /// @dev `p` must be a live oracle price that `health()` accepts; both callers check it first.
    function _bookInventory(uint256 p) internal returns (bool) {
        uint256 pending = unbookedStock();
        if (pending == 0) return false;
        _addCost(pending, pending * p);
        bookedStock += pending;
        totalStockReceived += pending;
        emit InventoryBooked(pending, bookedStock);
        return true;
    }

    /// @notice Simulate the immutable policy. `execute()` always recomputes the context and intent on chain.
    ///         For a sale, `amountIn` bounds stock removed from inventory. Net settlement, loss recovery and
    ///         partial fills may reduce the amount removed; only earned income can enter the buyback reserve.
    function preview() external view returns (bool due, StrategyAction action, uint256 amountIn) {
        return previewReader.preview(ITradablePercentPreview(address(this)));
    }

    /// @notice Execute one bounded policy action, paying its caller `bountyBps` of the actual swap output.
    ///         Sells pay USDG; buys pay stock. Keepers choose no action, route, lot, price or reward recipient.
    function execute() external override nonReentrant returns (Action action, uint256 id) {
        (bool ok, uint256 p) = health();
        if (!ok) revert Unhealthy();
        (bool live,) = _oracle.tryPrice();
        if (!live) revert Unhealthy();
        _bookInventory(p);

        StrategyContext memory context = _context(p, bookedStock);
        StrategyIntent memory intent = _policyIntent(context);
        if (!_basicIntentValid(intent) || intent.action == StrategyAction.Hold) revert NotDue();

        uint256 requested = intent.amountIn;
        ExecutionLimits memory limits = _executionLimits(context, intent.action);
        _notePrice(p);
        _noteTokenSpot();
        ExecutionResult memory result = _executeIntent(context, intent, p, limits);
        action = result.action;
        // A V3 exact-input swap can stop at the price limit after consuming only dust. Treating that as a strategy
        // action would let a thin or deliberately positioned venue advance the nonce and renew the cooldown while
        // barely consuming the daily budget. The check must use the actual fill and must happen before any strategy
        // state is committed; reverting here rolls the swap and its transfers back atomically.
        // It measures the FILL, not `turnover`: a sale's turnover is what left inventory, and loss recovery can
        // keep all of the withheld stock in inventory. A complete fill is not dust because none of it was reserved.
        if (result.filled < _params.minLotUsdg) revert NotDue();
        if (result.turnover > limits.remainingDaily) revert BadIntent();
        DailyBudget storage b = _dailyBudget();
        if (b.epoch != limits.epoch || b.capital == 0) {
            b.epoch = limits.epoch;
            b.capital = limits.totalValue;
            b.legacyUsed = limits.used;
            b.bought = 0;
        }
        if (intent.action == StrategyAction.BuyStock) b.bought += result.turnover;
        turnoverEpoch = limits.epoch;
        turnoverInEpoch = limits.used + result.turnover;
        lastStrategyAt = block.timestamp;
        policyState = intent.nextState;
        ++strategyNonce;
        id = strategyNonce;
        emit StrategyExecuted(
            strategyNonce,
            intent.action,
            requested,
            result.actualInput,
            result.actualOutput,
            p,
            result.turnover,
            intent.nextState
        );
        // Reward callbacks see the final inventory, cost, turnover, cooldown, state and nonce. A failed transfer
        // reverts the entire action, including its swap; there is no unpaid reward liability or claim path.
        if (result.keeperReward != 0) {
            IERC20 rewardAsset = result.action == Action.RebalanceSell ? _usdg : _stock;
            emit KeeperRewardPaid(strategyNonce, msg.sender, address(rewardAsset), result.keeperReward);
            rewardAsset.safeTransfer(msg.sender, result.keeperReward);
        }
    }

    function _executionLimits(StrategyContext memory context, StrategyAction action) private view returns (ExecutionLimits memory limits) {
        uint256 cooldown;
        uint256 maxDaily;
        if (context.stockValueUsdg > type(uint256).max - context.usdgInventory) revert BadIntent();
        limits.totalValue = context.stockValueUsdg + context.usdgInventory;
        if (limits.totalValue == 0) revert NotDue();
        (limits.targetBps, limits.deadbandBps, cooldown, limits.maxBuy, limits.maxSell, maxDaily) = _riskConfig(context, action);
        if (lastStrategyAt != 0 && block.timestamp < lastStrategyAt + cooldown) revert Cooldown();
        limits.epoch = _tradingDate();
        limits.used = turnoverEpoch == limits.epoch ? turnoverInEpoch : 0;
        limits.remainingDaily = _remaining(maxDaily, _usedDaily(limits.epoch, action));
        if (limits.remainingDaily == 0) revert NotDue();
    }

    function _executeIntent(
        StrategyContext memory context,
        StrategyIntent memory intent,
        uint256 price,
        ExecutionLimits memory limits
    ) private returns (ExecutionResult memory result) {
        if (intent.action == StrategyAction.SellStock) {
            return _executeSell(context, intent.amountIn, price, limits);
        }
        if (intent.action == StrategyAction.BuyStock) {
            return _executeBuy(context, intent.amountIn, price, limits);
        }
        // Buy-back has its own TWAP/anchor/cooldown state machine and remains a separate entry point.
        revert BadIntent();
    }

    function _executeSell(
        StrategyContext memory context,
        uint256 requested,
        uint256 price,
        ExecutionLimits memory limits
    ) private returns (ExecutionResult memory result) {
        uint256 upperValue = Math.mulDiv(limits.totalValue, limits.targetBps + limits.deadbandBps, BPS);
        if (policyCapabilities & StrategyCapabilities.SPOT_SELL == 0 || context.stockValueUsdg <= upperValue) {
            revert BadIntent();
        }
        uint256 excessUsdg = context.stockValueUsdg - Math.mulDiv(limits.totalValue, limits.targetBps, BPS);
        uint256 capUsdg = Math.min(limits.remainingDaily, excessUsdg);
        uint256 offered = Math.min(requested, Math.min(limits.maxSell, _ruleStockFor(capUsdg, price)));
        if (offered == 0 || _ruleValue(offered, price) < _params.minLotUsdg) revert NotDue();
        // Withhold at most the gross marked payout while swapping the rest. Actual net proceeds and prior
        // losses can only REDUCE this reserve. Any withheld stock that is not earned remains strategy inventory.
        // A partial fill scales the proposed reserve before the same net-income checks.
        uint256 cost = avgCost;
        uint256 gain = price > cost ? offered - Math.mulDiv(offered, cost, price) : 0;
        uint256 toBuyback = gain * payoutBps / BPS;
        uint256 sale = offered - toBuyback;
        (result.actualInput, result.actualOutput) = _swapStock(false, sale, price);
        result.keeperReward = Math.mulDiv(result.actualOutput, _params.bountyBps, BPS);
        if (result.actualInput != sale) {
            gain = Math.mulDiv(gain, result.actualInput, sale);
            toBuyback = Math.mulDiv(toBuyback, result.actualInput, sale);
        }
        result.filled = _ruleValue(result.actualInput + toBuyback, price);
        toBuyback = _accountIncome(result, price, toBuyback);
        uint256 moved = result.actualInput + toBuyback;
        bookedStock -= moved;
        buybackStock += toBuyback;
        result.turnover = _ruleValue(moved, price);
        result.action = Action.RebalanceSell;
        if (gain != 0) emit GainToBuyback(gain, toBuyback, cost, price);
    }

    function _accountIncome(ExecutionResult memory result, uint256 price, uint256 maximumReserve)
        private returns (uint256 reserved)
    {
        uint256 eligibleCash;
        DailyBudget storage b = _dailyBudget();
        (reserved, b.unrecoveredLossUsdg, eligibleCash) = previewReader.saleIncome(
            avgCost, price, result.actualInput, result.actualOutput - result.keeperReward,
            maximumReserve, payoutBps, b.unrecoveredLossUsdg);
        emit StrategyIncomeAccounted(eligibleCash, b.unrecoveredLossUsdg, reserved);
    }

    function _executeBuy(
        StrategyContext memory context,
        uint256 requested,
        uint256 price,
        ExecutionLimits memory limits
    ) private returns (ExecutionResult memory result) {
        uint256 lowerValue = Math.mulDiv(limits.totalValue, limits.targetBps - limits.deadbandBps, BPS);
        if (policyCapabilities & StrategyCapabilities.SPOT_BUY == 0 || context.stockValueUsdg >= lowerValue) {
            revert BadIntent();
        }
        uint256 deficitUsdg = Math.mulDiv(limits.totalValue, limits.targetBps, BPS) - context.stockValueUsdg;
        uint256 capUsdg = Math.min(Math.min(limits.maxBuy, limits.remainingDaily), deficitUsdg);
        uint256 offered = Math.min(Math.min(requested, capUsdg), context.usdgInventory);
        if (offered < _params.minLotUsdg) revert NotDue();
        (result.actualInput, result.actualOutput) = _swapStock(true, offered, price);
        result.keeperReward = Math.mulDiv(result.actualOutput, _params.bountyBps, BPS);
        uint256 retainedStock = result.actualOutput - result.keeperReward;
        // The whole USDG spend bought the stock retained after the executor's reward. Booking gross output would
        // create phantom inventory; pricing it at gross output would understate cost and manufacture later gains.
        _addCost(retainedStock, result.actualInput * _SCALE);
        bookedStock += retainedStock;
        result.turnover = result.filled = result.actualInput;
        result.action = Action.RebalanceBuy;
    }

    /// @dev The daily cap's day is the US equity session -- Sunday 20:00 to Friday 20:00 New York time, one trading
    ///      date per 24 hours -- not the UTC calendar day, whose midnight falls at 19:00 New York time in winter, an hour
    ///      before the session ends.
    function _tradingDate() private view returns (uint64) {
        return uint64(tradingCalendar.tradingDate(block.timestamp));
    }

    /// @dev Adds `qty` to the average cost at a total of `costTimesQty` (price x quantity, in the oracle's units), before
    ///      `bookedStock` grows by `qty`. Rounded up, so rounding never manufactures a gain.
    function _addCost(uint256 qty, uint256 costTimesQty) private {
        uint256 held = bookedStock;
        avgCost = Math.ceilDiv(held * avgCost + costTimesQty, held + qty);
    }

    function _context(uint256 p, uint256 inventory) private view returns (StrategyContext memory context) {
        context = StrategyContext({
            configHash: configHash,
            price: p,
            stockInventory: inventory,
            stockValueUsdg: _ruleValue(inventory, p),
            usdgInventory: reserveUsdg(),
            buybackStock: buybackStock,
            lastActionAt: lastStrategyAt,
            nonce: strategyNonce
        });
    }

    /// @dev The action's range is not re-checked here: `_policyIntent` refuses an out-of-range action word before
    ///      the enum decode, so every intent that reaches this point already holds a declared action.
    function _basicIntentValid(StrategyIntent memory intent) private view returns (bool) {
        return intent.configHash == configHash && intent.nonce == strategyNonce;
    }

    function _riskConfig(StrategyContext memory context, StrategyAction action)
        private
        view
        returns (
            uint256 targetBps,
            uint256 deadbandBps,
            uint256 cooldown,
            uint256 maxBuy,
            uint256 maxSell,
            uint256 maxDaily
        )
    {
        uint256 packed = uint256(_engineConfig.words[0]);
        targetBps = uint16(packed);
        deadbandBps = uint16(packed >> 16);
        cooldown = uint32(packed >> 32);
        maxBuy = Math.mulDiv(context.usdgInventory, TradablePercentEngineConfig.buyBps(_engineConfig.words[1]), BPS);
        maxSell = Math.mulDiv(context.stockInventory, TradablePercentEngineConfig.sellBps(_engineConfig.words[1]), BPS);
        maxDaily = _dailyCap(_capitalBasis(context.stockValueUsdg + context.usdgInventory), action == StrategyAction.BuyStock);
    }

    function _capitalBasis(uint256 liveValue) private view returns (uint256) {
        DailyBudget storage b = _dailyBudget();
        return b.epoch == _tradingDate() && b.capital != 0 ? b.capital : liveValue;
    }

    function _dailyCap(uint256 basis, bool buy) private view returns (uint256) {
        return Math.mulDiv(basis, TradablePercentEngineConfig.dailyBps(_engineConfig.words[2], buy), BPS);
    }

    function _policyIntent(StrategyContext memory context) private view returns (StrategyIntent memory intent) {
        return previewReader.intent(ITradablePercentPreview(address(this)), context);
    }
}

/// @notice Schema-3 implementation; upgrades preserve the complete inherited storage layout.
/// @dev Asset and policy immutables are per treasury. Future implementations preserve all inherited slots.
/// The policy's mutable listing flag is not an upgrade identity: disabling NEW launches cannot strand old ones.
contract HedgeFunV2TradablePercentEngineTreasuryLogic is HedgeFunV2TradablePercentEngineTreasuryCore {
    bytes32 public immutable upgradeConfigHash;
    error InvalidInitialization();

    constructor(
        address usdg_,
        address stock_,
        address v3Pool_,
        address oracle_,
        address token_,
        address poolManager_,
        address factory_,
        Params memory p,
        EngineBinding memory binding
    )
        HedgeFunV2TradablePercentEngineTreasuryCore(
            usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p, binding
        )
    {
        binding.manifest.enabledForNewLaunches = false;
        upgradeConfigHash = keccak256(
            abi.encode(
                keccak256("hedgefun.v2.tradable-percent-engine.proxy.storage.v1"),
                block.chainid,
                binding.treasury,
                [usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_],
                p,
                binding.config,
                binding.manifest,
                keccak256(abi.encode(_SCALE, _DUST_VALUE_LIMIT, SCALE, poolFeeBps, stockIsToken0, tradingCalendar))
            )
        );
    }

    /// @dev Both constructor-owned storage fields, including the guard, are initialized in the proxy.
    /// Direct implementation calls and post-construction replay fail. This is not the later migration entrypoint.
    function initializeProxy(Params calldata p, EngineConfig calldata c) external nonReentrant {
        if (address(this).code.length != 0) revert InvalidInitialization();
        _params = p;
        _engineConfig = c;
    }
}

/// @notice Upgradeable spot-policy treasury for future engine launches; fixed two-day controller notice.
/// @dev The constructor ABI remains the engine registry's ordinary args plus EngineConfig.
contract HedgeFunV2TradablePercentEngineTreasury is Proxy {
    V2TreasuryUpgradeController public immutable treasuryUpgradeController;
    address public immutable initialImplementation;
    bytes32 public immutable upgradeConfigHash;
    error NotUpgradeController();
    error PolicyUnavailable();

    constructor(
        address usdg_,
        address stock_,
        address v3Pool_,
        address oracle_,
        address token_,
        address poolManager_,
        address factory_,
        HedgeFunTreasuryBase.Params memory p,
        EngineConfig memory c
    ) {
        treasuryUpgradeController = IV2UpgradeRegistry(msg.sender).upgradeController();
        PolicyManifest memory manifest = IV2StrategyRegistry(msg.sender).policy(c.policyKey);
        if (!manifest.enabledForNewLaunches) revert PolicyUnavailable();
        HedgeFunV2TradablePercentEngineTreasuryLogic logic = new HedgeFunV2TradablePercentEngineTreasuryLogic(
            usdg_,
            stock_,
            v3Pool_,
            oracle_,
            token_,
            poolManager_,
            factory_,
            p,
            EngineBinding(c, manifest, address(this))
        );
        initialImplementation = address(logic);
        upgradeConfigHash = logic.upgradeConfigHash();
        _call(address(logic), abi.encodeCall(HedgeFunV2TradablePercentEngineTreasuryLogic.initializeProxy, (p, c)));
    }

    function implementation() public view returns (address) {
        address next = treasuryUpgradeController.implementationOf(address(this));
        return next == address(0) ? initialImplementation : next;
    }

    function _implementation() internal view override returns (address) {
        return implementation();
    }

    function applyUpgrade(bytes calldata data) external {
        if (msg.sender != address(treasuryUpgradeController)) revert NotUpgradeController();
        if (data.length != 0) _call(implementation(), data);
    }

    function _call(address target, bytes memory data) private {
        (bool ok, bytes memory result) = target.delegatecall(data);
        if (!ok) assembly ("memory-safe") { revert(add(result, 0x20), mload(result)) }
    }
}
