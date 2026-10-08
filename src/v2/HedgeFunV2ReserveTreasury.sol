// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LotReserveScheduler} from "./strategy/LotReserveScheduler.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {LotReserveLimits} from "./strategy/LotReserveLimits.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunTreasuryBase} from "../HedgeFunTreasuryBase.sol";
import {HedgeFunMath} from "../libraries/HedgeFunMath.sol";
import {HedgeFunV2Treasury} from "./HedgeFunV2Treasury.sol";
import {IV2UpgradeRegistry} from "./HedgeFunV2UpgradeableTreasury.sol";
import {V2TreasuryUpgradeController} from "./V2TreasuryUpgradeController.sol";
import {EngineConfig} from "./strategy/IStrategyPolicy.sol";
import {LotReserveConfig} from "./strategy/V2LotReservePolicy.sol";

/// @notice The lot rule with an opening reserve. A graduation books the whole treasury in stock, so a lot strategy
///         has no USDG until its first take-profit: if the stock only falls, no dip can ever be bought. This kind
///         first turns the creator's `reserveBps` (0 to 50%) of the graduation stock into USDG, then runs the
///         ordinary lot rule: sell rungs above each lot's cost, buy dips with the reserve.
///
/// The target is fixed at graduation from the exact principal (`wireWithGraduation`).
/// The reserve sale is the lowest-priority action: a due stop or take-profit always goes first. It sells from the
/// graduation lot in chunks of the listing's `sellChunkUsdg`, inside `maxSlippageBps` of the oracle, never on a
/// pool-only price, pays the keeper `bountyBps` of what it receives, and moves the dip reference to the sale price
/// so the first dip is measured from there. It is not a profit: the proceeds join the reserve, never the buy-back.
/// The phase ends when the target is sold, its tail is below one minimum lot, or a priority sale/cleanup intervenes.
/// Optional lifetime cash floor, gross dip budget and buy-count limit are independent; zero disables each limit.
///
/// The rungs keep the legacy floor of the V2 base: `tp1Bps` and `dipBps` at least twice the listing's slippage
/// limit plus pool fee.
abstract contract HedgeFunV2ReserveTreasuryCore is HedgeFunV2Treasury {
    using SafeERC20 for IERC20;

    /// @notice the creator's share of the graduation stock to hold as USDG, in bps
    uint16 public reserveBps;
    /// @notice graduation has supplied its exact principal, including a zero allocation
    bool public reserveArmed;
    /// @notice graduation stock still to sell for the opening reserve
    uint256 public reserveStockLeft;
    /// @notice the registered policy this treasury was launched with, as the registry checks at deployment
    bytes32 public strategyId;
    bytes32 public configHash;

    /// @notice packed floor/budget/count limits, buys, frozen basis flag, exact principal, USDG basis and gross spend
    LotReserveLimits.State public dipLimits;
    error GraduationPrincipalRequired();
    event ReserveCancelled(uint256 stockLeft);

    event ReserveSold(uint256 stockSold, uint256 usdgReceived, uint256 price);

    constructor(
        address usdg_,
        address stock_,
        address v3Pool_,
        address oracle_,
        address token_,
        address poolManager_,
        address factory_,
        Params memory p
    ) HedgeFunV2Treasury(usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p) {}

    function engineVersion() external pure returns (uint32) {
        return LotReserveConfig.ENGINE_VERSION;
    }

    /// @dev V2's stop/profit/buy order, using linked lot selection to leave room below EIP-170.
    ///      Freeze before any priority sale can change the graduation ledger.
    function execute() external override nonReentrant returns (Action action, uint256 id) {
        (bool ok, uint256 p) = health();
        if (!ok) revert Unhealthy();
        (bool live,) = _oracle.tryPrice();
        _freezeLimits(p, live);
        _book(); // at capacity, keep pending donations unbooked while urgent sales run
        uint256 stopDustId = type(uint256).max;
        if (live && _params.stopBps != 0) {
            // Remove non-economic due tails in the same transaction as the next real stop. A keeper can then
            // collect that stop's ordinary bounty without first paying for a separate zero-reward cleanup.
            for (uint256 i; i < lots.length;) {
                if (HedgeFunMath.fellTo(p, lots[i].cost, _params.stopBps) && _releaseStopDust(i, p)) {
                    if (i == 0) _afterStockSale(0, 0, 0);
                    stopDustId = i; // _shrink moved the last lot into i; inspect that slot next
                } else {
                    ++i;
                }
            }
            (bool found, uint256 stopId) = LotReserveScheduler.dueStop(lots, p, _params.stopBps);
            if (found) {
                (bool valid,, uint256 updatedAt) = _oracle.lastPriceAt();
                if (!valid) revert Unhealthy();
                if (_stopLoss(stopId)) {
                    (lastStopPrice, lastStopAt, lastStopStockUpdatedAt) = (p, block.timestamp, updatedAt);
                    _afterStop();
                }
                return (Action.Stop, stopId);
            }
        }
        uint256 profitDustId = type(uint256).max;
        for (uint256 i; i < lots.length;) {
            if (_releaseProfitDust(i, p)) {
                if (i == 0) _afterStockSale(0, 0, 0);
                profitDustId = i;
                continue; // inspect a swapped-in lot or an advanced TP1 stage at this same index
            }
            ++i;
        }
        (bool foundTp, uint256 dueId) = LotReserveScheduler.dueProfit(lots, p, _params.tp1Bps, _params.tp2Bps);
        if (foundTp) {
            _takeProfit(dueId);
            // A profit above a lot's cost means the market moved past the stop, so the dip rung is the
            // sale that just happened, not the stop. Without this the treasury could never buy back in.
            _clearStopGate();
            return (Action.TakeProfit, dueId);
        }
        // If a dip is ready, execute it in this transaction so a keeper can earn its ordinary bounty
        // after cleaning tails. Otherwise keep the cleanup itself, without inventing a paid sale.
        if ((stopDustId != type(uint256).max || profitDustId != type(uint256).max) && !_dipReadyAfterDust(p, live)) {
            if (stopDustId != type(uint256).max) return (Action.Stop, stopDustId);
            return (Action.TakeProfit, profitDustId);
        }

        // During a scheduled closure the pool can supply a bounded price for TP, but not
        // prove that no stop is due. A stop-enabled treasury therefore cannot add risk.
        if (!live && _params.stopBps != 0) revert NotDue();
        if (!_canBuyAfterStop(p, live)) revert NotDue();
        // Only after ruling out all sales do we compact exact-matching lots for a buy.
        // A fresh booking costs p and cannot itself be stop- or profit-due at p.
        _reserveBookV2();
        if (lots.length == MAX_STRATEGY_LOTS && !LotReserveScheduler.coalesce(lots)) {
            // Booking pending stock after dust cleanup may fill the freed slot. Preserve the cleanup
            // and booking, then leave the dip for a later call with capacity.
            if (stopDustId != type(uint256).max) return (Action.Stop, stopDustId);
            if (profitDustId != type(uint256).max) return (Action.TakeProfit, profitDustId);
            revert NotDue();
        }
        Action buyAction = _executeBuy(p, live);
        _clearStopGate();
        return (buyAction, buyAction == Action.RebalanceSell ? 0 : lots.length - 1);
    }

    /// @dev Fail closed if an old integration cannot provide the exact graduation principal.
    function wire(PoolKey calldata) public pure override {
        revert GraduationPrincipalRequired();
    }

    function wireWithGraduation(PoolKey calldata key, uint256 principal) external {
        super.wire(key); // existing factory-only, once-only wiring; transfer follows atomically
        reserveArmed = true;
        reserveStockLeft = HedgeFunMath.bps(principal, reserveBps);
        dipLimits.graduationStock = principal;
    }

    function book() public override nonReentrant returns (bool booked) {
        booked = _reserveBookV2();
        if (booked) LotReserveLimits.freeze(dipLimits, lots[0].cost, _SCALE);
    }

    function _reserveBookV2() internal returns (bool booked) {
        booked = _book();
        if (booked || lots.length != MAX_STRATEGY_LOTS) return booked;
        uint256 un = unbookedStock();
        (bool healthy, uint256 p) = health();
        (bool live,) = _oracle.tryPrice();
        if (!healthy || !live || un == 0 || _ruleValue(un, p) < _params.minLotUsdg) return false;
        if (!LotReserveScheduler.coalesce(lots)) return false;
        return _book();
    }

    function _freezeLimits(uint256 p, bool live) private {
        if (live) LotReserveLimits.freeze(dipLimits, p, _SCALE);
    }

    /// @dev Any priority sale ends the opening phase, including a short fill or all-profit dust.
    function _afterStockSale(uint256, uint256, uint256) internal override {
        if (reserveStockLeft != 0) {
            emit ReserveCancelled(reserveStockLeft);
            reserveStockLeft = 0;
        }
    }

    /// @dev Reached only when no stop or take-profit is due. Graduation fixes the target before any booking.
    function _executeBuy(uint256 p, bool live) internal override returns (Action) {
        uint256 left = reserveStockLeft;
        if (left == 0 || lots.length == 0) return _limitedDip(p);
        if (!live || pricedOffPoolOnly()) revert NotDue(); // never on a price only the pool vouches for
        Lot storage L = lots[0]; // the graduation lot: dips are not bought yet
        uint256 q = Math.min(Math.min(left, L.qty), _ruleStockFor(_params.sellChunkUsdg, p));
        if (_ruleValue(q, p) < _params.minLotUsdg) {
            _afterStockSale(0, 0, 0); // persist an unpaid phase completion instead of reverting on a flat price
            return Action.RebalanceSell;
        }
        _notePrice(p);
        _noteTokenSpot();
        uint256 got;
        (q, got) = _swapStock(false, q, p);
        // A priority TP cancels the opening phase, so its lot has no in-progress TP1 balance.
        _shrink(0, q);
        reserveStockLeft = left > q ? left - q : 0;
        lastSalePrice = p; // the first dip is measured from here
        emit ReserveSold(q, got, p);
        uint256 bounty = HedgeFunMath.bps(got, _params.bountyBps);
        if (bounty != 0) _usdg.safeTransfer(msg.sender, bounty); // last: every effect is already written
        return Action.RebalanceSell;
    }

    function _dipReadyAfterDust(uint256 p, bool live) internal view override returns (bool) {
        return super._dipReadyAfterDust(p, live)
            && LotReserveScheduler.spendLimit(dipLimits, reserveUsdg()) >= _params.minLotUsdg;
    }

    function _limitedDip(uint256 p) private returns (Action) {
        if (lastSalePrice == 0 || !HedgeFunMath.fellTo(p, lastSalePrice, _params.dipBps)) revert NotDue();
        uint256 cash = reserveUsdg();
        _buyWithReserve(p, LotReserveScheduler.spendLimit(dipLimits, cash));
        LotReserveLimits.record(dipLimits, cash - reserveUsdg()); // actual USDG fill plus keeper bounty
        return Action.BuyDip;
    }
}

