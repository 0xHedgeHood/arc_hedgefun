// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {V2LiquidityVault} from "../../src/v2/V2LiquidityVault.sol";
import {HedgeFunV2AssetPercentEngineTreasury} from "../../src/v2/HedgeFunV2AssetPercentEngineTreasury.sol";

/// @dev Independent test ghost reads the actual position and balances, never the reader/riskLimits result.
library FundAssetMath {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function nav(HedgeFunV2AssetPercentEngineTreasury t, IERC20 stock, uint256 price, uint256 scale)
        internal view returns (uint256)
    {
        V2LiquidityVault vault = V2LiquidityVault(t.liquidityVault());
        PoolKey memory key = vault.poolKey();
        uint256 owned = _ownedStock(vault, address(stock), TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing), bytes32(0));
        if (vault.surplusLiquidity() != 0)
            owned += _ownedStock(vault, address(stock), vault.surplusTickLower(), vault.surplusTickUpper(), bytes32(uint256(1)));
        return Math.mulDiv(stock.balanceOf(address(t)) + stock.balanceOf(address(vault)) + owned, price, scale)
            + t.reserveUsdg();
    }
    struct Position {
        int24 lower;
        int24 upper;
        uint128 liquidity;
        uint256 last0;
        uint256 last1;
        uint160 sqrtPrice;
    }
    function _ownedStock(V2LiquidityVault vault, address stock, int24 lower, int24 upper, bytes32 salt) private view returns (uint256) {
        IPoolManager manager = vault.poolManager();
        PoolKey memory key = vault.poolKey();
        PoolId id = key.toId();
        Position memory p;
        p.lower = lower;
        p.upper = upper;
        (p.liquidity, p.last0, p.last1) = manager.getPositionInfo(id, address(vault), p.lower, p.upper, salt);
        (p.sqrtPrice,,,) = manager.getSlot0(id);
        uint256 principal;
        bool first = Currency.unwrap(key.currency0) == stock;
        {
            uint160 a = TickMath.getSqrtPriceAtTick(p.lower);
            uint160 b = TickMath.getSqrtPriceAtTick(p.upper);
            uint160 bounded = p.sqrtPrice < a ? a : p.sqrtPrice > b ? b : p.sqrtPrice;
            principal = first ? SqrtPriceMath.getAmount0Delta(bounded, b, p.liquidity, false)
                : SqrtPriceMath.getAmount1Delta(a, bounded, p.liquidity, false);
        }
        (uint256 fee0, uint256 fee1) = manager.getFeeGrowthInside(id, p.lower, p.upper);
        uint256 delta;
        unchecked { delta = first ? fee0 - p.last0 : fee1 - p.last1; }
        return principal + Math.mulDiv(delta, p.liquidity, uint256(1) << 128);
    }

}
