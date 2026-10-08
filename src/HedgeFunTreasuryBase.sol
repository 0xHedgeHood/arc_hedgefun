// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PriceOracle} from "./PriceOracle.sol";
import {HedgeFunMath} from "./libraries/HedgeFunMath.sol";
import {IOwned} from "./interfaces/IOwned.sol";
import {IHedgeFunToken} from "./interfaces/IHedgeFunToken.sol";
import {IHedgeFunHook} from "./interfaces/IHedgeFunHook.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";
import "./libraries/HedgeFunLimits.sol" as Limits;


/// Everything a strategy's treasury does that does NOT depend on where the stock<->USDG leg trades: the per-lot rule
/// (book/takeProfit/stopLoss/buyDip), and the buy-back-and-burn (against the launch's own V4 pool). `HedgeFunTreasury`
/// (stock<->USDG on a V3 pool, via `PoolTrader`) implements `health()`, `pricedOffPoolOnly()` and `_swapStock()` and
/// inherits everything else from here. This is a base contract rather than a library because the shared part owns
/// storage (the lots) and makes external calls (the swaps).
///
/// `HedgeFunTreasury` also inherits `PoolTrader` for its V3 execution, which is why this base keeps its OWN copies of
/// `stock`/`usdg`/`oracle`/the unit-conversion scale (as `_stock`/`_usdg`/`_oracle`/`_SCALE`, `_ruleValue`/
/// `_ruleStockFor`) instead of the identically-named ones `PoolTrader` provides: two unrelated base contracts
/// declaring the same non-virtual name is a compile error the moment `HedgeFunTreasury` inherits both.
///
/// The invariant the ledger rests on: it moves by what the pool ACTUALLY took, never by what it was offered. A swap
/// that meets its price limit fills short without reverting, so a sale swaps first and shrinks the lot by what sold,
/// and `buyDip` books what it bought. Either direction may fill short.
///
/// The rule. Stock arrives as sell-tax from the hook and is booked as a lot at the oracle price of that moment; a dip
/// purchase is a lot at what it cost. Then, for each lot on its own:
///   takeProfit   price >= cost * (1 + tp1): sell half (or all of it, if tp2 is 0); >= cost * (1 + tp2): the rest
///   stopLoss     optional and off by default: price <= cost * (1 - stop) sells the lot, and burns nothing
///                (both sell at most `sellChunkUsdg` per call: a lot the pool cannot take in one sale leaves in several)
///   buyDip       price <= lastSale * (1 - dip): spend lotBps of the USDG reserve on a new lot
/// A lot is never sold below its own cost unless a stop is configured, so realised profit cannot go negative.
///
/// Only the PRINCIPAL of a sale becomes USDG (the reserve the next dip buys with). The PROFIT stays in stock,
/// because the launch's pool is <token>/<stock>: `buyback()` swaps it for the token there, in chunks, behind a
/// cooldown and a price-impact limit off the pool's own spot, and burns what it gets.
///
/// What holders do NOT have: any claim on this treasury. The token has no redemption and no floor.
abstract contract HedgeFunTreasuryBase is ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    struct Params {
        uint32 tp1Bps;                 // first take-profit, over the lot's own cost
        uint32 tp2Bps;                 // second; 0 = sell the whole lot at tp1
        uint16 dipBps;                 // re-entry, below the last sale
        uint16 stopBps;                // 0 = never sell a lot at a loss
        uint16 lotBps;                 // share of the USDG reserve spent per dip
        uint16 bountyBps;              // to whoever calls, out of what the call produced
        uint16 maxSlippageBps;
        uint16 maxDeviationBps;
        uint16 maxBuybackImpactBps;    // how far one buy-back chunk may move the token's pool
        uint32 buybackCooldown;
        uint256 minLotUsdg;
        uint256 buybackChunkUsdg;
        /// the most one `takeProfit` or `stopLoss` call OFFERS the pool, in USDG at the rule's price. It is a knob for
        /// execution quality, not for safety: a sale fills as far as `maxSlippageBps` under the oracle lets it and the
        /// rest stays in the lot, so a chunk too big for the pool cannot block a sale. What an oversized chunk costs is
        /// price -- each call may walk the pool to the limit -- so it is sized per listing from pool depth. Frozen at
        /// birth.
        uint256 sellChunkUsdg;
        /// how fast a STALE Chainlink feed lets the V3 pool's own mean pull the rule's price, in bps per hour of
        /// feed age. 0 = Chainlink only: the rule sleeps whenever the feed does. Chosen by the creator under the
        /// factory's ceiling and frozen at birth -- see `HedgeFunTreasury.health` for the rule and for what it
        /// does NOT close: after a REAL gap, whoever holds the pool for one TWAP window picks the rule's price
        /// anywhere inside the band. The band bounds which triggers are reachable, `bandBpsPerHour * age`
        /// from the feed; it does not bound the loss on a lot that is reached, which is the real price minus the
        /// pin. That is a function of pool depth against treasury size, and it is why this is a disclosed choice
        /// and not a default.
        uint16 bandBpsPerHour;
    }

    /// `tp1Left` is what the first take-profit still has to sell: half of the quantity the lot held when tp1 FIRST
    /// fired, worked off one chunk per call. Zero before tp1 has fired and again once it is done (`half`), so a lot
    /// that is mid-way is exactly one with `tp1Left != 0`.
    struct Lot { uint256 qty; uint256 cost; bool half; uint256 tp1Left; }

    /// the window the buy-back prices itself over. Matches `PoolTrader.TWAP_WINDOW`, and the hook's 1024-slot
    /// ring covers it with room for a griefer writing one observation a second.
    uint32 public constant BUYBACK_TWAP_WINDOW = 600;

    /// Legacy sizing-cache age limit. Retained in the V2 ABI; V2 uses guarded pool TWAP instead of this cache.
    uint256 public constant MAX_SIZING_AGE = 5 days;

    uint256 public constant MAX_BOUNTY_BPS = Limits.MAX_BOUNTY_BPS;
    uint256 public constant MAX_SLIPPAGE_BPS = Limits.MAX_SLIPPAGE_BPS;
    uint256 public constant MAX_BAND_BPS_PER_HOUR = Limits.MAX_BAND_BPS_PER_HOUR;

    IERC20 internal immutable _stock;
    IERC20 internal immutable _usdg;
    PriceOracle internal immutable _oracle;
    uint256 internal immutable _SCALE;         // 1e18 * 10^stockDecimals / 10^usdgDecimals
    uint256 internal immutable _DUST_VALUE_LIMIT; // one hundredth of a USDG, in its raw units

    IERC20 public immutable token;
    IPoolManager public immutable poolManager;
    address public immutable factory;
    /// @dev internal with a hand-written getter: with fourteen fields the auto-getter of a `public` struct is one slot
    ///      past the stack. `params()` returns the struct, which the ABI encodes as the same words in the same order
    ///      an auto-getter would return -- `bandBpsPerHour` last.
    Params internal _params;
    function params() external view returns (Params memory) { return _params; }

    PoolKey public poolKey;                    // the <token>/<stock> V4 pool, wired once by the factory
    address public hook;
    bool public stockIsCurrency0InTokenPool;

    Lot[] public lots;
    uint256 public bookedStock;                // held in lots
    uint256 public buybackStock;                  // realised profit, waiting to buy the token back
    uint256 public lastSalePrice;
    /// when a take-profit last sold at a price only the pool vouched for; see `_poolOnlyPace`
    uint256 public lastPoolOnlySaleAt;
    uint256 public constant POOL_ONLY_SALE_INTERVAL = 1 hours;
    /// however long since the last buy-back, its price limit never drifts further than this from the anchor
    uint256 internal constant MAX_DRIFT_BPS = 9000;
    uint256 public lastBuybackAt;
    /// the most favourable token-pool price the treasury has observed, and when. The launch token has no oracle,
    /// so this is the only reference for "is the pool where we left it" that an attacker cannot simply set. It
    /// RATCHETS: an observation cheaper than the anchor replaces it, a dearer one never does. See `_swapTokenPool`.
    uint160 public buybackAnchorSqrtP;
    uint256 public buybackAnchorAt;
    uint256 public totalBurned;

    /// the last live stock-oracle price used by a successful rule action, and when. Stock trades use it as their
    /// gate; a buy-back uses it only to size its chunk, then executes against the token pool's own TWAP/anchor bound.
    /// The equity feeds here are 24/5: across a weekend they stop updating entirely and `tryPrice()` answers false
    /// for ~65 hours. Everything that TRADES the stock must refuse then -- a stale feed is not evidence about its
    /// pool. The buy-back is the exception because the TOKEN pool never closes. See `buyback`.
    uint256 public lastGoodPrice;
    uint256 public lastGoodPriceAt;

    /// Write-only history, for judging the rule rather than running it. Nothing in this contract reads these two, so
    /// an error in one cannot block a path. The launch pool prices the token IN the stock, so the measure is in stock:
    ///
    ///     (stockEquivalentHeld() + totalStockSpentOnBuybacks) / totalStockReceived
    ///
    /// is 1.0 if the rule earned nothing over holding the stock it was handed, and above 1.0 if it earned stock.
    /// Deliberately NOT a NAV per token: there is no redemption, so a per-token asset value would describe a claim
    /// that does not exist. What a holder gets is `totalBurned` against the supply.
    uint256 public totalStockReceived;            // distinct incoming stock booked into lots, excluding rebooked dust
    uint256 public totalStockSpentOnBuybacks;     // spent buying the token back, before the caller's bounty
    /// @dev Previously received principal released from an uneconomic lot. It remains in the treasury's
    ///      unbooked balance and must not be counted a second time when a later donation makes booking viable.
    uint256 internal _releasedDustStock;

    // 2 while the buy-back's swap is in flight, else 0: the only `unlock` this treasury ever opens, so a callback at
    // any other moment is refused.
    uint8 internal _swapKind;

    event LotBooked(uint256 indexed id, uint256 qty, uint256 cost, bool fromTax);
    event ProfitTaken(uint256 qty, uint256 cost, uint256 price, uint256 usdgToReserve, uint256 stockToBurn);
    event Stopped(uint256 qty, uint256 cost, uint256 price);
    event StopDustReleased(uint256 indexed id, uint256 qty, uint256 cost, uint256 price);
    event Buyback(uint256 stockSpent, uint256 tokenBurned);
    event VoteDelegateSet(address indexed by, address indexed delegatee, bool accepted);

    error BadPair();
    error NotFactory();
    error AlreadyWired();
    error Unhealthy();
    error NotDue();
    error Cooldown();
    error NotPoolManager();
    error NotOwner();

    /// @dev takes already-validated values -- `HedgeFunTreasury` validates its own constructor arguments
    ///      (including `p`), so every such check reverts with its `BadConfig`.
    constructor(address usdg_, address stock_, address token_, address poolManager_, address factory_, address oracle_, uint256 scale_, Params memory p) {
        _usdg = IERC20(usdg_); _stock = IERC20(stock_); token = IERC20(token_);
        poolManager = IPoolManager(poolManager_); factory = factory_; _oracle = PriceOracle(oracle_); _SCALE = scale_;
        _DUST_VALUE_LIMIT = Math.max(1, 10 ** uint256(IERC20Metadata(usdg_).decimals()) / 100);
        _params = p;
    }

    /// @notice the factory tells the treasury which V4 pool its token trades in. Once.
    function wire(PoolKey calldata key) public virtual {
        if (msg.sender != factory) revert NotFactory();
        if (hook != address(0)) revert AlreadyWired();
        address c0 = Currency.unwrap(key.currency0); address c1 = Currency.unwrap(key.currency1);
        if (!((c0 == address(_stock) && c1 == address(token)) || (c0 == address(token) && c1 == address(_stock)))) revert BadPair();
        poolKey = key; hook = address(key.hooks); stockIsCurrency0InTokenPool = c0 == address(_stock);
    }

    // ------------------------------------------------------------------------------------------------ the vote, and nothing else
    /// @notice the factory's owner, read live: it follows an Ownable2Step handover. The factory disables ownership
    ///         renunciation so vote delegation remains available. The RULE never reads this.
    function owner() public view returns (address) { return IOwned(factory).owner(); }

    /// @notice point whatever votes the treasury's stock carries at `delegatee`. The ONLY thing the owner can do to a
    ///         launched treasury: one call, to one target fixed at birth (`stock`), with one selector.
    /// @dev If the stock token has no `delegate(address)`, the call fails, this emits `accepted = false` and nothing
    ///      else happens. It exists because the stock token is upgradeable by its issuer and a launched treasury is
    ///      not: a function that is not here at birth can never be added.
    ///
    ///      It keeps NO state of its own -- the token is the record (the one slot touched is the reentrancy guard's,
    ///      set and restored). It moves, approves, pledges and sells nothing, and it cannot reach the rule.
    ///      `nonReentrant` because the callee is that same upgradeable token: a `delegate` that calls back finds every
    ///      entry point shut. The call is contained -- a revert, or a `delegate` that burns all its gas, leaves
    ///      `accepted = false` and the 1/64 of gas the EVM holds back, which covers the event. No gas cap: the cost of
    ///      a checkpointing `delegate` is unknown, so any number frozen here could make the function useless for good;
    ///      uncapped, a gas bomb costs only the owner who chose to call. NOT defended: an upgrade that makes
    ///      `delegate(address)` itself approve-like. Whoever can do that can already `adminBurn` the treasury's
    ///      balance outright, so no check here would stand in its way.
    function setVoteDelegate(address delegatee) external nonReentrant {
        if (msg.sender != owner()) revert NotOwner();
        bool accepted;
        try IStockToken(address(_stock)).delegate(delegatee) { accepted = true; } catch {}
        emit VoteDelegateSet(msg.sender, delegatee, accepted);
    }

    // ------------------------------------------------------------------------------------------------ views
    function lotCount() external view returns (uint256) { return lots.length; }
    function reserveUsdg() public view returns (uint256) { return _usdg.balanceOf(address(this)); }
    function unbookedStock() public view returns (uint256) {
        uint256 b = _stock.balanceOf(address(this)); uint256 held = bookedStock + buybackStock;
        return b > held ? b - held : 0;
    }

    /// @notice everything the treasury holds, valued in the stock: booked and pending stock, profit waiting
    ///         to buy the token back, and USDG converted at the oracle. Returns unavailable while health is shut.
    /// @dev the ratio this feeds is deliberately left to the caller -- putting the division on chain would freeze
    ///      an assumption about how the USDG leg is priced into a contract that cannot be changed.
    function stockEquivalentHeld() external view returns (bool ok, uint256 stockAmount) {
        uint256 p;
        (ok, p) = health();
        if (!ok) return (false, 0);
        return (true, bookedStock + buybackStock + unbookedStock() + _ruleStockFor(reserveUsdg(), p));
    }

    function _notePrice(uint256 p) internal { lastGoodPrice = p; lastGoodPriceAt = block.timestamp; }

    function _ruleValue(uint256 stockAmount, uint256 p) internal view returns (uint256) { return Math.mulDiv(stockAmount, p, _SCALE); }
    function _ruleStockFor(uint256 usdgAmount, uint256 p) internal view returns (uint256) { return Math.mulDiv(usdgAmount, _SCALE, p); }

    /// @notice the rule's price, and whether it may be used at all: oracle healthy AND the stock pool's own spot and
    ///         10-minute mean within maxDeviationBps of it -- or, on a scheduled closure, the band. See
    ///         `HedgeFunTreasury.health`.
    function health() public view virtual returns (bool ok, uint256 p);

    /// @notice true when the price `health()` is serving comes from the pool alone, with no oracle behind it --
    ///         which on this chain means a scheduled market closure.
    /// @dev The rule is mean-reverting, so a WRONG price is mostly in the treasury's favour: a pool shoved up
    ///      lets `takeProfit` sell into the shover, a pool shoved down lets `buyDip` buy from them. Both take the
    ///      other side of the push. `stopLoss` is the exception and the reason this flag exists -- it is the only
    ///      call that sells INTO weakness, so a fake weekend crash would make it realise a loss that never
    ///      happened. It waits for the market to open instead.
    function pricedOffPoolOnly() public view virtual returns (bool);

    /// @dev Across a closure the price is the pool's, inside the band, and a pool can be pinned. Chunked sales can be
    ///      looped inside one transaction, so without a pace a pin could sell a whole lot at the pinned price. On that
    ///      path, and only there, one chunk per `POOL_ONLY_SALE_INTERVAL`. An open market is priced by Chainlink and is
    ///      not paced at all.
    function _poolOnlyPace() internal {
        if (!pricedOffPoolOnly()) return;
        if (block.timestamp < lastPoolOnlySaleAt + POOL_ONLY_SALE_INTERVAL) revert NotDue();
        lastPoolOnlySaleAt = block.timestamp;
    }

    /// @dev the stock<->USDG trade: an exact-input swap whose price limit is the oracle `maxSlippageBps` away, so the
    ///      pool computes its own depth -- it takes what fits inside the limit and returns the rest unspent. Both directions may fill short, and every caller sizes its effects from `spent`
    ///      and `got`. Two promises hold on whatever filled: no part of it past the limit (the marginal bound), and
    ///      the whole of it no worse than slippage-plus-fee on average (`Slippage` otherwise). A SALE that moves
    ///      nothing reverts `Slippage`: a swap through an empty book still drags the pool to its limit,
    ///      and a call that sold nothing must not leave that behind, spend the closed-market pace or pay anyone.
    function _swapStock(bool buy, uint256 amountIn, uint256 p) internal virtual returns (uint256 spent, uint256 got);

    // ------------------------------------------------------------------------------------------------ the rule
    /// @notice book whatever stock has arrived (sell-tax from the hook, or a gift) as a lot at the oracle price.
    ///         Out of hours there is no price to book it at, so it waits.
    /// @dev `nonReentrant` like every other entry point: the stock token is upgradeable and could come to call its
    ///      recipient on transfer. With the guard, a bounty receiver cannot re-enter here during a sale and have the
    ///      balance booked against a ledger that is mid-update.
    function book() public virtual nonReentrant returns (bool) { return _book(); }

    function _canAddLot() internal view virtual returns (bool) { return true; }

    function _book() internal returns (bool) {
        uint256 un = unbookedStock();
        if (un == 0 || !_canAddLot()) return false;
        (bool ok, uint256 p) = health();
        if (!ok || _ruleValue(un, p) < _params.minLotUsdg) return false;
        // A lot's cost is permanent -- and so is the dip reference the first one sets -- so neither is ever taken from
        // anything but a LIVE Chainlink print. Not from a price only the pool vouches for: a pool pinned high through
        // a closure would give the lot a cost its take-profit cannot reach. And not from a STALE print: while the
        // pool sits within the deviation gate of a frozen feed, `health()` answers with that feed, and a lot booked
        // there would plant an out-of-date dip reference. Out of hours it waits.
        { (bool live,) = _oracle.tryPrice(); if (!live) return false; }
        uint256 rebooked = Math.min(un, _releasedDustStock);
        _releasedDustStock -= rebooked;
        lots.push(Lot(un, p, false, 0)); bookedStock += un; totalStockReceived += un - rebooked;
        // The first lot is also where a dip is first measured from, so a treasury whose stock falls before it ever
        // rises can still `buyDip` with whatever USDG it holds (anyone may send it some). The booked price is a LIVE
        // oracle price -- see above -- and a sale or a dip buy replaces it.
        if (lastSalePrice == 0) lastSalePrice = p;
        _notePrice(p); _noteTokenSpot();
        emit LotBooked(lots.length - 1, un, p, true);
        return true;
    }

    /// @notice sell what is due on lot `id`, at most `sellChunkUsdg` of it per call. Call again for the rest.
    /// @dev No cooldown between chunks, and none is needed. Nothing fills below `oracle * (1 - maxSlippageBps)`,
    ///      which is an ABSOLUTE price and not one relative to where the pool stood when the call began -- and before
    ///      that `health()` must still find the pool inside `maxDeviationBps` of the oracle, which is the tighter of
    ///      the two by construction. So a caller who loops chunks inside one transaction walks the pool down until
    ///      `health()` refuses: the loop stops itself no lower than a single sale could ever have gone, and what has
    ///      not sold is still in the lot at its cost. (The buy-back needs its cooldown for the opposite reason: the
    ///      launch token has no oracle, so its limit is relative to the pool.)
    ///
    ///      Checks, then the swap, then every effect sized from what the pool actually took, then the bounty. The lot
    ///      is OFFERED `principal = q * cost / p`; the pool sells `sold <= principal`. A full fill gives up exactly
    ///      `q`. A short one gives up `sold * p / cost`, rounded down: never more than `q` (because
    ///      `sold < principal <= q * cost / p`) and never less than `sold` (because a take-profit is only due at
    ///      `p > cost`), so the profit share cannot go negative and what did not sell keeps its cost.
    function takeProfit(uint256 id) public virtual nonReentrant { _takeProfit(id); }

    function _takeProfit(uint256 id) internal virtual {
        (bool ok, uint256 p) = health();
        if (!ok) revert Unhealthy();
        _book();
        Lot storage L = lots[id];
        uint256 q = _ruleStockFor(_params.sellChunkUsdg, p);
        uint256 left;                                                           // what tp1 still owes; 0 = this is not tp1
        if (_params.tp2Bps != 0 && !L.half) {
            if (!HedgeFunMath.reached(p, L.cost, _params.tp1Bps)) revert NotDue();
            // half of what the lot held when tp1 FIRST fired, however many calls that takes. The condition above is
            // asked again on every one of them: a price that falls back leaves the remainder waiting, `half` unset.
            left = L.tp1Left;
            if (left == 0) left = L.qty / 2;
            // `left <= L.qty` always: tp1 gives up `q <= left` and the lot the same `q`, and a stop that shrinks the
            // lot clamps `tp1Left` to what is left of it, so what tp1 owes never outlives the stock.
            // A one-wei lot has no half to sell; selling nothing reverts in the pool and the lot would sit in tp1
            // for good. It moves on to tp2 instead, where all of it is due.
            if (left == 0) { L.half = true; return; }
            if (q > left) q = left;
        } else {
            if (!HedgeFunMath.reached(p, L.cost, _params.tp2Bps != 0 ? _params.tp2Bps : _params.tp1Bps)) revert NotDue();
            if (q > L.qty) q = L.qty;
        }
        uint256 cost = L.cost;
        _notePrice(p); _noteTokenSpot();

        // the principal becomes USDG for the next dip; the profit stays in stock to buy the token back with
        uint256 principal = Math.mulDiv(q, cost, p);
        // A principal worth less than one unit of USDG (the last wei of a lot, or the dust remainder of a chunked
        // one) is not swapped: the V3 pool refuses a sale that brings back nothing, and the remainder would never
        // leave the lot. It is treated as all profit.
        uint256 got;
        if (_ruleValue(principal, p) != 0) {
            _poolOnlyPace();                                                     // only a call that SELLS spends the closed-market hour
            uint256 sold;
            (sold, got) = _swapStock(false, principal, p);
            // the pool stopped at the limit: the lot gives up only what that much principal stands for (see above)
            if (sold != principal) { principal = sold; q = Math.mulDiv(sold, p, cost); }
        }
        // tp1 owes what it has not GIVEN UP, and is done only when that reaches nothing
        if (left != 0) { L.tp1Left = left - q; if (left == q) L.half = true; }
        _shrink(id, q);
        uint256 profit = q - principal;
        uint256 bounty = HedgeFunMath.bps(profit, _params.bountyBps);
        buybackStock += profit - bounty;
        lastSalePrice = p;
        emit ProfitTaken(q, cost, p, got, profit - bounty);
        _afterStockSale(p, principal, got);
        if (bounty != 0) _stock.safeTransfer(msg.sender, bounty);             // last: every effect is already written
    }

    function stopLoss(uint256 id) public virtual nonReentrant { _stopLoss(id); }

    /// @dev A residual worth less than one hundredth of a USDG is non-economic as an independent V3 sale.
    ///      USDG output can round down after fees while the minimum-output check rounds up. Retire only the
    ///      ENTIRE lot, leaving its unsold stock as unbooked principal. A later book may combine such tails.
    function _releaseStopDust(uint256 id, uint256 p) internal returns (bool) {
        Lot storage L = lots[id];
        uint256 q = Math.min(L.qty, _ruleStockFor(_params.sellChunkUsdg, p));
        if (q != L.qty || _ruleValue(q, p) >= _DUST_VALUE_LIMIT) return false;
        uint256 cost = L.cost;
        _shrink(id, q);
        _releasedDustStock += q;
        emit StopDustReleased(id, q, cost, p);
        return true;
    }

    function _stopLoss(uint256 id) internal returns (bool sold) {
        if (_params.stopBps == 0) revert NotDue();
        if (pricedOffPoolOnly()) revert NotDue();                               // see `pricedOffPoolOnly`
        (bool ok, uint256 p) = health();
        if (!ok) revert Unhealthy();
        Lot storage L = lots[id];
        if (!HedgeFunMath.fellTo(p, L.cost, _params.stopBps)) revert NotDue();
        if (_releaseStopDust(id, p)) return false;
        // in chunks, for the reason `takeProfit` gives -- and a stop is the sale most likely to meet a thin pool
        (uint256 q, uint256 cost) = (Math.min(L.qty, _ruleStockFor(_params.sellChunkUsdg, p)), L.cost);
        // A misconfigured chunk can be too small even when the whole lot is not dust. Do not shrink it or
        // advance the sale reference without receiving USDG.
        if (_ruleValue(q, p) == 0) revert NotDue();
        _notePrice(p); _noteTokenSpot();
        uint256 got;
        // `q` becomes what the pool actually took, and the lot, the event and the bounty below are all sized
        // from that: what did not sell is still in the lot, at its cost.
        (q, got) = _swapStock(false, q, p);
        if (q != L.qty && L.tp1Left > L.qty - q) L.tp1Left = L.qty - q;         // what tp1 still owes cannot outlive the stock
        _shrink(id, q);
        // out of the proceeds, because a stop has no profit to pay from. Without a bounty the only loss-limiting
        // function in the rule would be the only one nobody is paid to call.
        uint256 bounty = HedgeFunMath.bps(got, _params.bountyBps);
        lastSalePrice = p;
        emit Stopped(q, cost, p);
        _afterStockSale(p, q, got);
        if (bounty != 0) _usdg.safeTransfer(msg.sender, bounty);              // last: every effect is already written
        return true;
    }

    /// @dev Extensions observe only actual stock/USDG fills, before the keeper reward is transferred.
    function _afterStockSale(uint256 price, uint256 stockSold, uint256 usdgReceived) internal virtual {}

    function buyDip() public virtual nonReentrant { _buyDip(); }

    function _buyDip() internal {
        (bool ok, uint256 p) = health();
        if (!ok) revert Unhealthy();
        if (lastSalePrice == 0 || !HedgeFunMath.fellTo(p, lastSalePrice, _params.dipBps)) revert NotDue();
        _buyWithReserve(p, type(uint256).max);
    }

    /// @dev Callers validate the price trigger; this helper preserves actual-fill and inventory accounting.
    function _buyWithReserve(uint256 p, uint256 maxSpendUsdg) internal {
        uint256 spend = Math.min(HedgeFunMath.bps(reserveUsdg(), _params.lotBps), maxSpendUsdg);
        if (spend < _params.minLotUsdg || !_canAddLot()) revert NotDue();
        _notePrice(p); _noteTokenSpot();
        (uint256 spent, uint256 got) = _swapStock(true, spend - HedgeFunMath.bps(spend, _params.bountyBps), p);
        // A dip buy may fill short, so everything below is sized off what ACTUALLY filled, never off what was asked.
        // A bounty paid on the ask would let a caller shove the pool to the edge of the deviation gate -- close
        // enough that `health()` still opens, far enough that the oracle-derived price limit leaves the swap almost
        // no room -- and be paid more than the treasury managed to buy. Refusing a dust fill outright also keeps
        // `lastSalePrice` below from moving the dip rung for a purchase that did not really happen.
        if (spent < _params.minLotUsdg) revert NotDue();
        uint256 bounty = HedgeFunMath.bps(spent, _params.bountyBps);
        lots.push(Lot(got, Math.mulDiv(spent, _SCALE, got), false, 0)); bookedStock += got;
        lastSalePrice = p;                                                      // the next rung is another dip below this
        emit LotBooked(lots.length - 1, got, Math.mulDiv(spent, _SCALE, got), false);
        if (bounty != 0) _usdg.safeTransfer(msg.sender, bounty);              // last: every effect is already written
    }

    /// @dev record the token pool's spot if it is more favourable than what we have. Called from every rule
    ///      action, because those happen at moments the ORACLE gates rather than moments a buy-back caller picks:
    ///      an attacker who wants to keep the anchor high has to hold the pool shoved continuously, not just in
    ///      the block before each `buyback`. Only ever improves, so a shove can never raise it.
    function _noteTokenSpot() internal {
        if (hook == address(0)) return;
        // Not before the pool's first swap. Until then spot IS the opening price, the cheapest the token will ever
        // be, and the anchor only ever moves toward cheaper: a lot booked at launch would pin it there for good,
        // which is the same reason it is not seeded at `wire()`.
        if (IHedgeFunHook(hook).observationCount() == 0) return;
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolKey.toId());
        if (sqrtP == 0) return;
        bool better = buybackAnchorSqrtP == 0
            || (stockIsCurrency0InTokenPool ? sqrtP > buybackAnchorSqrtP : sqrtP < buybackAnchorSqrtP);
        if (better) { buybackAnchorSqrtP = sqrtP; buybackAnchorAt = block.timestamp; }
    }

    function _shrink(uint256 id, uint256 q) internal {
        bookedStock -= q;
        if (q == lots[id].qty) { lots[id] = lots[lots.length - 1]; lots.pop(); }
        else lots[id].qty -= q;
    }

    // ------------------------------------------------------------------------------------------------ buy back and burn
    /// @dev Sizing only. V2 supplies the stock pool's guarded TWAP during scheduled closures.
    function _buybackFallbackPrice() internal view virtual returns (uint256) {
        return block.timestamp - lastGoodPriceAt <= MAX_SIZING_AGE ? lastGoodPrice : 0;
    }

    /// @notice spend one chunk of realised profit buying the token in its own pool -- the launch's <token>/<stock> V4
    ///         pool -- and burn it.
    function buyback() external nonReentrant returns (uint256 spent, uint256 burned) {
        if (hook == address(0) || buybackStock == 0) revert NotDue();
        if (block.timestamp < lastBuybackAt + _params.buybackCooldown) revert Cooldown();
        // Only to size the chunk. Execution uses the FUN/stock pool's own price bounds. The legacy fallback is a
        // cached observation; V2 overrides it with a guarded stock/USDG TWAP during scheduled closures.
        (bool ok, uint256 p) = _oracle.tryPrice();
        if (ok) {
            // Record live oracle observations only; fallback quotes never refresh this timestamp.
            _notePrice(p);
        } else {
            p = _buybackFallbackPrice();
        }
        if (p == 0) revert Unhealthy();
        uint256 amountIn = Math.min(buybackStock, _buybackChunk(p));

        _swapKind = 2;
        (spent, burned) = abi.decode(poolManager.unlock(abi.encode(amountIn)), (uint256, uint256));
        _swapKind = 0;

        // A fill of dust is not a buy-back. The pool is priced past the drift allowance, and letting a two-wei
        // fill through would consume the cooldown and fire the sell spike -- handing a shover both for free. The
        // floor is the same minimum the rule uses everywhere else, except when so little profit is left that the
        // whole remainder is smaller than it, which must still be spendable.
        if (spent < Math.min(amountIn, _ruleStockFor(_params.minLotUsdg, p))) revert NotDue();

        buybackStock -= spent;
        totalStockSpentOnBuybacks += spent;
        lastBuybackAt = block.timestamp;
        uint256 bounty = HedgeFunMath.bps(burned, _params.bountyBps);
        if (bounty != 0) token.safeTransfer(msg.sender, bounty);
        burned -= bounty;
        IHedgeFunToken(address(token)).burn(burned);
        totalBurned += burned;
        IHedgeFunHook(hook).noteEvent();                                        // starts the sell spike
        emit Buyback(spent, burned);
    }

    /// @dev the most one buy-back offers the token pool, in stock, before the budget caps it: the listing's fixed
    ///      `buybackChunkUsdg`. A kind may size it another way; the price limit, the cooldown and the dust floor in
    ///      `buyback` are not its to change.
    function _buybackChunk(uint256 p) internal view virtual returns (uint256) {
        return _ruleStockFor(_params.buybackChunkUsdg, p);
    }

    /// @dev the actual token-pool swap: sell `amountIn` of stock for the launch token in `poolKey`. The launch token
    ///      has no oracle -- nothing outside this pool prices it -- so the bound has to come from the pool's own
    ///      history, and V4 stores none. The hook keeps a ring of it, and the treasury keeps its own memory for when
    ///      the ring cannot serve: `buybackAnchorSqrtP`, the most favourable price it has seen since the pool's first
    ///      swap. NOT seeded at `wire()` -- `_buybackLimitSqrtP` says why.
    ///
    ///      Anchoring matters because an impact cap measured off spot AT CALL TIME lets an attacker choose the
    ///      starting point: pre-push the pool, call `buyback`, let the full chunk execute at the pushed price, and
    ///      sell back into it. Such a cap bounds only the chunk's own move, never where it moves FROM.
    ///
    ///      So the limit is taken from the reference (the hook's mean tick when its ring serves the window, this
    ///      anchor otherwise) or from spot, whichever is less favourable to the buyer. A price
    ///      that has FALLEN since the last buy-back is bought freely, at spot. A price that has RISEN is only
    ///      bought up to `maxBuybackImpactBps` above where the treasury last paid, so a pre-push simply fills
    ///      short, or not at all. Genuine appreciation still gets bought, one cap-sized step per cooldown, and
    ///      each step moves the anchor -- which is the same shape as the rest of the rule, where a step that
    ///      cannot complete waits rather than executing at a price nobody vouched for. sqrt moves half as far as
    ///      price, hence impact/2 on the square root.
    function _swapTokenPool(uint256 amountIn) internal returns (uint256 spent, uint256 got) {
        bool zeroForOne = stockIsCurrency0InTokenPool;
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolKey.toId());
        uint160 limit = _buybackLimitSqrtP(zeroForOne, sqrtP);

        BalanceDelta d = poolManager.swap(poolKey, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}), "");
        (int128 dIn, int128 dOut) = zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        spent = uint256(uint128(-dIn));                                         // a short fill just spends less
        got = uint256(uint128(dOut));

        poolManager.sync(Currency.wrap(address(_stock)));
        _stock.safeTransfer(address(poolManager), spent);
        poolManager.settle();
        poolManager.take(Currency.wrap(address(token)), address(this), got);

        // only ever improves: a buy-back that executed at a shoved price must not teach the anchor that price,
        // or an attacker ratchets it up one round at a time and every later round passes the check for free.
        _noteTokenSpot();
    }

    /// @dev how far this chunk may push the pool, and -- the part that matters -- how far the pool may already have
    ///      moved before we got here. Measuring only the former off spot AT CALL TIME would let an attacker choose
    ///      the starting point, every cooldown; see `_swapTokenPool`.
    ///
    ///      There is no oracle for the launch token -- nothing outside its own pool prices it -- so the reference
    ///      has to be the treasury's own memory: `buybackAnchorSqrtP`, where it last transacted. A price that has
    ///      moved AGAINST the anchor is only bought into up to a drift allowance, and that allowance GROWS with the
    ///      time since the anchor was set: one impact cap's worth per elapsed cooldown. So a shove landing seconds
    ///      before the call is held to almost nothing, while a token that genuinely appreciated over hours is
    ///      bought without complaint.
    ///
    ///      The anchor is NOT seeded at `wire()`. The pool opens single-sided, so the first real buyers move it a
    ///      long way from the opening price in one trade; anchoring there would block every buy-back until the
    ///      drift caught up. When the hook's ring cannot serve the window either, the first buy-back therefore
    ///      executes on spot alone and sets the anchor. What that gives up is one chunk, once. What stays bounded is
    ///      the repeatable part: the same shove every cooldown for as long as `buybackStock` lasts.
    ///
    ///      The limit never crosses spot: a pool pushed past the allowance simply fills nothing, and `buyback`
    ///      turns that into `NotDue` rather than consuming the cooldown. sqrt moves half as far as price.
    function _buybackLimitSqrtP(bool zeroForOne, uint160 sqrtP) internal view returns (uint160) {
        uint256 half = uint256(_params.maxBuybackImpactBps) / 2;
        uint256 fromSpot = HedgeFunMath.shift(sqrtP, half, !zeroForOne);

        // The hook's own observation ring is the reference, when it can serve the window. It is written from
        // `afterSwap` on every swap, so its sample times are chosen by whoever trades rather than by a sampler --
        // which is what makes it something a shove cannot set. Refusing the window (too little history, or a
        // griefer flipping the tick every second to spend the ring) falls back to the treasury's own ratchet
        // below rather than to bare spot, because bare spot is exactly what the attacker controls.
        (bool ok, int24 mean) = IHedgeFunHook(hook).meanTick(BUYBACK_TWAP_WINDOW);
        if (ok) {
            uint256 fromMean = uint256(TickMath.getSqrtPriceAtTick(mean));
            fromMean = HedgeFunMath.shift(fromMean, half, !zeroForOne);
            uint256 bound = zeroForOne ? (fromMean > fromSpot ? fromMean : fromSpot)
                                       : (fromMean < fromSpot ? fromMean : fromSpot);
            return _clampToSpot(zeroForOne, sqrtP, bound);
        }

        uint256 anchor = buybackAnchorSqrtP;
        if (anchor == 0) return uint160(fromSpot);
        uint256 cd = _params.buybackCooldown == 0 ? 1 : _params.buybackCooldown;
        uint256 drift = half * (1 + (block.timestamp - buybackAnchorAt) / cd);
        if (drift > MAX_DRIFT_BPS) drift = MAX_DRIFT_BPS;
        uint256 anchored = HedgeFunMath.shift(anchor, drift, !zeroForOne);
        uint256 lim = zeroForOne ? (anchored > fromSpot ? anchored : fromSpot)
                                 : (anchored < fromSpot ? anchored : fromSpot);
        return _clampToSpot(zeroForOne, sqrtP, lim);
    }

    /// @dev a limit already on the wrong side of spot would revert inside V4 with its own error; keeping it just
    ///      short of spot makes the swap fill nothing instead, which `buyback` turns into `NotDue` -- so a shove
    ///      cannot spend the cooldown or fire the sell spike either.
    function _clampToSpot(bool zeroForOne, uint160 sqrtP, uint256 lim) private pure returns (uint160) {
        if (zeroForOne) return uint160(lim >= sqrtP ? uint256(sqrtP) - 1 : lim);
        return uint160(lim <= sqrtP ? uint256(sqrtP) + 1 : lim);
    }

    /// @dev only ever the buy-back (kind 2): the stock<->USDG leg is a direct V3 pool swap, not routed through
    ///      `poolManager`.
    function unlockCallback(bytes calldata data) external virtual override returns (bytes memory);
}
