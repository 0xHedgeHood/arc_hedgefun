// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TestFeed} from "./TestnetAssets.sol";

interface ITestMintable {
    function mint(address to, uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// Uniswap V3 core, the parts the testnet scripts call. The factory is deployed from the vendored v1.0.0 bytecode
/// (lib/v4-core/test/bin/v3Factory.bytecode), which is byte-identical to Robinhood Chain mainnet's factory.
interface IV3Factory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address);
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
}

interface IV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
    function increaseObservationCardinalityNext(uint16 next) external;
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external returns (uint256, uint256);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external returns (int256, int256);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
}

/// The testnet's market maker of last resort, for test assets only. It owns one V3 position per stock/tUSDG pool,
/// mints whatever tUSDG or test stock a pool asks of it (it is an operator on every test token), and moves the pool
/// and the stock's test feed TOGETHER, so the pool and the oracle agree the way arbitrage keeps them agreeing on
/// mainnet. Every treasury's deviation gate compares exactly those two.
///
/// Operator actions: `provide` (more depth), `setPrice` (pool and feed to a new price), `syncFeed` (feed to the pool
/// price, after public trades), `poke` (one observation write, which is what makes a grown observation ring live).
contract TestnetMarket is Ownable2Step {
    uint256 private constant Q96 = 1 << 96;

    struct Line {
        address stock;
        TestFeed feed;
        bool stockIsToken0;
        uint256 scale;     // PoolTrader.SCALE: 1e18 * 10^stockDecimals / 10^usdgDecimals
        int24 tickLower;
        int24 tickUpper;
    }

    address public immutable usdg;
    mapping(address => Line) public lines;    // by pool
    address[] public pools;
    address private _active;                   // the pool whose callback is expected; zero outside an operation

    event LineAdded(address indexed pool, address indexed stock, address feed, int24 tickLower, int24 tickUpper);
    event PriceSet(address indexed pool, uint256 priceE18, int256 feedAnswer);
    error BadLine();
    error BadCallback();
    error PriceNotReached(uint160 target, uint160 actual);
    error OutsideRange();

    constructor(address initialOwner, address usdg_) Ownable(initialOwner) { usdg = usdg_; }

    function poolCount() external view returns (uint256) { return pools.length; }

    /// @notice register a pool this contract will make a market in; the range bounds every later price move
    function addLine(address pool, address stock, TestFeed feed, uint8 stockDecimals, int24 tickLower, int24 tickUpper)
        external onlyOwner
    {
        IV3Pool p = IV3Pool(pool);
        bool stock0 = p.token0() == stock;
        if (lines[pool].stock != address(0) || !(stock0 ? p.token1() == usdg : p.token0() == usdg && p.token1() == stock)
            || tickLower >= tickUpper || tickLower % p.tickSpacing() != 0 || tickUpper % p.tickSpacing() != 0) {
            revert BadLine();
        }
        lines[pool] = Line(stock, feed, stock0, 1e18 * 10 ** stockDecimals / 1e6, tickLower, tickUpper);
        pools.push(pool);
        emit LineAdded(pool, stock, address(feed), tickLower, tickUpper);
    }

    /// @notice add `liquidity` to the line's position; the tokens are minted in the callback
    function provide(address pool, uint128 liquidity) external onlyOwner returns (uint256 a0, uint256 a1) {
        Line memory l = _line(pool);
        _active = pool;
        (a0, a1) = IV3Pool(pool).mint(address(this), l.tickLower, l.tickUpper, liquidity, "");
        _active = address(0);
    }

    /// @notice swap the pool to `priceE18` (1e18 USDG per whole stock token) and set the feed to the same price
    function setPrice(address pool, uint256 priceE18) external onlyOwner {
        Line memory l = _line(pool);
        uint160 target = sqrtFor(pool, priceE18);
        if (target <= TickMath.getSqrtPriceAtTick(l.tickLower) || target >= TickMath.getSqrtPriceAtTick(l.tickUpper)) {
            revert OutsideRange();
        }
        _swapTo(pool, target);
        (uint160 actual,,,,,,) = IV3Pool(pool).slot0();
        if (actual != target) revert PriceNotReached(target, actual);
        _setFeed(pool, l, priceE18);
    }

    /// @notice set the feed to the pool's current price (public trades move the pool; nothing moves the feed)
    function syncFeed(address pool) external onlyOwner {
        Line memory l = _line(pool);
        (uint160 s,,,,,,) = IV3Pool(pool).slot0();
        _setFeed(pool, l, priceAt(pool, s));
    }

    /// @notice a one-tick round trip that ends at the starting price. A swap writes the pool's observation for this
    ///         second only when it changes the tick, and that write is what turns a grown `observationCardinalityNext`
    ///         into the live cardinality `PoolTrader` requires. It must land in a later second than the pool's last
    ///         write (its `initialize`, or a `provide` in range).
    function poke(address pool) external onlyOwner {
        _line(pool);
        (uint160 start, int24 tick,,,,,) = IV3Pool(pool).slot0();
        _swapTo(pool, TickMath.getSqrtPriceAtTick(tick + 1));
        _swapTo(pool, start);
    }

    function uniswapV3MintCallback(uint256 owed0, uint256 owed1, bytes calldata) external { _pay(owed0, owed1); }

    function uniswapV3SwapCallback(int256 d0, int256 d1, bytes calldata) external {
        _pay(d0 > 0 ? uint256(d0) : 0, d1 > 0 ? uint256(d1) : 0);
    }

    function sqrtFor(address pool, uint256 priceE18) public view returns (uint160) {
        Line memory l = lines[pool];
        return uint160(Math.sqrt(l.stockIsToken0
            ? Math.mulDiv(priceE18, 1 << 192, l.scale) : Math.mulDiv(l.scale, 1 << 192, priceE18)));
    }

    function priceAt(address pool, uint160 sqrtP) public view returns (uint256) {
        Line memory l = lines[pool];
        uint256 rawX96 = Math.mulDiv(sqrtP, sqrtP, Q96);
        return l.stockIsToken0 ? Math.mulDiv(rawX96, l.scale, Q96) : Math.mulDiv(l.scale, Q96, rawX96);
    }

    function _swapTo(address pool, uint160 target) private {
        (uint160 current,,,,,,) = IV3Pool(pool).slot0();
        if (current == target) return;
        bool zeroForOne = target < current;
        _active = pool;
        IV3Pool(pool).swap(address(this), zeroForOne, type(int128).max, target, "");
        _active = address(0);
    }

    function _pay(uint256 owed0, uint256 owed1) private {
        if (msg.sender != _active || _active == address(0)) revert BadCallback();
        IV3Pool p = IV3Pool(msg.sender);
        if (owed0 != 0) _send(p.token0(), msg.sender, owed0);
        if (owed1 != 0) _send(p.token1(), msg.sender, owed1);
    }

    /// pays from what this contract already holds (swap proceeds) and mints only the shortfall
    function _send(address token, address to, uint256 amount) private {
        uint256 held = ITestMintable(token).balanceOf(address(this));
        if (held < amount) ITestMintable(token).mint(address(this), amount - held);
        ITestMintable(token).transfer(to, amount);
    }

    function _setFeed(address pool, Line memory l, uint256 priceE18) private {
        int256 answer = int256(priceE18 / 1e10);   // 8-decimal feed; the tUSDG feed stays at 1e8
        l.feed.set(answer);
        emit PriceSet(pool, priceE18, answer);
    }

    function _line(address pool) private view returns (Line memory l) {
        l = lines[pool];
        if (l.stock == address(0)) revert BadLine();
    }
}
