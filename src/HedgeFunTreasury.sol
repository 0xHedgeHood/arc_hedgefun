// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";
import {HedgeFunMath, BPS} from "./libraries/HedgeFunMath.sol";
import {MAX_BUYBACK_IMPACT_BPS} from "./libraries/HedgeFunLimits.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolTrader} from "./PoolTrader.sol";
import {PriceOracle} from "./PriceOracle.sol";
import {HedgeFunTreasuryBase} from "./HedgeFunTreasuryBase.sol";

/// The treasury of a strategy token: it holds one stock, trades it against USDG through a Uniswap V3 pool under a
/// published rule, and spends what it earns buying its own token back and burning it. No keeper, no parameters
/// that can change: every function of the rule is permissionless, and the caller chooses nothing but which lot to
/// look at. The factory's owner has exactly one call here, `setVoteDelegate` -- where the stock's votes point,
/// should the stock ever carry any -- and it reaches no asset, no allowance and no part of the rule.
///
/// The rule, the lot bookkeeping and the buyback live in `HedgeFunTreasuryBase`. This contract implements what the
/// base leaves virtual: `health()` and `pricedOffPoolOnly()` (oracle plus this pool's own spot AND 10-minute TWAP,
/// via `PoolTrader`; the band on a scheduled closure) and `_swapStock()` (a bounded V3 swap, via
/// `PoolTrader._swapBounded`, which may fill short in either direction -- the base sizes every effect from what
/// the pool actually took).

