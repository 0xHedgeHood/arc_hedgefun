// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {V2TreasuryDeployer} from "../../src/v2/V2TreasuryDeployer.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {TradingCalendar} from "../../src/TradingCalendar.sol";
import {TestUsdg, TestStock, TestFeed} from "./TestnetAssets.sol";
import {TestnetMarket, IV3Factory, IV3Pool} from "./TestnetMarket.sol";

/// @notice Append four synthetic stocks to the existing whitelist V2 TESTNET deployment.
/// No factory, router, quote asset, calendar, feed or existing stock is redeployed or reconfigured.
/// Candidate files are always unverified. Only independent receipt/readback verification can publish them.
contract AddV2TestnetStocks is Script {
    uint256 public constant CHAIN_ID = 46630;
    address public constant OPERATOR = 0x75Cee941B0eF3A83feA0397BbF903C12c1D7e96D;
    address public constant FACTORY = 0x3E95976E2425e63cb2A8d48BBce8976F55627019;
    address public constant MARKET = 0xc1AF2f52980F8A7AA4E90A8E30D5c3FaF0375f21;
    address public constant USDG = 0x539574139BB4Ac74Fd2183ba0E38ed777E30B58d;
    address public constant USDG_FEED = 0x6beF5980dDa88F8B925f814C5033959A13ae535A;
    address public constant CALENDAR = 0xB8661bAd51e504862107CF4eBAdB1c8c2ABFA6CD;
    address public constant V3_FACTORY = 0x0b0a96D7EB396E7471998889C4803dD0F529Eb01;
    address public constant TREASURY_DEPLOYER = 0xB15D34FC30292DeDb070875074e7b56FD34a1da2;
    uint16 public constant CARDINALITY = 720;
    uint16 public constant MAX_DEVIATION_BPS = 50;
    uint16 public constant MAX_SLIPPAGE_BPS = 100;
    uint64 public constant SELL_CHUNK_USDG = 2_000e6;
    uint16 public constant LP_BPS = 5000;
    uint256 public constant USDG_SIDE = 30_000_000e6;
    int24 internal constant RANGE_TICKS = 6960;
    string internal constant OUT = "deploy/testnet-v2-stock-extension.candidate.json";
    string internal constant OUT_DRY = "deploy/testnet-v2-stock-extension.dryrun.json";

    error WrongChain(uint256 chainId);
    error NotOperator(address sender);
    error BadBinding(string what);
    error AlreadyExtended(uint256 poolCount);
    error BadPoke(address pool);

    struct Venue {
        HedgeFunV2Factory factory;
        TestnetMarket market;
        TestUsdg usdg;
        TestFeed usdgFeed;
        TradingCalendar calendar;
        IV3Factory v3Factory;
        V2TreasuryDeployer treasury;
    }

    struct StockSpec {
        string symbol;
        string name;
        uint256 priceE18;
        uint256 openPriceE18;
        uint24 fee;
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

    // Overridden only by the offline test harness. Production targets cannot be supplied by environment or calldata.
    function _venue() internal view virtual returns (Venue memory v) {
        return Venue(
            HedgeFunV2Factory(FACTORY),
            TestnetMarket(MARKET),
            TestUsdg(USDG),
            TestFeed(USDG_FEED),
            TradingCalendar(CALENDAR),
            IV3Factory(V3_FACTORY),
            V2TreasuryDeployer(TREASURY_DEPLOYER)
        );
    }

    function specs() public pure returns (StockSpec[] memory s) {
        s = new StockSpec[](4);
        // Declared synthetic prices, NOT live market quotes. Curve opening FDV is about 10,000 tUSDG per stock.
        s[0] = StockSpec("MSFT", "Microsoft test stock (testnet, no value)", 500e18, 20_000_000_000, 3000, 20e18);
        s[1] = StockSpec("AMZN", "Amazon test stock (testnet, no value)", 200e18, 50_000_000_000, 3000, 50e18);
        s[2] = StockSpec("GOOGL", "Alphabet test stock (testnet, no value)", 200e18, 50_000_000_000, 500, 50e18);
        s[3] = StockSpec("META", "Meta test stock (testnet, no value)", 600e18, 16_666_666_667, 3000, 20e18);
    }

    function run() external returns (Line[] memory lines) {
        uint256 startBlock = block.number;
        lines = append();
        bool requested =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        _writeCandidate(_venue(), lines, startBlock, requested);
    }

    function append() public returns (Line[] memory lines) {
        _checkCaller();
        Venue memory v = _venue();
        _checkVenue(v);
        uint256 count = v.market.poolCount();
        if (count != 4) revert AlreadyExtended(count);
        StockSpec[] memory s = specs();
        lines = new Line[](s.length);
        vm.startBroadcast(OPERATOR);
        for (uint256 i; i < s.length; i++) {
            lines[i] = _deployLine(v, s[i]);
            Line memory l = lines[i];
            v.factory.list(address(l.stock), address(l.oracle), l.pool, l.openPriceE18, true);
            v.factory.setListingGates(address(l.stock), MAX_DEVIATION_BPS, MAX_SLIPPAGE_BPS, SELL_CHUNK_USDG);
            v.treasury.setLpBps(address(l.stock), LP_BPS);
        }
        vm.stopBroadcast();
        if (v.market.poolCount() != 8) revert BadBinding("pool inventory");
        for (uint256 i; i < lines.length; i++) {
            _readBack(v, lines[i]);
        }
    }

    /// @notice Separate transaction, at least one second after the pools' last write, for the NEW pools only.
    /// Pass the four candidate pool addresses. This never reads an unverified candidate or touches old pools.
    function poke(address[4] calldata pools) external {
        _checkCaller();
        Venue memory v = _venue();
        _checkVenue(v);
        for (uint256 i; i < pools.length; i++) {
            for (uint256 j; j < i; j++) {
                if (pools[i] == pools[j]) revert BadPoke(pools[i]);
            }
            bool registeredNew;
            for (uint256 j = 4; j < 8; j++) {
                if (v.market.pools(j) == pools[i]) registeredNew = true;
            }
            if (!registeredNew) revert BadPoke(pools[i]);
            (address stock, TestFeed feed,,,,) = v.market.lines(pools[i]);
            (address oracle, address pool,, bool enabled) = v.factory.listings(stock);
            if (
                !enabled || pool != pools[i] || v.v3Factory.getPool(stock, address(v.usdg), IV3Pool(pool).fee()) != pool
                    || PriceOracle(oracle).stock() != stock || address(PriceOracle(oracle).stockFeed()) != address(feed)
                    || TestStock(stock).owner() != OPERATOR || feed.owner() != OPERATOR
            ) revert BadPoke(pool);
        }
        vm.startBroadcast(OPERATOR);
        for (uint256 i; i < pools.length; i++) {
            v.market.poke(pools[i]);
        }
        vm.stopBroadcast();
        for (uint256 i; i < pools.length; i++) {
            (,,, uint16 card,,,) = IV3Pool(pools[i]).slot0();
            if (card < CARDINALITY) revert BadPoke(pools[i]);
        }
    }

    function _checkCaller() internal view {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        if (msg.sender != OPERATOR) revert NotOperator(msg.sender);
    }

    function _checkVenue(Venue memory v) internal view {
        if (
            address(v.factory).code.length == 0 || address(v.market).code.length == 0
                || address(v.usdg).code.length == 0 || address(v.usdgFeed).code.length == 0
                || address(v.calendar).code.length == 0 || address(v.v3Factory).code.length == 0
                || address(v.treasury).code.length == 0
        ) revert BadBinding("code");
        if (
            v.factory.owner() != OPERATOR || v.market.owner() != OPERATOR || v.usdg.owner() != OPERATOR
                || v.usdgFeed.owner() != OPERATOR || v.calendar.owner() != OPERATOR
        ) revert BadBinding("owner");
        if (
            v.factory.usdg() != address(v.usdg) || address(v.factory.v3Factory()) != address(v.v3Factory)
                || address(v.factory.treasuryDeployer()) != address(v.treasury)
                || v.treasury.factory() != address(v.factory) || v.market.usdg() != address(v.usdg)
                || !v.usdg.operators(address(v.market)) || !v.factory.publicLaunch()
        ) revert BadBinding("venue");
    }

    function _deployLine(Venue memory v, StockSpec memory s) internal returns (Line memory l) {
        l.symbol = s.symbol;
        l.fee = s.fee;
        l.priceE18 = s.priceE18;
        l.openPriceE18 = s.openPriceE18;
        l.stock = new TestStock(s.name, s.symbol, OPERATOR, s.dripAmount);
        l.feed = new TestFeed(
            string.concat(s.symbol, " / USD (testnet, operator-set)"), int256(s.priceE18 / 1e10), OPERATOR
        );
        l.stock.setOperator(address(v.market), true);
        l.feed.setOperator(address(v.market), true);
        l.oracle = new PriceOracle(
            address(l.stock), address(l.feed), address(v.usdgFeed), address(v.calendar), 26 hours, 26 hours
        );
        l.pool = v.v3Factory.createPool(address(l.stock), address(v.usdg), s.fee);
        bool stock0 = address(l.stock) < address(v.usdg);
        uint160 sqrtP = uint160(
            Math.sqrt(stock0 ? Math.mulDiv(s.priceE18, 1 << 192, 1e30) : Math.mulDiv(1e30, 1 << 192, s.priceE18))
        );
        int24 spacing = v.v3Factory.feeAmountTickSpacing(s.fee);
        int24 centre = TickMath.getTickAtSqrtPrice(sqrtP) / spacing * spacing;
        l.tickLower = centre - RANGE_TICKS / spacing * spacing;
        l.tickUpper = centre + RANGE_TICKS / spacing * spacing;
        v.market.addLine(l.pool, address(l.stock), l.feed, 18, l.tickLower, l.tickUpper);
        IV3Pool(l.pool).initialize(v.market.sqrtFor(l.pool, s.priceE18));
        IV3Pool(l.pool).increaseObservationCardinalityNext(CARDINALITY);
        uint256 a = TickMath.getSqrtPriceAtTick(l.tickLower);
        uint256 b = TickMath.getSqrtPriceAtTick(l.tickUpper);
        l.liquidity = uint128(
            stock0
                ? Math.mulDiv(USDG_SIDE, 1 << 96, uint256(sqrtP) - a)
                : Math.mulDiv(Math.mulDiv(USDG_SIDE, uint256(sqrtP), b - uint256(sqrtP)), b, 1 << 96)
        );
        v.market.provide(l.pool, l.liquidity);
    }

    function _readBack(Venue memory v, Line memory l) internal view {
        (address oracle, address pool, uint256 open, bool enabled) = v.factory.listings(address(l.stock));
        (uint16 dev, uint16 slip, uint64 chunk) = v.factory.listingGates(address(l.stock));
        (bool ok, uint256 price,) = l.oracle.lastPriceAt();
        (uint160 sqrtP,,, uint16 card, uint16 next,,) = IV3Pool(l.pool).slot0();
        if (
            !enabled || oracle != address(l.oracle) || pool != l.pool || open != l.openPriceE18
                || dev != MAX_DEVIATION_BPS || slip != MAX_SLIPPAGE_BPS || chunk != SELL_CHUNK_USDG
                || v.treasury.lpBps(address(l.stock)) != LP_BPS || !ok || price != l.priceE18
                || l.stock.owner() != OPERATOR || l.feed.owner() != OPERATOR || !l.stock.operators(address(v.market))
                || !l.feed.operators(address(v.market)) || l.stock.oraclePaused() || l.stock.uiMultiplier() != 1e18
                || l.stock.decimals() != 18 || IV3Pool(l.pool).liquidity() != l.liquidity
                || sqrtP != v.market.sqrtFor(l.pool, l.priceE18) || card == 0 || next < CARDINALITY
        ) revert BadBinding(l.symbol);
    }

    function _writeCandidate(Venue memory v, Line[] memory lines, uint256 startBlock, bool requested) internal {
        string memory k = "stock-extension";
        string memory stocks;
        for (uint256 i; i < lines.length; i++) {
            stocks = vm.serializeString("extension-stocks", lines[i].symbol, _lineJson(lines[i]));
        }
        vm.serializeString(k, "schema", "v2-testnet-stock-extension-v1");
        vm.serializeUint(k, "chainId", CHAIN_ID);
        vm.serializeBool(k, "broadcast", false);
        vm.serializeBool(k, "broadcastRequested", requested);
        vm.serializeString(k, "commit", vm.envOr("GIT_COMMIT", string("unset")));
        vm.serializeString(k, "priceSource", "Declared synthetic test prices; not live market quotes.");
        vm.serializeUint(k, "block", startBlock);
        vm.serializeAddress(k, "operator", OPERATOR);
        vm.serializeAddress(k, "baseFactory", address(v.factory));
        vm.serializeAddress(k, "baseMarket", address(v.market));
        vm.serializeAddress(k, "usdg", address(v.usdg));
        vm.serializeAddress(k, "usdgFeed", address(v.usdgFeed));
        vm.serializeAddress(k, "calendar", address(v.calendar));
        vm.serializeAddress(k, "v3Factory", address(v.v3Factory));
        vm.serializeAddress(k, "treasuryDeployer", address(v.treasury));
        string memory json = vm.serializeString(k, "stocks", stocks);
        vm.writeJson(json, requested ? OUT : OUT_DRY);
        console2.log("Wrote UNVERIFIED stock extension candidate:", requested ? OUT : OUT_DRY);
    }

    function _lineJson(Line memory l) internal returns (string memory) {
        string memory k = string.concat("extension-", l.symbol);
        vm.serializeString(k, "name", l.stock.name());
        vm.serializeAddress(k, "token", address(l.stock));
        vm.serializeAddress(k, "feed", address(l.feed));
        vm.serializeAddress(k, "oracle", address(l.oracle));
        vm.serializeAddress(k, "pool", l.pool);
        vm.serializeBytes32(k, "tokenCodeHash", address(l.stock).codehash);
        vm.serializeBytes32(k, "feedCodeHash", address(l.feed).codehash);
        vm.serializeBytes32(k, "oracleCodeHash", address(l.oracle).codehash);
        vm.serializeBytes32(k, "poolCodeHash", l.pool.codehash);
        vm.serializeUint(k, "fee", l.fee);
        vm.serializeString(k, "priceE18", vm.toString(l.priceE18));
        vm.serializeUint(k, "decimals", 18);
        vm.serializeString(k, "openPriceE18", vm.toString(l.openPriceE18));
        vm.serializeString(k, "dripAmount", vm.toString(l.stock.dripAmount()));
        vm.serializeString(k, "liquidity", vm.toString(uint256(l.liquidity)));
        vm.serializeInt(k, "tickLower", l.tickLower);
        vm.serializeInt(k, "tickUpper", l.tickUpper);
        vm.serializeUint(k, "cardinalityNext", CARDINALITY);
        vm.serializeUint(k, "lpBps", LP_BPS);
        vm.serializeUint(k, "maxDeviationBps", MAX_DEVIATION_BPS);
        vm.serializeUint(k, "maxSlippageBps", MAX_SLIPPAGE_BPS);
        return vm.serializeUint(k, "sellChunkUsdg", SELL_CHUNK_USDG);
    }
}
