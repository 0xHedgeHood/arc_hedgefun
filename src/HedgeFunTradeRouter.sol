// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HedgeFunFactory} from "./HedgeFunFactory.sol";
import {IHedgeFunTreasury} from "./interfaces/IHedgeFunTreasury.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3.sol";


/// Buy or sell a strategy token with USDG, in one transaction.
///
/// A strategy token's only pool is `<token>/<stock>`: it is quoted in the stock, taxed in the stock, and its treasury
/// is paid in the stock. That is the design, and it means a buyer needs the stock first. This is the two hops a front
/// end would otherwise make a user sign separately -- USDG -> stock in a Uniswap V3 pool, stock -> token in the
/// strategy's V4 pool, and the reverse -- and nothing else: periphery, no owner, holds nothing between calls, not known
/// to the factory. If it is ever wrong, deploy another.
///
/// It gives nobody a better deal than the pools do. Both hops are exact-input (the strategy hook accepts exact output
/// only for a buy at the flat rate, see `HedgeFunHook`), the buy tax burns and the sell tax reaches the treasury
/// exactly as on a direct swap, and the opening sell spike applies to a sale routed through here like any other.
/// The caller's one protection is `minOut` on
/// what finally arrives. Quote it by `eth_call`ing `buy` / `sell` themselves from the user's address (there is no V4
/// quoter to ask), because the token pool opens single-sided and moves a long way on size.
/// In the first seconds of a launch a buy pays the launch-window rate (`hook.buyRateBps(poolId)`, up to 99%): quote at
/// execution time and show that rate, or `minOut` protects a stale number.
///
/// The caller chooses WHICH V3 pool carries the stock hop, because the listing's pool is chosen for how well it tracks
/// Chainlink, not for depth. Any fee tier will do, but it must be the V3 factory's own pool for the pair, or a
/// contract posing as a pool could ask the callback for whatever the caller had approved.

