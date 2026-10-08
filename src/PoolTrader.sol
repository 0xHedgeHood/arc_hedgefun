// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3.sol";
import {HedgeFunMath, BPS} from "./libraries/HedgeFunMath.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PriceOracle} from "./PriceOracle.sol";


/// The one copy of everything that touches a price or the V3 pool: unit conversions for both token orderings (USDG
/// is token0 in some stock pools and token1 in others), the oracle-vs-pool health gate (spot AND the pool's own
/// 10-minute mean, so an atomic push cannot open it), and the one way the treasury trades:
///
///   _swapBounded    sqrtPriceLimit comes from the ORACLE +/- slippage, so the pool cannot fill past that marginal
///                   price, and the realised average is re-checked.
abstract contract PoolTrader {
    using SafeERC20 for IERC20;

    uint32 public constant TWAP_WINDOW = 600;
    /// slots the ring must have beyond one per second of the window
    uint32 internal constant RING_MARGIN = 60;
    uint256 internal constant Q192 = 1 << 192;                // sqrtPriceX96 squared is a Q192 price
    uint256 internal constant Q96 = 1 << 96;

    IERC20 public immutable usdg;
    IERC20 public immutable stock;
    IUniswapV3Pool public immutable pool;
    PriceOracle public immutable oracle;
    bool public immutable stockIsToken0;
    uint256 public immutable poolFeeBps;
    uint256 internal immutable SCALE;                        // 1e18 * 10^stockDecimals / 10^usdgDecimals
    bool private _swapping;

    error BadConfig();
    error Slippage();
    error NotPool();
    error ShortObservationRing(uint16 have, uint256 need);

    constructor(address usdg_, address stock_, address pool_, address oracle_) {
        if (usdg_ == address(0) || stock_ == address(0) || usdg_ == stock_) revert BadConfig();
        address t0 = IUniswapV3Pool(pool_).token0();
        address t1 = IUniswapV3Pool(pool_).token1();
        if (!((t0 == stock_ && t1 == usdg_) || (t0 == usdg_ && t1 == stock_))) revert BadConfig();
        if (PriceOracle(oracle_).stock() != stock_) revert BadConfig();
        // The whole deviation gate rests on this ring, and a pool that cannot serve the window is a treasury that
        // can never trade. Fail at deploy, not at the first trade. The ring writes at most once per second, so a
        // TWAP_WINDOW-second mean needs that many slots plus headroom.
        (,,, uint16 cardinality,,,) = IUniswapV3Pool(pool_).slot0();
        if (cardinality < TWAP_WINDOW + RING_MARGIN) revert ShortObservationRing(cardinality, TWAP_WINDOW + RING_MARGIN);
        usdg = IERC20(usdg_); stock = IERC20(stock_); pool = IUniswapV3Pool(pool_); oracle = PriceOracle(oracle_);
        stockIsToken0 = t0 == stock_;
        poolFeeBps = uint256(IUniswapV3Pool(pool_).fee()) / 100;
        SCALE = 1e18 * 10 ** uint256(IERC20Metadata(stock_).decimals()) / 10 ** uint256(IERC20Metadata(usdg_).decimals());
    }

    /// @dev stock amount -> USDG units at price p (1e18, human USDG per whole stock token), rounded down
    function _value(uint256 stockAmount, uint256 p) internal view returns (uint256) { return Math.mulDiv(stockAmount, p, SCALE); }
    function _stockFor(uint256 usdgAmount, uint256 p) internal view returns (uint256) { return Math.mulDiv(usdgAmount, SCALE, p); }

    /// @notice the pool's own price, same units as the oracle
    function spotPrice() public view returns (uint256) {
        (uint160 sqrtP,,,,,,) = pool.slot0();
        return _priceAtSqrt(sqrtP);
    }

    /// @notice the pool's TWAP_WINDOW mean price, same units as the oracle. 0 when the observation ring is too
    ///         short for the window (it holds at most one write per second, and a griefer flipping the tick every
    ///         second can push the window out of a short ring) — callers must treat 0 as "no opinion" and refuse,
    ///         never as a price.
    function twapPrice() public view returns (uint256) {
        uint32[] memory ago = new uint32[](2); ago[0] = TWAP_WINDOW;
        try pool.observe(ago) returns (int56[] memory tc, uint160[] memory) {
            return _priceAtSqrt(TickMath.getSqrtPriceAtTick(int24(_meanTick(int256(tc[1]) - int256(tc[0])))));
        } catch { return 0; }
    }

    /// @dev Solidity truncates toward zero, so a negative cumulative delta would round the mean UP by up to a
    ///      tick — a free basis point of slack in the deviation gate. Round toward negative infinity instead, as
    ///      Uniswap's OracleLibrary.consult does.
    function _meanTick(int256 delta) internal pure returns (int256 mean) {
        int256 w = int256(uint256(TWAP_WINDOW));
        mean = delta / w;
        if (delta < 0 && delta % w != 0) mean -= 1;
    }

    function _priceAtSqrt(uint160 sqrtP) internal view returns (uint256) {
        uint256 rawX96 = Math.mulDiv(sqrtP, sqrtP, Q96);
        if (rawX96 == 0) return 0;
        return stockIsToken0 ? Math.mulDiv(rawX96, SCALE, Q96) : Math.mulDiv(SCALE, Q96, rawX96);
    }

    function _sqrtPriceX96(uint256 p) internal view returns (uint160) {
        uint256 rawX192 = stockIsToken0 ? Math.mulDiv(p, Q192, SCALE) : Math.mulDiv(SCALE, Q192, p);
        uint256 sq = Math.sqrt(rawX192);
        if (sq > type(uint160).max) revert BadConfig();
        return uint160(sq);
    }

    /// @return ok oracle healthy, and both the pool's spot and its TWAP_WINDOW mean within maxDeviationBps of it
    function _health(uint256 maxDeviationBps) internal view returns (bool ok, uint256 p) {
        (ok, p) = oracle.tryPrice();
        if (!ok) return (false, 0);
        uint256 s = spotPrice();
        uint256 gap = s > p ? s - p : p - s;
        if (HedgeFunMath.exceeds(gap, p, maxDeviationBps)) return (false, p);
        // spot vs the pool's own recent mean, in ticks (1 tick = 1bp). A ring too short for the window fails closed.
        (, int24 tick,,,,,) = pool.slot0();
        uint32[] memory ago = new uint32[](2); ago[0] = TWAP_WINDOW;
        try pool.observe(ago) returns (int56[] memory tc, uint160[] memory) {
            int256 d = int256(tick) - _meanTick(int256(tc[1]) - int256(tc[0]));
            if (uint256(d < 0 ? -d : d) > maxDeviationBps) return (false, p);
        } catch { return (false, p); }
    }

    /// @dev may fill SHORT in either direction: a V3 swap that reaches its price limit stops early and silently -- it
    ///      returns with input unconsumed, no revert and no flag. The caller sizes every effect from `spent` and
    ///      `received`; the average-price check below is on `spent`, so a short fill meets the same floor a full one does.
    function _swapBounded(bool buy, uint256 amountIn, uint256 p, uint256 slipBps)
        internal returns (uint256 spent, uint256 received)
    {
        uint160 limit = _sqrtPriceX96(HedgeFunMath.shift(p, slipBps, buy));
        (spent, received) = _swap(buy, amountIn, limit);
        uint256 keep = BPS - slipBps - poolFeeBps;
        if (buy ? HedgeFunMath.short(_value(received, p), spent, keep) : HedgeFunMath.short(received, _value(spent, p), keep)) revert Slippage();
    }

    function _swap(bool buy, uint256 amountIn, uint160 limit) private returns (uint256 spent, uint256 received) {
        bool zeroForOne = buy ? !stockIsToken0 : stockIsToken0;
        _swapping = true;
        (int256 a0, int256 a1) = pool.swap(address(this), zeroForOne, int256(amountIn), limit, "");
        _swapping = false;
        (int256 dIn, int256 dOut) = zeroForOne ? (a0, a1) : (a1, a0);
        if (dIn <= 0 || dOut >= 0) revert Slippage();
        spent = uint256(dIn); received = uint256(-dOut);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != address(pool) || !_swapping) revert NotPool();
        if (amount0Delta > 0) (stockIsToken0 ? stock : usdg).safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) (stockIsToken0 ? usdg : stock).safeTransfer(msg.sender, uint256(amount1Delta));
    }
}
