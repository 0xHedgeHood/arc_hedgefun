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
import {V2FundAssetReader} from "./V2FundAssetReader.sol";
import {AssetPercentEngineConfig} from "./strategy/AssetPercentEngineConfig.sol";

/// @notice An append-only, schema-2 spot-policy engine with live total-external-asset percentage limits.
/// @dev Its registry kind is assigned at registration, never assumed. Schema 1 fixed-amount engines are unchanged.
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
/// Gains reach the burn as they do in kind 0. Inventory carries one average cost: stock booked at the live oracle
/// price, stock bought at its fill price, each weighted by quantity; a sale leaves it unchanged. A sale above that
/// cost realises a gain, and `payoutBps` of the gain -- the creator's choice, frozen in the config -- stays in stock
/// and moves to `buybackStock` instead of being sold, for the inherited paced `buyback()` to burn. The principal and
/// the rest of the gain are sold. `payoutBps = 0` is a pure rebalance whose buy-back is funded by LP fees alone.
contract HedgeFunV2AssetPercentEngineTreasury is HedgeFunV2Treasury {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant INTENT_RETURN_BYTES = 160;
    uint256 public constant MAX_POLICY_GAS = 500_000;
    uint256 private constant SPOT_CAPABILITIES = StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL;

    EngineConfig private _engineConfig;
    V2FundAssetReader public immutable assetReader;
    address public immutable policyImplementation;
    bytes32 public immutable policyRuntimeCodeHash;
    uint256 public immutable policyCapabilities;
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

    struct ExecutionLimits {
        uint256 targetBps;
        uint256 deadbandBps;
        uint256 maxTrade;
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
    }

    error BadEngineConfig();
    error PolicyUnavailable();
    error PolicyFailure();
    error BadPolicyReturn();
    error BadIntent();

    event InventoryBooked(uint256 amount, uint256 stockInventory);
    /// @notice a sale above `avgCost`: `gain` of the stock it took out of inventory was profit, and `toBuyback` of
    ///         that (`payoutBps`) stayed in stock for the buy-back instead of being sold
    event GainToBuyback(uint256 gain, uint256 toBuyback, uint256 avgCost, uint256 price);
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
        EngineConfig memory c
    ) HedgeFunV2Treasury(usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p) {
        PolicyManifest memory manifest = IV2StrategyRegistry(msg.sender).policy(c.policyKey);
        _validateEngineConfig(c, p, manifest);

        assetReader = new V2FundAssetReader(stock_, usdg_, poolManager_, token_, factory_, _SCALE);
        _engineConfig = c;
        payoutBps = uint16(AssetPercentEngineConfig.payoutBps(c.words[0]));
        tradingCalendar = PriceOracle(oracle_).calendar();
        policyImplementation = manifest.implementation;
        policyRuntimeCodeHash = manifest.runtimeCodeHash;
        policyCapabilities = manifest.capabilities;
        policyGasLimit = manifest.maxGas;
        policyReturnLimit = manifest.maxReturnBytes;
        configHash = keccak256(
            abi.encode(
                block.chainid,
                address(this),
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

    /// @dev The constructor is schema 2's authoritative word validator. The existing generic V2TreasuryDeployer
    ///      verifies policy/schema identity but only validates schema 1 words. Clients must preflight schema 2
    ///      with AssetPercentEngineConfig.valid; malformed CREATE2 launches atomically revert TreasuryDeployFailed.
    function _validateEngineConfig(EngineConfig memory c, Params memory p, PolicyManifest memory manifest)
        private
        view
    {
        bytes32 actualCodeHash = manifest.implementation.codehash;
        if (
            c.schema != AssetPercentEngineConfig.CONFIG_SCHEMA || c.engineVersion != StrategyCapabilities.SPOT_ENGINE_V1
                || manifest.engineVersion != c.engineVersion || manifest.configSchema != c.schema
                || !manifest.enabledForNewLaunches || manifest.implementation == address(0)
                || actualCodeHash == bytes32(0) || actualCodeHash != manifest.runtimeCodeHash || manifest.maxGas == 0
                || manifest.maxGas > MAX_POLICY_GAS || manifest.maxReturnBytes != INTENT_RETURN_BYTES
                || manifest.capabilities & SPOT_CAPABILITIES == 0 || manifest.capabilities & ~SPOT_CAPABILITIES != 0
                || p.sellChunkUsdg < p.minLotUsdg
                || !AssetPercentEngineConfig.valid(c.words, 0)
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

    /// @notice Live risk snapshot in USDG base units. NAV includes all treasury stock (buyback/pending),
    ///         cash and this fund vault's LP stock principal, uncollected stock fees and parked stock; excludes FUN. Caps are floored; minLot never raises a percentage cap.
    ///         Remaining daily capacity can decrease to zero or grow as NAV changes within the trading date.
    ///         Healthy describes the price snapshot, not cooldown or an executable allocation opportunity.
    function riskLimits() external view returns (
        bool healthy, uint256 navUsdg, uint256 maxTradeUsdg, uint256 maxDailyTurnoverUsdg,
        uint256 remainingDailyUsdg, uint64 epoch, uint256 usedUsdg
    ) {
        epoch = _tradingDate();
        usedUsdg = turnoverEpoch == epoch ? turnoverInEpoch : 0;
        (bool ok, uint256 price) = health();
        (bool live,) = _oracle.tryPrice();
        if (!ok || !live) return (false, 0, 0, 0, 0, epoch, usedUsdg);
        try assetReader.totalAssets(price) returns (uint256 value) { navUsdg = value; }
        catch { return (false, 0, 0, 0, 0, epoch, usedUsdg); }
        (,,, maxTradeUsdg, maxDailyTurnoverUsdg) = _riskConfig(navUsdg);
        remainingDailyUsdg = maxDailyTurnoverUsdg > usedUsdg ? maxDailyTurnoverUsdg - usedUsdg : 0;
        healthy = true;
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
    ///         For a sale, `amountIn` is the stock the action would take out of inventory; with a gain over
    ///         `avgCost`, `payoutBps` of the gain part of it goes to the buy-back and the rest to the pool.
    function preview() external view returns (bool due, StrategyAction action, uint256 amountIn) {
        (bool ok, uint256 p) = health();
        (bool live,) = _oracle.tryPrice();
        if (!ok || !live) return (false, StrategyAction.Hold, 0);
        uint256 nav;
        try assetReader.totalAssets(p) returns (uint256 value) { nav = value; }
        catch { return (false, StrategyAction.Hold, 0); }
        StrategyContext memory context = _context(p, bookedStock + unbookedStock());
        StrategyIntent memory intent = _policyIntent(context);
        if (!_basicIntentValid(intent) || intent.action == StrategyAction.Hold) {
            return (false, StrategyAction.Hold, 0);
        }
        amountIn = _previewExecutableAmount(context, intent, p, nav);
        if (amountIn == 0) return (false, StrategyAction.Hold, 0);
        return (true, intent.action, amountIn);
    }

    function _previewExecutableAmount(StrategyContext memory context, StrategyIntent memory intent, uint256 price, uint256 nav)
        private
        view
        returns (uint256 offered)
    {
        ExecutionLimits memory limits;
        uint256 cooldown;
        uint256 maxDaily;
        if (context.stockValueUsdg > type(uint256).max - context.usdgInventory) return 0;
        limits.totalValue = context.stockValueUsdg + context.usdgInventory;
        if (limits.totalValue == 0) return 0;
        (limits.targetBps, limits.deadbandBps, cooldown, limits.maxTrade, maxDaily) = _riskConfig(nav);
        if (lastStrategyAt != 0 && block.timestamp < lastStrategyAt + cooldown) return 0;
        uint64 epoch = _tradingDate();
        uint256 used = turnoverEpoch == epoch ? turnoverInEpoch : 0;
        if (used >= maxDaily) return 0;
        limits.remainingDaily = maxDaily - used;

        if (intent.action == StrategyAction.SellStock) {
            return _previewSell(context, intent.amountIn, price, limits);
        }
        if (intent.action == StrategyAction.BuyStock) {
            return _previewBuy(context, intent.amountIn, limits);
        }
        return 0;
    }

    function _previewSell(
        StrategyContext memory context,
        uint256 requested,
        uint256 price,
        ExecutionLimits memory limits
    ) private view returns (uint256 offered) {
        if (policyCapabilities & StrategyCapabilities.SPOT_SELL == 0) return 0;
        uint256 upperValue = Math.mulDiv(limits.totalValue, limits.targetBps + limits.deadbandBps, BPS);
        if (context.stockValueUsdg <= upperValue) return 0;
        uint256 targetValue = Math.mulDiv(limits.totalValue, limits.targetBps, BPS);
        uint256 capUsdg =
            Math.min(Math.min(limits.maxTrade, limits.remainingDaily), context.stockValueUsdg - targetValue);
        offered = Math.min(requested, Math.min(context.stockInventory, _ruleStockFor(capUsdg, price)));
        if (offered == 0 || _ruleValue(offered, price) < _params.minLotUsdg) return 0;
    }

    function _previewBuy(StrategyContext memory context, uint256 requested, ExecutionLimits memory limits)
        private
        view
        returns (uint256 offered)
    {
        if (policyCapabilities & StrategyCapabilities.SPOT_BUY == 0) return 0;
        uint256 lowerValue = Math.mulDiv(limits.totalValue, limits.targetBps - limits.deadbandBps, BPS);
        if (context.stockValueUsdg >= lowerValue) return 0;
        uint256 targetValue = Math.mulDiv(limits.totalValue, limits.targetBps, BPS);
        uint256 capUsdg =
            Math.min(Math.min(limits.maxTrade, limits.remainingDaily), targetValue - context.stockValueUsdg);
        offered = Math.min(Math.min(requested, capUsdg), context.usdgInventory);
        if (offered < _params.minLotUsdg) return 0;
    }

    /// @notice Execute one bounded policy action, paying its caller `bountyBps` of the actual swap output.
    ///         Sells pay USDG; buys pay stock. Keepers choose no action, route, lot, price or reward recipient.
    function execute() external override nonReentrant returns (Action action, uint256 id) {
        (bool ok, uint256 p) = health();
        if (!ok) revert Unhealthy();
        (bool live,) = _oracle.tryPrice();
        if (!live) revert Unhealthy();
        uint256 nav;
        try assetReader.totalAssets(p) returns (uint256 value) { nav = value; }
        catch { revert Unhealthy(); }
        _bookInventory(p);

        StrategyContext memory context = _context(p, bookedStock);
        StrategyIntent memory intent = _policyIntent(context);
        if (!_basicIntentValid(intent) || intent.action == StrategyAction.Hold) revert NotDue();

        uint256 requested = intent.amountIn;
        ExecutionLimits memory limits = _executionLimits(context, nav);
        _notePrice(p);
        _noteTokenSpot();
        ExecutionResult memory result = _executeIntent(context, intent, p, limits);
        action = result.action;
        // A V3 exact-input swap can stop at the price limit after consuming only dust. Treating that as a strategy
        // action would let a thin or deliberately positioned venue advance the nonce and renew the cooldown while
        // barely consuming the daily budget. The check must use the actual fill and must happen before any strategy
        // state is committed; reverting here rolls the swap and its transfers back atomically.
        if (result.turnover < _params.minLotUsdg) revert NotDue();
        if (result.turnover > limits.remainingDaily) revert BadIntent();
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

    function _executionLimits(StrategyContext memory context, uint256 nav) private view returns (ExecutionLimits memory limits) {
        uint256 cooldown;
        uint256 maxDaily;
        if (context.stockValueUsdg > type(uint256).max - context.usdgInventory) revert BadIntent();
        limits.totalValue = context.stockValueUsdg + context.usdgInventory;
        if (limits.totalValue == 0) revert NotDue();
        (limits.targetBps, limits.deadbandBps, cooldown, limits.maxTrade, maxDaily) = _riskConfig(nav);
        if (lastStrategyAt != 0 && block.timestamp < lastStrategyAt + cooldown) revert Cooldown();
        limits.epoch = _tradingDate();
        limits.used = turnoverEpoch == limits.epoch ? turnoverInEpoch : 0;
        if (limits.used >= maxDaily) revert NotDue();
        limits.remainingDaily = maxDaily - limits.used;
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
        uint256 capUsdg = Math.min(Math.min(limits.maxTrade, limits.remainingDaily), excessUsdg);
        uint256 offered = Math.min(requested, Math.min(bookedStock, _ruleStockFor(capUsdg, price)));
        if (offered == 0 || _ruleValue(offered, price) < _params.minLotUsdg) revert NotDue();
        // `offered` leaves inventory. The part of it that is gain over the average cost is `offered * (1 - cost/p)`;
        // `payoutBps` of that stays in stock for the buy-back and the rest is sold -- kind 0's split. A short fill
        // takes out only the share of both that the sold amount stands for, so a dust fill moves dust.
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
        uint256 moved = result.actualInput + toBuyback;
        bookedStock -= moved;
        buybackStock += toBuyback;
        result.turnover = _ruleValue(moved, price);
        result.action = Action.RebalanceSell;
        if (gain != 0) emit GainToBuyback(gain, toBuyback, cost, price);
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
        uint256 capUsdg = Math.min(Math.min(limits.maxTrade, limits.remainingDaily), deficitUsdg);
        uint256 offered = Math.min(Math.min(requested, capUsdg), context.usdgInventory);
        if (offered < _params.minLotUsdg) revert NotDue();
        (result.actualInput, result.actualOutput) = _swapStock(true, offered, price);
        result.keeperReward = Math.mulDiv(result.actualOutput, _params.bountyBps, BPS);
        uint256 retainedStock = result.actualOutput - result.keeperReward;
        // The whole USDG spend bought the stock retained after the executor's reward. Booking gross output would
        // create phantom inventory; pricing it at gross output would understate cost and manufacture later gains.
        _addCost(retainedStock, result.actualInput * _SCALE);
        bookedStock += retainedStock;
        result.turnover = result.actualInput;
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

    function _riskConfig(uint256 navUsdg)
        private
        view
        returns (uint256 targetBps, uint256 deadbandBps, uint256 cooldown, uint256 maxTrade, uint256 maxDaily)
    {
        uint256 packed = uint256(_engineConfig.words[0]);
        targetBps = uint16(packed);
        deadbandBps = uint16(packed >> 16);
        cooldown = uint32(packed >> 32);
        maxTrade = Math.min(
            Math.mulDiv(navUsdg, uint256(_engineConfig.words[1]), BPS), _params.sellChunkUsdg
        );
        maxDaily = Math.mulDiv(navUsdg, uint256(_engineConfig.words[2]), BPS);
    }

    function _policyIntent(StrategyContext memory context) private view returns (StrategyIntent memory intent) {
        address implementation = policyImplementation;
        if (implementation.codehash != policyRuntimeCodeHash) revert PolicyUnavailable();
        bytes memory callData = abi.encodeCall(IStrategyPolicy.decide, (context, _engineConfig, policyState));
        bool success;
        uint256 size;
        uint256 gasLimit = policyGasLimit;
        assembly ("memory-safe") {
            success := staticcall(gasLimit, implementation, add(callData, 0x20), mload(callData), 0, 0)
            size := returndatasize()
        }
        if (!success) revert PolicyFailure();
        if (size != INTENT_RETURN_BYTES || size > policyReturnLimit) revert BadPolicyReturn();
        bytes memory result = new bytes(size);
        uint256 actionWord;
        assembly ("memory-safe") {
            returndatacopy(add(result, 0x20), 0, size)
            actionWord := mload(add(result, 0x60)) // word 2 of (configHash, nonce, action, amountIn, nextState)
        }
        // `abi.decode` would refuse an undeclared enum value too, but with EMPTY revert data that a keeper cannot
        // tell from running out of gas; refuse it first, by name, so a policy returning a future action word
        // (options are 64 and up) is diagnosable.
        if (actionWord > uint256(type(StrategyAction).max)) revert BadPolicyReturn();
        intent = abi.decode(result, (StrategyIntent));
    }
}
