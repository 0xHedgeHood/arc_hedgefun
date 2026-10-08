// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HedgeFunHook} from "./HedgeFunHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HedgeFunMath} from "../libraries/HedgeFunMath.sol";

/// @notice V2 fees are stock on every side. A sell is taxed on the stock it receives and an exact-output buy on the
///         stock it pays, both in `afterSwap` as before. An exact-input buy is taxed on the stock it pays too, in
///         `beforeSwap`: the fee never exists in the strategy token, so nothing is held for anyone to convert and
///         the permissionless `sweep` settles every fee the pool has taken.
/// @dev `afterSwap` can only take from the unspecified currency, which for an exact-input buy is the token. Taking
///      the stock instead means taking it from the SPECIFIED amount, which only `beforeSwap` can do, and it does so
///      before the pool has moved: a swap that then stops at its price limit would have paid the rate on stock it
///      never traded. Such a buy is refused (`PartialFillRefused`) rather than overcharged; a buyer bounds the
///      price with a minimum output, as `HedgeFunV2TradeRouter` does. The treasury's own swaps are untaxed and may
///      stop early as before.
///
///      A graduated pool has no launch window (`registerGraduatedWithVault` refuses one), so its buy rate is the
///      flat tax and `beforeSwap` and `afterSwap` agree on the amount without carrying it between them: both read
///      only what registration fixed. Only `1 - rate` of the payment meets the pool, as on an exact-output buy at
///      the flat rate, so the pool's own LP fee is charged on that net amount too. The fee is
///      `floor(paid * rate)`: a payment under `10000 / rate` raw stock units pays none and is not held to a fill.
///
///      A pool registered without a vault keeps the base hook's rules, token-denominated burn included. The
///      address carries the base flags and BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA: 0x28CC.
contract HedgeFunV2Hook is HedgeFunHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    error PartialFillRefused();

    constructor(IPoolManager manager) HedgeFunHook(manager) {}

    function version() external pure returns (uint256) { return 3; }

    function _flags() internal pure override returns (uint160) {
        return FLAGS | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external override returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        PoolId id = key.toId();
        Pool storage p = _pool(id);
        if (sender == p.treasury || !_taxedOnInput(id, p, params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 paid = uint256(-params.amountSpecified);
        uint256 tax = HedgeFunMath.bps(paid, p.taxBps);
        if (tax == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        if (tax > uint128(type(int128).max)) revert BadConfig();
        // The claim joins every other pool's claims on this stock; `accruedStock` is what keeps it this pool's.
        poolManager.mint(address(this), Currency.wrap(p.stock).toId(), tax);
        p.accruedStock += uint128(tax);
        // As on an exact-output buy: `moved` is the stock that meets the pool, and the buyer pays `moved + tax`.
        emit Taxed(id, false, false, paid - tax, tax, p.taxBps);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(tax)), 0), 0);
    }

    /// @dev An exact-input buy on a vault pool was taxed before the swap; here it only has to have filled.
    function _tax(PoolId id, Pool storage p, address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta swapDelta)
        internal override returns (int128)
    {
        if (!_taxedOnInput(id, p, params)) return super._tax(id, p, sender, key, params, swapDelta);
        uint256 paid = uint256(-params.amountSpecified);
        uint256 tax = HedgeFunMath.bps(paid, p.taxBps);
        int128 swapped = params.zeroForOne ? swapDelta.amount0() : swapDelta.amount1();
        if (tax != 0 && uint256(uint128(-swapped)) != paid - tax) revert PartialFillRefused();
        return 0;
    }

    function _taxedOnInput(PoolId id, Pool storage p, SwapParams calldata params) private view returns (bool) {
        return liquidityVaultOf[id] != address(0) && params.amountSpecified < 0 && p.tokenIsCurrency0 != params.zeroForOne;
    }
}
