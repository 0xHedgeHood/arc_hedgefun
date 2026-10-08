// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2LaunchFeeDefaults} from "./V2LaunchFeeDefaults.sol";

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HedgeFunFactory, TokenDeployer} from "../../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {V2TreasuryDeployer} from "../../src/v2/V2TreasuryDeployer.sol";
import {CurveDeployer} from "../../src/v2/CurveDeployer.sol";
import {HedgeFunV2Hook} from "../../src/hooks/HedgeFunV2Hook.sol";
import {HedgeFunV2TradeRouter} from "../../src/v2/HedgeFunV2TradeRouter.sol";
import {HedgeFunV2NativeRouter, IWrappedNative} from "../../src/v2/HedgeFunV2NativeRouter.sol";
import {HedgeFunV2UpgradeableBuybackTreasury} from "../../src/v2/HedgeFunV2UpgradeableBuybackTreasury.sol";
import {HedgeFunV2UpgradeableEngineTreasury} from "../../src/v2/HedgeFunV2UpgradeableEngineTreasury.sol";
import {V2RebalancePolicy} from "../../src/v2/strategy/V2RebalancePolicy.sol";
import {StrategyCapabilities} from "../../src/v2/strategy/IStrategyPolicy.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {TradingCalendar} from "../../src/TradingCalendar.sol";
import {TestUsdg, TestStock, TestFeed} from "./TestnetAssets.sol";
import {TestnetMarket, IV3Factory, IV3Pool} from "./TestnetMarket.sol";

