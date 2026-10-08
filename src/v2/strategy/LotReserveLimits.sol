// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Lifetime cash accounting; no transfers, arbitrary targets or admin methods.
library LotReserveLimits {
    struct State {
        uint256 packedConfig;
        uint256 dipBuys;
        bool basisFrozen;
        uint256 graduationStock;
        uint256 basisUsdg;
        uint256 dipSpentUsdg;
    }

    /// @dev Freeze once, including a rounded zero. Donations, sales and market moves never replenish it.
    function freeze(State storage s, uint256 price, uint256 scale) internal {
        if (!s.basisFrozen) {
            s.basisFrozen = true;
            s.basisUsdg = Math.mulDiv(s.graduationStock, price, scale);
        }
    }

    function spendLimit(State storage s, uint256 cash) internal view returns (uint256 limit) {
        if (!s.basisFrozen || (uint16(s.packedConfig >> 32) != 0 && s.dipBuys >= uint16(s.packedConfig >> 32))) {
            return 0;
        }
        uint256 floor = Math.mulDiv(s.basisUsdg, uint16(s.packedConfig), 10_000, Math.Rounding.Ceil);
        limit = cash > floor ? cash - floor : 0;
        if (uint16(s.packedConfig >> 16) != 0) {
            uint256 budget = Math.mulDiv(s.basisUsdg, uint16(s.packedConfig >> 16), 10_000);
            uint256 left = budget > s.dipSpentUsdg ? budget - s.dipSpentUsdg : 0;
            limit = Math.min(limit, left);
        }
    }

    function record(State storage s, uint256 spent) internal {
        s.dipSpentUsdg += spent;
        ++s.dipBuys;
    }
}
