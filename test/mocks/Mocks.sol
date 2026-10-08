// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";

contract MockToken is ERC20 {
    uint8 internal immutable _dec;
    bool public oraclePaused;
    constructor(string memory s, uint8 d) ERC20(s, s) { _dec = d; }
    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 a) external { _mint(to, a); }
    function setOraclePaused(bool p) external { oraclePaused = p; }
}

contract MockFeed {
    uint8 public immutable decimals;
    int256 public answer; uint256 public updatedAt;
    constructor(uint8 d) { decimals = d; }
    function set(int256 a) external { answer = a; updatedAt = block.timestamp; }
    function setAt(int256 a, uint256 t) external { answer = a; updatedAt = t; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) { return (1, answer, updatedAt, updatedAt, 1); }
}

interface ISwapCallback { function uniswapV3SwapCallback(int256, int256, bytes calldata) external; }

/// A flat-price pool: every swap fills at `price` less the fee, and refuses (like V3's "SPL") when the caller's
/// limit is already on the wrong side of the price. Token order is whatever the test says, so both are covered.
contract MockPool {
    address public immutable token0; address public immutable token1; uint24 public immutable fee;
    bool internal immutable stockIs0; uint256 internal immutable SCALE;
    uint256 public price;                 // 1e18, USDG per stock

    constructor(address stock, address usdg, bool stockIsToken0, uint24 fee_, uint256 scale) {
        (token0, token1) = stockIsToken0 ? (stock, usdg) : (usdg, stock);
        stockIs0 = stockIsToken0; fee = fee_; SCALE = scale;
    }
    /// @dev keeps the tick and the 10-minute mean consistent with the price, the way a pool that actually traded
    ///      there would. `pushSpot` is the deliberate exception: it is how a test says "spot was shoved, the mean
    ///      has not caught up".
    function setPrice(uint256 p) public { price = p; tick = TickMath.getTickAtSqrtPrice(sqrtOf(p)); meanTick = tick; }

    function sqrtOf(uint256 p) public view returns (uint160) {
        if (p == 0) return 0;                                                    // a pool read before any price is set
        return uint160(Math.sqrt(stockIs0 ? Math.mulDiv(p, 1 << 192, SCALE) : Math.mulDiv(SCALE, 1 << 192, p)));
    }
    int24 public tick; int24 public meanTick; bool public ringTooShort;
    /// an atomic push: spot (and its tick) move, the 10-minute mean does not
    function pushSpot(uint256 p, int24 tickShift) external { price = p; tick = meanTick + tickShift; }
    function settle() external { meanTick = tick; }
    function setRingTooShort(bool b) external { ringTooShort = b; }
    uint16 public cardinality = 1000;
    function setCardinality(uint16 c) external { cardinality = c; }
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) { return (sqrtOf(price), tick, 0, cardinality, cardinality, 0, true); }
    function observe(uint32[] calldata ago) external view returns (int56[] memory tc, uint160[] memory l) {
        require(!ringTooShort, "OLD");
        tc = new int56[](2); l = new uint160[](2);
        tc[1] = int56(meanTick) * int56(uint56(ago[0]));
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 limit, bytes calldata data) external returns (int256 a0, int256 a1) {
        require(amountSpecified > 0, "exact in only");
        require(zeroForOne ? limit < sqrtOf(price) : limit > sqrtOf(price), "SPL");
        uint256 inAmt = uint256(amountSpecified);
        uint256 outAmt = _out(zeroForOne, inAmt);
        IERC20(zeroForOne ? token1 : token0).transfer(recipient, outAmt);
        (a0, a1) = zeroForOne ? (int256(inAmt), -int256(outAmt)) : (-int256(outAmt), int256(inAmt));
        IERC20 tin = IERC20(zeroForOne ? token0 : token1);
        uint256 before = tin.balanceOf(address(this));
        ISwapCallback(msg.sender).uniswapV3SwapCallback(a0, a1, data);
        require(tin.balanceOf(address(this)) >= before + inAmt, "IIA");
    }

    function _out(bool zeroForOne, uint256 inAmt) internal view returns (uint256) {
        uint256 net = inAmt * (1e6 - fee) / 1e6;
        return zeroForOne == stockIs0 ? Math.mulDiv(net, price, SCALE) : Math.mulDiv(net, SCALE, price);
    }
}

contract MockV3Factory {
    mapping(bytes32 => address) public pools;
    function set(address a, address b, uint24 fee, address pool) external { pools[keccak256(abi.encode(a, b, fee))] = pool; pools[keccak256(abi.encode(b, a, fee))] = pool; }
    function getPool(address a, address b, uint24 fee) external view returns (address) { return pools[keccak256(abi.encode(a, b, fee))]; }
}

interface IMintCallback { function uniswapV3MintCallback(uint256, uint256, bytes calldata) external; }