/// @notice Per-launch implementation behind the two-day upgrade controller, like every release kind.
/// @dev Future implementations preserve this storage layout and append. Parameters arrive as the five storage words
///      of `Params` (see `HedgeFunV2UpgradeableCycleTreasury`), which costs far less runtime than a struct copy.
contract HedgeFunV2UpgradeableReserveTreasuryLogic is HedgeFunV2ReserveTreasuryCore {
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
        EngineConfig memory c
    ) HedgeFunV2ReserveTreasuryCore(usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p) {
        upgradeConfigHash = keccak256(
            abi.encode(
                keccak256("hedgefun.v2.lot-reserve.proxy.storage.v1"),
                usdg_,
                stock_,
                v3Pool_,
                oracle_,
                token_,
                poolManager_,
                factory_,
                p,
                c
            )
        );
    }

    /// @dev Deployment-only delegatecall from the proxy's constructor, which validated the config and hashed it:
    ///      neither costs this runtime a byte.
    function initializeProxy(
        bytes32[5] calldata,
        uint16 reserveBps_,
        uint256 limits_,
        bytes32 strategyId_,
        bytes32 configHash_
    ) external {
        if (address(this).code.length != 0) revert InvalidInitialization();
        assembly ("memory-safe") {
            let slot := _params.slot
            for { let i := 0 } lt(i, 5) { i := add(i, 1) } { sstore(add(slot, i), calldataload(add(4, mul(i, 32)))) }
        }
        (reserveBps, strategyId, configHash) = (reserveBps_, strategyId_, configHash_);
        dipLimits.packedConfig = limits_;
    }
}

