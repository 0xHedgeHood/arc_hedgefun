// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";

/// @dev Places remaining launch tokens on their single-sided side of spot in the SAME pool.
/// Both positions are owned by the non-withdrawable vault. No quote asset or price change is needed.
library V2SurplusLiquidity {
    error UnseedableSurplus();

    function plan(uint160 price, int24 spacing, bool tokenIs0, uint256 budget, uint128 baseLiquidity)
        internal pure returns (int24 lower, int24 upper, uint128 liquidity)
    {
        if (budget < 2) return (0, 0, 0);
        int24 tick = TickMath.getTickAtSqrtPrice(price);
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) --compressed;
        lower = tokenIs0 ? (compressed + 1) * spacing : TickMath.minUsableTick(spacing);
        upper = tokenIs0 ? TickMath.maxUsableTick(spacing) : compressed * spacing;
        if (lower >= upper) revert UnseedableSurplus();
        uint160 a = TickMath.getSqrtPriceAtTick(lower);
        uint160 b = TickMath.getSqrtPriceAtTick(upper);
        uint256 l = tokenIs0
            ? Math.mulDiv(budget - 1, Math.mulDiv(a, b, 1 << 96), b - a)
            : Math.mulDiv(budget - 1, 1 << 96, b - a);
        // The two positions share one extreme tick. Enforce its aggregate gross-liquidity cap.
        if (l > uint256(Pool.tickSpacingToMaxLiquidityPerTick(spacing)) - baseLiquidity)
            revert UnseedableSurplus();
        liquidity = uint128(l);
    }
}
