// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {ITradingCalendar} from "./interfaces/ITradingCalendar.sol";

/// Price of one whole crypto asset in USDG, 1e18-scaled, in human units: asset feed / USDG feed. The same read ABI
/// as `PriceOracle` (`stock`, `calendar`, `tryPrice`, `lastPriceAt`, `price`), so a listing and its treasuries
/// cannot tell the two apart.
///
/// What differs from `PriceOracle` is only what a crypto asset lacks: there is no `oraclePaused()` to ask (cirBTC
/// and WETH have none, and `PriceOracle` would fail closed on them forever), and the session is a `CryptoCalendar`,
/// open every day unless halted. A price is served only when ALL of these hold; anything else fails closed:
///   - the calendar is not halted,
///   - both rounds are positive, not from the future, and no older than their max age.
/// Arc is a BFT L1 with no sequencer uptime feed, so updatedAt is the only liveness signal there is.
contract CryptoPriceOracle {
    /// the oldest print a listing may accept: one 24h heartbeat plus two hours of grace
    uint256 internal constant MAX_FEED_AGE = 26 hours;

    IAggregatorV3 public immutable stockFeed;
    IAggregatorV3 public immutable usdgFeed;
    ITradingCalendar public immutable calendar;
    address public immutable stock;
    uint256 public immutable maxStockAge;
    uint256 public immutable maxUsdgAge;
    uint256 internal immutable _num;   // 1e18 * 10^usdgFeedDecimals
    uint256 internal immutable _den;   // 10^stockFeedDecimals

    error Unhealthy();

    constructor(address stock_, address stockFeed_, address usdgFeed_, address calendar_, uint256 maxStockAge_, uint256 maxUsdgAge_) {
        require(stock_.code.length != 0 && stockFeed_.code.length != 0 && usdgFeed_.code.length != 0
            && calendar_.code.length != 0, "code");
        require(maxStockAge_ != 0 && maxStockAge_ <= MAX_FEED_AGE && maxUsdgAge_ != 0 && maxUsdgAge_ <= MAX_FEED_AGE, "age");
        stock = stock_; stockFeed = IAggregatorV3(stockFeed_); usdgFeed = IAggregatorV3(usdgFeed_); calendar = ITradingCalendar(calendar_);
        maxStockAge = maxStockAge_; maxUsdgAge = maxUsdgAge_;
        _num = 1e18 * 10 ** uint256(IAggregatorV3(usdgFeed_).decimals());
        _den = 10 ** uint256(IAggregatorV3(stockFeed_).decimals());
    }

    /// @return ok false whenever the price must not be used; p is 0 then
    function tryPrice() public view returns (bool ok, uint256 p) {
        try calendar.isClosed(block.timestamp) returns (bool closed) { if (closed) return (false, 0); } catch { return (false, 0); }
        (bool okS, uint256 s) = _read(stockFeed, maxStockAge);
        (bool okU, uint256 u) = _read(usdgFeed, maxUsdgAge);
        if (!okS || !okU) return (false, 0);
        p = Math.mulDiv(s, _num, u * _den);
        return (p != 0, p);
    }

    /// @notice the same price without the calendar and age gates, and the asset leg's age. The treasuries ask for it
    ///         only on a scheduled closure, which a `CryptoCalendar` never has; it is here for the shared ABI.
    function lastPriceAt() external view returns (bool ok, uint256 p, uint256 stockUpdatedAt) {
        (bool okU, uint256 u) = _read(usdgFeed, maxUsdgAge);                    // the dollar leg never gets to be stale
        if (!okU) return (false, 0, 0);
        try stockFeed.latestRoundData() returns (uint80, int256 s, uint256, uint256 su, uint80) {
            if (s <= 0 || su == 0 || su > block.timestamp) return (false, 0, 0);
            p = Math.mulDiv(uint256(s), _num, u * _den);
            return (p != 0, p, su);
        } catch { return (false, 0, 0); }
    }

    function price() external view returns (uint256 p) {
        bool ok; (ok, p) = tryPrice();
        if (!ok) revert Unhealthy();
    }

    function _read(IAggregatorV3 feed, uint256 maxAge) internal view returns (bool, uint256) {
        try feed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) return (false, 0);
            return (true, uint256(answer));
        } catch { return (false, 0); }
    }
}