/// @notice Upgradeable lot-with-reserve treasury: the registry's ordinary args plus the creator's EngineConfig.
contract HedgeFunV2UpgradeableReserveTreasury is Proxy {
    V2TreasuryUpgradeController public immutable treasuryUpgradeController;
    address public immutable initialImplementation;
    bytes32 public immutable upgradeConfigHash;
    error NotUpgradeController();

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
        uint16 reserve = LotReserveConfig.reserveBps(c); // refuse a bad config before deploying anything
        treasuryUpgradeController = IV2UpgradeRegistry(msg.sender).upgradeController();
        HedgeFunV2UpgradeableReserveTreasuryLogic logic = new HedgeFunV2UpgradeableReserveTreasuryLogic(
            usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p, c
        );
        initialImplementation = address(logic);
        upgradeConfigHash = logic.upgradeConfigHash();
        _call(
            address(logic),
            abi.encodeCall(
                HedgeFunV2UpgradeableReserveTreasuryLogic.initializeProxy,
                (_words(p), reserve, uint256(c.words[1]), c.policyKey, keccak256(abi.encode(c)))
            )
        );
    }

    /// @dev `Params` as Solidity lays it out in storage, exactly as `HedgeFunV2UpgradeableCycleTreasury._words`.
    function _words(HedgeFunTreasuryBase.Params memory p) private pure returns (bytes32[5] memory w) {
        w[0] = bytes32(
            uint256(p.tp1Bps) | uint256(p.tp2Bps) << 32 | uint256(p.dipBps) << 64 | uint256(p.stopBps) << 80
                | uint256(p.lotBps) << 96 | uint256(p.bountyBps) << 112 | uint256(p.maxSlippageBps) << 128
                | uint256(p.maxDeviationBps) << 144 | uint256(p.maxBuybackImpactBps) << 160 | uint256(p.buybackCooldown)
                << 176
        );
        w[1] = bytes32(p.minLotUsdg);
        w[2] = bytes32(p.buybackChunkUsdg);
        w[3] = bytes32(p.sellChunkUsdg);
        w[4] = bytes32(uint256(p.bandBpsPerHour));
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
