// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HedgeFunV2Treasury} from "./HedgeFunV2Treasury.sol";
import {HedgeFunMath} from "../libraries/HedgeFunMath.sol";

/// @notice The fixed V2 lot rules plus one recovery buy after an actual sale. Uses the same Params and
///         registerKind launch path: dipBps is also the rise above the sale needed for recovery.
///         Stops and profits keep their priority, ordinary dip rungs keep their existing behavior, and
///         the recovery entry closes only after a real, minimum-sized buy succeeds.
/// @dev The rule and its storage, without the two convenience views: the upgradeable logic is this core, and has
///      no bytes to spare for them. `reentrySaleAt != 0` is "a recovery entry is open".
abstract contract HedgeFunV2CycleTreasuryCore is HedgeFunV2Treasury {
    /// @notice Oracle reference price of the qualifying live sale; zero after the entry is consumed/cancelled.
    uint256 public reentrySalePrice;
    /// @notice Time of that sale, whose recovery cooldown is 600 seconds.
    uint256 public reentrySaleAt;
    /// @notice Stock-feed report time at that sale; recovery needs a newer report.
    uint256 public reentryStockUpdatedAt;

    /// @dev Latest stop time for recovery; survives TP clearing the inherited dip gate, including dust TP.
    uint256 private _recoveryStopAt;
    /// @dev That stop's stock-report time; recovery needs a newer report even after a small or zero-sale TP.
    uint256 private _recoveryStopStockUpdatedAt;

    event RecoveryArmed(uint256 salePrice, uint256 saleAt, uint256 stockUpdatedAt);
    event RecoveryConsumed(bool boughtOnRecovery);
    event RecoveryCancelled();

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

    function _reentryPending() internal view returns (bool) {
        return reentrySaleAt != 0;
    }

    function _afterStockSale(uint256 p, uint256 sold, uint256 received) internal override {
        if (received == 0 || _ruleValue(sold, p) < _params.minLotUsdg) return;
        (bool live,) = _oracle.tryPrice();
        (bool valid,, uint256 updatedAt) = _oracle.lastPriceAt();
        // A scheduled-closure TP may use the bounded pool price. It must not create a live-feed recovery signal.
        if (!live || !valid) {
            bool pending = _reentryPending();
            _clearReentry();
            if (pending) emit RecoveryCancelled();
            return;
        }
        reentrySalePrice = p;
        reentrySaleAt = block.timestamp;
        reentryStockUpdatedAt = updatedAt;
        emit RecoveryArmed(p, block.timestamp, updatedAt);
    }

    function _afterStop() internal override {
        _recoveryStopAt = lastStopAt;
        _recoveryStopStockUpdatedAt = lastStopStockUpdatedAt;
    }

    function _recoveryDue(uint256 p, bool live) internal view returns (bool) {
        if (
            !live || !_reentryPending() || block.timestamp - reentrySaleAt < STOP_REENTRY_COOLDOWN
                || !HedgeFunMath.reached(p, reentrySalePrice, _params.dipBps)
        ) return false;
        // A sub-minimum later stop renews recovery's wait without refreshing its qualifying sale anchor.
        // A later TP may clear the inherited dip gate, but must not erase this recovery observation.
        if (_recoveryStopAt != 0 && block.timestamp - _recoveryStopAt < STOP_REENTRY_COOLDOWN) return false;
        (bool valid,, uint256 updatedAt) = _oracle.lastPriceAt();
        return
            valid && updatedAt > reentryStockUpdatedAt
                && updatedAt > _recoveryStopStockUpdatedAt;
    }

    function _canBuyAfterStop(uint256 p, bool live) internal view override returns (bool) {
        return super._canBuyAfterStop(p, live) || _recoveryDue(p, live);
    }

    function _dipReadyAfterDust(uint256 p, bool live) internal view override returns (bool) {
        // Both entries need the same cash/capacity gates. A recovery also always needs a live feed.
        if ((!live && _params.stopBps != 0)
            || HedgeFunMath.bps(reserveUsdg(), _params.lotBps) < _params.minLotUsdg || !_canAddLot()) return false;
        if (lastSalePrice != 0 && HedgeFunMath.fellTo(p, lastSalePrice, _params.dipBps)
            && _canBuyAfterStop(p, live)) return true;
        return _params.sellChunkUsdg >= _params.minLotUsdg && _recoveryDue(p, live);
    }

    function _executeBuy(uint256 p, bool live) internal override returns (Action action) {
        uint256 maxSpend;
        if (lastSalePrice != 0 && HedgeFunMath.fellTo(p, lastSalePrice, _params.dipBps)) {
            maxSpend = type(uint256).max;
            action = Action.BuyDip;
        } else {
            if (!_recoveryDue(p, live)) revert NotDue();
            // The existing cash fraction is also bounded by the listing's stock trade chunk for this new entry.
            maxSpend = _params.sellChunkUsdg;
            action = Action.BuyRecovery;
        }
        _buyWithReserve(p, maxSpend);
        bool pending = _reentryPending();
        _clearReentry();
        if (pending) emit RecoveryConsumed(action == Action.BuyRecovery);
    }

    function _clearReentry() private {
        delete reentrySalePrice;
        delete reentrySaleAt;
        delete reentryStockUpdatedAt;
        delete _recoveryStopAt;
        delete _recoveryStopStockUpdatedAt;
    }
}

/// @notice The fixed V2 lot rules plus one recovery buy after an actual sale, deployed directly (not upgradeable).
contract HedgeFunV2CycleTreasury is HedgeFunV2CycleTreasuryCore {
    constructor(address usdg_, address stock_, address v3Pool_, address oracle_, address token_,
        address poolManager_, address factory_, Params memory p)
        HedgeFunV2CycleTreasuryCore(usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p) {}

    /// @notice Whether one upward recovery entry remains open. Ordinary dip rungs do not require it.
    function reentryPending() public view returns (bool) {
        return _reentryPending();
    }

    /// @notice Reports the recovery price/time gate only. execute() also checks venue health, sale priority,
    ///         cash and lot capacity; keepers must simulate execute() before submitting a transaction.
    function recoveryDue() external view returns (bool) {
        (bool live, uint256 p) = _oracle.tryPrice();
        return _recoveryDue(p, live);
    }
}
