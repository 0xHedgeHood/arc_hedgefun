// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IUniswapV3Pool, IUniswapV3Factory} from "../../src/interfaces/IUniswapV3.sol";
import {ITradingCalendar} from "../../src/interfaces/ITradingCalendar.sol";

/// @notice Testnet crypto session: open every day, with an explicit operator halt.
/// @dev Engine turnover uses UTC days. This is separate from the stock market's NYSE calendar.
contract TestnetCryptoCalendar is Ownable2Step, ITradingCalendar {
    bool public halted;
    event HaltedSet(bool halted);

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setHalted(bool value) external onlyOwner { halted = value; emit HaltedSet(value); }
    function isClosed(uint256) external view returns (bool) { return halted; }
    function isScheduledClosure(uint256) external pure returns (bool) { return false; }
    function tradingDate(uint256 timestamp) external pure returns (uint256) { return timestamp / 1 days; }
}

interface ICryptoV3Pool is IUniswapV3Pool {
    function factory() external view returns (address);
    function liquidity() external view returns (uint128);
}

/// @notice Canonical WETH/tUSDG 600-second arithmetic-mean tick oracle, with the PriceOracle read ABI.
/// @dev No stock feed or spot fallback. The operator may halt this separate UTC crypto calendar.
/// Pool initialization, a live 720-slot ring and a full window must precede listing activation.
contract TestnetCryptoOracle {
    uint256 public constant version = 2;
    uint32 public constant twapSeconds = 600;
    address public immutable stock;
    address public immutable usdg;
    ICryptoV3Pool public immutable pool;
    address public immutable v3Factory;
    ITradingCalendar public immutable calendar;
    uint128 public immutable minLiquidity;
    bool public immutable stockIsToken0;

    error BadConfig();
    error Unhealthy();

    constructor(address stock_, address usdg_, address pool_, address calendar_, uint128 minimumLiquidity) {
        if (stock_.code.length == 0 || usdg_.code.length == 0 || pool_.code.length == 0
            || calendar_.code.length == 0 || stock_ == usdg_ || minimumLiquidity == 0
            || IERC20Metadata(stock_).decimals() != 18 || IERC20Metadata(usdg_).decimals() != 6) revert BadConfig();
        ICryptoV3Pool candidate = ICryptoV3Pool(pool_);
        address factory = candidate.factory();
        address a = candidate.token0(); address b = candidate.token1();
        if (factory.code.length == 0 || candidate.fee() != 500
            || !((a == stock_ && b == usdg_) || (a == usdg_ && b == stock_))
            || IUniswapV3Factory(factory).getPool(stock_, usdg_, 500) != pool_) revert BadConfig();
        stock = stock_; usdg = usdg_; pool = candidate; v3Factory = factory;
        calendar = ITradingCalendar(calendar_); minLiquidity = minimumLiquidity; stockIsToken0 = a == stock_;
    }

    function tryPrice() public view returns (bool ok, uint256 p) {
        try calendar.isClosed(block.timestamp) returns (bool closed) { if (closed) return (false, 0); }
        catch { return (false, 0); }
        try pool.liquidity() returns (uint128 active) { if (active < minLiquidity) return (false, 0); }
        catch { return (false, 0); }
        try pool.slot0() returns (uint160, int24, uint16, uint16 cardinality, uint16 next, uint8, bool unlocked) {
            if (cardinality < 720 || next < 720 || !unlocked) return (false, 0);
        } catch { return (false, 0); }
        uint32[] memory ago = new uint32[](2); ago[0] = twapSeconds;
        try pool.observe(ago) returns (int56[] memory ticks, uint160[] memory secondsPerLiquidity) {
            if (ticks.length != 2 || secondsPerLiquidity.length != 2) return (false, 0);
            int256 delta = int256(ticks[1]) - int256(ticks[0]);
            int256 mean = delta / int256(uint256(twapSeconds));
            // Solidity rounds toward zero; the Uniswap arithmetic mean must round negative ticks down.
            if (delta < 0 && delta % int256(uint256(twapSeconds)) != 0) --mean;
            if (mean < TickMath.MIN_TICK || mean > TickMath.MAX_TICK) return (false, 0);
            p = _priceAtTick(int24(mean));
            return p == 0 ? (false, uint256(0)) : (true, p);
        } catch { return (false, 0); }
    }

    /// @dev The timestamp identifies this validated TWAP read, not a manual feed print.
    function lastPriceAt() external view returns (bool ok, uint256 p, uint256 updatedAt) {
        (ok, p) = tryPrice(); return (ok, p, ok ? block.timestamp : 0);
    }

    function price() external view returns (uint256 p) {
        bool ok; (ok, p) = tryPrice(); if (!ok) revert Unhealthy();
    }

    function _priceAtTick(int24 tick) private view returns (uint256) {
        uint256 sqrt = TickMath.getSqrtPriceAtTick(tick);
        // 18 stock decimals / 6 quote decimals: quote raw ratio is scaled by 1e30 for priceE18.
        // These two branches bound the squared ratio and the final result below uint256 at every valid tick.
        if (sqrt <= type(uint128).max) {
            uint256 ratioX192 = sqrt * sqrt;
            return stockIsToken0 ? Math.mulDiv(ratioX192, 1e30, 1 << 192) : Math.mulDiv(1 << 192, 1e30, ratioX192);
        }
        uint256 ratioX128 = Math.mulDiv(sqrt, sqrt, 1 << 64);
        return stockIsToken0 ? Math.mulDiv(ratioX128, 1e30, 1 << 128) : Math.mulDiv(1 << 128, 1e30, ratioX128);
    }
}
