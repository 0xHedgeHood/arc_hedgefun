// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TwapRing} from "../libraries/TwapRing.sol";
import {IOwned} from "../interfaces/IOwned.sol";
import {IHedgeFunToken} from "../interfaces/IHedgeFunToken.sol";
import {HedgeFunMath, BPS} from "../libraries/HedgeFunMath.sol";
import "../libraries/HedgeFunLimits.sol" as Limits;


/// The tax on a strategy token's own <token>/<stock> Uniswap V4 pool.
///
/// Charged in `afterSwap`, on what the swap actually moved (a V4 swap that meets its price limit stops early and
/// silently, so a `beforeSwap` charge on the requested amount would overcharge every partial fill), and it lands in
/// the UNSPECIFIED currency -- V4 lets `afterSwap` return a delta on that currency and no other. On an exact-INPUT
/// swap the unspecified leg is the output, so a BUY is taxed in the token and a SELL is taxed in the stock:
///   - token-denominated take is burned, all of it;
///   - stock-denominated take goes `protocolBps` to the protocol, `creatorBps` to whoever launched the strategy,
///     and the rest to the strategy's treasury, which books it as a lot and trades it under its published rule.
///
/// Exact-OUTPUT swaps: the unspecified leg is the INPUT. An exact-output BUY at the FLAT rate is accepted, taxed
/// `r / (1 - r)` of its input -- in the stock, so it is split like a sell's tax rather than burned. Every other
/// exact-output swap is refused; `_tax` says why.
///
/// BUYS carry a launch window: for `snipeSeconds` after a pool is registered the buy rate starts at `snipeBps` and
/// falls in a straight line to the flat rate. The pool opens at a price where a few shares buy a tenth of the supply,
/// and this chain makes a block every 0.1s; without a window the opening is a latency race that a bot wins. With one
/// it is a falling-price auction whose premium is burned. A buy inside the launch TRANSACTION, by the very contract
/// that called the factory, is exempt -- the creator's own -- by two transient words the EVM clears with the transaction.
///
/// Sells can carry a spike on top of the flat rate for `spikeSeconds` after the treasury buys back, decaying
/// linearly, so that a buy-back cannot simply be dumped into. It is timed in seconds, not blocks: this chain makes a
/// block every 0.1s. The same clock starts at REGISTRATION -- the launch -- so the first `spikeSeconds` of a launch
/// carry the spike too: whoever snipes the opening block cannot simply dump it. The treasury's own swaps are never
/// taxed.
///
/// ONE hook serves every strategy. Tax claims and parked stock of different pools therefore sit at one address, so
/// nothing below may ever infer one pool's money from a balance (see "paying it out"), and an issuer who deny-lists
/// THIS address stops every strategy's stock leg at once.
///
/// No code here can change and no rate, rule, treasury or pool can move. The address must carry BEFORE_INITIALIZE |
/// BEFORE_ADD_LIQUIDITY | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA (0x2844) in its low 14 bits. The two `before` flags
/// keep everyone but the factory (V1) or its registered immutable vault (V2) out: the tax lives in `afterSwap` and nowhere else, so a third-party position would
/// be a way to sell without paying it -- a one-spacing range just past spot is filled by the next buyer and exits
/// untaxed. And because a pool must be REGISTERED by the factory before `beforeInitialize` will answer for it, nobody
/// can open a pool on this hook that the factory did not launch.
/// The take is booked as ERC-6909 claims and paid out by a permissionless `sweep`, each currency on its own
/// leg so that one that cannot settle never strands the other.
contract HedgeFunHook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using TwapRing for TwapRing.Ring;

    struct Rates {
        uint16 taxBps;           // flat, both directions
        uint16 spikeBps;         // sell rate at the instant of a buy-back
        uint32 spikeSeconds;     // linear decay back to taxBps
        uint16 protocolBps;      // of the stock-denominated take
        uint16 creatorBps;       // of the stock-denominated take; the rest is the treasury's
        uint16 sweepTipBps;      // of whatever a sweep distributes
        uint16 snipeBps;         // buy rate at the instant of the launch; 0 = no snipe tax
        uint8 snipeSeconds;      // linear decay back to taxBps
    }

    /// Everything one strategy's pool is. Laid out by who reads it: a swap is the hot path, so what it needs is
    /// packed into as few words as it can be.
    struct Pool {
        // word 0 -- all a BUY reads, the launch-window snipe rate included. `treasury != 0` is also what
        // "registered" means.
        address treasury;
        uint16 taxBps;
        bool tokenIsCurrency0;
        uint16 snipeBps;
        uint8 snipeSeconds;
        uint40 launchedAt;
        // word 1 -- a SELL reads this too, for the spike and its clock
        address token;
        uint40 lastEventAt;
        uint16 spikeBps;
        uint32 spikeSeconds;
        // word 2 -- tax booked as ERC-6909 claims and not yet swept. The manager keeps claims per (hook, currency)
        // and every pool on one stock shares that currency, so THIS is the only record of whose they are.
        uint128 accruedToken;
        uint128 accruedStock;
        // word 3 -- `index` and `epoch` (next word) say which state of the stock's pot the three `owed` below are in
        address stock;
        uint96 index;
        // who is paid the protocol's cut, and who is paid the creator's. The ONLY two things about a pool that can
        // ever change, and neither changes a rate, the rule, the treasury or the liquidity -- see `owner()`.
        address protocol;
        uint32 epoch;
        uint16 protocolBps;              // the split, read only by a sweep -- which reads `protocol` anyway
        uint16 creatorBps;
        uint16 sweepTipBps;
        address creator;
        address pendingCreator;
        uint48 pendingCreatorAt;
        uint48 noProposalBefore;
        address pendingBy;               // the owner who proposed; a successor proposes again, with its own 14 days
        // what is parked for each ROLE, in wei of the stock as of `index` (see "paying it out")
        uint256 owedProtocol;
        uint256 owedCreator;
        uint256 owedTreasury;            // zero except while the treasury cannot be paid
        // The observation ring this pool would have had on V3. Written from `afterSwap` on every swap, which is
        // what makes it safe: the sample times are chosen by whoever trades, not by a sampler who could pick them.
        // It exists so the treasury's buy-back has a real time-weighted price to bound itself against -- the
        // launch token has no oracle, and nothing outside this pool prices it.
        TwapRing.Ring ring;
    }

    /// what this address must carry in its low 14 bits, and nothing else: the two `before` flags guard the seed, the
    /// two `after` flags take the tax. 0x2844.
    uint160 internal constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint256 public constant MAX_TAX_BPS = Limits.MAX_TAX_BPS;
    uint256 public constant MAX_SPIKE_BPS = Limits.MAX_SPIKE_BPS;
    uint256 public constant MAX_TIP_BPS = Limits.MAX_TIP_BPS;
    /// a buyer inside the launch window always keeps at least 1% of what the pool gave
    uint256 public constant MAX_SNIPE_BPS = Limits.MAX_SNIPE_BPS;

    IPoolManager public immutable poolManager;
    /// whoever bound this hook -- the factory. Only it may register a pool. V1 permits that factory to initialize
    /// and seed; V2 freezes one per-pool vault for those two operations before initialization.
    address public factory;
    bool internal _distributing;

    mapping(PoolId => Pool) internal pools;
    /// @notice V2 pools seed through a fee-only vault which owns the locked position.
    ///         V1 pools leave this unset and continue to seed through the factory.
    mapping(PoolId => address) public liquidityVaultOf;
    /// The treasury-facing calls (`noteEvent`, `meanTick`, `observationCount`) take no pool: a treasury is found by
    /// its own address, so it can only ever reach its own pool.
    mapping(address => PoolId) public poolOfTreasury;

    event Bound(address indexed factory);
    event Registered(PoolId indexed id, address indexed token, address indexed stock, address treasury, address protocol, address creator, Rates rates);
    event Taxed(PoolId indexed id, bool indexed selling, bool inToken, uint256 moved, uint256 tax, uint256 rateBps);
    event Swept(PoolId indexed id, uint256 tokenBurned, uint256 stockToTreasury, uint256 stockToProtocol, uint256 stockToCreator);

    error NotPoolManager();
    error NotTreasury();
    error HookNotImplemented();
    error WrongPool();
    error BadConfig();
    error NotSeeder();
    error ExactOutputRefused();
    error Reentered();
    error NotOwner();
    error NotCreator();
    error NothingPending();
    error TooEarly();
    error Expired();
    error AlreadyBound();
    error NotFactory();
    error AlreadyRegistered();

    constructor(IPoolManager pm) {
        if (address(pm) == address(0)) revert BadConfig();
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != _flags()) revert BadConfig();
        poolManager = pm;
    }

    /// @dev what the address must carry. `HedgeFunV2Hook` adds the two flags its `beforeSwap` needs.
    function _flags() internal pure virtual returns (uint160) { return FLAGS; }

    // ------------------------------------------------------------------------------------------------ the factory only
    /// @notice claim this hook. `HedgeFunFactory` does it from its own constructor, so a hook somebody else has
    ///         already claimed fails that constructor loudly, before anything is live. Once: a second factory could
    ///         register pools that pay whom it likes.
    function bind() external {
        if (factory != address(0)) revert AlreadyBound();
        factory = msg.sender;
        emit Bound(msg.sender);
    }

    /// @notice the factory announces a pool it is about to open. The configuration is validated here, and a pool is
    ///         registered once, with one pool per treasury -- the treasury-facing calls resolve the pool from the
    ///         caller, so a treasury mapped twice would be ambiguous.
    /// @dev registration itself starts the sell spike (`lastEventAt`) and the launch window (`launchedAt`)
    function register(PoolKey calldata key, address token_, address stock_, address treasury_, address protocol_, address creator_, address launcher_, Rates calldata r) external {
        _register(key, token_, stock_, treasury_, protocol_, creator_, launcher_, r);
    }

    /// @notice Register a graduated curve without restarting launch taxes. Its frozen rates determine any later spike.
    function registerGraduated(PoolKey calldata key, address token_, address stock_, address treasury_, address protocol_, address creator_, Rates calldata r) external {
        if (r.snipeBps != 0 || r.snipeSeconds != 0) revert BadConfig();
        PoolId id = _register(key, token_, stock_, treasury_, protocol_, creator_, address(0), r);
        pools[id].lastEventAt = 0;
    }

    /// @notice Register a graduated pool whose permanently locked position is owned by its fee vault.
    function registerGraduatedWithVault(PoolKey calldata key, address token_, address stock_, address treasury_, address protocol_, address creator_, Rates calldata r, address vault) external {
        if (vault.code.length == 0 || r.snipeBps != 0 || r.snipeSeconds != 0) revert BadConfig();
        PoolId id = _register(key, token_, stock_, treasury_, protocol_, creator_, address(0), r);
        liquidityVaultOf[id] = vault;
        pools[id].lastEventAt = 0;
    }

    function _register(PoolKey calldata key, address token_, address stock_, address treasury_, address protocol_, address creator_, address launcher_, Rates calldata r) internal returns (PoolId id) {
        if (msg.sender != factory) revert NotFactory();
        if (token_ == address(0) || stock_ == address(0) || treasury_ == address(0) || protocol_ == address(0) || creator_ == address(0)) revert BadConfig();
        if (r.taxBps > MAX_TAX_BPS || r.spikeBps > MAX_SPIKE_BPS || uint256(r.protocolBps) + r.creatorBps > BPS || r.sweepTipBps > MAX_TIP_BPS || r.snipeBps > MAX_SNIPE_BPS) revert BadConfig();
        address a0 = Currency.unwrap(key.currency0);
        if (token_ == stock_ || !((a0 == token_ && Currency.unwrap(key.currency1) == stock_) || (a0 == stock_ && Currency.unwrap(key.currency1) == token_))) revert BadConfig();
        if (address(key.hooks) != address(this)) revert BadConfig();
        id = key.toId();
        Pool storage p = pools[id];
        if (p.treasury != address(0) || PoolId.unwrap(poolOfTreasury[treasury_]) != bytes32(0)) revert AlreadyRegistered();
        poolOfTreasury[treasury_] = id;
        p.treasury = treasury_; p.taxBps = r.taxBps; p.tokenIsCurrency0 = a0 == token_; p.snipeBps = r.snipeBps; p.snipeSeconds = r.snipeSeconds; p.launchedAt = uint40(block.timestamp);
        p.token = token_; p.lastEventAt = uint40(block.timestamp); p.spikeBps = r.spikeBps; p.spikeSeconds = r.spikeSeconds; p.protocolBps = r.protocolBps; p.creatorBps = r.creatorBps; p.sweepTipBps = r.sweepTipBps;
        Pot storage pot = pots[stock_];
        if (pot.index == 0) pot.index = uint96(RAY);                             // the first pool on this stock
        p.stock = stock_; p.index = pot.index; p.epoch = pot.epoch; p.protocol = protocol_; p.creator = creator_;
        // this transaction is the launch, and `launcher_` is whoever called the factory: see `_buyRate`
        assembly ("memory-safe") { tstore(0, id) tstore(1, launcher_) }
        emit Registered(id, token_, stock_, treasury_, protocol_, creator_, r);
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view override returns (bytes4) {
        _onlySeed(sender, key);
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata) external view override returns (bytes4) {
        _onlySeed(sender, key);
        return IHooks.beforeAddLiquidity.selector;
    }

    function _onlySeed(address sender, PoolKey calldata key) internal view {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (pools[key.toId()].treasury == address(0)) revert WrongPool();        // a pool the factory never registered
        address seeder = liquidityVaultOf[key.toId()];
        if (sender != (seeder == address(0) ? factory : seeder)) revert NotSeeder();
    }

    function _pool(PoolId id) internal view returns (Pool storage p) {
        p = pools[id];
        if (p.treasury == address(0)) revert WrongPool();
    }

    // ------------------------------------------------------------------------------------------------ reading a pool
    function isRegistered(PoolId id) external view returns (bool) { return pools[id].treasury != address(0); }
    function poolConfig(PoolId id) external view returns (address token, address stock, address treasury, bool tokenIsCurrency0) {
        Pool storage p = pools[id];
        return (p.token, p.stock, p.treasury, p.tokenIsCurrency0);
    }
    function rates(PoolId id) external view returns (Rates memory) {
        Pool storage p = pools[id];
        return Rates(p.taxBps, p.spikeBps, p.spikeSeconds, p.protocolBps, p.creatorBps, p.sweepTipBps, p.snipeBps, p.snipeSeconds);
    }
    function tokenOf(PoolId id) external view returns (address) { return pools[id].token; }
    function stockOf(PoolId id) external view returns (address) { return pools[id].stock; }
    function treasuryOf(PoolId id) external view returns (address) { return pools[id].treasury; }
    function protocolOf(PoolId id) external view returns (address) { return pools[id].protocol; }
    function creatorOf(PoolId id) external view returns (address) { return pools[id].creator; }
    function lastEventAt(PoolId id) external view returns (uint256) { return pools[id].lastEventAt; }
    function pendingCreator(PoolId id) external view returns (address) { return pools[id].pendingCreator; }
    function pendingCreatorAt(PoolId id) external view returns (uint256) { return pools[id].pendingCreatorAt; }
    function pendingBy(PoolId id) external view returns (address) { return pools[id].pendingBy; }
    function noProposalBefore(PoolId id) external view returns (uint256) { return pools[id].noProposalBefore; }
    /// @notice tax booked for this pool as ERC-6909 claims and not yet swept
    function accrued(PoolId id) external view returns (uint256 inToken, uint256 inStock) {
        Pool storage p = pools[id];
        return (p.accruedToken, p.accruedStock);
    }

    // ------------------------------------------------------------------------------------------------ the treasury only
    /// @notice the treasury has just bought back: start the sell spike
    /// @dev at most one spike per `2 * spikeSeconds`, so the rate always spends at least as long at the flat rate
    ///      as it spends spiked, and a seller always has a window. Without that bound the spike could be pinned up
    ///      indefinitely: `buyback()` is permissionless and its cooldown is shorter than the spike is long, so
    ///      anyone willing to spend the treasury's own realised profit could re-arm a 90% sell tax forever and
    ///      hold every other seller in. A buy-back during a live spike is already protected by that spike.
    ///      The pool is the CALLER's: treasury A has no way to name pool B.
    function noteEvent() external {
        Pool storage p = _mine();
        if (block.timestamp < p.lastEventAt + 2 * uint256(p.spikeSeconds)) return;
        p.lastEventAt = uint40(block.timestamp);
    }

    /// @notice the calling treasury's own pool's mean tick over `window` seconds
    /// @return ok false when the ring cannot serve the window -- too little history, or a griefer flipping the
    ///         tick every second has pushed it out. The caller must refuse to trade, never substitute spot.
    function meanTick(uint32 window) external view returns (bool ok, int24 mean) {
        _mine();
        return meanTickOf(poolOfTreasury[msg.sender], window);
    }

    function observationCount() external view returns (uint16) { return _mine().ring.filled; }

    function _mine() internal view returns (Pool storage p) {
        p = pools[poolOfTreasury[msg.sender]];
        if (p.treasury != msg.sender) revert NotTreasury();                      // every address that is no treasury lands here
    }

    /// @notice the same two readings for anyone who is not the treasury, by pool
    function meanTickOf(PoolId id, uint32 window) public view returns (bool ok, int24 mean) {
        (, int24 tickNow,,) = poolManager.getSlot0(id);
        return pools[id].ring.meanTick(window, tickNow);
    }

    function observationCountOf(PoolId id) external view returns (uint16) { return pools[id].ring.filled; }

    function sellRateBps(PoolId id) external view returns (uint256) { return _sellRate(pools[id]); }

    function _sellRate(Pool storage p) internal view returns (uint256) {
        uint256 tax = p.taxBps; uint256 secs = p.spikeSeconds; uint256 last = p.lastEventAt;
        if (secs == 0 || last == 0) return tax;
        uint256 dt = block.timestamp - last;
        if (dt >= secs) return tax;
        uint256 s = uint256(p.spikeBps) * (secs - dt) / secs;
        return s > tax ? s : tax;
    }

    // ------------------------------------------------------------------------------------------------ the tax
    function afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta swapDelta, bytes calldata)
        external override returns (bytes4, int128)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        PoolId id = key.toId();
        Pool storage p = pools[id];
        {
            address treasury = p.treasury;
            if (treasury == address(0)) revert WrongPool();                      // a pool the factory never registered
            _observe(id, p);
            if (sender == treasury) return (IHooks.afterSwap.selector, 0);       // the buy-back is not taxed
        }
        // The tax can only land on the UNSPECIFIED leg: V4 lets `afterSwap` return a delta on that currency and no
        // other. On an exact-input swap that is the output -- a buy is taxed in the token, a sell in the stock. On an
        // exact-output swap it is the INPUT: `_tax` accepts that for a BUY at the flat rate only, grossing the rate
        // up so the trader ends where they would have, and refuses every other exact-output swap.
        return (IHooks.afterSwap.selector, _tax(id, p, sender, key, params, swapDelta));
    }

    /// @dev A rate `r` charged on the output leaves the trader `1 - r` of it. Charged at face value on the input it
    ///      would leave `1 / (1 + r)`: within a percent at the flat rate, but 0.526 against 0.100 at a 90% spike.
    ///      Grossed up to `r / (1 - r)` of the input it leaves `1 - r` again, to the wei of rounding (the gross-up
    ///      rounds up) -- and that is accepted for exactly one case: an exact-output BUY at the FLAT rate, whose tax
    ///      arrives in the stock (the input) and is split like a sell's rather than burned. An exact-output SELL is
    ///      refused always, and an exact-output buy is refused while the launch window holds the buy rate above the
    ///      flat tax (`ExactOutputRefused`); the body says why.
    function _tax(PoolId id, Pool storage p, address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta swapDelta) internal virtual returns (int128) {
        bool unspecifiedIsCurrency1 = params.zeroForOne == (params.amountSpecified < 0);
        Currency c = unspecifiedIsCurrency1 ? key.currency1 : key.currency0;
        uint256 moved;
        { int128 d = unspecifiedIsCurrency1 ? swapDelta.amount1() : swapDelta.amount0(); moved = uint256(uint128(d < 0 ? -d : d)); }
        bool selling = p.tokenIsCurrency0 == params.zeroForOne;                  // the token is what goes in
        uint256 rate = selling ? _sellRate(p) : _buyRate(id, p, sender);
        // Exact output: `moved` is the swap's INPUT. Allowed for a BUY at the flat rate and nowhere else. Grossed
        // up, the tax is still `rate` of everything the trader pays -- but it never meets the pool's curve, so only
        // (1 - r) of the payment moves the price, which at spike or launch-window rates makes the trade materially
        // cheaper than its exact-input equivalent. And an exact-output SELL is taxed in the token, which burns: the
        // treasury, the creator and the protocol would be paid only by sellers who chose to.
        if (params.amountSpecified > 0 && (selling || rate > p.taxBps)) revert ExactOutputRefused();
        uint256 tax = params.amountSpecified > 0 ? FullMath.mulDivRoundingUp(moved, rate, BPS - rate) : HedgeFunMath.bps(moved, rate);
        if (tax == 0) return 0;
        if (tax > uint128(type(int128).max)) revert BadConfig();                 // 99x a 2^127 input: not a real trade
        poolManager.mint(address(this), c.toId(), tax);
        // The claim just minted joins every other pool's claims on that currency; this line is what keeps it this
        // pool's. By CURRENCY, not by direction: an exact-output swap is taxed in the other one.
        // (The SUM overflowing reverts the swap until somebody sweeps -- the safe way round.)
        bool inToken = Currency.unwrap(c) == p.token;
        if (inToken) p.accruedToken += uint128(tax); else p.accruedStock += uint128(tax);
        emit Taxed(id, selling, inToken, moved, tax, rate);
        return int128(int256(tax));
    }

    /// @notice what a buy pays right now. For `snipeSeconds` after the launch it starts at `snipeBps` and falls in a
    ///         straight line to the flat rate, so the opening seconds are a falling-price auction instead of a race
    ///         for the first block: whoever wants the launch price most pays for it, in tokens that are burned.
    /// @dev Linear, like the sell spike: `block.timestamp` moves in whole seconds, so a window of a few seconds has
    ///      only that many steps and a curve would be a claim the clock cannot keep. A buy inside the LAUNCH
    ///      TRANSACTION, by the contract that called the factory, is exempt -- the creator's own, through
    ///      `HedgeFunLaunchRouter` or a contract of theirs that launches and buys. Two transient words `register` sets and the
    ///      EVM clears when the transaction ends: no list of addresses. The transaction alone is not enough, because a
    ///      bundle or a relayed launch puts strangers inside it (see `_buyRate`).
    function buyRateBps(PoolId id) external view returns (uint256) { return _buyRate(id, pools[id], msg.sender); }

    function _buyRate(PoolId id, Pool storage p, address sender) internal view returns (uint256) {
        uint256 tax = p.taxBps; uint256 secs = p.snipeSeconds;
        if (secs == 0) return tax;
        uint256 dt = block.timestamp - p.launchedAt;
        if (dt >= secs) return tax;
        // Exempt: THIS pool's launch transaction AND the very contract that called the factory. The transaction alone
        // is not enough: a 4337 bundle, a relayer batch or a public multicall puts strangers' calls in the creator's
        // transaction, and whoever orders the bundle could buy at the flat rate.
        bytes32 launching; address launcher; assembly ("memory-safe") { launching := tload(0) launcher := tload(1) }
        if (launching == PoolId.unwrap(id) && sender == launcher) return tax;
        uint256 s_ = uint256(p.snipeBps) * (secs - dt) / secs;
        return s_ > tax ? s_ : tax;
    }

    function _observe(PoolId id, Pool storage p) internal {
        // every swap is observed, including the treasury's own and including ones that end up untaxed: a ring with
        // holes in it is a ring an attacker chooses the shape of
        // ... with one exception: a tick with no liquidity behind it. The seed is single-sided and the pool opens
        // one spacing outside it, so a swap can slide through the empty side to MIN/MAX moving no tokens, paying no
        // tax, and costing nothing but gas. That is not a price anyone can trade at, and recording it would let a
        // stranger holding neither currency write the limit into the ring for free. The ring keeps the last tick
        // that had a market.
        if (poolManager.getLiquidity(id) != 0) {
            (, int24 tickNow,,) = poolManager.getSlot0(id);
            p.ring.write(tickNow);
        }
    }

    // ------------------------------------------------------------------------------------------------ paying it out
    // This address holds the stock of every pool on that stock, so NO amount is ever inferred from a balance:
    //   - a sweep redeems exactly `accruedStock` of ITS pool and splits exactly what it redeemed. The redeem, the
    //     credits and the payouts are ONE `try`ed call, so there is no instant at which stock has arrived here and
    //     belongs to nobody. As separate legs, a caller could choose the gas so that the split died after the redeem
    //     had succeeded, orphaning that pool's revenue for good;
    //   - what could not be delivered is PARKED: each role of each pool holds a plain wei amount, and `parked` of
    //     the pool's stock is their sum over every pool on it. While nothing has been burned that is all there is
    //     to it, and every figure is exact;
    //   - the balance can fall below `parked` only if the issuer burns this hook's stock. `_square` then lowers
    //     `parked` to what is left and the stock's `index` by the same proportion -- two writes, no loop -- and every
    //     parked amount of every pool on that stock is worth pro rata less, because an amount is read through
    //     `index now / index when it was last touched` and rebased the next time its pool is touched. It runs BEFORE
    //     new revenue is redeemed, and fresh credits are taken at the CURRENT index: so the loss lands on the claims
    //     that were here when it happened, never on a later sweep's split or a treasury's fresh share;
    //   - stock above `parked` -- a donation, the wei a rebase rounds away -- is NOBODY'S. It is never split, never
    //     tipped and cannot be claimed; all it can ever do is stand between parked claims and a burn.

    /// One per stock: wei parked over every pool on it, and the write-down index those amounts are read through.
    struct Pot { uint256 parked; uint96 index; uint32 epoch; }
    mapping(address => Pot) internal pots;
    uint256 internal constant RAY = 1e27;
    /// An index that would fall below this -- a cumulative haircut past 10^18 to 1, or a balance of zero -- is a
    /// wipe-out instead: the epoch moves on, every amount of the old one reads zero (again with no loop), and the
    /// index starts over. It keeps the index's rounding error far under a wei for any real amount, and means no
    /// sequence of burns can grind the index to a zero that would divide.
    uint256 internal constant MIN_INDEX = 1e9;

    event Claimed(PoolId indexed id, address indexed who, address indexed to, uint256 amount);
    event WrittenDown(address indexed stock, uint256 parkedBefore, uint256 parkedAfter);

    /// @dev not from inside a payout. A payout moves the ledger and then the stock; a sweep in between would
    ///      reconcile against a balance that does not yet agree with it.
    function sweep(PoolId id) external {
        if (_distributing) revert Reentered();
        _pool(id);
        poolManager.unlock(abi.encode(id, msg.sender));
    }

    function unlockCallback(bytes calldata data) public virtual override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolId id, address caller) = abi.decode(data, (PoolId, address));
        // Every leg is independent. A stock that can pause or blocklist its own transfers refuses the `take`, and
        // that must not strand the TOKEN side, which had nothing to do with it. These are tokenised equities, not
        // plain ERC20s, so that is a switch someone else holds.
        try this.settleToken(id, caller) {} catch {}
        // ... and a stock leg that cannot redeem still pays out whatever is already parked and has become payable
        try this.settleStock(id, caller) {} catch { try this.flush(id) {} catch {} }
        return "";
    }

    /// @dev external only so the leg above can be `try`ed. Burns exactly what this pool's buys were taxed, less the
    ///      tip -- never "the token balance": the hook is shared, and nothing here stops a strategy token from one
    ///      day being listed as another pool's stock.
    function settleToken(PoolId id, address caller) public virtual {
        if (msg.sender != address(this)) revert NotPoolManager();
        Pool storage p = pools[id];
        uint256 t = p.accruedToken;
        if (t == 0) return;
        p.accruedToken = 0;
        address token = p.token;
        _redeem(Currency.wrap(token), t);
        uint256 tip = HedgeFunMath.bps(t, p.sweepTipBps);
        if (tip != 0) IERC20(token).safeTransfer(caller, tip);
        IHedgeFunToken(token).burn(t - tip);
        emit Swept(id, t - tip, 0, 0, 0);
    }

    function _redeem(Currency c, uint256 amount) internal {
        poolManager.burn(address(this), c.toId(), amount);
        poolManager.take(c, address(this), amount);
    }

    /// @dev external only so the leg can be `try`ed. Everyone is CREDITED before anyone is paid, then each is paid
    ///      out of the ledger in its own `try`: a recipient that cannot be paid -- deny-listed by the stock's issuer,
    ///      or a contract built to revert -- keeps its credit and never blocks another role's payout, and an
    ///      undelivered cut is never split again by a later sweep. The treasury is credited like the others, so a
    ///      treasury that cannot be paid does not revert the split.
    ///
    ///      Nobody can rescue a stuck balance from this contract, so nothing in this path may be able to stick. The
    ///      tip goes last, behind the latch, so a caller who re-enters finds nothing but its own tip; a tip that
    ///      cannot be delivered becomes the treasury's, because left in the balance it would be nobody's.
    function settleStock(PoolId id, address caller) external {
        if (msg.sender != address(this)) revert NotPoolManager();
        if (_distributing) revert Reentered();
        Pool storage p = pools[id];
        // Square the pot with the balance BEFORE new revenue lands in it. Afterwards a shortfall is invisible: the
        // new tax covers the hole, no write-down happens, and the treasury's share of that tax quietly goes to
        // refilling a debt the issuer burned.
        address stock = _square(p);
        uint256 s = p.accruedStock;
        _distributing = true;
        if (s == 0) {
            _payRoles(id, p);
        } else {
            p.accruedStock = 0;
            _redeem(Currency.wrap(stock), s);
            uint256 tip = HedgeFunMath.bps(s, p.sweepTipBps);
            uint256 cut = HedgeFunMath.bps(s - tip, p.protocolBps);
            uint256 mine = HedgeFunMath.bps(s - tip, p.creatorBps);
            uint256 toTreasury = s - tip - cut - mine;
            _credit(p, stock, toTreasury, cut, mine);
            _payRoles(id, p);                                                    // the treasury books it as a lot
            if (tip != 0 && !_tryPay(stock, caller, tip)) _credit(p, stock, tip, 0, 0);
            emit Swept(id, 0, toTreasury, cut, mine);
        }
        _distributing = false;
    }

    /// @dev what the stock leg falls back to when the redeem itself cannot happen: pay what is already parked
    function flush(PoolId id) external {
        if (msg.sender != address(this)) revert NotPoolManager();
        if (_distributing) revert Reentered();
        Pool storage p = pools[id];
        _square(p);
        _distributing = true;
        _payRoles(id, p);
        _distributing = false;
    }

    function _payRoles(PoolId id, Pool storage p) internal {
        if ((p.owedTreasury | p.owedProtocol | p.owedCreator) == 0) return;
        address treasury = p.treasury; address protocol = p.protocol; address creator = p.creator;
        _pay(id, p, treasury, treasury);
        _pay(id, p, protocol, protocol);
        _pay(id, p, creator, creator);
    }

    /// The ledger is kept by ROLE, not by address, so that changing who holds a role moves exactly that role's
    /// money and nothing else -- a protocol that is also the creator of one strategy has two separate balances.
    /// Each reads what the role's parked amount is worth NOW: after any issuer burn, recorded yet or not.
    function owedProtocol(PoolId id) external view returns (uint256) { return _worth(pools[id], pools[id].owedProtocol); }
    function owedCreator(PoolId id) external view returns (uint256) { return _worth(pools[id], pools[id].owedCreator); }
    function owedTreasury(PoolId id) external view returns (uint256) { return _worth(pools[id], pools[id].owedTreasury); }

    /// @notice what `who` has been credited in pool `id` and not yet paid, over every role `who` holds there
    function owed(PoolId id, address who) external view returns (uint256) {
        Pool storage p = pools[id];
        uint256 amount;                                                          // role by role, as a claim rounds it
        if (who == p.protocol) amount = _worth(p, p.owedProtocol);
        if (who == p.creator) amount += _worth(p, p.owedCreator);
        if (who == p.treasury) amount += _worth(p, p.owedTreasury);
        return amount;
    }

    /// @notice everything parked in `stock`, over every pool on it, at what it is worth now. After a write-down it
    ///         can sit a few wei above the sum of the roles: each rebase rounds down, and the wei stays here.
    function totalOwed(address stock) external view returns (uint256 parked) { (parked,,) = _pot(stock); }
    /// @notice the raw pot, as last written: (parked, index, epoch)
    function potOf(address stock) external view returns (uint256 parked, uint256 index, uint256 epoch) {
        Pot storage pot = pots[stock];
        return (pot.parked, pot.index, pot.epoch);
    }

    /// @notice take what pool `id` owes YOU, to any address you name. This is how a creator whose own address
    ///         cannot receive the stock -- deny-listed by its issuer, say -- still gets paid, and how one moves to a
    ///         multisig without this hook needing a recipient anyone could change. Nothing to do in the ordinary
    ///         case: every sweep already tries to pay you at your own address.
    function claim(PoolId id, address to) external returns (uint256 paid) { return _claim(id, msg.sender, to); }

    /// @notice push what is owed to `who`, to `who`. Anyone may call: a front end, a bot, the recipient's friend.
    function claimFor(PoolId id, address who) external returns (uint256 paid) { return _claim(id, who, who); }

    function _claim(PoolId id, address who, address to) internal returns (uint256 paid) {
        if (_distributing) revert Reentered();
        Pool storage p = _pool(id);
        _square(p);
        _distributing = true;
        paid = _pay(id, p, who, to);
        _distributing = false;
    }

    /// @dev the pot of `stock` as it stands against the balance. Only ever evaluated with nothing in flight --
    ///      before a redeem, or outside a payout -- so the balance is parked stock plus whatever is nobody's, and
    ///      being short of `parked` can only mean the issuer burned some.
    function _pot(address stock) internal view returns (uint256 parked, uint256 index, uint32 epoch) {
        Pot storage pot = pots[stock];
        parked = pot.parked; index = pot.index; epoch = pot.epoch;
        if (parked == 0) return (parked, index, epoch);
        uint256 bal = IERC20(stock).balanceOf(address(this));
        if (bal >= parked) return (parked, index, epoch);
        index = index * bal / parked;                                            // rounds DOWN: never worth more than is here
        if (index < MIN_INDEX) return (0, RAY, epoch + 1);
        parked = bal;
    }

    /// @dev Square the stock's pot with the balance -- however many pools hold claims on it, they are all read
    ///      through the one index -- and then bring THIS pool's three amounts up to it. Returns the stock.
    function _square(Pool storage p) internal returns (address stock) {
        stock = p.stock;
        Pot storage pot = pots[stock];
        (uint256 parked, uint256 index, uint32 epoch) = _pot(stock);
        if (parked != pot.parked) {
            emit WrittenDown(stock, pot.parked, parked);
            pot.parked = parked; pot.index = uint96(index); pot.epoch = epoch;
        }
        if (p.epoch != epoch) {                                                  // parked before a wipe-out: gone
            p.epoch = epoch; p.index = uint96(index);
            p.owedProtocol = 0; p.owedCreator = 0; p.owedTreasury = 0;
        } else if (p.index != index) {
            uint256 was = p.index;
            p.index = uint96(index);
            p.owedProtocol = p.owedProtocol * index / was; p.owedCreator = p.owedCreator * index / was; p.owedTreasury = p.owedTreasury * index / was;
        }
    }

    function _worth(Pool storage p, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        (, uint256 index, uint32 epoch) = _pot(p.stock);
        if (p.epoch != epoch) return 0;
        return p.index == index ? amount : amount * index / p.index;
    }

    /// @dev park `t`, `c` and `m` wei for the treasury, the protocol and the creator. The stock is already here, and
    ///      `_square` has already run in this call: the pool is at the current index, so a fresh credit is exact.
    function _credit(Pool storage p, address stock, uint256 t, uint256 c, uint256 m) internal {
        pots[stock].parked += t + c + m;
        if (t != 0) p.owedTreasury += t;
        if (c != 0) p.owedProtocol += c;
        if (m != 0) p.owedCreator += m;
    }

    /// @dev the ledger moves only if the stock did. Never reverts: a payout that fails leaves the debt where it was.
    ///      Only ever called after `_square`, so the three amounts are plain wei at the current index.
    function _pay(PoolId id, Pool storage p, address who, address to) internal returns (uint256 amount) {
        uint256 op = who == p.protocol ? p.owedProtocol : 0;
        uint256 oc = who == p.creator ? p.owedCreator : 0;
        uint256 ot = who == p.treasury ? p.owedTreasury : 0;
        amount = op + oc + ot;
        if (amount == 0 || to == address(0)) return 0;
        address stock = p.stock;
        // The ledger moves BEFORE the stock and is put back if the stock did not move: at no instant, seen from
        // inside the transfer, is the balance short of what the ledger says is parked.
        if (op != 0) p.owedProtocol = 0;
        if (oc != 0) p.owedCreator = 0;
        if (ot != 0) p.owedTreasury = 0;
        pots[stock].parked -= amount;
        if (!_tryPay(stock, to, amount)) {
            if (op != 0) p.owedProtocol = op;
            if (oc != 0) p.owedCreator = oc;
            if (ot != 0) p.owedTreasury = ot;
            pots[stock].parked += amount;
            return 0;
        }
        emit Claimed(id, who, to, amount);
    }

    function _tryPay(address stock, address to, uint256 amount) internal returns (bool ok) {
        try this.payStock(stock, to, amount) { return true; } catch { return false; }
    }

    /// @dev external only so a single recipient can be `try`ed; it pays nothing unless called from inside a payout.
    ///      A recipient that REVERTS is handled by the `try`. One that returns normally after leaving an open delta in
    ///      the manager -- `pm.mint(self, id, 1)` from a transfer callback is enough -- is not: the payout runs inside
    ///      this hook's own `unlock`, which would then revert `CurrencyNotSettled` and take every leg of every sweep of
    ///      that pool with it. So the manager's open-delta count must be what it was; if not, this frame reverts, the
    ///      recipient's delta goes with it, and the cut is parked like any other that failed.
    function payStock(address stock, address to, uint256 amount) external {
        if (msg.sender != address(this) || !_distributing) revert NotPoolManager();
        uint256 open_ = TransientStateLibrary.getNonzeroDeltaCount(poolManager);
        IERC20(stock).safeTransfer(to, amount);
        if (TransientStateLibrary.getNonzeroDeltaCount(poolManager) != open_) revert NotPoolManager();
    }

    // ------------------------------------------------------------------------------------------------ the owner
    // Whoever owns the factory, read live: the current owner or its successor after a two-step handover;
    // the factory disables ownership renunciation. Per pool, it can redirect the protocol's own cut, and it can -- slowly, in
    // public, and only if the creator does not object -- redirect the cut of a creator who has gone. It cannot touch
    // a rate, the rule, the treasury, the liquidity, or a wei that is owed to a creator who is still there to say no.

    uint256 public constant TAKEOVER_DELAY = 14 days;
    /// a creator who has vetoed is demonstrably there. Without this an owner could propose again the same minute,
    /// and hold a creator to a transaction every fourteen days for life.
    uint256 public constant VETO_QUIET = 180 days;
    /// a proposal that has matured must be used within this long or made again. Without it a proposal never
    /// accepted would stay usable for ever, leaving a creator who missed it takeable on no notice.
    uint256 public constant ACCEPT_WINDOW = 14 days;

    event ProtocolChanged(PoolId indexed id, address indexed from, address indexed to);
    event CreatorProposed(PoolId indexed id, address indexed current, address indexed proposed, uint256 effectiveAt);
    event CreatorVetoed(PoolId indexed id, address indexed by, address indexed proposed);
    event CreatorChanged(PoolId indexed id, address indexed from, address indexed to);

    function owner() public view returns (address) { return IOwned(factory).owner(); }

    modifier onlyOwner() { if (msg.sender != owner()) revert NotOwner(); _; }

    /// @notice move the protocol's payout in pool `id`, and whatever is parked for it, to `next`. Its own money; no delay.
    function setProtocol(PoolId id, address next) external onlyOwner {
        if (_distributing) revert Reentered();                                   // never from inside a payout
        if (next == address(0)) revert BadConfig();
        Pool storage p = _pool(id);
        emit ProtocolChanged(id, p.protocol, next);
        p.protocol = next;
    }

    /// @notice start the clock on handing a vanished creator's payout to `next`. Proposing again restarts it.
    function proposeCreator(PoolId id, address next) external onlyOwner {
        if (_distributing) revert Reentered();
        if (next == address(0)) revert BadConfig();
        Pool storage p = _pool(id);
        if (block.timestamp < p.noProposalBefore) revert TooEarly();
        p.pendingCreator = next; p.pendingBy = msg.sender;
        p.pendingCreatorAt = uint48(block.timestamp + TAKEOVER_DELAY);
        emit CreatorProposed(id, p.creator, next, block.timestamp + TAKEOVER_DELAY);
    }

    /// @notice the creator says no -- one call, from the creator's own address, which needs no stock and so works
    ///         even for a creator the issuer has deny-listed, and it buys `VETO_QUIET` in which nothing can be
    ///         proposed again. The owner may also withdraw its own proposal, which buys nothing.
    ///         The creator may also call it with NOTHING pending, as proof of life: otherwise an owner who withdrew
    ///         just ahead of the veto would deny the quiet period and could propose again the same minute.
    function vetoCreator(PoolId id) external {
        Pool storage p = _pool(id);
        bool isCreator = msg.sender == p.creator;
        if (!isCreator && msg.sender != owner()) revert NotCreator();
        if (p.pendingCreatorAt == 0 && !isCreator) revert NothingPending();
        emit CreatorVetoed(id, msg.sender, p.pendingCreator);
        p.pendingCreator = address(0); p.pendingCreatorAt = 0; p.pendingBy = address(0);
        if (isCreator) p.noProposalBefore = uint48(block.timestamp + VETO_QUIET);
    }

    /// @notice fourteen days of silence later. What was parked for the old creator goes with the role.
    function acceptCreator(PoolId id) external onlyOwner {
        if (_distributing) revert Reentered();
        Pool storage p = _pool(id);
        uint256 at = p.pendingCreatorAt;
        if (at == 0) revert NothingPending();
        if (block.timestamp < at) revert TooEarly();
        if (block.timestamp > at + ACCEPT_WINDOW || p.pendingBy != msg.sender) revert Expired();
        emit CreatorChanged(id, p.creator, p.pendingCreator);
        p.creator = p.pendingCreator;
        p.pendingCreator = address(0); p.pendingCreatorAt = 0; p.pendingBy = address(0);
    }

    // ------------------------------------------------------------------------------------------------ unused callbacks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) { revert HookNotImplemented(); }
    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external pure override returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure override returns (bytes4) { revert HookNotImplemented(); }
    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external pure override returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata) external virtual override returns (bytes4, BeforeSwapDelta, uint24) { revert HookNotImplemented(); }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure override returns (bytes4) { revert HookNotImplemented(); }
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure override returns (bytes4) { revert HookNotImplemented(); }
}
