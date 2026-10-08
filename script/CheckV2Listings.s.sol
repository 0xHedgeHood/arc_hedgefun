// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {CurveDeployer} from "../src/v2/CurveDeployer.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {PoolTrader} from "../src/PoolTrader.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {HedgeFunMath} from "../src/libraries/HedgeFunMath.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice The treasury's own price code on a listing's pool and oracle: `_health` is the exact deviation gate a
///         V1 or V2 treasury applies (spot vs oracle, AND spot tick vs the pool's 600 s mean). Deploying it also runs
///         `PoolTrader`'s constructor, so a pool whose observation ring is too short for the window fails here the
///         way it would fail a treasury deployment.
contract V2CheckGateProbe is PoolTrader {
    constructor(address usdg_, address stock_, address pool_, address oracle_) PoolTrader(usdg_, stock_, pool_, oracle_) {}

    function health(uint256 maxDeviationBps) external view returns (bool ok, uint256 p) { return _health(maxDeviationBps); }
    function priceAt(uint160 sqrtP) external view returns (uint256) { return _priceAtSqrt(sqrtP); }
    function sqrtAt(uint256 p) external view returns (uint160) { return _sqrtPriceX96(p); }

    /// @return ok false when the ring cannot serve the window (the treasury then fails closed)
    function meanTick() external view returns (bool ok, int256 mean) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW;
        try pool.observe(ago) returns (int56[] memory tc, uint160[] memory) {
            return (true, _meanTick(int256(tc[1]) - int256(tc[0])));
        } catch { return (false, 0); }
    }
}

/// @notice Runs a V3 pool's own `swap` and reverts from inside the callback, like Uniswap's QuoterV2: the pool
///         computes the whole trade and moves its price, the callback reads the post-trade slot0 and asks the gate
///         probe whether a treasury would still trade there, and the revert undoes everything. No token is dealt
///         and no fork state survives a quote.
contract V2CheckQuoter {
    bytes32 internal constant MAGIC = keccak256("CheckV2Listings.quote");

    struct Quote {
        bool ok;             // the pool reached the callback; false = the swap reverted (err says why)
        int256 amount0;
        int256 amount1;
        uint160 sqrtAfter;
        int24 tickAfter;
        bool healthAfter;    // V2CheckGateProbe.health(dev) evaluated on the post-trade pool
        uint256 spotAfter;   // post-trade spot, oracle units
        string err;
    }

    /// what the callback reverts with; decoded as one struct to stay inside the legacy pipeline's stack
    struct Packed { bytes32 tag; int256 amount0; int256 amount1; uint160 sqrtAfter; int24 tickAfter; bool healthAfter; uint256 spotAfter; }

    V2CheckGateProbe private _probe;
    uint256 private _dev;

    function quote(IUniswapV3Pool pool, bool zeroForOne, int256 amount, uint160 limit, V2CheckGateProbe probe, uint256 dev)
        external returns (Quote memory q)
    {
        _probe = probe;
        _dev = dev;
        try pool.swap(address(this), zeroForOne, amount, limit, "") {
            q.err = "swap returned without calling back";
        } catch (bytes memory r) {
            if (r.length == 224 && abi.decode(r, (Packed)).tag == MAGIC) {
                Packed memory k = abi.decode(r, (Packed));
                (q.ok, q.amount0, q.amount1, q.sqrtAfter) = (true, k.amount0, k.amount1, k.sqrtAfter);
                (q.tickAfter, q.healthAfter, q.spotAfter) = (k.tickAfter, k.healthAfter, k.spotAfter);
            } else {
                q.err = _reason(r);
            }
        }
    }

    function uniswapV3SwapCallback(int256 amount0, int256 amount1, bytes calldata) external view {
        (uint160 s, int24 t,,,,,) = IUniswapV3Pool(msg.sender).slot0();
        (bool h,) = _probe.health(_dev);
        bytes memory out = abi.encode(Packed(MAGIC, amount0, amount1, s, t, h, _probe.spotPrice()));
        assembly ("memory-safe") { revert(add(out, 32), mload(out)) }
    }

    function _reason(bytes memory r) internal pure returns (string memory) {
        if (r.length >= 68 && bytes4(r) == 0x08c379a0) {
            // drop the selector: write the shortened length over its last 4 bytes and point past them
            assembly ("memory-safe") {
                mstore(add(r, 4), sub(mload(r), 4))
                r := add(r, 4)
            }
            return abi.decode(r, (string));
        }
        if (r.length >= 4) return string.concat("custom error ", _hex4(bytes4(r)));
        return "empty revert";
    }

    function _hex4(bytes4 b) internal pure returns (string memory) {
        bytes memory h = "0123456789abcdef";
        bytes memory s = new bytes(10);
        s[0] = "0"; s[1] = "x";
        for (uint256 i; i < 4; i++) {
            s[2 + 2 * i] = h[uint8(b[i]) >> 4];
            s[3 + 2 * i] = h[uint8(b[i]) & 15];
        }
        return string(s);
    }
}

