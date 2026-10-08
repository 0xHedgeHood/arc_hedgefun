// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HedgeFunFactory, TokenDeployer} from "../../src/HedgeFunFactory.sol";
import {HedgeFunV2Hook} from "../../src/hooks/HedgeFunV2Hook.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {V2TreasuryDeployer} from "../../src/v2/V2TreasuryDeployer.sol";
import {HedgeFunV2UpgradeableBuybackTreasury} from "../../src/v2/HedgeFunV2UpgradeableBuybackTreasury.sol";
import {HedgeFunV2UpgradeableEngineTreasury} from "../../src/v2/HedgeFunV2UpgradeableEngineTreasury.sol";
import {V2RebalancePolicy} from "../../src/v2/strategy/V2RebalancePolicy.sol";
import {StrategyCapabilities} from "../../src/v2/strategy/IStrategyPolicy.sol";
import {CurveDeployer} from "../../src/v2/CurveDeployer.sol";
import {HedgeFunV2TradeRouter} from "../../src/v2/HedgeFunV2TradeRouter.sol";
import {HedgeFunV2NativeRouter, IWrappedNative} from "../../src/v2/HedgeFunV2NativeRouter.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {TradingCalendar} from "../../src/TradingCalendar.sol";
import {TestUsdg, TestStock, TestFeed} from "./TestnetAssets.sol";
import {TestnetMarket, IV3Factory, IV3Pool} from "./TestnetMarket.sol";
import {V2LaunchFeeDefaults} from "./V2LaunchFeeDefaults.sol";

