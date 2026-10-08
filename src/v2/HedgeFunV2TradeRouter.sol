// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HedgeFunFactory} from "../HedgeFunFactory.sol";
import {IHedgeFunTreasury} from "../interfaces/IHedgeFunTreasury.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3.sol";

interface ICurveRegistry {
    function curves(uint256 id) external view returns (address);
}

interface ICurveTrade {
    function status() external view returns (uint8);
    function buy(uint256 maxStockIn, uint256 minTokensOut, address recipient, uint256 deadline)
        external returns (uint256 stockSpent, uint256 tokensOut);
    function sell(uint256 tokenIn, uint256 minStockOut, address recipient, uint256 deadline)
        external returns (uint256 stockOut);
}

/// @notice Same-chain ERC20 entry/exit for a stock-denominated curve and its graduated V4 pool.
/// @dev Each route uses at most three exact-input canonical V3 pools. Empty paths trade stock directly.
///      Wrapped-native tokens work like any other ERC20; this router never accepts native currency.
///      No owner, arbitrary call target, custody, or persistent token approvals. Curve buys
///      deliver directly to the final recipient so opening-tax exemptions cannot attach to this router.
contract HedgeFunV2TradeRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_HOPS = 3;
    uint8 public constant ACTIVE = 0;
    uint8 public constant GRADUATED = 2;
    HedgeFunFactory public immutable factory;
    IPoolManager public immutable poolManager;

    struct Hop { address pool; address tokenOut; }
    struct TradeParams {
        uint256 id;
        address asset;          // buy: payment ERC20; sell: desired output ERC20
        uint256 amountIn;       // buy: payment asset; sell: strategy tokens
        uint256 minStockReceived; // buy-only: minimum stock produced by the payment route, including any refund
        uint256 minFinalOut;    // absolute minimum received after all swaps and taxes, never prorated
        uint256 deadline;
        uint8 expectedStage;    // checked at entry; an Active buy may atomically graduate
        bool allowPartialFill; // allows stock refund on a curve buy or strategy-token refund on a sell; a V4 buy fills or reverts
    }
    struct Strategy { address token; address treasury; address stock; address curve; }
    struct V3Callback { address pool; address token; uint256 maximum; bool zeroForOne; }
    V3Callback private _v3Callback;
    uint256 private _v3Paid;
    bytes32 private _unlockHash;

    event Bought(uint256 indexed id, address indexed buyer, address indexed paymentAsset,
        address recipient, uint256 paymentIn, uint256 tokensOut, uint256 stockRefund);
    event Sold(uint256 indexed id, address indexed seller, address indexed outputAsset,
        uint256 tokensSpent, uint256 outputAmount, uint256 tokenRefund);

    error BadFactory();
    error BadPath();
    error WrongPool();
    error NotThePool();
    error NotPoolManager();
    error BadCallback();
    error StageChanged(uint8 actual);
    error TooLittleStock(uint256 got);
    error TooLittle(uint256 got);
    error Expired();
    error PartialFill(uint256 spent);
    error BadAmount();
    error TransferMismatch();

    constructor(HedgeFunFactory factory_) {
        if (address(factory_).code.length == 0) revert BadFactory();
        factory = factory_;
        poolManager = factory_.poolManager();
        if (address(poolManager).code.length == 0 || address(factory_.v3Factory()).code.length == 0) revert BadFactory();
    }

    /// @notice Buy with any normal ERC20 that has the supplied V3 path to stock; approve amountIn first.
    /// @dev Partial fills refund STOCK, not the original payment asset. They require explicit opt-in even
    ///      for tiny integer-rounding refunds. minFinalOut remains the full absolute promised token amount.
    ///      minStockReceived separately protects the whole payment-to-stock conversion: at a capped fill,
    ///      a worse V3 price may reduce the stock refund without reducing the strategy-token output.
    function buy(TradeParams calldata p, Hop[] calldata path)
        external nonReentrant returns (uint256 tokensOut, uint256 stockRefund)
    {
        return _buy(p, path, msg.sender);
    }

    /// @notice Buy for a designated final recipient. The payer cannot claim that recipient's
    ///         exemption while holding the tokens in this router: delivery is direct and checked.
    /// @dev Used by the native wrapper to identify its caller. Anyone may fund a recipient's buy.
    function buyFor(TradeParams calldata p, Hop[] calldata path, address recipient)
        external nonReentrant returns (uint256 tokensOut, uint256 stockRefund)
    {
        return _buy(p, path, recipient);
    }

    function _buy(TradeParams calldata p, Hop[] calldata path, address recipient)
        private returns (uint256 tokensOut, uint256 stockRefund)
    {
        if (recipient == address(0) || recipient == address(this)) revert BadPath();
        Strategy memory s = _strategy(p);
        _checkPath(path, p.asset, s.stock, s.token);
        _pull(p.asset, p.amountIn);
        uint256 stockGot = _route(path, p.asset, p.amountIn);
        if (stockGot < p.minStockReceived) revert TooLittleStock(stockGot);
        uint256 spent;
        if (p.expectedStage == ACTIVE) {
            (spent, tokensOut) = _curveBuy(s, stockGot, p.deadline, recipient);
        } else {
            (spent, tokensOut) = _v4(s, s.stock, s.token, stockGot);
        }
        stockRefund = stockGot - spent;
        _checkFill(p, spent, stockRefund, tokensOut);
        if (p.expectedStage == GRADUATED) _send(s.token, recipient, tokensOut);
        if (stockRefund != 0) _send(s.stock, msg.sender, stockRefund);
        emit Bought(p.id, msg.sender, p.asset, recipient, p.amountIn, tokensOut, stockRefund);
    }

    /// @notice Sell strategy tokens for any normal ERC20 reachable from stock over the supplied V3 path.
    /// @dev A partial graduated V4 sale refunds strategy tokens; V3 hops always require a full fill.
    ///      minStockReceived is a buy-only constraint and is ignored here; minFinalOut protects the sale.
    function sell(TradeParams calldata p, Hop[] calldata path)
        external nonReentrant returns (uint256 outputAmount, uint256 tokenRefund)
    {
        Strategy memory s = _strategy(p);
        _checkPath(path, s.stock, p.asset, s.token);
        _pull(s.token, p.amountIn);
        uint256 stockGot;
        uint256 spent;
        if (p.expectedStage == ACTIVE) {
            spent = p.amountIn;
            stockGot = _curveSell(s, p.amountIn, p.deadline);
        } else {
            (spent, stockGot) = _v4(s, s.token, s.stock, p.amountIn);
        }
        tokenRefund = p.amountIn - spent;
        outputAmount = _route(path, s.stock, stockGot);
        _checkFill(p, spent, tokenRefund, outputAmount);
        _send(p.asset, msg.sender, outputAmount);
        if (tokenRefund != 0) _send(s.token, msg.sender, tokenRefund);
        emit Sold(p.id, msg.sender, p.asset, spent, outputAmount, tokenRefund);
    }

    function _strategy(TradeParams calldata p) private view returns (Strategy memory s) {
        if (block.timestamp > p.deadline) revert Expired();
        if (p.amountIn == 0 || p.amountIn > uint256(type(int256).max)) revert BadAmount();
        (s.token, s.treasury,, s.stock,) = factory.strategies(p.id);
        s.curve = ICurveRegistry(address(factory)).curves(p.id);
        uint8 actual = ICurveTrade(s.curve).status();
        if ((p.expectedStage != ACTIVE && p.expectedStage != GRADUATED) || p.expectedStage != actual) {
            revert StageChanged(actual);
        }
    }

    function _checkFill(TradeParams calldata p, uint256 spent, uint256 refund, uint256 out) private pure {
        if (!p.allowPartialFill && refund != 0) revert PartialFill(spent);
        if (out == 0 || out < p.minFinalOut) revert TooLittle(out);
    }

    function _checkPath(Hop[] calldata path, address start, address end, address strategyToken) private view {
        if (start == address(0) || end == address(0) || start == strategyToken || end == strategyToken
            || path.length > MAX_HOPS) revert BadPath();
        address current = start;
        for (uint256 i; i < path.length; ++i) {
            Hop calldata h = path[i];
            if (h.tokenOut == address(0) || h.tokenOut == start || h.tokenOut == strategyToken) revert BadPath();
            for (uint256 j; j < i; ++j) if (path[j].tokenOut == h.tokenOut) revert BadPath();
            IUniswapV3Pool pool = IUniswapV3Pool(h.pool);
            address t0 = pool.token0();
            address t1 = pool.token1();
            if (!((t0 == current && t1 == h.tokenOut) || (t1 == current && t0 == h.tokenOut))
                || factory.v3Factory().getPool(current, h.tokenOut, pool.fee()) != h.pool) revert WrongPool();
            current = h.tokenOut;
        }
        if (current != end) revert BadPath();
    }

    function _route(Hop[] calldata path, address input, uint256 amount) private returns (uint256) {
        for (uint256 i; i < path.length; ++i) {
            amount = _v3(path[i].pool, input, path[i].tokenOut, amount);
            input = path[i].tokenOut;
        }
        return amount;
    }

    function _curveBuy(Strategy memory s, uint256 amount, uint256 deadline, address recipient)
        private returns (uint256 spent, uint256 out)
    {
        uint256 beforeIn = IERC20(s.stock).balanceOf(address(this));
        uint256 beforeOut = IERC20(s.token).balanceOf(recipient);
        uint256 routerTokens = IERC20(s.token).balanceOf(address(this));
        IERC20(s.stock).forceApprove(s.curve, amount);
        (spent, out) = ICurveTrade(s.curve).buy(amount, 0, recipient, deadline);
        IERC20(s.stock).forceApprove(s.curve, 0);
        if (spent > amount) revert BadCallback();
        if (IERC20(s.stock).balanceOf(address(this)) + spent != beforeIn
            || IERC20(s.token).balanceOf(recipient) != beforeOut + out
            || IERC20(s.token).balanceOf(address(this)) != routerTokens) revert TransferMismatch();
    }

    function _curveSell(Strategy memory s, uint256 amount, uint256 deadline) private returns (uint256 out) {
        uint256 beforeIn = IERC20(s.token).balanceOf(address(this));
        uint256 beforeOut = IERC20(s.stock).balanceOf(address(this));
        IERC20(s.token).forceApprove(s.curve, amount);
        out = ICurveTrade(s.curve).sell(amount, 0, address(this), deadline);
        IERC20(s.token).forceApprove(s.curve, 0);
        _checkDeltas(s.token, s.stock, beforeIn, beforeOut, amount, out);
    }

    function _v3(address pool, address input, address output, uint256 amount) private returns (uint256 out) {
        if (amount == 0 || amount > uint256(type(int256).max)) revert BadAmount();
        uint256 beforeIn = IERC20(input).balanceOf(address(this));
        uint256 beforeOut = IERC20(output).balanceOf(address(this));
        bool zeroForOne = IUniswapV3Pool(pool).token0() == input;
        _v3Callback = V3Callback(pool, input, amount, zeroForOne);
        _v3Paid = 0;
        (int256 a0, int256 a1) = IUniswapV3Pool(pool).swap(address(this), zeroForOne, int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1, "");
        delete _v3Callback;
        (int256 deltaIn, int256 deltaOut) = zeroForOne ? (a0, a1) : (a1, a0);
        if (deltaIn < 0 || deltaOut >= 0 || deltaOut == type(int256).min || uint256(deltaIn) != _v3Paid) revert BadCallback();
        if (uint256(deltaIn) != amount) revert PartialFill(uint256(deltaIn));
        out = uint256(-deltaOut);
        _v3Paid = 0;
        _checkDeltas(input, output, beforeIn, beforeOut, amount, out);
    }

    /// @dev Pool, input token, direction and maximum debt come from our own pending swap, never callback data.
    ///      Disarm before token transfer: even a token callback cannot trigger a second payment.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        V3Callback memory c = _v3Callback;
        if (msg.sender != c.pool || c.pool == address(0)) revert NotThePool();
        (int256 debt, int256 output) = c.zeroForOne ? (amount0Delta, amount1Delta) : (amount1Delta, amount0Delta);
        if (debt <= 0 || output > 0 || uint256(debt) > c.maximum) revert BadCallback();
        delete _v3Callback;
        _v3Paid = uint256(debt);
        _send(c.token, msg.sender, uint256(debt));
    }

    function _v4(Strategy memory s, address input, address output, uint256 amount) private returns (uint256 spent, uint256 out) {
        if (amount == 0 || amount > uint256(type(int256).max)) revert BadAmount();
        PoolKey memory key;
        (key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks) = IHedgeFunTreasury(s.treasury).poolKey();
        address t0 = Currency.unwrap(key.currency0);
        address t1 = Currency.unwrap(key.currency1);
        if (!((t0 == input && t1 == output) || (t1 == input && t0 == output))) revert WrongPool();
        uint256 beforeIn = IERC20(input).balanceOf(address(this));
        uint256 beforeOut = IERC20(output).balanceOf(address(this));
        bytes memory data = abi.encode(key, input, output, amount);
        _unlockHash = keccak256(data);
        (spent, out) = abi.decode(poolManager.unlock(data), (uint256, uint256));
        _unlockHash = bytes32(0);
        _checkDeltas(input, output, beforeIn, beforeOut, spent, out);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager) || _unlockHash == bytes32(0) || keccak256(data) != _unlockHash) revert NotPoolManager();
        _unlockHash = bytes32(0);
        (PoolKey memory key, address input, address output, uint256 amount) = abi.decode(data, (PoolKey, address, address, uint256));
        bool zeroForOne = Currency.unwrap(key.currency0) == input;
        BalanceDelta delta = poolManager.swap(key, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}), "");
        (int128 dIn, int128 dOut) = zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        if (dIn > 0 || dOut < 0) revert BadCallback();
        uint256 spent = uint256(-int256(dIn));
        if (spent > amount) revert BadCallback();
        poolManager.sync(Currency.wrap(input));
        _send(input, address(poolManager), spent);
        if (poolManager.settle() != spent) revert TransferMismatch();
        poolManager.take(Currency.wrap(output), address(this), uint256(uint128(dOut)));
        return abi.encode(spent, uint256(uint128(dOut)));
    }

    function _checkDeltas(address input, address output, uint256 beforeIn, uint256 beforeOut, uint256 spent, uint256 out) private view {
        if (IERC20(input).balanceOf(address(this)) + spent != beforeIn
            || IERC20(output).balanceOf(address(this)) != beforeOut + out) revert TransferMismatch();
    }

    function _pull(address asset, uint256 amount) private {
        uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
        uint256 beforeSender = IERC20(asset).balanceOf(msg.sender);
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(asset).balanceOf(address(this)) != beforeBalance + amount
            || IERC20(asset).balanceOf(msg.sender) + amount != beforeSender) revert TransferMismatch();
    }

    function _send(address asset, address to, uint256 amount) private {
        uint256 beforeHere = IERC20(asset).balanceOf(address(this));
        uint256 beforeThere = IERC20(asset).balanceOf(to);
        IERC20(asset).safeTransfer(to, amount);
        if (IERC20(asset).balanceOf(address(this)) + amount != beforeHere
            || IERC20(asset).balanceOf(to) != beforeThere + amount) revert TransferMismatch();
    }
}
