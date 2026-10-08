// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {LotReserveLimits} from "./LotReserveLimits.sol";
import {HedgeFunTreasuryBase} from "../../HedgeFunTreasuryBase.sol";
import {HedgeFunMath} from "../../libraries/HedgeFunMath.sol";

/// @notice V2 priority selection, isolated to keep the new engine deployable under EIP-170.
/// @dev Storage-only linked code; rules match HedgeFunV2Treasury's selection exactly.
library LotReserveScheduler {
    function spendLimit(LotReserveLimits.State storage s, uint256 cash) public view returns (uint256) {
        return LotReserveLimits.spendLimit(s, cash);
    }

    function dueStop(HedgeFunTreasuryBase.Lot[] storage lots, uint256 p, uint16 stopBps)
        public
        view
        returns (bool found, uint256 id)
    {
        uint256 highestCost;
        uint256 largestQty;
        for (uint256 i; i < lots.length; ++i) {
            HedgeFunTreasuryBase.Lot storage L = lots[i];
            if (
                HedgeFunMath.fellTo(p, L.cost, stopBps)
                    && (!found || L.cost > highestCost || (L.cost == highestCost && L.qty > largestQty))
            ) {
                (found, id, highestCost, largestQty) = (true, i, L.cost, L.qty);
            }
        }
    }

    function dueProfit(HedgeFunTreasuryBase.Lot[] storage lots, uint256 p, uint32 tp1Bps, uint32 tp2Bps)
        public
        view
        returns (bool found, uint256 id)
    {
        // At one price, close an already-half-sold lot before starting another TP1.
        bool tp2;
        uint256 selectedCost;
        uint256 selectedQty;
        for (uint256 i; i < lots.length; ++i) {
            HedgeFunTreasuryBase.Lot storage L = lots[i];
            bool second = tp2Bps == 0 || L.half;
            uint256 trigger = second && tp2Bps != 0 ? tp2Bps : tp1Bps;
            if (
                HedgeFunMath.reached(p, L.cost, trigger)
                    && (!found
                        || (second && !tp2)
                        || (second == tp2
                            && (L.cost < selectedCost || (L.cost == selectedCost && L.qty > selectedQty))))
            ) {
                (found, tp2, id, selectedCost, selectedQty) = (true, second, i, L.cost, L.qty);
            }
        }
    }

    event LotsCoalesced(uint256 indexed kept, uint256 indexed removed, uint256 qty, uint256 cost);

    function coalesce(HedgeFunTreasuryBase.Lot[] storage lots) public returns (bool) {
        for (uint256 i; i < lots.length; ++i) {
            HedgeFunTreasuryBase.Lot storage A = lots[i];
            for (uint256 j = i + 1; j < lots.length; ++j) {
                HedgeFunTreasuryBase.Lot storage B = lots[j];
                if (A.cost != B.cost || A.half != B.half || (A.tp1Left == 0) != (B.tp1Left == 0)) continue;
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
}