contract HedgeFunTreasury is PoolTrader, HedgeFunTreasuryBase {
    /// @dev `SCALE` is recomputed here rather than passed as `PoolTrader.SCALE`: base-contract constructor
    ///      arguments are evaluated in linearized order, not textual order, so another base's immutable can still
    ///      read as its zero default at this point, and the base would divide by zero.
    constructor(address usdg_, address stock_, address v3Pool_, address oracle_, address token_, address poolManager_, address factory_, Params memory p)
        PoolTrader(usdg_, stock_, v3Pool_, oracle_)
        HedgeFunTreasuryBase(usdg_, stock_, token_, poolManager_, factory_, oracle_,
            1e18 * 10 ** uint256(IERC20Metadata(stock_).decimals()) / 10 ** uint256(IERC20Metadata(usdg_).decimals()), p)
    {
        if (token_ == address(0) || poolManager_ == address(0) || factory_ == address(0)) revert BadConfig();
        if (p.tp1Bps == 0 || (p.tp2Bps != 0 && p.tp2Bps <= p.tp1Bps) || p.dipBps == 0 || p.dipBps >= BPS || p.stopBps >= BPS) revert BadConfig();
        if (p.lotBps == 0 || p.lotBps > BPS || p.bountyBps > MAX_BOUNTY_BPS || p.bandBpsPerHour > MAX_BAND_BPS_PER_HOUR) revert BadConfig();
        if (p.maxSlippageBps == 0 || p.maxSlippageBps > MAX_SLIPPAGE_BPS || p.maxDeviationBps == 0 || p.maxDeviationBps >= p.maxSlippageBps) revert BadConfig();
        if (p.maxBuybackImpactBps == 0 || p.maxBuybackImpactBps > MAX_BUYBACK_IMPACT_BPS || p.minLotUsdg == 0 || p.buybackChunkUsdg == 0 || p.sellChunkUsdg == 0) revert BadConfig();
        // the rule must clear its own execution cost, twice over: a take-profit smaller than slippage-plus-fee "sells
        // above cost" yet returns less than it paid, and with dip and tp1 both inside that margin the whole treasury
        // flips on every Chainlink print for whoever sandwiches it
        if (p.tp1Bps < 2 * (p.maxSlippageBps + poolFeeBps) || p.dipBps < 2 * (p.maxSlippageBps + poolFeeBps)) revert BadConfig();
    }

    /// The widest the band may ever get, however stale the feed. Past this, "the pool is broken" is likelier than
    /// "the market repriced", and the rule parks. A circuit breaker, not a filter on gaps: gaps are the point.
    uint256 public constant MAX_BAND_BPS = 3000;

    /// @notice the rule's price, and whether it may be used at all.
    ///
    /// Chainlink is trusted in proportion to its freshness. The equity feeds print on a 0.5% move while the
    /// exchange trades and then go quiet, while the pool keeps trading; the gap between pool and feed is much wider
    /// when the feed is quiet, so one fixed gate is either shut then or loose in the cash session.
    ///
    /// With `bandBpsPerHour == 0` nothing below applies: the price is Chainlink's, corroborated by spot and the
    /// 600-second mean inside `maxDeviationBps`, and the rule sleeps whenever the feed does.
    ///
    /// Otherwise, and ONLY on a scheduled closure, the pool's 600-second mean may pull the price off the feed, inside
    /// a BAND that widens with the feed's age and with nothing else:
    ///
    ///     band = maxDeviationBps + bandBpsPerHour * feedAgeHours,   capped at MAX_BAND_BPS
    ///
    ///   - within `maxDeviationBps` the two agree and the price IS the feed. Holding the pool a few bps off buys
    ///     nothing.
    ///   - between there and the band, the price follows the pool one-for-one PAST the agreement zone, so it is
    ///     continuous and the most the pool can move it is `bandBpsPerHour * feedAgeHours`.
    ///   - outside the band the rule refuses.
    ///
    /// The band keys off TIME because time is the one input nobody can buy. A gate that widened to fit the gap it
    /// saw would be opened by pushing the pool.
    ///
    /// What it does NOT close: after a REAL gap, whoever holds the pool for one window can pin the mean
    /// anywhere inside the band, so a trigger within `bandBpsPerHour * age` of the stale feed can be fired at the
    /// pin while the real price is further on. The band bounds which triggers are reachable, not the loss on one
    /// that is; that depends on the treasury's size against the pool's depth. Hence a creator's published choice
    /// under a factory ceiling, not a default.
    ///
    /// Required whatever the band: `oraclePaused()` false; a fresh USDG feed; spot within `maxDeviationBps` of the
    /// mean, so an atomic shove never becomes the price; a ring that serves the window; and a closure the calendar
    /// SCHEDULES and the owner left alone. While the market is open the band does not exist -- a feed that prints on
    /// 0.5% and has not printed is evidence, not silence -- and a day the owner forced shut trades nothing at all.
    function health() public view virtual override returns (bool ok, uint256 p) { (ok, p,) = _priced(); }

    /// @inheritdoc HedgeFunTreasuryBase
    /// @dev true exactly when the pool has pulled the served price off the feed. `stopLoss` and `book` therefore
    ///      only ever act on a number Chainlink signed -- stale, perhaps, but anything due at a stale print was
    ///      already due when it was fresh, so pinning the pool ONTO the feed fires nothing new.
    function pricedOffPoolOnly() public view override returns (bool pulled) { (,, pulled) = _priced(); }

    function _priced() internal view returns (bool, uint256, bool) {
        // The plain gate first, whatever the band: spot against Chainlink, spot against the mean. A band only ever
        // ADDS to when the rule may act; going straight to mean-vs-feed would shut the gate more often, because in a
        // fast market the 600-second mean lags further than the feed.
        (bool ok0, uint256 p0) = _health(_params.maxDeviationBps);
        if (ok0 || _params.bandBpsPerHour == 0) return (ok0, p0, false);
        (bool fresh, uint256 feed, uint256 age) = _feed();
        if (!fresh) return (false, p0, false);                                   // no band applies: report what `_health` judged against

        uint256 band = Math.min(uint256(_params.maxDeviationBps) + uint256(_params.bandBpsPerHour) * age / 1 hours, MAX_BAND_BPS);
        uint256 mean = _guardedPoolPrice(feed, band);
        if (mean == 0) return (false, feed, false);
        uint256 dev = _priceGap(mean, feed);

        uint256 agree = HedgeFunMath.bps(feed, _params.maxDeviationBps);
        if (dev <= agree) return (true, feed, false);
        return (true, mean > feed ? mean - agree : mean + agree, true);
    }

    /// @dev A complete TWAP window, spot/mean agreement and a bounded departure from the last stock feed.
    function _guardedPoolPrice(uint256 feed, uint256 band) internal view returns (uint256 mean) {
        mean = twapPrice();
        if (mean == 0) return 0;
        uint256 s = spotPrice();
        if (HedgeFunMath.exceeds(_priceGap(s, mean), mean, _params.maxDeviationBps)
            || HedgeFunMath.exceeds(_priceGap(mean, feed), feed, band)) return 0;
    }

    function _priceGap(uint256 a, uint256 b) private pure returns (uint256) { return a > b ? a - b : b - a; }

    /// @dev the feed's last value and the stock leg's age, or nothing.
    function _feed() internal view returns (bool, uint256, uint256) {
        PriceOracle o = PriceOracle(address(_oracle));
        try IStockToken(address(_stock)).oraclePaused() returns (bool paused) {
            if (paused) return (false, 0, 0);
        } catch { return (false, 0, 0); }
        (bool ok, uint256 feed, uint256 at) = o.lastPriceAt();
        if (!ok) return (false, 0, 0);
        uint256 age = block.timestamp - at;
        // The band exists ONLY on a closure the calendar schedules and the owner left alone. While the market is open
        // these feeds print on any 0.5% move, so a quiet feed is not uncertainty -- it is evidence the price has not
        // moved (or the oracle network is down, and then the pool is no witness either). Widening with age on an open
        // day would hand a 600-second pin a wide band against a feed whose true price is inside 0.5%. Open days get
        // `_health` and nothing else; a day the owner forced shut gets nothing at all.
        try o.calendar().isScheduledClosure(block.timestamp) returns (bool scheduled) {
            if (!scheduled) return (false, 0, 0);
        } catch { return (false, 0, 0); }
        return (true, feed, age);
    }

    /// @dev may fill short in BOTH directions: the pool stops at the oracle-derived limit and `_swapBounded`
    ///      reports what it took, which is all the swap callback ever paid (a V3 pool asks for the input it consumed,
    ///      not the input it was offered). Its average-price check is already on `spent`, so a short fill is held to
    ///      the same slippage-plus-fee floor a full one is; and `PoolTrader._swap` reverts `Slippage` when nothing
    ///      went in or nothing came out, which is the base's "a sale that moves nothing reverts".
    function _swapStock(bool buy, uint256 amountIn, uint256 p) internal override returns (uint256 spent, uint256 got) {
        return _swapBounded(buy, amountIn, p, _params.maxSlippageBps);
    }

    /// @dev the only unlock consumer here is the buyback (kind 2) -- the stock<->USDG leg is a direct V3 pool
    ///      swap via `uniswapV3SwapCallback`, not routed through `poolManager`.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager) || _swapKind != 2) revert NotPoolManager();
        (uint256 spent, uint256 got) = _swapTokenPool(abi.decode(data, (uint256)));
        return abi.encode(spent, got);
    }
}
