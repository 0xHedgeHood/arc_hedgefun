// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {ITradingCalendar} from "./interfaces/ITradingCalendar.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";


/// Price of one stock token in USDG, 1e18-scaled, in human units (USDG per whole token): stock feed / USDG feed.
///
/// The Robinhood equity feeds ("RHNVDA / USD") already include the token's uiMultiplier(), so the answer prices one
/// TOKEN, not one share, and is continuous across corporate actions. Never multiply by the multiplier again.
///
/// The feeds are 24/5 with a 0.5% deviation trigger and a 24h heartbeat, and latestRoundData() keeps returning the
/// last value across a weekend, so a price is only served when ALL of these hold; anything else fails closed:
///   - the on-chain trading calendar says the market is open,
///   - the token's oraclePaused() is false (set while a corporate action is processed),
///   - both rounds are positive, not from the future, and no older than their max age.
/// There is no L2 sequencer uptime feed on this chain, so updatedAt is the only liveness signal there is.
contract PriceOracle {
    /// the oldest stock print a listing may accept: 72h would serve Friday's close at Sunday's open
    uint256 internal constant MAX_STOCK_AGE = 48 hours;

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
        require(stock_ != address(0) && stockFeed_ != address(0) && usdgFeed_ != address(0) && calendar_ != address(0), "zero");
        require(maxStockAge_ != 0 && maxStockAge_ <= MAX_STOCK_AGE && maxUsdgAge_ != 0, "age");   // 72h would serve Friday's close at Sunday's open
        stock = stock_; stockFeed = IAggregatorV3(stockFeed_); usdgFeed = IAggregatorV3(usdgFeed_); calendar = ITradingCalendar(calendar_);
        maxStockAge = maxStockAge_; maxUsdgAge = maxUsdgAge_;
        _num = 1e18 * 10 ** uint256(IAggregatorV3(usdgFeed_).decimals());
        _den = 10 ** uint256(IAggregatorV3(stockFeed_).decimals());
    }

    /// @return ok false whenever the price must not be used; p is 0 then
    function tryPrice() public view returns (bool ok, uint256 p) {
        try calendar.isClosed(block.timestamp) returns (bool closed) { if (closed) return (false, 0); } catch { return (false, 0); }
        try IStockToken(stock).oraclePaused() returns (bool paused) { if (paused) return (false, 0); } catch { return (false, 0); }
        (bool okS, uint256 s) = _read(stockFeed, maxStockAge);
        (bool okU, uint256 u) = _read(usdgFeed, maxUsdgAge);
        if (!okS || !okU) return (false, 0);
        p = Math.mulDiv(s, _num, u * _den);
        return (p != 0, p);
    }

    /// @notice the same price, WITHOUT the calendar and age gates: what the feeds are saying right now, however
    ///         old that is. Across a weekend the equity feeds stop updating and keep returning Friday's close, so
    ///         this is that close -- a number Chainlink did sign off on, just not recently.
    /// @dev Never a price to TRADE at on its own: `tryPrice` is what answers that question, and it fails closed.
    ///      This exists so a caller can ask "how far has the pool moved since the market shut", which needs the
    ///      frozen number AND its age. The round sanity checks still apply, so a feed answering zero or from the
    ///      future gets no answer at all.
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