/// A V3 pool that models the ONE fee behaviour the swap-only mock does not: `Position.update` credits the WHOLE
/// position's uncollected fee to `tokensOwed` on ANY update — including a zero burn — computed on the liquidity
/// held before the delta, not on the slice being changed. That is what let a dust redeemer sweep every holder's
/// fees, and a mock without it cannot see the bug.
contract MockLpPool {
    address public immutable token0; address public immutable token1; uint24 public immutable fee;
    int24 public constant tickSpacing = 10;
    uint160 public sqrtPriceX96 = uint160(1 << 96);
    int24 public tick;
    uint16 public cardinality = 1000;

    mapping(bytes32 => uint128) public liq;
    mapping(bytes32 => uint128) public owed0;
    mapping(bytes32 => uint128) public owed1;
    uint128 public pending0; uint128 public pending1;          // earned by the position, not yet credited

    constructor(address t0, address t1, uint24 f) { (token0, token1, fee) = (t0, t1, f); }

    function setSqrt(uint160 s) external { sqrtPriceX96 = s; tick = TickMath.getTickAtSqrtPrice(s); }
    function setCardinality(uint16 c) external { cardinality = c; }
    /// @dev the pool earned this much for the position; it stays uncredited until the position is touched
    function accrueFees(uint128 a0, uint128 a1) external { pending0 += a0; pending1 += a1; }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, tick, 0, cardinality, cardinality, 0, true);
    }
    function observe(uint32[] calldata ago) external view returns (int56[] memory tc, uint160[] memory l) {
        tc = new int56[](2); l = new uint160[](2);
        tc[1] = int56(tick) * int56(uint56(ago[0]));
    }
    function positions(bytes32 k) external view returns (uint128, uint256, uint256, uint128, uint128) {
        return (liq[k], 0, 0, owed0[k], owed1[k]);
    }
    function _key(address o, int24 lo, int24 hi) internal pure returns (bytes32) { return keccak256(abi.encodePacked(o, lo, hi)); }

    /// @dev the real V3 amounts for `l` of liquidity across the range at the current price
    function amountsFor(int24 lo, int24 hi, uint128 l) public view returns (uint256 a0, uint256 a1) {
        uint160 a = TickMath.getSqrtPriceAtTick(lo);
        uint160 b = TickMath.getSqrtPriceAtTick(hi);
        uint160 p = sqrtPriceX96;
        if (p <= a) return (SqrtPriceMath.getAmount0Delta(a, b, l, true), 0);
        if (p >= b) return (0, SqrtPriceMath.getAmount1Delta(a, b, l, true));
        return (SqrtPriceMath.getAmount0Delta(p, b, l, true), SqrtPriceMath.getAmount1Delta(a, p, l, true));
    }

    function mint(address recipient, int24 lo, int24 hi, uint128 amount, bytes calldata data) external returns (uint256 a0, uint256 a1) {
        bytes32 k = _key(recipient, lo, hi);
        _credit(k);
        liq[k] += amount;
        (a0, a1) = amountsFor(lo, hi, amount);
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        IMintCallback(msg.sender).uniswapV3MintCallback(a0, a1, data);
        require(IERC20(token0).balanceOf(address(this)) >= b0 + a0 && IERC20(token1).balanceOf(address(this)) >= b1 + a1, "M0");
    }

    function burn(int24 lo, int24 hi, uint128 amount) external returns (uint256 a0, uint256 a1) {
        bytes32 k = _key(msg.sender, lo, hi);
        _credit(k);                                                             // <- the whole fee, even for amount == 0
        liq[k] -= amount;
        (a0, a1) = amountsFor(lo, hi, amount);
        owed0[k] += uint128(a0); owed1[k] += uint128(a1);                        // principal joins the owed balance
    }

    function collect(address recipient, int24 lo, int24 hi, uint128 m0, uint128 m1) external returns (uint128, uint128) {
        bytes32 k = _key(msg.sender, lo, hi);
        uint128 a0 = owed0[k] < m0 ? owed0[k] : m0;
        uint128 a1 = owed1[k] < m1 ? owed1[k] : m1;
        owed0[k] -= a0; owed1[k] -= a1;
        if (a0 != 0) IERC20(token0).transfer(recipient, a0);
        if (a1 != 0) IERC20(token1).transfer(recipient, a1);
        return (a0, a1);
    }

    function _credit(bytes32 k) internal {
        if (liq[k] == 0) return;
        owed0[k] += pending0; owed1[k] += pending1;
        pending0 = 0; pending1 = 0;
    }
}

/// The Chainlink aggregator surface the fork tests read directly off a live feed, and a calendar stub that never
/// closes. Both live here rather than in a fork test file so that the unit suites, which must run with no network,
/// do not have to import one.
interface IAgg { function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80); }

/// A calendar whose closure can be switched on, so a suite can ask what the rule does over a weekend without
/// waiting for one. The real `TradingCalendar` answers the same question from a 24/5 schedule.
contract SwitchableCalendar {
    bool public closed;                              // shut by the SCHEDULE: a weekend, a holiday
    bool public forcedShut;                          // shut by the owner's override, on what the schedule calls a live day
    function setClosed(bool c) external { closed = c; }
    function setForcedShut(bool c) external { forcedShut = c; }
    function isClosed(uint256) external view returns (bool) { return closed || forcedShut; }
    function isScheduledClosure(uint256) external view returns (bool) { return closed && !forcedShut; }
    function tradingDate(uint256 ts) external pure returns (uint256) { return ts / 1 days; }
}

contract AlwaysOpen {
    function isClosed(uint256) external pure returns (bool) { return false; }
    function isScheduledClosure(uint256) external pure returns (bool) { return false; }
    function tradingDate(uint256 ts) external pure returns (uint256) { return ts / 1 days; }
}
