// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HedgeFunV2Treasury} from "./HedgeFunV2Treasury.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3.sol";
import {V2CreatorParams} from "./strategy/V2CreatorParams.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunMath} from "../libraries/HedgeFunMath.sol";

/// @notice Ordinary V2 whose creator chooses TP, dip and stop rungs independently of execution costs.
/// @dev A price trigger does not guarantee a profitable fill. Health, slippage and inventory accounting still apply.
///      A new registry defaults to this core; an immutable old registry can append it only for future launches.
contract HedgeFunV2AllInTreasury is HedgeFunV2Treasury {
    using SafeERC20 for IERC20;

    event DustCleared(uint256 indexed id, uint256 stockAmount);
    event RemainderReclassified(uint256 indexed id, uint256 stockAmount);
    bool private _noEconomicSale;

    constructor(
        address usdg_,
        address stock_,
        address v3Pool_,
        address oracle_,
        address token_,
        address poolManager_,
        address factory_,
        Params memory p
    ) HedgeFunV2Treasury(usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, _checked(p, v3Pool_)) {
        // The adapter bypasses only the parent's legacy economic floors. Freeze the creator's original rule.
        _params = p;
    }

    /// @dev Preserve every inherited non-floor check. The old parent requires a double slippage/fee rung, so
    ///      pass it a deep copy with those rungs temporarily raised and its stop disabled, then restore the original
    ///      parameters. Validate all original rung bounds first, including the original TP2 relationship.
    function _checked(Params memory p, address v3Pool_) private view returns (Params memory legacy) {
        uint256 fee = uint256(IUniswapV3Pool(v3Pool_).fee()) / 100;
        V2CreatorParams.validate(p.tp1Bps, p.tp2Bps, p.dipBps, p.stopBps);
        legacy = abi.decode(abi.encode(p), (Params));
        uint32 floor = uint32(2 * (uint256(p.maxSlippageBps) + fee));
        if (legacy.tp1Bps < floor) legacy.tp1Bps = floor;
        if (legacy.dipBps < floor) legacy.dipBps = uint16(floor);
        if (legacy.tp2Bps != 0 && legacy.tp2Bps <= legacy.tp1Bps) legacy.tp2Bps = legacy.tp1Bps + 1;
        legacy.stopBps = 0;
    }

    /// @dev Same bounded sizing/TP1/shrink algorithm as the legacy core. A keeper reward requires an actual
    ///      monetary fill. Non-tradable principal returns to unbooked stock, never the income-only buyback budget.
    function _takeProfit(uint256 id) internal virtual override {
        (bool ok, uint256 p) = health();
        if (!ok) revert Unhealthy();
        _book();
        Lot storage L = lots[id];
        uint256 q = _ruleStockFor(_params.sellChunkUsdg, p);
        uint256 left;
        if (_params.tp2Bps != 0 && !L.half) {
            if (!HedgeFunMath.reached(p, L.cost, _params.tp1Bps)) revert NotDue();
            left = L.tp1Left;
            if (left == 0) left = L.qty / 2;
            // Preserve the zero-fill TP1 stage transition, without moving any stock or paying a reward.
            if (left == 0) { L.half = true; _noEconomicSale = true; return; }
            if (q > left) q = left;
        } else {
            if (!HedgeFunMath.reached(p, L.cost, _params.tp2Bps != 0 ? _params.tp2Bps : _params.tp1Bps)) revert NotDue();
            if (q > L.qty) q = L.qty;
        }
        // A zero-USDG ENTIRE lot cannot trade or earn a monetary reward. Reclassify it without declaring profit
        // or advancing the sale/price references, so 128 different-cost dust tails cannot permanently block buys.
        if (_ruleValue(L.qty, p) == 0) {
            uint256 dust = L.qty;
            _shrink(id, dust);
            _releasedDustStock += dust;
            _noEconomicSale = true;
            emit DustCleared(id, dust);
            return;
        }
        if (q == 0) revert NotDue();
        uint256 cost = L.cost;
        uint256 principal = Math.mulDiv(q, cost, p);
        // This selected quantity has value, but its cost-basis principal rounds below one raw USDG. No venue
        // trade can return monetary principal. Keep every untraded share, without manufacturing a keeper profit.
        if (_ruleValue(principal, p) == 0) {
            if (left != 0) { L.tp1Left = left - q; if (left == q) L.half = true; }
            _shrink(id, q);
            _releasedDustStock += q;
            _noEconomicSale = true;
            emit RemainderReclassified(id, q);
            return;
        }
        _notePrice(p); _noteTokenSpot();
        uint256 got;
        _poolOnlyPace();
        uint256 sold;
        (sold, got) = _swapStock(false, principal, p);
        if (sold == 0 || got == 0) revert NotDue();
        if (sold != principal) { principal = sold; q = Math.mulDiv(sold, p, cost); }
        if (q == 0) revert NotDue();
        uint256 profit = q - principal;
        uint256 bounty = HedgeFunMath.bps(profit, _params.bountyBps);
        if (left != 0) { L.tp1Left = left - q; if (left == q) L.half = true; }
        _shrink(id, q);
        buybackStock += profit - bounty;
        lastSalePrice = p;
        emit ProfitTaken(q, cost, p, got, profit - bounty);
        if (bounty != 0) _stock.safeTransfer(msg.sender, bounty);
    }

    /// @dev execute calls this exactly once after TP or a dip buy. Dust/stage-only progress is not a sale and
    ///      cannot lift a stop's cooldown/report gate. Consume the flag before returning so later actions are normal.
    function _clearStopGate() internal override {
        bool skip = _noEconomicSale;
        _noEconomicSale = false;
        if (!skip) super._clearStopGate();
    }
}
