// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {V2LiquidityVault} from "./V2LiquidityVault.sol";

interface IV2FundAssetSource {
    function liquidityVault() external view returns (address);
    function poolKey() external view returns (Currency, Currency, uint24, int24, IHooks);
}

/// @notice Values only this fund's external stock and USDG, including its own locked LP stock leg.
/// @dev Each schema-2 treasury constructs and freezes its own reader. FUN has no external-asset value.
///      Quotes during a PoolManager unlock are refused: fees/principal can be temporarily unsettled.
contract V2FundAssetReader {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address public immutable treasury;
    IERC20 public immutable stock;
    IERC20 public immutable usdg;
    IPoolManager public immutable poolManager;
    address public immutable token;
    address public immutable factory;
    uint256 public immutable scale;

    error UnavailableAssets();

    constructor(address stock_, address usdg_, address manager_, address token_, address factory_, uint256 scale_) {
        treasury = msg.sender;
        stock = IERC20(stock_);
        usdg = IERC20(usdg_);
        poolManager = IPoolManager(manager_);
        token = token_;
        factory = factory_;
        scale = scale_;
    }

    /// @notice All stock quantities are token base units, cash is USDG base units. Pending vault fees are
    ///         already in vaultStock; treasuryStock already includes buyback and unbooked stock.
    function assetBalances() public view returns (
        uint256 treasuryStock, uint256 vaultStock, uint256 lpStock, uint256 uncollectedStockFee, uint256 cash
    ) {
        if (poolManager.isUnlocked()) revert UnavailableAssets();
        address vaultAddress = IV2FundAssetSource(treasury).liquidityVault();
        if (vaultAddress == address(0)) revert UnavailableAssets();
        V2LiquidityVault vault = V2LiquidityVault(vaultAddress);
        if (vault.factory() != factory || vault.treasury() != treasury || vault.stock() != address(stock)
            || vault.token() != token || address(vault.poolManager()) != address(poolManager) || !vault.seeded()) {
            revert UnavailableAssets();
        }
        PoolKey memory key = vault.poolKey();
        PoolKey memory expected;
        (expected.currency0, expected.currency1, expected.fee, expected.tickSpacing, expected.hooks) =
            IV2FundAssetSource(treasury).poolKey();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(expected.toId()) || key.tickSpacing <= 0
            || !((Currency.unwrap(key.currency0) == address(stock) && Currency.unwrap(key.currency1) == token)
                || (Currency.unwrap(key.currency1) == address(stock) && Currency.unwrap(key.currency0) == token))) {
            revert UnavailableAssets();
        }
        (lpStock, uncollectedStockFee) = _positionStock(key, vaultAddress,
            TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), bytes32(0));
        // Older immutable vaults have only the base position and no surplus getter.
        try vault.surplusLiquidity() returns (uint128 extraLiquidity) {
            if (extraLiquidity != 0) {
                (uint256 extraStock, uint256 extraFees) = _positionStock(key, vaultAddress,
                    vault.surplusTickLower(), vault.surplusTickUpper(), bytes32(uint256(1)));
                lpStock += extraStock;
                uncollectedStockFee += extraFees;
            }
        } catch {}
        treasuryStock = stock.balanceOf(treasury);
        vaultStock = stock.balanceOf(vaultAddress);
        cash = usdg.balanceOf(treasury);
    }

    /// @dev The caller must supply the same certified live V3 oracle price used by the engine context.
    ///      Overflow and malformed/unsettled LP snapshots revert rather than falling back to a smaller NAV.
    function totalAssets(uint256 price) external view returns (uint256 navUsdg) {
        if (price == 0) revert UnavailableAssets();
        (uint256 held, uint256 parked, uint256 principal, uint256 fees, uint256 cash) = assetBalances();
        navUsdg = Math.mulDiv(held + parked + principal + fees, price, scale) + cash;
    }

    function _positionStock(PoolKey memory key, address vault, int24 lower, int24 upper, bytes32 salt)
        private view returns (uint256 principal, uint256 fees)
    {
        PoolId id = key.toId();
        (uint128 liquidity, uint256 last0, uint256 last1) = poolManager.getPositionInfo(id, vault, lower, upper, salt);
        bool stockIs0 = Currency.unwrap(key.currency0) == address(stock);
        {
            (uint160 sqrtPrice,,,) = poolManager.getSlot0(id);
            if (sqrtPrice == 0 || liquidity == 0) revert UnavailableAssets();
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lower);
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upper);
            if (stockIs0 && sqrtPrice < sqrtUpper) {
                principal = SqrtPriceMath.getAmount0Delta(sqrtPrice > sqrtLower ? sqrtPrice : sqrtLower, sqrtUpper, liquidity, false);
            } else if (!stockIs0 && sqrtPrice > sqrtLower) {
                principal = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPrice < sqrtUpper ? sqrtPrice : sqrtUpper, liquidity, false);
            }
        }
        (uint256 inside0, uint256 inside1) = poolManager.getFeeGrowthInside(id, lower, upper);
        uint256 growth;
        unchecked { growth = stockIs0 ? inside0 - last0 : inside1 - last1; }
        fees = Math.mulDiv(growth, liquidity, uint256(1) << 128);
    }
}