/// @notice Fresh two-sided-fee core on chain 46630, reusing exactly the eight existing synthetic stock markets.
/// @dev No venue mutation, signing material or environment-supplied target address. Candidate files are ALWAYS
/// unverified (broadcast=false), even after --broadcast. Independent receipt/readback verification publishes them.
contract DeployV2FeeUpgradeTestnet is Script {
    uint256 public constant CHAIN_ID = 46630;
    address public constant OPERATOR = 0x75Cee941B0eF3A83feA0397BbF903C12c1D7e96D;
    address public constant BASE_FACTORY = 0x3E95976E2425e63cb2A8d48BBce8976F55627019;
    address public constant BASE_TREASURY = 0xB15D34FC30292DeDb070875074e7b56FD34a1da2;
    address public constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address public constant WETH = 0x7943e237c7F95DA44E0301572D358911207852Fa;
    address public constant USDG = 0x539574139BB4Ac74Fd2183ba0E38ed777E30B58d;
    address public constant USDG_FEED = 0x6beF5980dDa88F8B925f814C5033959A13ae535A;
    address public constant CALENDAR = 0xB8661bAd51e504862107CF4eBAdB1c8c2ABFA6CD;
    address public constant V3_FACTORY = 0x0b0a96D7EB396E7471998889C4803dD0F529Eb01;
    address public constant MARKET = 0xc1AF2f52980F8A7AA4E90A8E30D5c3FaF0375f21;
    string public constant BASE_BOOK_SHA256 = "1b0d19f7e5e36ec19df5c3d8b879d95510dbe70527724602686d95411d04b67e";
    uint160 public constant HOOK_FLAGS = 0x28CC;
    /// The share of supply every launch on the new core sells on its curve; `CurveDeployer` accepts no other.
    uint16 public constant SALE_BPS = 7931;
    uint256 public constant PLANNED_TRANSACTIONS = 38;
    string internal constant OUT = "deploy/testnet-v2-fees.candidate.json";
    string internal constant OUT_DRY = "deploy/testnet-v2-fees.dryrun.json";

    error WrongChain(uint256 chainId);
    error NotOperator(address sender);
    error BadBinding(string what);
    error BadCommit();

    struct Venue {
        HedgeFunV2Factory factory;
        V2TreasuryDeployer treasury;
        TestnetMarket market;
        TestUsdg usdg;
        TestFeed usdgFeed;
        TradingCalendar calendar;
        IV3Factory v3Factory;
    }

    struct Seed {
        string symbol;
        address stock;
        address feed;
        address oracle;
        address pool;
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
        uint16 maxDeviationBps;
        uint16 maxSlippageBps;
        uint64 sellChunkUsdg;
        uint16 lpBps;
    }

    struct Deployment {
        Venue venue;
        Line[] lines;
        HedgeFunFactory.Defaults defaults;
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
    }

    // Virtual only for an offline fixture. The production contract pins every reused address below.
    function _venue() internal view virtual returns (Venue memory) {
        return Venue(
            HedgeFunV2Factory(BASE_FACTORY),
            V2TreasuryDeployer(BASE_TREASURY),
            TestnetMarket(MARKET),
            TestUsdg(USDG),
            TestFeed(USDG_FEED),
            TradingCalendar(CALENDAR),
            IV3Factory(V3_FACTORY)
        );
    }

    function _seeds() internal view virtual returns (Seed[] memory s) {
        s = new Seed[](8);
        s[0] = Seed(
            "AAPL",
            0x7efCa82CE9f4596230743b767260f55B9673AffE,
            0x44280A33Df11EE67B8B75B0E9055d0D2dF6c182e,
            0x800180c0097e25CfB6313af08289e2C8cd1411a5,
            0xcd596f59D8ea2c3577d5a7cB7aAFC6B46Bb8Fd06
        );
        s[1] = Seed(
            "GME",
            0xDD301669340232F283b1e91a7c4571591d86bd85,
            0x3B73e842567da49905468368222D03078aD84417,
            0xe9858C468FC2B17840cFed7379d0C25737B1E4b0,
            0x9f978fa32e3dc5D61D92Be85644c867DCee692c0
        );
        s[2] = Seed(
            "NVDA",
            0x7b6a95E6c97a212d5307e8B50290DC1ac2715B84,
            0xe669024986027d0b458D7a41Cedd368587334a58,
            0x878DaF3a1565Ecb16C50904Ddaf2476a17E54296,
            0x52e6b4d22c7e1cDFf8329Dab4017A73f607B487E
        );
        s[3] = Seed(
            "TSLA",
            0xcee322837F181Bd93AC2d71e4dDf334BFF565b98,
            0x91B711c49Cc10098BFcCDD7d935AbA576BD4bffb,
            0x5001C9C8b278425129C36C8099520aBAA70aa4ae,
            0x04083643FF9E8c27f66C9dD99947743A9B777244
        );
        s[4] = Seed(
            "MSFT",
            0x8ABbdc97C8D4c8b950cb80488606D27b09A3e9ce,
            0x4708D200c1A043Ce4d273F53eA1c245A17e2b5F6,
            0xcD81F9041f6e56CB734F580676e3A3B0BffD9d34,
            0xf94Fda49fD23F11116644Ff5880522EF04097699
        );
        s[5] = Seed(
            "AMZN",
            0xebecC6d4ee7aD6d58870c82770389F7Cf2Eedd88,
            0xC69FaDbFEc1213ab7eE20f0Cc883F5728FD12975,
            0xA81F110FA29c9335ce7B4a289CcE98ED1a44A1bB,
            0x86fd810f5b4c769E9FBad9A38E1e92bed8909652
        );
        s[6] = Seed(
            "GOOGL",
            0x3027527030CFaE82e93119EAE3B1372D07064Dfe,
            0x1E7f20E9Ee11C23B9D8D1Ee021b32723dc24546d,
            0x79847509969fB5ca678836563a49C770DEFCD585,
            0x87f94AC256B0108c09e7281402b127fd1b932481
        );
        s[7] = Seed(
            "META",
            0xEa3de3A8064278227760760e72e9A1c215F89903,
            0x34781f5Ab7A9b44B7616984B49d9DAFb39F4732D,
            0x14f9867471039f91A106276C9736Df66c92BDa80,
            0xD638256044b6EB3CC0a4617F704C6df8BF1a6856
        );
    }

    function run() external returns (Deployment memory x) {
        string memory commit = vm.envOr("GIT_COMMIT", string(""));
        _checkCommit(commit);
        uint256 startBlock = block.number;
        x = deploy(vm.envOr("HOOK_SALT_START", uint256(0)));
        bool requested =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        _writeCandidate(x, startBlock, requested, commit);
        console2.log("new fee factory", address(x.factory));
        console2.log("new fee hook", address(x.hook));
        console2.log("new fee router", address(x.router));
        console2.log("reused stocks", x.lines.length);
    }

    function deploy(uint256 saltStart) public returns (Deployment memory x) {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        if (msg.sender != deploymentOperator()) revert NotOperator(msg.sender);
        x.venue = _venue();
        _checkVenue(x.venue);
        x.defaults = x.venue.factory.getDefaults();
        if (
            x.defaults.supply != 1_000_000_000e18 || x.defaults.minTaxBps > 100
                || x.defaults.maxTaxBps < 100 || x.defaults.maxCreatorBps < 1000
        ) {
            revert BadBinding("base fee defaults");
        }
        x.defaults.sweepTipBps = 0;
        x.defaults = V2LaunchFeeDefaults.applyTo(x.defaults);
        Seed[] memory seeds = _seeds();
        // The shared test market is append-only. New, unrelated lines must not
        // block a fresh core for these eight reviewed seeds. _readPool still
        // verifies every original pool in the first eight registry entries.
        if (seeds.length != 8 || x.venue.market.poolCount() < 8) revert BadBinding("eight markets");
        x.lines = new Line[](8);
        for (uint256 i; i < seeds.length; ++i) {
            for (uint256 j; j < i; ++j) {
                if (seeds[i].stock == seeds[j].stock || seeds[i].pool == seeds[j].pool) {
                    revert BadBinding("duplicate stock");
                }
            }
            x.lines[i] = _readLine(x.venue, seeds[i]);
        }
        x.hookSalt = _mineHook(saltStart);
        vm.startBroadcast(deploymentOperator());
        _deployCore(x);
        _register(x);
        for (uint256 i; i < x.lines.length; ++i) {
            Line memory l = x.lines[i];
            x.factory.list(address(l.stock), address(l.oracle), l.pool, l.openPriceE18, true);
            x.factory.setListingGates(address(l.stock), l.maxDeviationBps, l.maxSlippageBps, l.sellChunkUsdg);
            x.treasury.setLpBps(address(l.stock), l.lpBps);
        }
        x.factory.setPublicLaunch(true);
        vm.stopBroadcast();
        _readBack(x);
    }

    function _checkVenue(Venue memory v) internal view {
        if (PM.code.length == 0 || WETH.code.length == 0 || CREATE2_FACTORY.code.length == 0) {
            revert BadBinding("chain dependencies");
        }
        if (
            v.factory.owner() != OPERATOR || v.factory.protocol() != OPERATOR
                || v.treasury.factory() != address(v.factory)
                || address(v.factory.treasuryDeployer()) != address(v.treasury) || v.factory.usdg() != address(v.usdg)
                || address(v.factory.v3Factory()) != address(v.v3Factory) || address(v.factory.poolManager()) != PM
                || v.market.owner() != OPERATOR || v.market.usdg() != address(v.usdg) || v.usdg.owner() != OPERATOR
                || v.usdgFeed.owner() != OPERATOR || v.calendar.owner() != OPERATOR || v.usdg.decimals() != 6
                || v.usdgFeed.decimals() != 8
        ) revert BadBinding("base venue");
    }

    function _readLine(Venue memory v, Seed memory s) internal view returns (Line memory l) {
        l.symbol = s.symbol;
        l.stock = TestStock(s.stock);
        l.feed = TestFeed(s.feed);
        l.oracle = PriceOracle(s.oracle);
        l.pool = s.pool;
        {
            (address oracle, address pool, uint256 open, bool enabled) = v.factory.listings(s.stock);
            if (!enabled || oracle != s.oracle || pool != s.pool || open == 0) revert BadBinding(s.symbol);
            l.openPriceE18 = open;
        }
        _checkOracle(v, l);
        _readPool(v, l);
        (bool ok, uint256 price,) = l.oracle.lastPriceAt();
        if (!ok || price == 0) revert BadBinding("synthetic price snapshot");
        l.priceE18 = price;
        (l.maxDeviationBps, l.maxSlippageBps, l.sellChunkUsdg) = v.factory.listingGates(s.stock);
        l.lpBps = v.treasury.lpBps(s.stock);
    }

    function _checkOracle(Venue memory v, Line memory l) internal view {
        if (
            l.stock.owner() != OPERATOR || l.feed.owner() != OPERATOR || l.stock.decimals() != 18
                || l.feed.decimals() != 8 || l.oracle.stock() != address(l.stock)
                || address(l.oracle.stockFeed()) != address(l.feed)
                || address(l.oracle.usdgFeed()) != address(v.usdgFeed)
                || address(l.oracle.calendar()) != address(v.calendar) || l.oracle.maxStockAge() != 26 hours
                || l.oracle.maxUsdgAge() != 26 hours
        ) revert BadBinding(l.symbol);
    }

    function _readPool(Venue memory v, Line memory l) internal view {
        IV3Pool p = IV3Pool(l.pool);
        l.fee = p.fee();
        if (
            v.v3Factory.getPool(address(l.stock), address(v.usdg), l.fee) != l.pool
                || !((p.token0() == address(l.stock) && p.token1() == address(v.usdg))
                    || (p.token1() == address(l.stock) && p.token0() == address(v.usdg)))
        ) revert BadBinding("canonical pool");
        (address marketStock, TestFeed marketFeed,, uint256 scale, int24 lo, int24 hi) = v.market.lines(l.pool);
        bool registered;
        for (uint256 i; i < 8; ++i) {
            if (v.market.pools(i) == l.pool) registered = true;
        }
        if (!registered || marketStock != address(l.stock) || address(marketFeed) != address(l.feed) || scale != 1e30) {
            revert BadBinding("market line");
        }
        l.tickLower = lo;
        l.tickUpper = hi;
        l.liquidity = p.liquidity();
        (,,, uint16 cardinality, uint16 cardinalityNext,,) = p.slot0();
        if (l.liquidity == 0 || cardinality < 720 || cardinalityNext < 720) revert BadBinding("pool depth/ring");
    }

    function _deployCore(Deployment memory x) internal {
        x.treasury = new V2TreasuryDeployer();
        x.token = new TokenDeployer();
        x.curve = new CurveDeployer(SALE_BPS);
        x.hook = new HedgeFunV2Hook{salt: x.hookSalt}(IPoolManager(PM));
        if (uint160(address(x.hook)) & 0x3FFF != HOOK_FLAGS) revert BadBinding("hook flags");
        x.factory = new HedgeFunV2Factory(
            deploymentOperator(),
            PM,
            address(x.venue.v3Factory),
            address(x.venue.usdg),
            OPERATOR,
            address(x.treasury),
            address(x.token),
            address(x.hook),
            address(x.curve),
            x.defaults
        );
        x.router = new HedgeFunV2TradeRouter(x.factory);
        x.nativeRouter = new HedgeFunV2NativeRouter(x.router, IWrappedNative(WETH));
    }

    function _register(Deployment memory x) internal virtual {
        (address a, address b) = x.treasury.makeChunks(type(HedgeFunV2UpgradeableBuybackTreasury).creationCode);
        if (x.treasury.registerKind(a, b) != 1) revert BadBinding("buyback kind");
        x.policy = new V2RebalancePolicy();
        x.policyKey = x.treasury
            .registerPolicy(
                address(x.policy),
                150_000,
                x.treasury.POLICY_RETURN_BYTES(),
                keccak256("hedgefun testnet 46630: V2RebalancePolicy dependencies (none audited for testnet)"),
                keccak256("hedgefun testnet 46630: V2RebalancePolicy audit manifest (testnet placeholder)")
            );
        (a, b) = x.treasury.makeChunks(type(HedgeFunV2UpgradeableEngineTreasury).creationCode);
        x.engineKind = x.treasury
            .registerEngineKind(
                a,
                b,
                StrategyCapabilities.SPOT_ENGINE_V1,
                StrategyCapabilities.CONFIG_SCHEMA_V1,
                StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL
            );
        if (x.engineKind != 2) revert BadBinding("engine kind");
    }

    function _readBack(Deployment memory x) internal view {
        if (
            x.factory.owner() != deploymentOperator() || x.factory.protocol() != OPERATOR || !x.factory.publicLaunch()
                || x.factory.strategyCount() != 0 || address(x.factory.poolManager()) != PM
                || address(x.factory.v3Factory()) != address(x.venue.v3Factory)
                || x.factory.usdg() != address(x.venue.usdg) || x.hook.factory() != address(x.factory)
                || x.hook.version() != 3 || x.treasury.factory() != address(x.factory)
                || x.token.factory() != address(x.factory) || x.curve.factory() != address(x.factory)
                || address(x.router.factory()) != address(x.factory)
                || address(x.nativeRouter.router()) != address(x.router)
                || address(x.nativeRouter.wrappedNative()) != WETH || x.treasury.kindCount() != 3
                || x.treasury.policy(x.policyKey).implementation != address(x.policy)
                || keccak256(abi.encode(x.factory.getDefaults())) != keccak256(abi.encode(x.defaults))
        ) revert BadBinding("new core");
        for (uint256 i; i < x.lines.length; ++i) {
            Line memory l = x.lines[i];
            (address oracle, address pool, uint256 open, bool enabled) = x.factory.listings(address(l.stock));
            (uint16 dev, uint16 slip, uint64 chunk) = x.factory.listingGates(address(l.stock));
            if (
                !enabled || oracle != address(l.oracle) || pool != l.pool || open != l.openPriceE18
                    || dev != l.maxDeviationBps || slip != l.maxSlippageBps || chunk != l.sellChunkUsdg
                    || x.treasury.lpBps(address(l.stock)) != l.lpBps
            ) revert BadBinding(l.symbol);
        }
        // Every venue call before and after core deployment is a view; check its bindings again.
        _checkVenue(x.venue);
    }

    function _mineHook(uint256 start) internal view returns (bytes32) {
        if (start > type(uint256).max - 2_000_000) revert BadBinding("salt range");
        bytes32 initHash = keccak256(abi.encodePacked(type(HedgeFunV2Hook).creationCode, abi.encode(PM)));
        for (uint256 i = start; i < start + 2_000_000; ++i) {
            address hook = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, bytes32(i), initHash))))
            );
            if (uint160(hook) & 0x3FFF == HOOK_FLAGS && hook.code.length == 0) return bytes32(i);
        }
        revert BadBinding("no hook salt");
    }

    function _checkCommit(string memory commit) internal pure {
        bytes memory c = bytes(commit);
        if (c.length != 40) revert BadCommit();
        for (uint256 i; i < c.length; ++i) {
            if (!((c[i] >= 0x30 && c[i] <= 0x39) || (c[i] >= 0x61 && c[i] <= 0x66))) revert BadCommit();
        }
    }

    function _writeCandidate(Deployment memory x, uint256 startBlock, bool requested, string memory commit) internal {
        string memory k = "feeUpgrade";
        vm.serializeString(k, "schema", "v2-testnet-two-sided-fee-upgrade-v1");
        vm.serializeString(k, "featureVersion", _featureVersion());
        vm.serializeUint(k, "chainId", CHAIN_ID);
        vm.serializeBool(k, "broadcast", false);
        vm.serializeBool(k, "broadcastRequested", requested);
        vm.serializeUint(k, "block", startBlock);
        vm.serializeString(k, "commit", commit);
        vm.serializeString(k, "baseBookSha256", BASE_BOOK_SHA256);
        vm.serializeAddress(k, "baseFactory", address(x.venue.factory));
        vm.serializeAddress(k, "baseTreasuryDeployer", address(x.venue.treasury));
        vm.serializeAddress(k, "operator", deploymentOperator());
        vm.serializeAddress(k, "owner", deploymentOperator());
        vm.serializeAddress(k, "venueOperator", OPERATOR);
        vm.serializeAddress(k, "protocol", OPERATOR);
        vm.serializeAddress(k, "poolManager", PM);
        vm.serializeAddress(k, "weth", WETH);
        vm.serializeAddress(k, "usdg", address(x.venue.usdg));
        vm.serializeAddress(k, "usdgFeed", address(x.venue.usdgFeed));
        vm.serializeAddress(k, "calendar", address(x.venue.calendar));
        vm.serializeAddress(k, "v3Factory", address(x.venue.v3Factory));
        vm.serializeAddress(k, "market", address(x.venue.market));
        vm.serializeAddress(k, "factory", address(x.factory));
        vm.serializeAddress(k, "treasuryDeployer", address(x.treasury));
        vm.serializeAddress(k, "tokenDeployer", address(x.token));
        vm.serializeAddress(k, "curveDeployer", address(x.curve));
        vm.serializeAddress(k, "hook", address(x.hook));
        vm.serializeBytes32(k, "hookSalt", x.hookSalt);
        vm.serializeAddress(k, "tradeRouter", address(x.router));
        vm.serializeAddress(k, "nativeRouter", address(x.nativeRouter));
        vm.serializeAddress(k, "rebalancePolicy", address(x.policy));
        vm.serializeBytes32(k, "rebalancePolicyKey", x.policyKey);
        vm.serializeUint(k, "engineKind", x.engineKind);
        vm.serializeUint(k, "recommendedTaxBps", 100);
        vm.serializeUint(k, "recommendedCreatorBps", 1000);
        vm.serializeUint(k, "plannedTransactionCount", plannedTransactionCount());
        string memory stocks;
        for (uint256 i; i < x.lines.length; ++i) {
            stocks = vm.serializeString("reusedStocks", x.lines[i].symbol, _lineJson(x.lines[i]));
        }
        string memory json = vm.serializeString(k, "stocks", stocks);
        string memory path = _candidatePath(requested);
        vm.writeJson(json, path);
        console2.log("unverified candidate", path);
    }

    /// @dev `-v2` from the version-3 hook on: a book of this family that says `-v1` has the hook whose buy fee
    ///      waits for `convertFees`, and the tools written for it must not accept one that does not.
    function _featureVersion() internal pure virtual returns (string memory) {
        return "v2-two-sided-stock-fees-v2";
    }

    /// @dev A fresh test operator can own only the new core. Reused venue ownership,
    ///      protocol recipient and every original venue check stay pinned to OPERATOR.
    function deploymentOperator() public pure virtual returns (address) {
        return OPERATOR;
    }

    function plannedTransactionCount() public pure virtual returns (uint256) {
        return PLANNED_TRANSACTIONS;
    }

    function _candidatePath(bool requested) internal pure virtual returns (string memory) {
        return requested ? OUT : OUT_DRY;
    }

    function _lineJson(Line memory l) internal returns (string memory) {
        string memory k = string.concat("feeStock.", l.symbol);
        vm.serializeAddress(k, "token", address(l.stock));
        vm.serializeAddress(k, "feed", address(l.feed));
        vm.serializeAddress(k, "oracle", address(l.oracle));
        vm.serializeAddress(k, "pool", l.pool);
        vm.serializeUint(k, "fee", l.fee);
        vm.serializeUint(k, "decimals", 18);
        // These are synthetic oracle snapshots, never a claim of a live stock market quote.
        vm.serializeString(k, "priceE18", vm.toString(l.priceE18));
        vm.serializeString(k, "openPriceE18", vm.toString(l.openPriceE18));
        vm.serializeInt(k, "tickLower", l.tickLower);
        vm.serializeInt(k, "tickUpper", l.tickUpper);
        vm.serializeString(k, "liquidity", vm.toString(l.liquidity));
        vm.serializeUint(k, "maxDeviationBps", l.maxDeviationBps);
        vm.serializeUint(k, "maxSlippageBps", l.maxSlippageBps);
        vm.serializeString(k, "sellChunkUsdg", vm.toString(l.sellChunkUsdg));
        return vm.serializeUint(k, "lpBps", l.lpBps);
    }
}