/// @notice The whole Hedgefun V2 launchpad on the PUBLIC Robinhood Chain testnet (chain 46630), with test doubles
///         for everything the testnet lacks: a Uniswap V3 factory (from the vendored bytecode, byte-identical to
///         mainnet's), test USDG, test stocks with `oraclePaused()`, operator-set feeds, one stock/tUSDG V3 pool per
///         stock with deep liquidity, and a fresh `TradingCalendar`. The testnet's own Uniswap V4 PoolManager (same
///         bytecode as mainnet's), WETH, CREATE2 deployer and Permit2 are used as they are.
/// @dev Refuses every chain but 46630. The operator's EOA is the broadcaster, factory owner and (by default) protocol
///      recipient: there is no Safe on this deployment and nothing on it has value. See docs/TESTNET_V2.md.
///
///      OPERATOR=0x.. forge script script/testnet/DeployV2Testnet.s.sol:DeployV2Testnet \
///        --rpc-url https://rpc.testnet.chain.robinhood.com --sender $OPERATOR            # dry run
///      ... --account <keystore> --broadcast --slow                                        # the operator's deployment
contract DeployV2Testnet is Script {
    uint256 internal constant CHAIN_ID = 46630;
    address internal constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;          // Uniswap V4, testnet
    address internal constant WETH = 0x7943e237c7F95DA44E0301572D358911207852Fa;        // L2 WETH, testnet
    uint160 internal constant HOOK_FLAGS = 0x28CC;
    string internal constant V3_FACTORY_BYTECODE = "lib/v4-core/test/bin/v3Factory.bytecode";
    string internal constant OUT = "deploy/testnet-v2-whitelist.json";
    string internal constant OUT_DRY = "deploy/testnet-v2-whitelist.dryrun.json";

    /// V2 launch-check gates, as the planned mainnet listings (deploy/v2-listings-plan.json)
    uint16 internal constant MAX_DEVIATION_BPS = 50;
    uint16 internal constant MAX_SLIPPAGE_BPS = 100;
    uint64 internal constant SELL_CHUNK_USDG = 2_000e6;
    uint16 internal constant LP_BPS = 7000;                     // V2TreasuryDeployer.DEFAULT_LP_BPS, set explicitly
    /// New-deployment reference FDV with supply-preserving graduation, at the mock price and with no opening burn.
    /// The calibration uses the chosen sale fraction and unchanged post-graduation supply.
    uint256 public constant TARGET_GRADUATION_FDV_USD_E18 = 50_000e18;
    uint16 public constant REFERENCE_SALE_BPS = 7931;
    /// PriceOracle ages, as mainnet's (script/DeployPriceOracles.s.sol)
    uint256 internal constant MAX_STOCK_AGE = 26 hours;
    uint256 internal constant MAX_USDG_AGE = 26 hours;
    /// Each pool's position spans about half to double the opening price, and holds this much tUSDG on its USDG side:
    /// roughly 500,000 tUSDG per 1% move, so the fixed 7931 raise (~8,205 USDG) moves it a few
    /// bps. The market mints the other side.
    int24 internal constant RANGE_TICKS = 6960;
    uint256 internal constant USDG_SIDE = 30_000_000e6;
    uint16 internal constant CARDINALITY = 720;                 // PoolTrader needs TWAP_WINDOW + RING_MARGIN = 660

    error WrongChain(uint256 chainId);
    error MissingCode(address target);
    error NotOperator(address sender, address operator);
    error BadHook(address expected, address actual);
    error ReadbackFailed(string what);

    struct StockSpec {
        string symbol;
        string name;
        uint256 priceE18;         // USDG per whole token, near the mainnet oracle on 2026-09-28
        uint256 openPriceE18;     // calibrated for this fresh testnet deployment; not a historical address-book value
        uint24 fee;               // the mainnet listing pool's fee tier
        uint256 dripAmount;
    }

    struct Line {
        string symbol;
        TestStock stock;
        TestFeed feed;
        PriceOracle oracle;
        address pool;
        uint24 fee;
        uint256 priceE18;
        uint256 openPriceE18;
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
    }

    struct Deployment {
        address operator;
        address owner;
        address protocol;
        TestUsdg usdg;
        TestFeed usdgFeed;
        TradingCalendar calendar;
        IV3Factory v3Factory;
        TestnetMarket market;
        V2TreasuryDeployer treasury;
        TokenDeployer token;
        CurveDeployer curve;
        HedgeFunV2Hook hook;
        HedgeFunV2Factory factory;
        HedgeFunV2TradeRouter router;
        HedgeFunV2NativeRouter nativeRouter;
        V2RebalancePolicy policy;
        bytes32 policyKey;
        uint8 engineKind;
        bytes32 hookSalt;
        Line[] lines;
    }

    function run() external returns (Deployment memory x) {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        address operator = vm.envAddress("OPERATOR");
        if (msg.sender != operator) revert NotOperator(msg.sender, operator);
        address protocol = vm.envOr("PROTOCOL", operator);
        x = deploy(operator, protocol, vm.envOr("HOOK_SALT_START", uint256(0)));
        _log(x);
        bool live = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        _writeJson(x, live ? OUT : OUT_DRY, live);
    }

    /// @notice every transaction, broadcast from `operator`; `run` adds the environment, the log and the JSON
    function deploy(address operator, address protocol, uint256 hookSaltStart) public returns (Deployment memory x) {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        if (PM.code.length == 0) revert MissingCode(PM);
        if (WETH.code.length == 0) revert MissingCode(WETH);
        if (CREATE2_FACTORY.code.length == 0) revert MissingCode(CREATE2_FACTORY);
        x.operator = operator;
        x.owner = operator;
        x.protocol = protocol;
        (x.hookSalt,) = _mineHook(hookSaltStart);

        vm.startBroadcast(operator);
        _deployVenue(x);
        _deployLines(x);
        _deployV2(x);
        _register(x);
        _list(x);
        vm.stopBroadcast();

        _readBack(x);
    }

    // ------------------------------------------------------------------------------------------ test doubles
    function _specs() internal pure returns (StockSpec[] memory s) {
        s = new StockSpec[](4);
        s[0] = StockSpec("NVDA", "NVIDIA test stock (testnet, no value)", 228e18, 44_200_000_000, 500, 20e18);
        s[1] = StockSpec("TSLA", "Tesla test stock (testnet, no value)", 358e18, 26_500_000_000, 3000, 15e18);
        s[2] = StockSpec("GME", "GameStop test stock (testnet, no value)", 24e18, 423_000_000_000, 500, 200e18);
        s[3] = StockSpec("AAPL", "Apple test stock (testnet, no value)", 339e18, 29_800_000_000, 500, 15e18);
        for (uint256 i; i < s.length; ++i) s[i].openPriceE18 = referenceOpenPriceE18(s[i].priceE18);
    }

    /// @notice 18-decimal stock units per token, scaled by 1e18. Recalibrate if supply or sale changes.
    /// @dev A reference target, not a USD cap enforced by the curve: stock prices and opening burns can change FDV.
    function referenceOpenPriceE18(uint256 stockUsdE18) public pure returns (uint256) {
        uint256 sale = REFERENCE_SALE_BPS;
        uint256 remaining = 10_000 - sale;
        // Graduation preserves total supply. The remaining tokens enter locked LP positions.
        uint256 openingFdv = Math.mulDiv(
            TARGET_GRADUATION_FDV_USD_E18, remaining * remaining, 10_000 * 10_000
        );
        return Math.mulDiv(openingFdv, 1e18, stockUsdE18 * 1_000_000_000);
    }

    function _deployVenue(Deployment memory x) internal {
        x.usdg = new TestUsdg(x.operator);
        x.usdgFeed = new TestFeed("tUSDG / USD (testnet, operator-set)", 1e8, x.operator);
        x.calendar = new TradingCalendar(x.operator);
        bytes memory code = vm.readFileBinary(V3_FACTORY_BYTECODE);
        address v3;
        assembly ("memory-safe") { v3 := create(0, add(code, 0x20), mload(code)) }
        if (v3 == address(0)) revert MissingCode(v3);
        x.v3Factory = IV3Factory(v3);
        x.market = new TestnetMarket(x.operator, address(x.usdg));
        x.usdg.setOperator(address(x.market), true);
    }

    function _deployLines(Deployment memory x) internal {
        StockSpec[] memory specs = _specs();
        x.lines = new Line[](specs.length);
        for (uint256 i; i < specs.length; i++) x.lines[i] = _deployLine(x, specs[i]);
    }

    function _deployLine(Deployment memory x, StockSpec memory s) internal returns (Line memory l) {
        l.symbol = s.symbol;
        l.fee = s.fee;
        l.priceE18 = s.priceE18;
        l.openPriceE18 = s.openPriceE18;
        l.stock = new TestStock(s.name, s.symbol, x.operator, s.dripAmount);
        l.feed = new TestFeed(string.concat(s.symbol, " / USD (testnet, operator-set)"), int256(s.priceE18 / 1e10), x.operator);
        l.stock.setOperator(address(x.market), true);
        l.feed.setOperator(address(x.market), true);
        l.oracle = new PriceOracle(address(l.stock), address(l.feed), address(x.usdgFeed), address(x.calendar),
            MAX_STOCK_AGE, MAX_USDG_AGE);

        l.pool = x.v3Factory.createPool(address(l.stock), address(x.usdg), s.fee);
        int24 spacing = x.v3Factory.feeAmountTickSpacing(s.fee);
        // the range is centred on the opening tick; the pool is initialised by the market's own price math
        uint160 sqrtP = _sqrtFor(address(l.stock) < address(x.usdg), s.priceE18);
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 centre = tick / spacing * spacing;
        l.tickLower = centre - RANGE_TICKS / spacing * spacing;
        l.tickUpper = centre + RANGE_TICKS / spacing * spacing;
        x.market.addLine(l.pool, address(l.stock), l.feed, 18, l.tickLower, l.tickUpper);
        IV3Pool(l.pool).initialize(x.market.sqrtFor(l.pool, s.priceE18));
        IV3Pool(l.pool).increaseObservationCardinalityNext(CARDINALITY);
        l.liquidity = _liquidityFor(address(l.stock) < address(x.usdg), sqrtP, l.tickLower, l.tickUpper);
        x.market.provide(l.pool, l.liquidity);
    }

    /// TestnetMarket.sqrtFor, before the line exists: 18-decimal stock, 6-decimal USDG
    function _sqrtFor(bool stockIsToken0, uint256 priceE18) internal pure returns (uint160) {
        uint256 scale = 1e30;
        return uint160(Math.sqrt(stockIsToken0 ? Math.mulDiv(priceE18, 1 << 192, scale) : Math.mulDiv(scale, 1 << 192, priceE18)));
    }

    /// the liquidity whose USDG side, at the opening price, is USDG_SIDE
    function _liquidityFor(bool stockIsToken0, uint160 s, int24 lo, int24 hi) internal pure returns (uint128) {
        uint256 a = TickMath.getSqrtPriceAtTick(lo);
        uint256 b = TickMath.getSqrtPriceAtTick(hi);
        // USDG is token1 when the stock is token0: amount1 = L (s - a) / Q96; else amount0 = L (b - s) Q96 / (s b)
        uint256 l = stockIsToken0
            ? Math.mulDiv(USDG_SIDE, 1 << 96, uint256(s) - a)
            : Math.mulDiv(Math.mulDiv(USDG_SIDE, uint256(s), b - uint256(s)), b, 1 << 96);
        return uint128(l);
    }

    // ------------------------------------------------------------------------------------------ V2, as RehearseV2Launchpad
    function _deployV2(Deployment memory x) internal {
        x.treasury = new V2TreasuryDeployer();
        x.token = new TokenDeployer();
        x.curve = new CurveDeployer(REFERENCE_SALE_BPS);
        (, address mined) = _hookAddress(x.hookSalt);
        x.hook = new HedgeFunV2Hook{salt: x.hookSalt}(IPoolManager(PM));
        if (address(x.hook) != mined || uint160(address(x.hook)) & 0x3FFF != HOOK_FLAGS) revert BadHook(mined, address(x.hook));
        x.factory = new HedgeFunV2Factory(x.owner, PM, address(x.v3Factory), address(x.usdg), x.protocol,
            address(x.treasury), address(x.token), address(x.hook), address(x.curve), _defaults());
        x.router = new HedgeFunV2TradeRouter(x.factory);
        x.nativeRouter = new HedgeFunV2NativeRouter(x.router, IWrappedNative(WETH));
    }

    /// kind 1 (buyback), the rebalance policy, and kind 2 (the spot engine), as test/V2StrategyEngine.t.sol
    function _register(Deployment memory x) internal {
        (address a, address b) = x.treasury.makeChunks(type(HedgeFunV2UpgradeableBuybackTreasury).creationCode);
        if (x.treasury.registerKind(a, b) != 1) revert ReadbackFailed("kind 1");
        x.policy = new V2RebalancePolicy();
        x.policyKey = x.treasury.registerPolicy(address(x.policy), 150_000, x.treasury.POLICY_RETURN_BYTES(),
            keccak256("hedgefun testnet 46630: V2RebalancePolicy dependencies (none audited for testnet)"),
            keccak256("hedgefun testnet 46630: V2RebalancePolicy audit manifest (testnet placeholder)"));
        (a, b) = x.treasury.makeChunks(type(HedgeFunV2UpgradeableEngineTreasury).creationCode);
        x.engineKind = x.treasury.registerEngineKind(a, b, StrategyCapabilities.SPOT_ENGINE_V1,
            StrategyCapabilities.CONFIG_SCHEMA_V1, StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL);
    }

    function _list(Deployment memory x) internal {
        for (uint256 i; i < x.lines.length; i++) {
            Line memory l = x.lines[i];
            x.factory.list(address(l.stock), address(l.oracle), l.pool, l.openPriceE18, true);
            x.factory.setListingGates(address(l.stock), MAX_DEVIATION_BPS, MAX_SLIPPAGE_BPS, SELL_CHUNK_USDG);
            x.treasury.setLpBps(address(l.stock), LP_BPS);
        }
        x.factory.setPublicLaunch(true);
    }

    /// @dev the rehearsal's Defaults (docs/V2_DEPLOYMENT_REHEARSAL.md, decisions of 2026-09-28): creators choose tax
    ///      1-15%, raise size (default saleBps 7931) and opening window (default 3 s).
    ///      Current fee choices: 0.0005 ETH to launch, creator share 0-10% of collected tax.
    function _defaults() internal pure returns (HedgeFunFactory.Defaults memory d) {
        d.supply = 1_000_000_000e18;
        d.lpFee = 2000;
        d.tickSpacing = 60;
        d.minTaxBps = 100;
        d.maxTaxBps = 1500;
        d.protocolBps = 3000;
        d.spikeBps = 0;
        d.spikeSeconds = 0;
        d.sweepTipBps = 0; // V2 stock revenue is split exactly 30% protocol / creator share / treasury remainder.
        d.snipeBps = 9900;
        d.snipeSeconds = 3;
        d.bountyBps = 50;
        d.maxSlippageBps = 100;
        d.maxDeviationBps = 50;
        d.maxBuybackImpactBps = 300;
        d.buybackCooldown = 10;
        d.minLotUsdg = 5e6;
        d.buybackChunkUsdg = 500e6;
        d.sellChunkUsdg = 2_000e6;
        return V2LaunchFeeDefaults.applyTo(d);
    }

    // ------------------------------------------------------------------------------------------ checks
    function _readBack(Deployment memory x) internal view {
        HedgeFunV2Factory f = x.factory;
        if (f.owner() != x.owner || f.protocol() != x.protocol || !f.publicLaunch()) revert ReadbackFailed("factory roles");
        if (address(f.poolManager()) != PM || address(f.v3Factory()) != address(x.v3Factory) || f.usdg() != address(x.usdg)) {
            revert ReadbackFailed("factory venue");
        }
        if (x.treasury.factory() != address(f) || x.token.factory() != address(f) || x.curve.factory() != address(f)
            || x.hook.factory() != address(f) || address(x.router.factory()) != address(f)) revert ReadbackFailed("binding");
        if (x.hook.version() != 3) revert ReadbackFailed("stock-fee hook");
        if (x.treasury.kindCount() != 3 || x.engineKind != 2) revert ReadbackFailed("kinds");
        if (x.treasury.policy(x.policyKey).implementation != address(x.policy)) revert ReadbackFailed("policy");
        if (keccak256(abi.encode(f.getDefaults())) != keccak256(abi.encode(_defaults()))) revert ReadbackFailed("defaults");
        for (uint256 i; i < x.lines.length; i++) {
            Line memory l = x.lines[i];
            (address oracle, address pool, uint256 open, bool enabled) = f.listings(address(l.stock));
            (uint16 dev, uint16 slip, uint64 chunk) = f.listingGates(address(l.stock));
            if (oracle != address(l.oracle) || pool != l.pool || open != l.openPriceE18 || !enabled
                || dev != MAX_DEVIATION_BPS || slip != MAX_SLIPPAGE_BPS || chunk != SELL_CHUNK_USDG
                || x.treasury.lpBps(address(l.stock)) != LP_BPS) revert ReadbackFailed(l.symbol);
            (bool ok, uint256 p) = l.oracle.tryPrice();
            // the calendar may be closed right now (a weekend); the feed itself must answer the listing price
            (bool okLast, uint256 last,) = l.oracle.lastPriceAt();
            if (!okLast || last != l.priceE18 || (ok && p != l.priceE18)) revert ReadbackFailed(l.symbol);
            (,,, uint16 card, uint16 cardNext,,) = IV3Pool(l.pool).slot0();
            if (cardNext < CARDINALITY || card == 0 || IV3Pool(l.pool).liquidity() != l.liquidity) revert ReadbackFailed(l.symbol);
        }
    }

    function _hookAddress(bytes32 salt) internal pure returns (bytes32, address) {
        bytes32 initHash = keccak256(abi.encodePacked(type(HedgeFunV2Hook).creationCode, abi.encode(PM)));
        return (salt, address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, salt, initHash))))));
    }

    function _mineHook(uint256 start) internal view returns (bytes32 salt, address hook) {
        bytes32 initHash = keccak256(abi.encodePacked(type(HedgeFunV2Hook).creationCode, abi.encode(PM)));
        for (uint256 i = start; i < start + 2_000_000; ++i) {
            hook = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, bytes32(i), initHash)))));
            if (uint160(hook) & 0x3FFF == HOOK_FLAGS && hook.code.length == 0) return (bytes32(i), hook);
        }
        revert("no hook salt");
    }

    // ------------------------------------------------------------------------------------------ output
    function _log(Deployment memory x) internal pure {
        console2.log("Hedgefun V2 testnet deployment, chain 46630");
        console2.log("operator (owner, broadcaster)", x.operator);
        console2.log("protocol", x.protocol);
        console2.log("tUSDG", address(x.usdg));
        console2.log("tUSDG feed", address(x.usdgFeed));
        console2.log("TradingCalendar", address(x.calendar));
        console2.log("UniswapV3Factory", address(x.v3Factory));
        console2.log("TestnetMarket", address(x.market));
        console2.log("V2 factory", address(x.factory));
        console2.log("V2 trade router", address(x.router));
        console2.log("V2 native router", address(x.nativeRouter));
        console2.log("hook", address(x.hook));
        console2.log("treasury deployer", address(x.treasury));
        console2.log("token deployer", address(x.token));
        console2.log("curve deployer", address(x.curve));
        console2.log("rebalance policy", address(x.policy));
        console2.log("engine kind", x.engineKind);
        for (uint256 i; i < x.lines.length; i++) {
            Line memory l = x.lines[i];
            console2.log(string.concat(l.symbol, " stock / oracle / pool"), address(l.stock), address(l.oracle), l.pool);
        }
        console2.log("public launch true; readback passed");
    }

    function _writeJson(Deployment memory x, string memory path, bool live) internal {
        string memory o = "testnet";
        vm.serializeUint(o, "chainId", CHAIN_ID);
        vm.serializeBool(o, "broadcast", live);
        vm.serializeString(o, "featureVersion", "v2-two-sided-stock-fees-v2");
        // Launch requests remain bounded creator choices; these are the selected UI defaults, not immutable rates.
        vm.serializeUint(o, "recommendedTaxBps", 100);
        vm.serializeUint(o, "recommendedCreatorBps", 1000);
        vm.serializeUint(o, "block", block.number);
        vm.serializeString(o, "commit", vm.envOr("GIT_COMMIT", string("unset")));
        vm.serializeAddress(o, "operator", x.operator);
        vm.serializeAddress(o, "owner", x.owner);
        vm.serializeAddress(o, "protocol", x.protocol);
        vm.serializeAddress(o, "poolManager", PM);
        vm.serializeAddress(o, "weth", WETH);
        vm.serializeAddress(o, "usdg", address(x.usdg));
        vm.serializeAddress(o, "usdgFeed", address(x.usdgFeed));
        vm.serializeAddress(o, "calendar", address(x.calendar));
        vm.serializeAddress(o, "v3Factory", address(x.v3Factory));
        vm.serializeAddress(o, "market", address(x.market));
        vm.serializeAddress(o, "factory", address(x.factory));
        vm.serializeAddress(o, "tradeRouter", address(x.router));
        vm.serializeAddress(o, "nativeRouter", address(x.nativeRouter));
        vm.serializeAddress(o, "hook", address(x.hook));
        vm.serializeBytes32(o, "hookSalt", x.hookSalt);
        vm.serializeAddress(o, "treasuryDeployer", address(x.treasury));
        vm.serializeAddress(o, "tokenDeployer", address(x.token));
        vm.serializeAddress(o, "curveDeployer", address(x.curve));
        vm.serializeAddress(o, "rebalancePolicy", address(x.policy));
        vm.serializeBytes32(o, "rebalancePolicyKey", x.policyKey);
        vm.serializeUint(o, "engineKind", x.engineKind);
        string memory stocks = "stocks";
        string memory json;
        for (uint256 i; i < x.lines.length; i++) json = vm.serializeString(stocks, x.lines[i].symbol, _lineJson(x.lines[i]));
        json = vm.serializeString(o, "stocks", json);
        vm.writeJson(json, path);
        console2.log("wrote", path);
    }

    function _lineJson(Line memory l) internal returns (string memory) {
        string memory k = l.symbol;
        vm.serializeAddress(k, "token", address(l.stock));
        vm.serializeAddress(k, "feed", address(l.feed));
        vm.serializeAddress(k, "oracle", address(l.oracle));
        vm.serializeAddress(k, "pool", l.pool);
        vm.serializeUint(k, "fee", l.fee);
        vm.serializeUint(k, "decimals", 18);
        // big integers as decimal strings, always: JSON numbers past 2^53 do not survive a JavaScript parser
        vm.serializeString(k, "priceE18", vm.toString(l.priceE18));
        vm.serializeString(k, "openPriceE18", vm.toString(l.openPriceE18));
        vm.serializeInt(k, "tickLower", l.tickLower);
        vm.serializeInt(k, "tickUpper", l.tickUpper);
        return vm.serializeString(k, "liquidity", vm.toString(l.liquidity));
    }
}
