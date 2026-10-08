// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HedgeFunToken} from "./HedgeFunToken.sol";
import {HedgeFunTreasuryBase} from "./HedgeFunTreasuryBase.sol";
import {HedgeFunHook} from "./hooks/HedgeFunHook.sol";
import {BoundDeployer, TreasuryDeployer, TokenDeployer} from "./HedgeFunDeployers.sol";
import {IHedgeFunTreasury} from "./interfaces/IHedgeFunTreasury.sol";
import {IUniswapV3Factory, IUniswapV3Pool} from "./interfaces/IUniswapV3.sol";
import {PriceOracle} from "./PriceOracle.sol";
import {BPS} from "./libraries/HedgeFunMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {MAX_TAX_BPS, MAX_SPIKE_BPS, MAX_TIP_BPS, MAX_SNIPE_BPS, MAX_BOUNTY_BPS, MAX_SLIPPAGE_BPS, MAX_BAND_BPS_PER_HOUR, MAX_BUYBACK_IMPACT_BPS, MAX_NAME_BYTES, MAX_SYMBOL_BYTES} from "./libraries/HedgeFunLimits.sol";


/// A launchpad for strategy tokens. A creator picks a listed stock, names the token and fills in the RULE
/// (take-profit steps, the dip, an optional stop, the lot size) and the tax; the factory deploys a fixed-supply
/// token and the treasury that trades that stock under that rule, registers the <token>/<stock> V4 pool with the
/// shared tax hook, and seeds it with the ENTIRE supply as single-sided liquidity that nobody can ever
/// withdraw, because this contract owns the position and has no function to remove it. A launch therefore needs no
/// capital: the first buyer brings the first stock. A creator who wants to BE that first buyer, and to give the
/// treasury a first lot, does both atomically through `HedgeFunLaunchRouter` -- periphery this contract knows nothing about.
///
/// What a creator can NOT choose, because each one is a way to rob the people who buy the token:
///   - the stock's oracle and the pool its treasury trades in. Those come from the owner's listing of the stock; a
///     creator-supplied oracle is a creator-controlled price.
///   - the protocol's share, the execution bounds (slippage, deviation, the sell and buy-back chunks, the buy-back's
///     cooldown and impact), the supply and the opening price. Those are the factory's defaults at the moment of
///     launch -- except slippage, deviation and the sell chunk where the owner has given the stock its own
///     (`setListingGates`).
/// What the OWNER cannot do: touch anything already launched. Listings and defaults apply to future launches only;
/// a launched strategy has no mutable parameter. Its hook answers to this contract's owner for the pool's two payout
/// addresses, and its treasury for one thing: whom the stock it holds votes through (`setVoteDelegate`), which moves
/// no asset and cannot reach the rule.
contract HedgeFunFactory is Ownable2Step, IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// what the creator fills in
    struct Request {
        string name;
        string symbol;
        address stock;
        address creator;                 // receives creatorBps of the stock-denominated tax, forever
        uint16 taxBps;
        uint16 creatorBps;
        uint32 tp1Bps;                   // uint32: a take-profit may sit far above cost (100x = 990,000 bps). Unbounded above, on purpose
        uint32 tp2Bps;                   // 0 = sell the whole lot at tp1
        uint16 dipBps;
        uint16 stopBps;                  // 0 = never sell at a loss
        uint16 lotBps;
        uint16 bandBpsPerHour;           // <= bandCeiling[stock]. 0 = Chainlink only. See HedgeFunTreasury.health
        /// picked by whoever launches, and the only thing that separates two launches of the same symbol by the
        /// same creator. It is in the CREATE2 salt so that a launch that cannot go through -- someone launched the
        /// same (symbol, creator, nonce) first -- is retried under a new number rather than being stuck forever.
        /// The salt depends on nothing else that moves, so other people's launches cannot shift a predicted address.
        uint96 nonce;
        /// what the launcher agreed to. The fee and the opening price are the only launch inputs that `terms` (see
        /// `predict`) does not pin, because they are in no address and no rate: without these two the owner could raise a
        /// USDG fee under a creator's standing approval, or re-list the stock 1000x cheaper and buy half the supply
        /// for the price of a coffee -- and, with no malice at all, an ordinary re-listing could land between a
        /// creator reading the price and their launch confirming. In the struct, not the signature: `launch` is one
        /// stack slot from the limit.
        uint256 maxFee;
        uint256 expectedOpenPriceE18;
    }

    /// what the owner lists per stock. openPriceE18 is stock per token; v3Pool is where its treasuries trade it.
    struct Listing { address oracle; address v3Pool; uint256 openPriceE18; bool enabled; }

    /// FeeCurrency.None charges nothing. .Native takes `msg.value` in this chain's native asset, sent straight to
    /// `protocol` — no swap, no price lookup, nothing that can be gamed. .Stock takes the fee in the SAME stock the
    /// strategy is being launched against, at whatever `launchFeeAmount` is in that stock's own decimals — appropriate
    /// because a creator launching e.g. an NVDA strategy plausibly already holds NVDA and does not want to touch USDG
    /// at all. .Usdg takes `launchFeeAmount` in USDG.
    enum FeeCurrency { None, Native, Usdg, Stock }

    /// what every launch gets
    struct Defaults {
        uint256 supply;
        uint24 lpFee;
        int24 tickSpacing;
        uint16 minTaxBps;
        uint16 maxTaxBps;
        uint16 protocolBps;
        uint16 maxCreatorBps;
        uint16 spikeBps;
        uint32 spikeSeconds;
        uint16 sweepTipBps;
        uint16 snipeBps;                  // buy rate at the instant of a launch, falling to the tax over snipeSeconds; 0 = off
        uint8 snipeSeconds;
        uint16 bountyBps;
        uint16 maxSlippageBps;
        uint16 maxDeviationBps;
        uint16 maxBuybackImpactBps;
        uint32 buybackCooldown;
        uint256 minLotUsdg;
        uint256 buybackChunkUsdg;
        uint256 sellChunkUsdg;            // the most one takeProfit/stopLoss call sells; see HedgeFunTreasuryBase.Params
        FeeCurrency launchFeeCurrency;
        uint256 launchFeeAmount;          // units of launchFeeCurrency: wei for Native, the token's own decimals otherwise
    }

    struct Strategy { address token; address treasury; address hook; address stock; address creator; }

    IPoolManager public immutable poolManager;
    IUniswapV3Factory public immutable v3Factory;
    address public immutable usdg;
    address public immutable protocol;
    TreasuryDeployer public immutable treasuryDeployer;
    TokenDeployer public immutable tokenDeployer;
    /// the one hook every strategy's pool runs on. Bound to this factory in the constructor; it registers nothing for anyone else.
    HedgeFunHook public immutable hook;

    Defaults internal defaults;
    function getDefaults() public view returns (Defaults memory) { return defaults; }
    mapping(address => Listing) public listings;
    bool public publicLaunch;                                 // false: only the owner may launch
    Strategy[] public strategies;
    mapping(address => uint16) public bandCeiling;
    mapping(address => bool) public launchers;
    /// the two execution gates, per stock, because pools of different fee tiers sit at different distances from
    /// Chainlink and one pair cannot fit them all. Both zero (the default) means the factory's defaults. The owner's to set and never a creator's: `maxSlippageBps` is
    /// the most a sandwich takes from the holders' treasury on every trade it ever makes.
    ///
    /// `sellChunkUsdg` rides in the same slot, with its own zero-means-default. A sale fills as far as the slippage
    /// limit lets it and keeps the rest, so a chunk too big for a pool does not stop a sale; it only costs price
    /// (each call may walk the pool to the limit, about half the slippage on average). That makes it a number to size
    /// per stock from measured depth. uint64 of 6-decimal USDG is 1.8e13 USDG, and the three still pack in one slot.
    struct Gates { uint16 maxDeviationBps; uint16 maxSlippageBps; uint64 sellChunkUsdg; }
    mapping(address => Gates) public listingGates;
    bool private _seeding;

    event Launched(uint256 indexed id, string symbol, address token, address treasury, address hook, address stock, address creator);
    event BandCeilingSet(address indexed stock, uint16 bps);
    event LauncherSet(address indexed launcher, bool ok);
    event ListingGatesSet(address indexed stock, uint16 maxDeviationBps, uint16 maxSlippageBps, uint64 sellChunkUsdg);
    event Listed(address indexed stock, address oracle, address v3Pool, uint256 openPriceE18, bool enabled);
    event DefaultsSet(Defaults d);
    event PublicLaunchSet(bool open);

    error WrongPool();
    error NotListed();
    error Restated();
    error NotOpen();
    error BadRequest();
    error NotPoolManager();
    error OwnershipRenunciationDisabled();

    /// @dev the deployer is passed in rather than created here: embedding its creation code would put this
    ///      contract's own initcode over the EIP-3860 limit. It holds no state and trusts nobody, so anyone's
    ///      deployment of it is as good as ours. The hook is passed in because its ADDRESS is its permission set,
    ///      and is mined; it must be unbound, and it must sit on this pool manager.
    constructor(address owner_, address poolManager_, address v3Factory_, address usdg_, address protocol_,
                address treasuryDeployer_, address tokenDeployer_, address hook_, Defaults memory d) Ownable(owner_) {
        require(poolManager_ != address(0) && v3Factory_ != address(0) && usdg_ != address(0) && protocol_ != address(0), "zero");
        require(treasuryDeployer_.code.length != 0 && tokenDeployer_.code.length != 0 && hook_.code.length != 0, "deployers");
        poolManager = IPoolManager(poolManager_); v3Factory = IUniswapV3Factory(v3Factory_); usdg = usdg_; protocol = protocol_;
        treasuryDeployer = TreasuryDeployer(treasuryDeployer_); tokenDeployer = TokenDeployer(tokenDeployer_);
        hook = HedgeFunHook(hook_);
        require(address(hook.poolManager()) == poolManager_, "hook");
        // claim both, so nobody else can deploy through the deployer at an address a launch is counting on, and
        // nobody else can register a pool on the hook. One already claimed reverts here, which is the right moment
        // to find out.
        BoundDeployer(treasuryDeployer_).bind();
        BoundDeployer(tokenDeployer_).bind();
        hook.bind();
        _setDefaults(d);
    }

    /// @notice Ownership may be transferred in two steps, but cannot be renounced: treasury vote delegation
    ///         and the hook's payout administration depend on the factory retaining an owner.
    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }

    // ------------------------------------------------------------------------------------------------ owner: future launches only
    function setDefaults(Defaults calldata d) external onlyOwner { _setDefaults(d); }
    function _setDefaults(Defaults memory d) internal {
        if (d.supply == 0 || d.minTaxBps > d.maxTaxBps || uint256(d.protocolBps) + d.maxCreatorBps > BPS) revert BadRequest();
        // Everything a launch hands to a constructor is checked HERE as well. A constructor's revert reason does not
        // survive CREATE2, so a default the treasury refuses bricks every launch as an opaque `TreasuryDeployFailed` until
        // someone works out which of two dozen numbers it was. (The hook's bounds are checked by `register`, whose
        // reason does survive -- but a default that fails there still fails EVERY launch, so it is refused here too.)
        if (d.maxTaxBps > MAX_TAX_BPS || d.spikeBps > MAX_SPIKE_BPS || d.sweepTipBps > MAX_TIP_BPS || d.bountyBps > MAX_BOUNTY_BPS || d.snipeBps > MAX_SNIPE_BPS) revert BadRequest();
        if (!_gatesOk(d.maxDeviationBps, d.maxSlippageBps)) revert BadRequest();
        if (d.maxBuybackImpactBps == 0 || d.maxBuybackImpactBps > MAX_BUYBACK_IMPACT_BPS || d.minLotUsdg == 0 || d.buybackChunkUsdg == 0 || d.sellChunkUsdg < d.minLotUsdg) revert BadRequest();   // a chunk under a lot: thousands of calls, bounties that floor to zero
        // V1 cannot collect fees from its permanently locked position. A later factory may opt in
        // only if its position owner exposes a fee-only collection path.
        if (d.lpFee < _minLpFee() || d.lpFee > _maxLpFee() || d.tickSpacing < 1) revert BadRequest();
        defaults = d; emit DefaultsSet(d);
    }
    function _minLpFee() internal pure virtual returns (uint24) { return 0; }
    function _maxLpFee() internal pure virtual returns (uint24) { return 0; }
    function setPublicLaunch(bool open) external onlyOwner { publicLaunch = open; emit PublicLaunchSet(open); }
    /// @notice the most `bandBpsPerHour` a creator may ask for on `stock`. Per stock, because what a band risks is a
    ///         pinned pool, and what a pin costs is that pool's depth.
    ///         Zero until the owner says otherwise, so a new listing is Chainlink-only by default. Reaches
    ///         future launches only; a treasury's band is frozen at birth.
    function setBandCeiling(address stock, uint16 bps) external onlyOwner {
        if (bps > MAX_BAND_BPS_PER_HOUR) revert BadRequest();
        bandCeiling[stock] = bps; emit BandCeilingSet(stock, bps);
    }
    /// @notice the deviation and slippage gates treasuries of `stock` are born with, in place of the defaults. (0, 0)
    ///         clears them. Anything else meets the bounds the defaults meet, which are the treasury constructor's own:
    ///         a pair it refuses would fail every launch of this stock as an opaque `TreasuryDeployFailed`. Reaches future
    ///         launches only, and not one already quoted: the gates are constructor arguments, so they are in the
    ///         treasury's address, which is in `terms` -- a launch quoted before this call reverts `Restated`.
    ///         `chunk` is the stock's own `sellChunkUsdg`, independently of the pair: 0 means the default, anything
    ///         else is at least a lot, as the default must be (`_lotParams` asks again at launch, since `minLotUsdg`
    ///         can move afterwards). It is a constructor argument like the gates, so `terms` covers it the same way.
    function setListingGates(address stock, uint16 dev, uint16 slip, uint64 chunk) external onlyOwner {
        if (((dev | slip) != 0 && !_gatesOk(dev, slip)) || (chunk != 0 && chunk < defaults.minLotUsdg)) revert BadRequest();
        listingGates[stock] = Gates(dev, slip, chunk); emit ListingGatesSet(stock, dev, slip, chunk);
    }
    function _gatesOk(uint16 dev, uint16 slip) internal pure returns (bool) { return slip <= MAX_SLIPPAGE_BPS && dev != 0 && dev < slip; }
    /// @dev the ONE place the effective gates are read. Anything that depends on them goes through here, so a
    ///      listing's values and the defaults can never be consulted by two different rules. The pair falls back as
    ///      a pair; the chunk falls back on its own.
    function _gates(address stock, uint16 band, Defaults memory d) internal view returns (uint16 dev, uint16 slip, uint256 chunk) {
        Gates storage g = listingGates[stock];
        (dev, slip) = g.maxSlippageBps == 0 ? (d.maxDeviationBps, d.maxSlippageBps) : (g.maxDeviationBps, g.maxSlippageBps);
        chunk = g.sellChunkUsdg == 0 ? d.sellChunkUsdg : g.sellChunkUsdg;
        // A launch that trades closures never gets MORE than the default chunk. On an open market the chunk only costs
        // price; at a pinned pool each hourly sale is min(chunk, depth), so a larger chunk sells more at a pinned price.
        if (band != 0 && chunk > d.sellChunkUsdg) chunk = d.sellChunkUsdg;
    }
    /// @notice vouch for a periphery contract that launches on its caller's behalf. It must refuse any `q.creator` but
    ///         its own caller, or the check in `launch` means nothing.
    function setLauncher(address launcher, bool ok) external onlyOwner { launchers[launcher] = ok; emit LauncherSet(launcher, ok); }

    /// @notice list a stock: which oracle prices it and which V3 pool its treasuries trade in. The pool must
    ///         be the canonical one for the pair (V3 has exactly one pool per fee tier, enforced by its factory);
    ///         the oracle must be for this stock.
    function list(address stock, address oracle, address v3Pool, uint256 openPriceE18, bool enabled) external onlyOwner {
        if (v3Factory.getPool(usdg, stock, IUniswapV3Pool(v3Pool).fee()) != v3Pool) revert WrongPool();
        if (PriceOracle(oracle).stock() != stock || openPriceE18 == 0) revert BadRequest();
        listings[stock] = Listing(oracle, v3Pool, openPriceE18, enabled);
        emit Listed(stock, oracle, v3Pool, openPriceE18, enabled);
    }

    function strategyCount() external view returns (uint256) { return strategies.length; }

    // ------------------------------------------------------------------------------------------------ addresses, before the fact
    function _salt(Request memory q) internal pure returns (bytes32) { return keccak256(abi.encode(q.symbol, q.creator, q.nonce)); }

    function predictToken(Request memory q) public view returns (address) {
        return tokenDeployer.predict(_salt(q), _tokenArgs(q, defaults.supply));
    }

    /// @dev the whole supply is minted to this contract, which seeds the pool with it. `q.creator` becomes the token's
    ///      `deployer`: the one address that may write the token's metadata, and nothing else about it.
    function _tokenArgs(Request memory q, uint256 supply) internal view returns (bytes memory) {
        return abi.encode(q.name, q.symbol, supply, address(this), q.creator);
    }

    function _lotParams(Request memory q, Defaults memory d) internal view returns (HedgeFunTreasuryBase.Params memory p) {
        p = HedgeFunTreasuryBase.Params({tp1Bps: q.tp1Bps, tp2Bps: q.tp2Bps, dipBps: q.dipBps, stopBps: q.stopBps,
            lotBps: q.lotBps, bountyBps: d.bountyBps, maxSlippageBps: 0, maxDeviationBps: 0,
            maxBuybackImpactBps: d.maxBuybackImpactBps, buybackCooldown: d.buybackCooldown, minLotUsdg: d.minLotUsdg, buybackChunkUsdg: d.buybackChunkUsdg,
            sellChunkUsdg: 0, bandBpsPerHour: q.bandBpsPerHour});
        (p.maxDeviationBps, p.maxSlippageBps, p.sellChunkUsdg) = _gates(q.stock, q.bandBpsPerHour, d);
        // a listing's chunk was checked against the `minLotUsdg` of the day it was set, and defaults move: a chunk
        // under a lot is thousands of calls and bounties that floor to zero, refused here as it is in `_setDefaults`
        if (p.sellChunkUsdg < d.minLotUsdg) revert BadRequest();
    }

    function _treasuryArgs(Request memory q, address token) internal view returns (bytes memory) {
        Listing memory L = listings[q.stock]; Defaults memory d = getDefaults();
        return abi.encode(usdg, q.stock, L.v3Pool, L.oracle, token, address(poolManager), address(this), _lotParams(q, d));
    }

    /// @notice where a launch of `q` will land, and the TERMS it will land on -- hand `terms` back to `launch`. The
    ///         hook is `hook`, always; the pool is (token, q.stock) in address order at `lpFee` and `tickSpacing`.
    function predict(Request memory q) external view returns (address token, address treasury, bytes32 terms) {
        token = predictToken(q);
        treasury = treasuryDeployer.predict(_salt(q), _treasuryArgs(q, token));
        terms = _terms(q, token, treasury, getDefaults());
    }

    /// @dev The launcher's commitment to what it was quoted. It covers the token (so the supply), the treasury (so
    ///      the listing's oracle and pool, and every execution bound, all of which are in its address), the pool's
    ///      fee and spacing, and the rates -- so an owner who moves ANY default or re-lists the stock underneath a
    ///      pending launch makes it revert `Restated` instead of going through on terms nobody agreed to. Without
    ///      this the owner could take `protocolBps` to 100% minus the creator's cut in the block before a launch.
    function _terms(Request memory q, address token, address treasury, Defaults memory d) internal view virtual returns (bytes32) {
        // ... and the fee's CURRENCY: `maxFee` alone is a number, and 1e16 of a stock is a very different thing from
        // 1e16 of USDG under a standing approval
        return keccak256(abi.encode(token, treasury, d.lpFee, d.tickSpacing, _rates(q, d), d.launchFeeCurrency, d.launchFeeAmount));
    }

    // ------------------------------------------------------------------------------------------------ launch
    /// @dev `nonReentrant` because the launch fee is paid out before anything is deployed, and a fee recipient
    ///      that re-enters would otherwise launch from inside a launch. The re-entry would land before any seeding,
    ///      so the `_seeding` window would not overlap -- but that is a fact about call ordering, not a guarantee.
    function launch(Request memory q, bytes32 terms) external payable nonReentrant returns (uint256 id) { return _launch(q, terms); }

    /// @notice the same launch, and the token's page written in the same transaction (see `HedgeFunToken.initMetadata`
    ///         for why a coin should never be live with an empty card). `info` is the creator's and nobody else's:
    ///         `_launch` only takes a launch from `q.creator` or from a launcher that insists on the same. It is not
    ///         in `terms` -- it is the creator's own text, not something quoted to them. A field over the token's caps
    ///         reverts the whole launch (`TooLong`): validate byte lengths before sending.
    function launchWithMetadata(Request memory q, bytes32 terms, HedgeFunToken.Info calldata info) external payable nonReentrant returns (uint256 id) {
        id = _launch(q, terms);
        HedgeFunToken(strategies[id].token).initMetadata(info);
    }

    function _launch(Request memory q, bytes32 terms) internal returns (uint256 id) {
        if (!publicLaunch && msg.sender != owner()) revert NotOpen();
        // A launch is sent by its creator, or by a launcher the owner has vouched for (`HedgeFunLaunchRouter`, which itself
        // insists `q.creator` is ITS caller). The salt is (symbol, creator, nonce): if anyone could launch in anyone's
        // name, a bot copying an announced launch would occupy its addresses, leave a strategy that looks like the
        // creator's own, and make the creator's launch collide and revert.
        if (msg.sender != q.creator && !launchers[msg.sender]) revert BadRequest();
        // the token's own metadata is capped; these two are not the token's to refuse. Uncapped, an oversized name
        // would cost the launch its gas and ride out in `Launched` for every indexer and wallet to choke on.
        if (bytes(q.name).length > MAX_NAME_BYTES || bytes(q.symbol).length > MAX_SYMBOL_BYTES) revert BadRequest();
        Listing memory L = listings[q.stock];
        if (!L.enabled) revert NotListed();
        Defaults memory d = getDefaults();
        if (q.creator == address(0) || q.taxBps < d.minTaxBps || q.taxBps > d.maxTaxBps || q.creatorBps > d.maxCreatorBps) revert BadRequest();
        if (q.bandBpsPerHour > bandCeiling[q.stock]) revert BadRequest();
        if (d.launchFeeAmount > q.maxFee || L.openPriceE18 != q.expectedOpenPriceE18) revert Restated();
        _chargeLaunchFee(d, q.stock);

        address token = tokenDeployer.deploy(_salt(q), _tokenArgs(q, d.supply));
        // validates the rule's bounds
        address treasury = treasuryDeployer.deploy(_salt(q), _treasuryArgs(q, token));
        if (_terms(q, token, treasury, d) != terms) revert Restated();                  // see `_terms`
        _openAndSeed(q, token, treasury, L.openPriceE18, d);

        id = strategies.length;
        strategies.push(Strategy(token, treasury, address(hook), q.stock, q.creator));
        emit Launched(id, q.symbol, token, treasury, address(hook), q.stock, q.creator);
    }

    /// @dev a stray `msg.value` on a non-Native launch is refused rather than silently kept: sending ETH to a call
    ///      that was never going to look at it is almost always a mistake worth surfacing, not revenue worth taking.
    function _chargeLaunchFee(Defaults memory d, address stock) internal {
        if (d.launchFeeCurrency == FeeCurrency.None) { if (msg.value != 0) revert BadRequest(); return; }
        if (d.launchFeeCurrency == FeeCurrency.Native) {
            if (msg.value != d.launchFeeAmount) revert BadRequest();
            (bool ok,) = protocol.call{value: msg.value}("");
            if (!ok) revert BadRequest();
            return;
        }
        if (msg.value != 0) revert BadRequest();
        address feeToken = d.launchFeeCurrency == FeeCurrency.Stock ? stock : usdg;
        if (d.launchFeeAmount != 0) IERC20(feeToken).safeTransferFrom(msg.sender, protocol, d.launchFeeAmount);
    }

    function _rates(Request memory q, Defaults memory d) internal pure returns (HedgeFunHook.Rates memory) {
        return HedgeFunHook.Rates({taxBps: q.taxBps, spikeBps: d.spikeBps, spikeSeconds: d.spikeSeconds,
            protocolBps: d.protocolBps, creatorBps: q.creatorBps, sweepTipBps: d.sweepTipBps,
            snipeBps: d.snipeBps, snipeSeconds: d.snipeSeconds});
    }

    /// @dev its own frame: eight arguments on top of `_openAndSeed`'s locals is one stack slot too many
    function _register(PoolKey memory key, Request memory q, address token, address treasury, Defaults memory d) internal {
        hook.register(key, token, q.stock, treasury, protocol, q.creator, msg.sender, _rates(q, d));
    }

    function _openAndSeed(Request memory q, address token, address treasury, uint256 openPriceE18, Defaults memory d) internal virtual {
        bool tokenIs0 = token < q.stock;
        PoolKey memory key = tokenIs0
            ? PoolKey(Currency.wrap(token), Currency.wrap(q.stock), d.lpFee, d.tickSpacing, hook)
            : PoolKey(Currency.wrap(q.stock), Currency.wrap(token), d.lpFee, d.tickSpacing, hook);
        // The hook answers `beforeInitialize` only for a pool it has been told about, and only this contract can
        // tell it. Its bounds are the ones `_setDefaults` mirrors; unlike a constructor's, its reason survives.
        _register(key, q, token, treasury, d);
        // openPrice is stock per token; currency1 per currency0 is that, or its inverse
        uint160 sqrtP = uint160(Math.sqrt(tokenIs0 ? Math.mulDiv(openPriceE18, 1 << 192, 1e18) : Math.mulDiv(1e18, 1 << 192, openPriceE18)));
        poolManager.initialize(key, sqrtP);
        IHedgeFunTreasury(treasury).wire(key);

        _seeding = true;
        poolManager.unlock(abi.encode(key, token, d.supply, sqrtP));
        _seeding = false;
        uint256 dust = IERC20(token).balanceOf(address(this));
        if (dust != 0) HedgeFunToken(token).burn(dust);
    }

    /// @dev the whole supply as ONE single-sided position on the side of the price the token is bought into. This
    ///      contract is the position's owner and has no way to take it back out.
    function unlockCallback(bytes calldata data) external virtual override returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_seeding) revert NotPoolManager();
        (PoolKey memory key, address token, uint256 supply, uint160 sqrtP) = abi.decode(data, (PoolKey, address, uint256, uint160));
        bool tokenIs0 = Currency.unwrap(key.currency0) == token;
        (int24 lo, int24 hi, uint256 liq) = _seedRange(key.tickSpacing, sqrtP, tokenIs0, supply - supply / 1e12);   // the manager rounds what it is owed UP

        (BalanceDelta d,) = poolManager.modifyLiquidity(key, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: int256(liq), salt: 0}), "");
        int128 owed = tokenIs0 ? d.amount0() : d.amount1();
        poolManager.sync(Currency.wrap(token));
        IERC20(token).transfer(address(poolManager), uint256(uint128(-owed)));
        poolManager.settle();
        return "";
    }

    /// @dev the range sits entirely on the side of the opening price that the token is BOUGHT into, so it is made of
    ///      the token alone: above the price when the token is currency0, below it when it is currency1.
    function _seedRange(int24 sp, uint160 sqrtP, bool tokenIs0, uint256 amount) internal pure returns (int24 lo, int24 hi, uint256 liq) {
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 floorT = (tick / sp) * sp; if (tick < 0 && tick % sp != 0) floorT -= sp;
        (lo, hi) = tokenIs0 ? (floorT + sp, TickMath.maxUsableTick(sp)) : (TickMath.minUsableTick(sp), floorT);
        uint160 a = TickMath.getSqrtPriceAtTick(lo); uint160 b = TickMath.getSqrtPriceAtTick(hi);
        liq = tokenIs0 ? FullMath.mulDiv(amount, FullMath.mulDiv(a, b, FixedPoint96.Q96), b - a) : FullMath.mulDiv(amount, FixedPoint96.Q96, b - a);
    }
}
