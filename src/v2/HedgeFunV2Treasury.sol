// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HedgeFunTreasury} from "../HedgeFunTreasury.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunMath} from "../libraries/HedgeFunMath.sol";

/// @notice V2 parks fees and donations until graduation wires its permanent pool. Its stock
/// strategy runs through execute() with fixed stop/profit/buy priority. The deterministic
/// graduation price anchors the first token buyback.
contract HedgeFunV2Treasury is HedgeFunTreasury {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    address public liquidityVault;
    uint256 public constant MAX_STRATEGY_LOTS = 128;
    uint256 public constant STOP_REENTRY_COOLDOWN = 600;
    uint256 public lastStopPrice;
    uint256 public lastStopAt;
    uint256 public lastStopStockUpdatedAt;

    /// @dev The first three values are the deployed V2 ABI. New engine actions append only,
    ///      so existing return values and indexers keep their meaning.
    enum Action { Stop, TakeProfit, BuyDip, RebalanceBuy, RebalanceSell, BuyRecovery }
    error UseExecute();
    event LotsCoalesced(uint256 indexed kept, uint256 indexed removed, uint256 qty, uint256 cost);
    event ProfitDustReleased(uint256 indexed id, uint256 qty, uint256 cost, uint256 price);

    constructor(address usdg_, address stock_, address v3Pool_, address oracle_, address token_,
        address poolManager_, address factory_, Params memory p)
        HedgeFunTreasury(usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p) {
        // A newly purchased lot uses its actual V3 fill as cost. A stop inside the maximum
        // buy execution friction can therefore be due without any new adverse market move.
        if (p.stopBps != 0 && p.stopBps <= p.maxSlippageBps + poolFeeBps + p.bountyBps) revert BadConfig();
    }

    /// @dev V1 keeps the individual entry points. V2 cannot let callers select their order or lot.
    function takeProfit(uint256) public pure override { revert UseExecute(); }
    function stopLoss(uint256) public pure override { revert UseExecute(); }
    function buyDip() public pure override { revert UseExecute(); }

    /// @dev Closed-market buybacks need a stock/USDG conversion, even for a new treasury with no price cache.
    ///      This is independent of the strategy's optional band: it sizes income-only FUN purchases, never stock
    ///      trades. Keep the existing 30% outer band, fresh dollar leg, pause and spot/TWAP gates. Pool prices do
    ///      not refresh lastGoodPrice. V2 never bypasses a rejected quote with the legacy sizing cache.
    function _buybackFallbackPrice() internal view override returns (uint256 p) {
        (bool valid, uint256 feed,) = _feed();
        if (valid) p = _guardedPoolPrice(feed, MAX_BAND_BPS);
    }

    function _canAddLot() internal view virtual override returns (bool) { return lots.length < MAX_STRATEGY_LOTS; }

    function book() public virtual override nonReentrant returns (bool) { return _bookV2(); }

    function _bookV2() internal returns (bool booked) {
        booked = _book();
        if (booked || lots.length != MAX_STRATEGY_LOTS) return booked;
        uint256 un = unbookedStock();
        (bool healthy, uint256 p) = health();
        (bool live,) = _oracle.tryPrice();
        if (!healthy || !live || un == 0 || _ruleValue(un, p) < _params.minLotUsdg) return false;
        if (!_coalesceLots()) return false;
        return _book();
    }

    /// @dev Reclaim a slot only when it preserves every lot's price triggers. Distinct
    ///      bases remain separate; at full capacity the treasury can still sell but pauses buys.
    function _coalesceLots() internal returns (bool) {
        for (uint256 i; i < lots.length; ++i) {
            Lot storage A = lots[i];
            for (uint256 j = i + 1; j < lots.length; ++j) {
                Lot storage B = lots[j];
                if (A.cost != B.cost || A.half != B.half
                    || (A.tp1Left == 0) != (B.tp1Left == 0)) continue;
                A.qty += B.qty;
                A.tp1Left += B.tp1Left;
                emit LotsCoalesced(i, j, A.qty, A.cost);
                uint256 last = lots.length - 1;
                if (j != last) lots[j] = lots[last];
                lots.pop();
                return true;
            }
        }
        return false;
    }

    /// @notice Execute one bounded strategy action. A later call rechecks the oracle and every lot.
    ///         No new buy can jump over a due stop, including the remainder of a short fill. A microscopic
    ///         unsellable tail first leaves the lot ledger as unbooked stock, without recording a sale.
    function execute() external virtual nonReentrant returns (Action action, uint256 id) {
        (bool ok, uint256 p) = health();
        if (!ok) revert Unhealthy();
        _book(); // at capacity, keep pending donations unbooked while urgent sales run
        (bool live,) = _oracle.tryPrice();
        uint256 stopDustId = type(uint256).max;
        if (live && _params.stopBps != 0) {
            // Remove non-economic due tails in the same transaction as the next real stop. A keeper can then
            // collect that stop's ordinary bounty without first paying for a separate zero-reward cleanup.
            for (uint256 i; i < lots.length;) {
                if (HedgeFunMath.fellTo(p, lots[i].cost, _params.stopBps) && _releaseStopDust(i, p)) {
                    stopDustId = i; // _shrink moved the last lot into i; inspect that slot next
                } else {
                    ++i;
                }
            }
            (bool found, uint256 stopId) = _dueStop(p);
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
                profitDustId = i;
                continue; // inspect a swapped-in lot or an advanced TP1 stage at this same index
            }
            ++i;
        }
        (bool foundTp, uint256 dueId) = _dueProfit(p);
        if (foundTp) {
            _takeProfit(dueId);
            // A profit above a lot's cost means the market moved past the stop, so the dip rung is the
            // sale that just happened, not the stop. Without this the treasury could never buy back in.
            _clearStopGate();
            return (Action.TakeProfit, dueId);
        }
        // If a dip is ready, execute it in this transaction so a keeper can earn its ordinary bounty
        // after cleaning tails. Otherwise keep the cleanup itself, without inventing a paid sale.
        if ((stopDustId != type(uint256).max || profitDustId != type(uint256).max)
            && !_dipReadyAfterDust(p, live)) {
            if (stopDustId != type(uint256).max) return (Action.Stop, stopDustId);
            return (Action.TakeProfit, profitDustId);
        }

        // During a scheduled closure the pool can supply a bounded price for TP, but not
        // prove that no stop is due. A stop-enabled treasury therefore cannot add risk.
        if (!live && _params.stopBps != 0) revert NotDue();
        if (!_canBuyAfterStop(p, live)) revert NotDue();
        // Only after ruling out all sales do we compact exact-matching lots for a buy.
        // A fresh booking costs p and cannot itself be stop- or profit-due at p.
        _bookV2();
        if (lots.length == MAX_STRATEGY_LOTS && !_coalesceLots()) {
            // Booking pending stock after dust cleanup may fill the freed slot. Preserve the cleanup
            // and booking, then leave the dip for a later call with capacity.
            if (stopDustId != type(uint256).max) return (Action.Stop, stopDustId);
            if (profitDustId != type(uint256).max) return (Action.TakeProfit, profitDustId);
            revert NotDue();
        }
        Action buyAction = _executeBuy(p, live);
        _clearStopGate();
        return (buyAction, lots.length - 1);
    }

    function _canBuyAfterStop(uint256 p, bool live) internal view virtual returns (bool) {
        if (lastStopAt == 0) return true;
        if (!live || block.timestamp - lastStopAt < STOP_REENTRY_COOLDOWN
            || !HedgeFunMath.fellTo(p, lastStopPrice, _params.dipBps)) return false;
        (bool valid,, uint256 updatedAt) = _oracle.lastPriceAt();
        return valid && updatedAt > lastStopStockUpdatedAt;
    }

    function _executeBuy(uint256, bool) internal virtual returns (Action) {
        _buyDip();
        return Action.BuyDip;
    }

    function _afterStop() internal virtual {}

    /// @dev The post-stop gate guards the first re-entry after a stop only. Once the treasury has sold at a
    ///      profit or bought again, `lastSalePrice` is a newer reference than the stop and the gate is done.
    function _clearStopGate() internal virtual {
        if (lastStopAt != 0) (lastStopPrice, lastStopAt, lastStopStockUpdatedAt) = (0, 0, 0);
    }

    /// @dev Only used after a dust cleanup. The ordinary buy path below retains its own checks.
    function _dipReadyAfterDust(uint256 p, bool live) internal view virtual returns (bool) {
        if (!live && _params.stopBps != 0) return false;
        if (lastSalePrice == 0 || !HedgeFunMath.fellTo(p, lastSalePrice, _params.dipBps)) return false;
        if (HedgeFunMath.bps(reserveUsdg(), _params.lotBps) < _params.minLotUsdg || !_canAddLot()) return false;
        return _canBuyAfterStop(p, live);
    }

    function _dueStop(uint256 p) internal view returns (bool found, uint256 id) {
        uint256 highestCost;
        uint256 largestQty;
        for (uint256 i; i < lots.length; ++i) {
            Lot storage L = lots[i];
            if (HedgeFunMath.fellTo(p, L.cost, _params.stopBps)
                && (!found || L.cost > highestCost || (L.cost == highestCost && L.qty > largestQty))) {
                (found, id, highestCost, largestQty) = (true, i, L.cost, L.qty);
            }
        }
    }

    function _dueProfit(uint256 p) internal view returns (bool found, uint256 id) {
        // At one price, close an already-half-sold lot before starting another TP1.
        bool tp2;
        uint256 selectedCost;
        uint256 selectedQty;
        for (uint256 i; i < lots.length; ++i) {
            Lot storage L = lots[i];
            bool second = _params.tp2Bps == 0 || L.half;
            uint256 trigger = second && _params.tp2Bps != 0 ? _params.tp2Bps : _params.tp1Bps;
            if (HedgeFunMath.reached(p, L.cost, trigger)
                && (!found || (second && !tp2) || (second == tp2 &&
                    (L.cost < selectedCost || (L.cost == selectedCost && L.qty > selectedQty))))) {
                (found, tp2, id, selectedCost, selectedQty) = (true, second, i, L.cost, L.qty);
            }
        }
    }

    /// @dev Retire only a whole microscopic lot or the final microscopic slice of a TP1 that already sold
    ///      a chunk. This is not a monetary sale; unbooked stock keeps the cost basis out of buyback profit.
    function _releaseProfitDust(uint256 id, uint256 p) internal returns (bool cleared) {
        Lot storage L = lots[id];
        bool first = _params.tp2Bps != 0 && !L.half;
        uint256 trigger = first ? _params.tp1Bps : (_params.tp2Bps != 0 ? _params.tp2Bps : _params.tp1Bps);
        if (!HedgeFunMath.reached(p, L.cost, trigger)) return false;

        uint256 offered = _ruleStockFor(_params.sellChunkUsdg, p);
        uint256 q = offered;
        uint256 left;
        if (first) {
            left = L.tp1Left;
            if (left == 0) left = L.qty / 2;
            if (left == 0) return false; // existing zero-quantity TP1 stage transition cannot revert
            q = Math.min(q, left);
        } else {
            q = Math.min(q, L.qty);
        }
        // Both inherited TP implementations already handle a principal worth zero without entering V3.
        // Intervene only where they would try a microscopic swap that can fail on output rounding.
        if (q == 0 || _ruleValue(Math.mulDiv(q, L.cost, p), p) == 0) return false;
        if (offered >= L.qty && _ruleValue(L.qty, p) < _DUST_VALUE_LIMIT) {
            uint256 qty = L.qty;
            uint256 dustCost = L.cost;
            _shrink(id, qty);
            _releasedDustStock += qty;
            emit ProfitDustReleased(id, qty, dustCost, p);
            return true;
        }
        if ((q != L.qty && (!first || L.tp1Left == 0 || q != left))
            || _ruleValue(q, p) >= _DUST_VALUE_LIMIT) {
            return false;
        }
        uint256 cost = L.cost;
        if (first) { L.tp1Left = left - q; if (left == q) L.half = true; }
        _shrink(id, q);
        _releasedDustStock += q;
        emit ProfitDustReleased(id, q, cost, p);
        return true;
    }

    /// @notice The factory freezes the position owner before the first V4 pool is seeded.
    function setLiquidityVault(address vault) external {
        if (msg.sender != factory) revert NotFactory();
        if (liquidityVault != address(0)) revert AlreadyWired();
        liquidityVault = vault;
    }

    /// @notice Realized stock-side LP fees enter the buyback budget, never a strategy cost-basis lot.
    /// @dev Pulling under the reentrancy guard prevents token callbacks from booking the fee as principal.
    function creditLiquidityFee(uint256 amount) external virtual nonReentrant {
        if (msg.sender != liquidityVault || amount == 0) revert NotFactory();
        _stock.safeTransferFrom(msg.sender, address(this), amount);
        buybackStock += amount;
    }

    /// @dev Every booking and stock-trading entry point in the base consults this virtual gate.
    function health() public view override returns (bool ok, uint256 p) {
        if (hook == address(0)) return (false, 0);
        return super.health();
    }

    /// @dev Unlike V1's one-sided opening, graduation already has a terminal curve price and
    /// balanced liquidity. Capture that price before the pool can trade. Later TWAP/anchor
    /// fallback stays usable even if high-frequency swaps exhaust the hook's observation ring.
    function wire(PoolKey calldata key) public virtual override {
        super.wire(key);
        (uint160 price,,,) = poolManager.getSlot0(key.toId());
        if (price == 0) revert BadConfig();
        buybackAnchorSqrtP = price;
        buybackAnchorAt = block.timestamp;
    }
}