contract HedgeFunTradeRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    HedgeFunFactory public immutable factory;
    IPoolManager public immutable poolManager;
    IERC20 public immutable usdg;

    address private _v3Pool;      // the one pool allowed to call the V3 callback, and only while we are inside its swap

    event Bought(uint256 indexed id, address indexed who, uint256 usdgIn, uint256 stockThrough, uint256 tokensOut);
    event Sold(uint256 indexed id, address indexed who, uint256 tokensIn, uint256 stockThrough, uint256 usdgOut);

    error NotPoolManager();
    error NotThePool();
    error WrongPool();
    error TooLittle(uint256 got);
    error Expired();
    error PartialFill(uint256 spent);

    constructor(HedgeFunFactory factory_) { factory = factory_; poolManager = factory_.poolManager(); usdg = IERC20(factory_.usdg()); }

    /// @notice USDG in, strategy tokens out. Approve this router for `usdgIn` first.
    /// @param id the strategy, as `factory.strategies(id)`
    /// @param stockPool the V3 `<stock>/USDG` pool to route the first hop through (any fee tier)
    function buy(uint256 id, address stockPool, uint256 usdgIn, uint256 minTokensOut, uint256 deadline) external nonReentrant returns (uint256 tokensOut) {
        if (block.timestamp > deadline) revert Expired();
        (address token, address treasury,, address stock,) = factory.strategies(id);
        _checkPool(stockPool, stock);
        usdg.safeTransferFrom(msg.sender, address(this), usdgIn);
        uint256 stockGot = _v3(stockPool, address(usdg), usdgIn);
        tokensOut = _v4(_key(treasury), stock, token, stockGot, msg.sender, msg.sender);
        if (tokensOut < minTokensOut) revert TooLittle(tokensOut);
        emit Bought(id, msg.sender, usdgIn, stockGot, tokensOut);
    }

    /// @notice strategy tokens in, USDG out. Approve this router for `tokensIn` first. The sell tax is taken in the
    ///         stock by the strategy's hook, inside the first hop, as on any sale.
    function sell(uint256 id, address stockPool, uint256 tokensIn, uint256 minUsdgOut, uint256 deadline) external nonReentrant returns (uint256 usdgOut) {
        if (block.timestamp > deadline) revert Expired();
        (address token, address treasury,, address stock,) = factory.strategies(id);
        _checkPool(stockPool, stock);
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);
        uint256 stockGot = _v4(_key(treasury), token, stock, tokensIn, address(this), msg.sender);
        usdgOut = _v3(stockPool, stock, stockGot);
        if (usdgOut < minUsdgOut) revert TooLittle(usdgOut);
        usdg.safeTransfer(msg.sender, usdgOut);
        emit Sold(id, msg.sender, tokensIn, stockGot, usdgOut);
    }

    /// @dev the key the strategy was BORN with, read from its treasury, where the factory wired it once. The
    ///      factory's current defaults apply to future launches only, so a key rebuilt from them would miss every
    ///      strategy launched before a `setDefaults` that changed the fee or tick spacing.
    function _key(address treasury) internal view returns (PoolKey memory key) {
        (key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks) = IHedgeFunTreasury(treasury).poolKey();
    }

    function _checkPool(address pool, address stock) internal view {
        if (factory.v3Factory().getPool(address(usdg), stock, IUniswapV3Pool(pool).fee()) != pool) revert WrongPool();
    }

    // ------------------------------------------------------------------------------------------------ the V3 hop
    function _v3(address pool, address tokenIn, uint256 amountIn) internal returns (uint256 out) {
        bool zeroForOne = IUniswapV3Pool(pool).token0() == tokenIn;
        _v3Pool = pool;
        (int256 a0, int256 a1) = IUniswapV3Pool(pool).swap(address(this), zeroForOne, int256(amountIn),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1, abi.encode(tokenIn));
        _v3Pool = address(0);
        // A V3 swap that runs out of liquidity stops early and asks the callback for LESS than `amountIn` -- silently.
        // The whole `amountIn` is already here (pulled from the buyer, or just bought from the V4 pool for a seller),
        // and nothing else in this contract is balance-based, so an unspent part would stay here for good. `minOut`
        // does not catch it when the quote came from an `eth_call` of this very function. All or nothing: the caller
        // picks a fee tier that can take the trade.
        uint256 spent = uint256(zeroForOne ? a0 : a1);
        if (spent != amountIn) revert PartialFill(spent);
        out = uint256(-(zeroForOne ? a1 : a0));
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != _v3Pool) revert NotThePool();
        IERC20(abi.decode(data, (address))).safeTransfer(msg.sender, uint256(amount0Delta > 0 ? amount0Delta : amount1Delta));
    }

    // ------------------------------------------------------------------------------------------------ the V4 hop
    /// @param to who receives the output  @param refundTo who gets back input the pool could not absorb
    function _v4(PoolKey memory key, address tokenIn, address tokenOut, uint256 amountIn, address to, address refundTo) internal returns (uint256) {
        return abi.decode(poolManager.unlock(abi.encode(key, tokenIn, tokenOut, amountIn, to, refundTo)), (uint256));
    }

    /// @dev the manager calls back whoever unlocked it, so this only ever runs inside `_v4` above
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, address tokenIn, address tokenOut, uint256 amountIn, address to, address refundTo) =
            abi.decode(data, (PoolKey, address, address, uint256, address, address));
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
        BalanceDelta delta = poolManager.swap(key, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}), "");
        (int128 dIn, int128 dOut) = zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        uint256 owedIn = uint256(uint128(-dIn));
        poolManager.sync(Currency.wrap(tokenIn));
        IERC20(tokenIn).safeTransfer(address(poolManager), owedIn);
        poolManager.settle();
        uint256 out = uint256(uint128(dOut));
        poolManager.take(Currency.wrap(tokenOut), to, out);
        // a swap that ran out of pool consumed less than it was given: the rest goes back to whoever this is for
        if (owedIn < amountIn) IERC20(tokenIn).safeTransfer(refundTo, amountIn - owedIn);
        return abi.encode(out);
    }
}