/// @notice Pre-launch check for Hedgefun V2 listings (audit round 3 M-2 / M-3, round 4 M4-1). READ-ONLY: run it
///         with `forge script` against a fork and never with `--broadcast`; it refuses a broadcast context and never
///         calls startBroadcast. Driven by `tools/v2_launch_check.py`, which pins the block, builds the plan and
///         judges the lines this prints; the verdict logic lives there and is unit-tested.
///
/// For each stock it prints one line, `V2CHECK {json}`, with:
///   - the curve terms, from a real `HedgeFunBondingCurve` deployed on the fork with the listing's openPriceE18,
///     supply and saleBps, so Rg = terminalStock - virtualStock is the contract's own integer arithmetic;
///   - one exact-output buy of Rg stock with USDG through the listing's V3 pool: USDG cost, stock delivered, the
///     post-trade price and tick, and whether a treasury's `_health(maxDeviationBps)` still passes after it;
///   - a drain: an exact-input buy of DRAIN_USDG, which is everything the pool's stock side can deliver at any
///     price a buyer could pay;
///   - the gate's headroom: an exact-input buy stopped at the tighter of the two edges `_health` enforces (spot at
///     oracle + maxDeviationBps, spot tick at the 600 s mean tick + maxDeviationBps), i.e. the most stock a single
///     buyer can take out of the pool while every treasury on it can still trade;
///   - USDG depth for a 1% move of the pool's spot, up (USDG spent buying stock) and down (USDG received selling it).
///
/// Entry points:
///   run(address factory, bytes plan)            plan = abi.encode(Entry[]); factory 0 = take every field from plan,
///                                               otherwise take `stock` and `saleBps` from it and read the rest from
///                                               factory. `saleBps` is the creator's choice, never the factory's
///                                               (`CurveDeployer.setCurveConfig`): 0 = the deployer's default
///   runFactory(address factory, address[] stocks)
contract CheckV2Listings is Script {
    address internal constant MAINNET_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    /// the listing's quote token: the factory's own `usdg` when one is given (the testnet's is tUSDG), else mainnet's
    address internal usdg;
    uint160 internal constant MIN_SQRT = 4295128739;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;
    /// the drain's budget: 500 million USDG, round 3's All18 figure. Far past any raise; bounded so a full-range
    /// position (which quotes stock at every price) cannot make the quote overflow.
    uint256 internal constant DRAIN_USDG = 500_000_000e6;
    /// the depth-down quote's stock budget; the 1% price limit stops the swap long before it is spent
    uint256 internal constant HUGE_STOCK = 1e36;
    /// `CurveDeployer.DEFAULT_SALE_BPS`, assumed only for a factory that has no curve deployer to ask
    uint16 internal constant DEFAULT_SALE_BPS = 7931;

    struct Entry {
        address stock;
        address oracle;
        address pool;
        uint256 openPriceE18;
        uint256 supply;
        uint16 saleBps;
        uint16 maxDeviationBps;
        uint16 maxSlippageBps;
        uint256 sellChunkUsdg;
    }

    struct R {
        Entry e;
        string symbol;
        string source;          // "plan" or "factory"
        string saleBpsSource;   // where saleBps came from: "plan", "creator", or the factory's curve deployer default
        bool enabled;
        string configError;     // non-empty: the listing is unusable as configured; nothing else was measured
        uint24 fee;
        int24 tickSpacing;
        bool stockIsToken0;
        uint8 stockDecimals;
        uint8 usdgDecimals;
        uint256 virtualStock;
        uint256 minTokenReserve;
        uint256 terminalStock;
        uint256 rg;
        bool oracleLive;
        uint256 oraclePrice;
        uint256 oracleUpdatedAt;
        uint160 sqrt0;
        int24 tick0;
        bool meanOk;
        int256 meanTick;
        uint256 spot0;
        bool healthBefore;
        V2CheckQuoter.Quote rgq;
        uint256 rgOut;
        uint256 rgUsdgIn;
        V2CheckQuoter.Quote drain;
        uint256 deliverable;
        uint256 drainUsdgIn;
        V2CheckQuoter.Quote gate;
        uint160 gateLimit;
        uint256 gateStock;
        uint256 gateUsdg;
        V2CheckQuoter.Quote up;
        uint256 upUsdg;
        uint256 upStock;
        V2CheckQuoter.Quote down;
        uint256 downUsdg;
        uint256 downStock;
    }

    V2CheckQuoter internal quoter;

    function run(address factory, bytes calldata plan) external {
        Entry[] memory es = abi.decode(plan, (Entry[]));
        _begin(factory, es.length);
        for (uint256 i; i < es.length; i++) _one(factory, es[i]);
        console2.log("V2CHECK_DONE", es.length);
    }

    function runFactory(address factory, address[] calldata stocks) external {
        require(factory != address(0), "factory");
        _begin(factory, stocks.length);
        Entry memory e;
        for (uint256 i; i < stocks.length; i++) {
            e.stock = stocks[i];
            _one(factory, e);
        }
        console2.log("V2CHECK_DONE", stocks.length);
    }

    function _begin(address factory, uint256 n) internal {
        // Read-only by construction: nothing here broadcasts, and a broadcast context is refused outright.
        require(!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) && !vm.isContext(VmSafe.ForgeContext.ScriptResume),
            "CheckV2Listings is read-only: run it without --broadcast");
        usdg = factory == address(0) ? MAINNET_USDG : HedgeFunFactory(factory).usdg();
        require(usdg.code.length != 0, "USDG has no code: not a Robinhood Chain fork");
        quoter = new V2CheckQuoter();
        console2.log(string.concat("V2CHECK_META {\"chainId\":", vm.toString(block.chainid),
            ",\"block\":", vm.toString(block.number), ",\"timestamp\":", vm.toString(block.timestamp),
            ",\"factory\":\"", vm.toString(factory), "\",\"stocks\":", vm.toString(n),
            ",\"drainUsdg\":", vm.toString(DRAIN_USDG), "}"));
    }

    function _one(address factory, Entry memory e) internal {
        R memory r;
        r.e = e;
        r.enabled = true;
        r.source = "plan";
        r.saleBpsSource = "plan";
        if (factory != address(0)) _fromFactory(r, factory);
        _config(r);
        if (bytes(r.configError).length == 0) {
            V2CheckGateProbe probe = _probe(r);
            if (address(probe) != address(0)) {
                _prices(r, probe);
                _raise(r, probe);
                _depth(r, probe);
            }
        }
        _emit(r);
    }

    function _fromFactory(R memory r, address factory) internal view {
        r.source = "factory";
        HedgeFunFactory f = HedgeFunFactory(factory);
        (r.e.oracle, r.e.pool, r.e.openPriceE18, r.enabled) = f.listings(r.e.stock);
        HedgeFunFactory.Defaults memory d = f.getDefaults();
        r.e.supply = d.supply;
        // HedgeFunFactory._gates: the pair falls back as a pair (on maxSlippageBps == 0), the chunk on its own
        (uint16 dev, uint16 slip, uint64 chunk) = f.listingGates(r.e.stock);
        (r.e.maxDeviationBps, r.e.maxSlippageBps) = slip == 0 ? (d.maxDeviationBps, d.maxSlippageBps) : (dev, slip);
        r.e.sellChunkUsdg = chunk == 0 ? d.sellChunkUsdg : chunk;
        // The raise size is each creator's own choice, registered per launch on the curve deployer; a V2 factory
        // holds no per-stock value. A creator's proposal arrives in the entry; otherwise every launch that
        // registers nothing gets the deployer's default.
        if (r.e.saleBps != 0) {
            r.saleBpsSource = "creator";
            return;
        }
        try HedgeFunV2Factory(factory).curveDeployer() returns (CurveDeployer cd) {
            try cd.DEFAULT_SALE_BPS() returns (uint16 s) {
                r.e.saleBps = s;
                r.saleBpsSource = "curveDeployer.DEFAULT_SALE_BPS";
                return;
            } catch {}
        } catch {}
        r.e.saleBps = DEFAULT_SALE_BPS;
        r.saleBpsSource = "DEFAULT_SALE_BPS (no curve deployer default to read: not a V2 factory)";
    }

    function _config(R memory r) internal {
        Entry memory e = r.e;
        try IERC20Metadata(e.stock).symbol() returns (string memory s) { r.symbol = s; } catch { r.symbol = "?"; }
        if (e.pool.code.length == 0) { r.configError = "pool has no code (not listed?)"; return; }
        IUniswapV3Pool pool = IUniswapV3Pool(e.pool);
        address t0 = pool.token0();
        address t1 = pool.token1();
        if (!((t0 == e.stock && t1 == usdg) || (t0 == usdg && t1 == e.stock))) {
            r.configError = "pool is not the stock/USDG pair";
            return;
        }
        r.stockIsToken0 = t0 == e.stock;
        r.fee = pool.fee();
        (bool okS, bytes memory sp) = e.pool.staticcall(abi.encodeWithSignature("tickSpacing()"));
        if (okS && sp.length == 32) r.tickSpacing = abi.decode(sp, (int24));
        r.stockDecimals = IERC20Metadata(e.stock).decimals();
        r.usdgDecimals = IERC20Metadata(usdg).decimals();
        if (e.oracle.code.length == 0) { r.configError = "oracle has no code"; return; }
        try PriceOracle(e.oracle).stock() returns (address priced) {
            if (priced != e.stock) { r.configError = "oracle prices a different stock"; return; }
        } catch { r.configError = "oracle is not a PriceOracle (stock() reverts)"; return; }
        if (e.openPriceE18 == 0) { r.configError = "openPriceE18 is 0"; return; }
        // The factory's own formula (HedgeFunV2Factory._curveInit), then the curve's own constructor for the rest.
        r.virtualStock = Math.mulDiv(e.openPriceE18, e.supply, 1e18, Math.Rounding.Ceil);
        HedgeFunBondingCurve.Init memory p = HedgeFunBondingCurve.Init({
            factory: _dummy("factory"), token: _dummy("token"), stock: e.stock, treasury: _dummy("treasury"),
            protocol: _dummy("protocol"), creator: _dummy("creator"), supply: e.supply, virtualStock: r.virtualStock,
            saleBps: e.saleBps, taxBps: 100, protocolBps: 2000, creatorBps: 0, snipeBps: 0, snipeSeconds: 0,
            openingTaxExemptions: new address[](0)});
        try new HedgeFunBondingCurve(p) returns (HedgeFunBondingCurve c) {
            r.minTokenReserve = c.minTokenReserve();
            r.terminalStock = c.terminalStock();
            r.rg = r.terminalStock - c.virtualStock();
        } catch {
            r.configError = "HedgeFunBondingCurve constructor reverts (BadConfig: saleBps, supply or virtualStock out of bounds)";
        }
    }

    function _probe(R memory r) internal returns (V2CheckGateProbe probe) {
        try new V2CheckGateProbe(usdg, r.e.stock, r.e.pool, r.e.oracle) returns (V2CheckGateProbe g) {
            probe = g;
        } catch (bytes memory why) {
            r.configError = bytes4(why) == PoolTrader.ShortObservationRing.selector
                ? "observation ring too short for the 600 s TWAP (a treasury cannot be deployed on this pool)"
                : "PoolTrader constructor reverts on this pool/oracle";
        }
    }

    function _prices(R memory r, V2CheckGateProbe probe) internal view {
        (r.oracleLive, r.oraclePrice) = PriceOracle(r.e.oracle).tryPrice();
        if (!r.oracleLive) {
            // market closed, paused or stale: measure against the frozen last print and say so
            (bool ok, uint256 p, uint256 at) = PriceOracle(r.e.oracle).lastPriceAt();
            if (ok) { r.oraclePrice = p; r.oracleUpdatedAt = at; }
        }
        (r.sqrt0, r.tick0,,,,,) = IUniswapV3Pool(r.e.pool).slot0();
        (r.meanOk, r.meanTick) = probe.meanTick();
        r.spot0 = probe.spotPrice();
        (r.healthBefore,) = probe.health(r.e.maxDeviationBps);
    }

    function _raise(R memory r, V2CheckGateProbe probe) internal {
        IUniswapV3Pool pool = IUniswapV3Pool(r.e.pool);
        // buying stock with USDG: USDG goes in, so zeroForOne exactly when USDG is token0, i.e. the stock is token1
        bool zf = !r.stockIsToken0;
        uint160 far = zf ? MIN_SQRT + 1 : MAX_SQRT - 1;
        r.rgq = quoter.quote(pool, zf, -int256(r.rg), far, probe, r.e.maxDeviationBps);
        if (r.rgq.ok) (r.rgUsdgIn, r.rgOut) = _inOut(r.rgq, zf);
        r.drain = quoter.quote(pool, zf, int256(DRAIN_USDG), far, probe, r.e.maxDeviationBps);
        if (r.drain.ok) (r.drainUsdgIn, r.deliverable) = _inOut(r.drain, zf);
        if (r.oraclePrice == 0 || !r.meanOk) return;
        // Buying stock raises the stock price: sqrtP rises when the stock is token0, falls when it is token1, and
        // the tick with it. The limit is whichever of the two edges the price reaches first, pulled one unit inside.
        uint160 oracleEdge = probe.sqrtAt(HedgeFunMath.shift(r.oraclePrice, r.e.maxDeviationBps, true));
        int256 dev = int256(uint256(r.e.maxDeviationBps));
        if (r.stockIsToken0) {
            uint160 tickEdge = TickMath.getSqrtPriceAtTick(int24(r.meanTick + dev + 1)) - 1;
            r.gateLimit = oracleEdge < tickEdge ? oracleEdge : tickEdge;
        } else {
            uint160 tickEdge = TickMath.getSqrtPriceAtTick(int24(r.meanTick - dev)) + 1;
            r.gateLimit = oracleEdge > tickEdge ? oracleEdge : tickEdge;
        }
        // A pool already outside the gate has no headroom; V3 would revert 'SPL' on a limit behind the price.
        if (zf ? r.gateLimit >= r.sqrt0 : r.gateLimit <= r.sqrt0) return;
        r.gate = quoter.quote(pool, zf, int256(DRAIN_USDG), r.gateLimit, probe, r.e.maxDeviationBps);
        if (r.gate.ok) (r.gateUsdg, r.gateStock) = _inOut(r.gate, zf);
    }

    function _depth(R memory r, V2CheckGateProbe probe) internal {
        if (r.spot0 == 0) return;
        IUniswapV3Pool pool = IUniswapV3Pool(r.e.pool);
        bool buyZf = !r.stockIsToken0;
        r.up = quoter.quote(pool, buyZf, int256(DRAIN_USDG), probe.sqrtAt(HedgeFunMath.shift(r.spot0, 100, true)),
            probe, r.e.maxDeviationBps);
        if (r.up.ok) (r.upUsdg, r.upStock) = _inOut(r.up, buyZf);
        r.down = quoter.quote(pool, !buyZf, int256(HUGE_STOCK), probe.sqrtAt(HedgeFunMath.shift(r.spot0, 100, false)),
            probe, r.e.maxDeviationBps);
        if (r.down.ok) (r.downStock, r.downUsdg) = _inOut(r.down, !buyZf);
    }

    /// @return tokenIn what the swap takes in, tokenOut what it pays out, for a swap in direction zeroForOne
    function _inOut(V2CheckQuoter.Quote memory q, bool zeroForOne) internal pure returns (uint256 tokenIn, uint256 tokenOut) {
        (int256 dIn, int256 dOut) = zeroForOne ? (q.amount0, q.amount1) : (q.amount1, q.amount0);
        tokenIn = dIn > 0 ? uint256(dIn) : 0;
        tokenOut = dOut < 0 ? uint256(-dOut) : 0;
    }

    function _dummy(string memory tag) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked("CheckV2Listings.", tag)))));
    }

    // ---- output: one JSON object per stock, on a line starting with "V2CHECK " ----

    function _emit(R memory r) internal pure {
        console2.log(string.concat("V2CHECK {", _jConfig(r), _jCurve(r), _jPrices(r), _jRaise(r), _jDepth(r)));
    }

    function _jConfig(R memory r) internal pure returns (string memory s) {
        s = string.concat(_s("symbol", r.symbol), _s("source", r.source), _s("saleBpsSource", r.saleBpsSource));
        s = string.concat(s, _b("enabled", r.enabled), _s("configError", r.configError), _a("stock", r.e.stock));
        s = string.concat(s, _a("pool", r.e.pool), _a("oracle", r.e.oracle), _u("fee", r.fee));
        s = string.concat(s, _i("tickSpacing", r.tickSpacing), _b("stockIsToken0", r.stockIsToken0));
        s = string.concat(s, _u("stockDecimals", r.stockDecimals), _u("usdgDecimals", r.usdgDecimals));
    }

    function _jCurve(R memory r) internal pure returns (string memory s) {
        s = string.concat(_u("supply", r.e.supply), _u("openPriceE18", r.e.openPriceE18), _u("saleBps", r.e.saleBps));
        s = string.concat(s, _u("maxDeviationBps", r.e.maxDeviationBps), _u("maxSlippageBps", r.e.maxSlippageBps));
        s = string.concat(s, _u("sellChunkUsdg", r.e.sellChunkUsdg), _u("virtualStock", r.virtualStock));
        s = string.concat(s, _u("minTokenReserve", r.minTokenReserve), _u("terminalStock", r.terminalStock), _u("rg", r.rg));
    }

    function _jPrices(R memory r) internal pure returns (string memory s) {
        s = string.concat(_b("oracleLive", r.oracleLive), _u("oraclePrice", r.oraclePrice));
        s = string.concat(s, _u("oracleUpdatedAt", r.oracleUpdatedAt), _u("sqrt0", r.sqrt0), _i("tick0", r.tick0));
        s = string.concat(s, _b("meanOk", r.meanOk), _i("meanTick", r.meanTick), _u("spot0", r.spot0));
        s = string.concat(s, _b("healthBefore", r.healthBefore));
    }

    function _jRaise(R memory r) internal pure returns (string memory s) {
        s = string.concat(_q("rg", r.rgq), _u("rgOut", r.rgOut), _u("rgUsdgIn", r.rgUsdgIn));
        s = string.concat(s, _q("drain", r.drain), _u("deliverable", r.deliverable), _u("drainUsdgIn", r.drainUsdgIn));
        s = string.concat(s, _q("gate", r.gate), _u("gateLimit", r.gateLimit), _u("gateStock", r.gateStock));
        s = string.concat(s, _u("gateUsdg", r.gateUsdg));
    }

    function _jDepth(R memory r) internal pure returns (string memory s) {
        s = string.concat(_q("up", r.up), _u("upUsdg", r.upUsdg), _u("upStock", r.upStock), _q("down", r.down));
        s = string.concat(s, _u("downUsdg", r.downUsdg), "\"downStock\":", vm.toString(r.downStock), "}");
    }

    function _q(string memory k, V2CheckQuoter.Quote memory q) internal pure returns (string memory) {
        string memory s = string.concat(_b(string.concat(k, "Ok"), q.ok), _s(string.concat(k, "Err"), q.err));
        s = string.concat(s, _u(string.concat(k, "SqrtAfter"), q.sqrtAfter), _i(string.concat(k, "TickAfter"), q.tickAfter));
        return string.concat(s, _b(string.concat(k, "HealthAfter"), q.healthAfter), _u(string.concat(k, "SpotAfter"), q.spotAfter));
    }

    function _u(string memory k, uint256 v) internal pure returns (string memory) {
        return string.concat("\"", k, "\":", vm.toString(v), ",");
    }
    function _i(string memory k, int256 v) internal pure returns (string memory) {
        return string.concat("\"", k, "\":", vm.toString(v), ",");
    }
    function _b(string memory k, bool v) internal pure returns (string memory) {
        return string.concat("\"", k, "\":", v ? "true" : "false", ",");
    }
    function _a(string memory k, address v) internal pure returns (string memory) {
        return string.concat("\"", k, "\":\"", vm.toString(v), "\",");
    }
    function _s(string memory k, string memory v) internal pure returns (string memory) {
        return string.concat("\"", k, "\":\"", _clean(v), "\",");
    }
    /// a revert string or token symbol must not break the JSON line
    function _clean(string memory v) internal pure returns (string memory) {
        bytes memory b = bytes(v);
        for (uint256 i; i < b.length; i++) if (b[i] == "\"" || b[i] == "\\" || uint8(b[i]) < 0x20) b[i] = "'";
        return string(b);
    }
}
