// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TestFeed} from "./TestnetAssets.sol";
import {IV3Factory, IV3Pool} from "./TestnetMarket.sol";

/// @notice One prefunded WETH/tUSDG testnet position. Native tokens are never minted or fabricated.
/// @dev Deposits into the WETH contract and both prefunding transfers happen outside this contract.
/// Every callback consumes one bounded allowance and verifies exact balance movements.
contract TestnetNativeMarket is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 private constant Q96 = 1 << 96;
    uint256 private constant SCALE = 1e30;

    address public immutable stock;
    address public immutable usdg;
    IV3Pool public immutable pool;
    TestFeed public immutable feed;
    bool public immutable stockIsToken0;
    int24 public immutable tickLower;
    int24 public immutable tickUpper;
    uint8 private _callback;
    uint256 private _remaining0;
    uint256 private _remaining1;

    event Provided(uint128 liquidity, uint256 amount0, uint256 amount1);
    event PriceSet(uint256 priceE18);
    event Poked(uint160 startingSqrtPrice);
    error BadConfig();
    error BadCallback();
    error InputLimit();
    error TransferMismatch();
    error Expired();
    error OutsideRange();
    error PriceNotReached();

    constructor(address initialOwner, address factory, address usdg_, address stock_, address pool_,
        TestFeed feed_, int24 lower, int24 upper)
        Ownable(initialOwner)
    {
        IV3Pool p = IV3Pool(pool_);
        bool stock0 = p.token0() == stock_;
        int24 spacing = p.tickSpacing();
        if (stock_ == usdg_ || IERC20Metadata(stock_).decimals() != 18 || IERC20Metadata(usdg_).decimals() != 6
            || IV3Factory(factory).getPool(stock_, usdg_, p.fee()) != pool_
            || !(stock0 ? p.token1() == usdg_ : p.token0() == usdg_ && p.token1() == stock_)
            || address(feed_).code.length == 0 || spacing <= 0 || lower >= upper
            || lower < TickMath.MIN_TICK || upper > TickMath.MAX_TICK || lower % spacing != 0 || upper % spacing != 0) revert BadConfig();
        stock = stock_; usdg = usdg_; pool = p; feed = feed_; stockIsToken0 = stock0;
        tickLower = lower; tickUpper = upper;
    }

    function provide(uint128 liquidity, uint256 max0, uint256 max1, uint256 deadline)
        external onlyOwner nonReentrant returns (uint256 a0, uint256 a1)
    {
        _deadline(deadline);
        if (liquidity == 0) revert BadConfig();
        _arm(1, max0, max1);
        (a0, a1) = pool.mint(address(this), tickLower, tickUpper, liquidity, "");
        _clear();
        emit Provided(liquidity, a0, a1);
    }

    function setPrice(uint256 priceE18, uint256 max0, uint256 max1, uint256 deadline)
        external onlyOwner nonReentrant
    {
        _deadline(deadline);
        _swapTo(sqrtFor(priceE18), max0, max1);
        feed.set(int256(priceE18 / 1e10));
        emit PriceSet(priceE18);
    }

    function syncFeed() external onlyOwner nonReentrant {
        (uint160 sqrtP,,,,,,) = pool.slot0();
        uint256 price = priceAt(sqrtP);
        if (price == 0 || price / 1e10 > uint256(type(int256).max)) revert BadConfig();
        feed.set(int256(price / 1e10));
        emit PriceSet(price);
    }

    /// @notice The round trip must be in a later second than the last in-range position write.
    function poke(uint256 max0, uint256 max1, uint256 deadline) external onlyOwner nonReentrant {
        _deadline(deadline);
        (uint160 start, int24 tick,,,,,) = pool.slot0();
        _swapTo(TickMath.getSqrtPriceAtTick(tick + 1), max0, max1);
        _swapTo(start, max0, max1);
        emit Poked(start);
    }

    function sqrtFor(uint256 priceE18) public view returns (uint160) {
        if (priceE18 == 0 || priceE18 / 1e10 == 0 || priceE18 / 1e10 > uint256(type(int256).max)) revert BadConfig();
        uint256 square = stockIsToken0
            ? Math.mulDiv(priceE18, 1 << 192, SCALE) : Math.mulDiv(SCALE, 1 << 192, priceE18);
        uint256 root = Math.sqrt(square);
        if (root > type(uint160).max) revert BadConfig();
        return uint160(root);
    }

    function priceAt(uint160 sqrtP) public view returns (uint256) {
        uint256 raw = Math.mulDiv(sqrtP, sqrtP, Q96);
        if (raw == 0) revert BadConfig();
        return stockIsToken0 ? Math.mulDiv(raw, SCALE, Q96) : Math.mulDiv(SCALE, Q96, raw);
    }

    function uniswapV3MintCallback(uint256 owed0, uint256 owed1, bytes calldata) external { _pay(owed0, owed1, 1); }
    function uniswapV3SwapCallback(int256 d0, int256 d1, bytes calldata) external {
        _pay(d0 > 0 ? uint256(d0) : 0, d1 > 0 ? uint256(d1) : 0, 2);
    }

    function _swapTo(uint160 target, uint256 max0, uint256 max1) private {
        if (target <= TickMath.getSqrtPriceAtTick(tickLower) || target >= TickMath.getSqrtPriceAtTick(tickUpper)) revert OutsideRange();
        (uint160 current,,,,,,) = pool.slot0();
        if (current == target) return;
        bool zeroForOne = target < current;
        uint256 amount = zeroForOne ? max0 : max1;
        if (amount == 0 || amount > uint256(type(int256).max)) revert InputLimit();
        _arm(2, zeroForOne ? max0 : 0, zeroForOne ? 0 : max1);
        pool.swap(address(this), zeroForOne, int256(amount), target, "");
        _clear();
        (uint160 actual,,,,,,) = pool.slot0();
        if (actual != target) revert PriceNotReached();
    }

    function _arm(uint8 callback, uint256 max0, uint256 max1) private {
        _callback = callback; _remaining0 = max0; _remaining1 = max1;
    }

    function _clear() private { _callback = 0; _remaining0 = 0; _remaining1 = 0; }

    function _pay(uint256 owed0, uint256 owed1, uint8 callback) private {
        if (msg.sender != address(pool) || _callback != callback || callback == 0) revert BadCallback();
        if (owed0 > _remaining0 || owed1 > _remaining1) revert InputLimit();
        _clear(); // One callback only; disarm before either token transfer.
        if (owed0 != 0) _send(stockIsToken0 ? stock : usdg, owed0);
        if (owed1 != 0) _send(stockIsToken0 ? usdg : stock, owed1);
    }

    function _send(address token, uint256 amount) private {
        uint256 here = IERC20(token).balanceOf(address(this));
        uint256 there = IERC20(token).balanceOf(address(pool));
        IERC20(token).safeTransfer(address(pool), amount);
        if (IERC20(token).balanceOf(address(this)) + amount != here
            || IERC20(token).balanceOf(address(pool)) != there + amount) revert TransferMismatch();
    }

    function _deadline(uint256 deadline) private view { if (block.timestamp > deadline) revert Expired(); }
}
