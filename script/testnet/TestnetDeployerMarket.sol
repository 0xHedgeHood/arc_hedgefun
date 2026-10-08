// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Drip, TestFeed} from "./TestnetAssets.sol";
import {IV3Pool} from "./TestnetMarket.sol";

interface IV3PoolPosition {
    function burn(int24 tickLower, int24 tickUpper, uint128 amount) external returns (uint256, uint256);
    function collect(address recipient, int24 tickLower, int24 tickUpper, uint128 amount0Requested, uint128 amount1Requested)
        external returns (uint128, uint128);
}

/// A market maker of last resort for the testnet that MINTS NOTHING. `TestnetMarket` moves a pool by minting whatever
/// the swap asks of it, which needs the mint role the venue owner holds. This one owns one position per pool and
/// moves the price by stepping out of the pool, letting a swap slide the empty pool to the target for nothing, and
/// stepping back in at the new price with what it holds, so faucet drips are all the capital it ever has. The feed
/// moves with the pool, as on the original market, so every treasury's deviation gate keeps agreeing.
///
/// Owner actions: `addLine`, `provide` (all holdings into the position), `setPrice`, `syncFeed`, `poke`, `withdraw`.
/// Anyone may `drip` the test tokens to it once a day each.
contract TestnetDeployerMarket is Ownable2Step {
    uint256 private constant Q96 = 1 << 96;

    struct Line {
        address stock;
        TestFeed feed;
        bool stockIsToken0;
        uint256 scale;     // 1e18 * 10^stockDecimals / 10^usdgDecimals
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity; // this contract's position, the only one it ever holds in the pool
    }

    address public immutable usdg;
    mapping(address => Line) public lines;    // by pool
    address[] public pools;
    address private _active;

    event LineAdded(address indexed pool, address indexed stock, address feed, int24 tickLower, int24 tickUpper);
    event Provided(address indexed pool, uint128 liquidity, uint256 amount0, uint256 amount1);
    event PriceSet(address indexed pool, uint256 priceE18, int256 feedAnswer, uint128 liquidity);
    error BadLine();
    error BadCallback();
    error PriceNotReached(uint160 target, uint160 actual);
    error OutsideRange();
    error NothingToProvide();

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
        lines[pool] = Line(stock, feed, stock0, 1e18 * 10 ** stockDecimals / 1e6, tickLower, tickUpper, 0);
        pools.push(pool);
        emit LineAdded(pool, stock, address(feed), tickLower, tickUpper);
    }

    /// @notice claim a test token's daily drip for this contract; anyone may top it up this way
    function drip(address token) external { Drip(token).drip(); }

    function withdraw(address token, uint256 amount) external onlyOwner {
        require(IERC20(token).transfer(msg.sender, amount), "transfer failed");
    }

    /// @notice put everything this contract holds of the pair into the position, at the pool's current price
    function provide(address pool) external onlyOwner returns (uint128 added, uint256 a0, uint256 a1) {
        Line storage l = _line(pool);
        (added, a0, a1) = _provide(pool, l);
    }

    /// @notice move the pool to `priceE18` (1e18 USDG per whole stock token) and the feed with it. The position is
    ///         withdrawn, the empty pool is swapped to the target (which costs nothing when nobody else provides
    ///         liquidity), and the position is rebuilt at the new price from what the withdrawal returned.
    function setPrice(address pool, uint256 priceE18) external onlyOwner {
        Line storage l = _line(pool);
        uint160 target = sqrtFor(pool, priceE18);
        if (target <= TickMath.getSqrtPriceAtTick(l.tickLower) || target >= TickMath.getSqrtPriceAtTick(l.tickUpper)) {
            revert OutsideRange();
        }
        _withdraw(pool, l);
        _swapTo(pool, target);
        (uint160 actual,,,,,,) = IV3Pool(pool).slot0();
        if (actual != target) revert PriceNotReached(target, actual);
        _provide(pool, l);
        int256 answer = _setFeed(l, priceE18);
        emit PriceSet(pool, priceE18, answer, l.liquidity);
    }

    /// @notice set the feed to the pool's current price (public trades move the pool; nothing moves the feed)
    function syncFeed(address pool) external onlyOwner {
        Line storage l = _line(pool);
        (uint160 s,,,,,,) = IV3Pool(pool).slot0();
        int256 answer = _setFeed(l, priceAt(pool, s));
        emit PriceSet(pool, priceAt(pool, s), answer, l.liquidity);
    }

    /// @notice a one-tick round trip that ends at the starting price, so the pool writes an observation and a grown
    ///         `observationCardinalityNext` becomes live. Needs a later second than the pool's last write.
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

    /// @notice the liquidity this contract's balances afford in the line's range at the pool's current price
    function affordable(address pool) public view returns (uint128) {
        Line memory l = lines[pool];
        IV3Pool p = IV3Pool(pool);
        (uint160 sqrtP,,,,,,) = p.slot0();
        uint256 a = TickMath.getSqrtPriceAtTick(l.tickLower);
        uint256 b = TickMath.getSqrtPriceAtTick(l.tickUpper);
        uint256 bal0 = IERC20(p.token0()).balanceOf(address(this));
        uint256 bal1 = IERC20(p.token1()).balanceOf(address(this));
        uint256 liquidity;
        if (sqrtP <= a) liquidity = _forAmount0(a, b, bal0);
        else if (sqrtP >= b) liquidity = _forAmount1(a, b, bal1);
        else liquidity = Math.min(_forAmount0(sqrtP, b, bal0), _forAmount1(a, sqrtP, bal1));
        liquidity -= liquidity / 10_000;   // the pool rounds the amounts it asks for up; leave it that room
        return uint128(Math.min(liquidity, type(uint128).max));
    }

    function _provide(address pool, Line storage l) private returns (uint128 added, uint256 a0, uint256 a1) {
        added = affordable(pool);
        if (added == 0) revert NothingToProvide();
        _active = pool;
        (a0, a1) = IV3Pool(pool).mint(address(this), l.tickLower, l.tickUpper, added, "");
        _active = address(0);
        l.liquidity += added;
        emit Provided(pool, added, a0, a1);
    }

    function _withdraw(address pool, Line storage l) private {
        if (l.liquidity == 0) return;
        IV3PoolPosition(pool).burn(l.tickLower, l.tickUpper, l.liquidity);
        IV3PoolPosition(pool).collect(address(this), l.tickLower, l.tickUpper, type(uint128).max, type(uint128).max);
        l.liquidity = 0;
    }

    function _swapTo(address pool, uint160 target) private {
        (uint160 current,,,,,,) = IV3Pool(pool).slot0();
        if (current == target) return;
        bool zeroForOne = target < current;
        _active = pool;
        IV3Pool(pool).swap(address(this), zeroForOne, type(int128).max, target, "");
        _active = address(0);
    }

    /// pays only from what this contract holds; a shortfall reverts instead of minting
    function _pay(uint256 owed0, uint256 owed1) private {
        if (msg.sender != _active || _active == address(0)) revert BadCallback();
        IV3Pool p = IV3Pool(msg.sender);
        if (owed0 != 0) require(IERC20(p.token0()).transfer(msg.sender, owed0), "transfer failed");
        if (owed1 != 0) require(IERC20(p.token1()).transfer(msg.sender, owed1), "transfer failed");
    }

    function _setFeed(Line storage l, uint256 priceE18) private returns (int256 answer) {
        answer = int256(priceE18 / 1e10);   // 8-decimal feed; the tUSDG feed stays at 1e8
        l.feed.set(answer);
    }

    function _forAmount0(uint256 sqrtA, uint256 sqrtB, uint256 amount0) private pure returns (uint256) {
        return Math.mulDiv(amount0, Math.mulDiv(sqrtA, sqrtB, Q96), sqrtB - sqrtA);
    }

    function _forAmount1(uint256 sqrtA, uint256 sqrtB, uint256 amount1) private pure returns (uint256) {
        return Math.mulDiv(amount1, Q96, sqrtB - sqrtA);
    }

    function _line(address pool) private view returns (Line storage l) {
        l = lines[pool];
        if (l.stock == address(0)) revert BadLine();
    }
}
