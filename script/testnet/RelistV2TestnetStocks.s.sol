// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {Drip, TestFeed} from "./TestnetAssets.sol";
import {IV3Factory, IV3Pool} from "./TestnetMarket.sol";
import {TestnetDeployerMarket} from "./TestnetDeployerMarket.sol";

/// @notice Re-list the release factory's stocks on a venue the deployer controls: a feed and an oracle per stock, a
///         fresh V3 pool at the other fee tier, and `TestnetDeployerMarket` as its only liquidity provider, funded by
///         faucet drips. The tokens, the tUSDG feed and the calendar stay the venue owner's; none of them needs an
///         owner to keep working. One phase per transaction set, `SYMBOLS` (default `TSLA`) selects the stocks, and
///         the venue file carries the state between phases. No key is held here.
///
///         deploy()   feed, oracle, pool, cardinality 720, market line; writes the venue file
///         fund()     drips to the deployer and the market, moves the deployer's balances in, provides liquidity
///         relist()   `list` and `setListingGates` on the release factory, then a `poke` so the observation ring is live
///         setPrice() `SYMBOL`, `PRICE_E18`: pool and feed to the price (then wait ten minutes for the mean)
///         syncFeed() `SYMBOL`: feed to the pool price after public trades
///         status()   read-only
contract RelistV2TestnetStocks is Script {
    uint256 private constant CHAIN_ID = 46630;
    address private constant OWNER = 0x36437b878415EdA1a24186CF79AFffBc9ecEd298;
    address private constant FACTORY = 0x6847318D28aB2f9343DDd2067871DC4f48609383;
    address private constant USDG = 0x539574139BB4Ac74Fd2183ba0E38ed777E30B58d;
    address private constant USDG_FEED = 0x6beF5980dDa88F8B925f814C5033959A13ae535A;
    address private constant CALENDAR = 0xB8661bAd51e504862107CF4eBAdB1c8c2ABFA6CD;
    address private constant V3_FACTORY = 0x0b0a96D7EB396E7471998889C4803dD0F529Eb01;
    uint16 private constant CARDINALITY = 720;
    int24 private constant RANGE_TICKS = 6960;         // the original lines' half-width: about a 2x move either way
    uint256 private constant MAX_AGE = 26 hours;       // as the original oracles
    // Gates for a pool a few days of drips deep, instead of the original 50 / 100 / 2,000 on thirty-million pools.
    uint16 private constant MAX_DEVIATION_BPS = 200;
    uint16 private constant MAX_SLIPPAGE_BPS = 300;
    uint64 private constant SELL_CHUNK_USDG = 200e6;
    string private constant BOOK = "deploy/testnet-v2-release.json";
    string private constant VERIFIED = "deploy/testnet-v2-venue.json";
    string private constant OUT = "deploy/testnet-v2-venue.candidate.json";
    string private constant OUT_DRY = "deploy/testnet-v2-venue.dryrun.json";

    struct Line {
        string symbol;
        address stock;
        TestFeed feed;
        PriceOracle oracle;
        address pool;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 priceE18;
    }

    error WrongChain(uint256 actual);
    error WrongSender(address actual);
    error BadBook(string what);
    error BadVenue(string what);

    TestnetDeployerMarket private market;
    Line[] private venue;

    function deploy() external {
        _sender();
        string memory book = _book();
        string[] memory symbols = _symbols();
        bool fresh = !_loadVenue();
        vm.startBroadcast();
        if (fresh) market = new TestnetDeployerMarket(OWNER, USDG);
        for (uint256 i; i < symbols.length; i++) {
            if (_indexOf(symbols[i]) != type(uint256).max) continue;   // already on the venue
            venue.push(_deployLine(book, symbols[i]));
        }
        vm.stopBroadcast();
        if (fresh && market.owner() != OWNER) revert BadVenue("market owner");
        _writeVenue();
        _status();
    }

    /// @dev One symbol at a time is the useful way to run this: `provide` puts ALL the market's tUSDG into the pool.
    function fund() external {
        _sender();
        _book();
        if (!_loadVenue()) revert BadVenue("deploy first");
        string[] memory symbols = _symbols();
        vm.startBroadcast();
        _dripBoth(USDG);
        for (uint256 i; i < symbols.length; i++) _dripBoth(venue[_index(symbols[i])].stock);
        _moveIn(USDG, vm.envOr("USDG_IN", IERC20(USDG).balanceOf(OWNER)));
        for (uint256 i; i < symbols.length; i++) {
            Line memory l = venue[_index(symbols[i])];
            _moveIn(l.stock, vm.envOr("STOCK_IN", IERC20(l.stock).balanceOf(OWNER)));
            (uint128 added, uint256 a0, uint256 a1) = market.provide(l.pool);
            console2.log(string.concat(l.symbol, " liquidity added"), uint256(added));
            console2.log(string.concat(l.symbol, " amount0 / amount1"), a0, a1);
        }
        vm.stopBroadcast();
        _status();
    }

    function relist() external {
        _sender();
        _book();
        if (!_loadVenue()) revert BadVenue("deploy first");
        HedgeFunV2Factory factory = HedgeFunV2Factory(FACTORY);
        string[] memory symbols = _symbols();
        vm.startBroadcast();
        for (uint256 i; i < symbols.length; i++) {
            Line memory l = venue[_index(symbols[i])];
            if (IV3Pool(l.pool).liquidity() == 0) revert BadVenue("fund first");
            (,, uint256 open,) = factory.listings(l.stock);
            factory.list(l.stock, address(l.oracle), l.pool, open, true);
            factory.setListingGates(l.stock, MAX_DEVIATION_BPS, MAX_SLIPPAGE_BPS, SELL_CHUNK_USDG);
            market.poke(l.pool);
        }
        vm.stopBroadcast();
        for (uint256 i; i < symbols.length; i++) _readBack(venue[_index(symbols[i])]);
        _status();
    }

    function setPrice() external {
        _sender();
        _book();
        if (!_loadVenue()) revert BadVenue("deploy first");
        Line memory l = venue[_index(vm.envString("SYMBOL"))];
        uint256 price = vm.envUint("PRICE_E18");
        vm.startBroadcast();
        market.setPrice(l.pool, price);
        vm.stopBroadcast();
        (bool ok, uint256 p,) = l.oracle.lastPriceAt();
        (uint160 sqrtP,,,,,,) = IV3Pool(l.pool).slot0();
        if (!ok || p != price || sqrtP != market.sqrtFor(l.pool, price)) revert BadVenue("price not set");
        _status();
    }

    function syncFeed() external {
        _sender();
        _book();
        if (!_loadVenue()) revert BadVenue("deploy first");
        Line memory l = venue[_index(vm.envString("SYMBOL"))];
        vm.startBroadcast();
        market.syncFeed(l.pool);
        vm.stopBroadcast();
        _status();
    }

    function status() external {
        _book();
        if (!_loadVenue()) revert BadVenue("deploy first");
        _status();
    }

    // ------------------------------------------------------------------------------------------------------ phases

    function _deployLine(string memory book, string memory symbol) private returns (Line memory l) {
        string memory key = string.concat(".stocks.", symbol);
        l.symbol = symbol;
        l.stock = vm.parseJsonAddress(book, string.concat(key, ".token"));
        uint24 oldFee = uint24(vm.parseJsonUint(book, string.concat(key, ".fee")));
        l.fee = uint24(vm.envOr("POOL_FEE", uint256(oldFee == 3000 ? 500 : 3000)));
        l.priceE18 = _priceOf(PriceOracle(vm.parseJsonAddress(book, string.concat(key, ".oracle"))), l.stock, symbol);
        (l.feed, l.oracle) = _oracleFor(symbol, l.stock, l.priceE18);
        (l.pool, l.tickLower, l.tickUpper) = _openPool(l.stock, l.fee, l.priceE18);
        market.addLine(l.pool, l.stock, l.feed, 18, l.tickLower, l.tickUpper);
        if (IV3Pool(l.pool).liquidity() != 0) console2.log(string.concat(symbol, ": the pool already has other liquidity"));
    }

    function _priceOf(PriceOracle old, address stock, string memory symbol) private view returns (uint256 price) {
        bool ok;
        (ok, price,) = old.lastPriceAt();
        if (!ok || price == 0 || old.stock() != stock) revert BadBook(symbol);
    }

    function _oracleFor(string memory symbol, address stock, uint256 price) private returns (TestFeed feed, PriceOracle oracle) {
        feed = new TestFeed(string.concat(symbol, " / USD (testnet, deployer-set)"), int256(price / 1e10), OWNER);
        feed.setOperator(address(market), true);
        oracle = new PriceOracle(stock, address(feed), USDG_FEED, CALENDAR, MAX_AGE, MAX_AGE);
    }

    /// @dev the pool at the fee tier, created and opened at `price` if new; the line is centred on the pool's price
    function _openPool(address stock, uint24 fee, uint256 price) private returns (address pool, int24 lower, int24 upper) {
        IV3Factory v3 = IV3Factory(V3_FACTORY);
        pool = v3.getPool(stock, USDG, fee);
        if (pool == address(0)) pool = v3.createPool(stock, USDG, fee);
        int24 spacing = v3.feeAmountTickSpacing(fee);
        if (spacing == 0) revert BadVenue("fee tier");
        (uint160 sqrtP,,,,,,) = IV3Pool(pool).slot0();
        if (sqrtP == 0) {
            bool stock0 = stock < USDG;
            sqrtP = uint160(Math.sqrt(stock0 ? Math.mulDiv(price, 1 << 192, 1e30) : Math.mulDiv(1e30, 1 << 192, price)));
            IV3Pool(pool).initialize(sqrtP);
        }
        int24 centre = TickMath.getTickAtSqrtPrice(sqrtP) / spacing * spacing;
        lower = centre - RANGE_TICKS / spacing * spacing;
        upper = centre + RANGE_TICKS / spacing * spacing;
        IV3Pool(pool).increaseObservationCardinalityNext(CARDINALITY);
    }

    function _dripBoth(address token) private {
        Drip d = Drip(token);
        if (d.lastDrip(OWNER) + d.DRIP_INTERVAL() <= block.timestamp) d.drip();
        if (d.lastDrip(address(market)) + d.DRIP_INTERVAL() <= block.timestamp) market.drip(token);
    }

    function _moveIn(address token, uint256 amount) private {
        if (amount != 0) require(IERC20(token).transfer(address(market), amount), "transfer failed");
    }

    function _readBack(Line memory l) private view {
        HedgeFunV2Factory factory = HedgeFunV2Factory(FACTORY);
        (address oracle, address pool, uint256 open, bool enabled) = factory.listings(l.stock);
        (uint16 dev, uint16 slip, uint64 chunk) = factory.listingGates(l.stock);
        if (
            !enabled || oracle != address(l.oracle) || pool != l.pool || open == 0 || dev != MAX_DEVIATION_BPS
                || slip != MAX_SLIPPAGE_BPS || chunk != SELL_CHUNK_USDG
        ) revert BadVenue(string.concat(l.symbol, " listing"));
        _poolReadBack(l);
    }

    function _poolReadBack(Line memory l) private view {
        (bool ok, uint256 price,) = l.oracle.lastPriceAt();
        (uint160 sqrtP,,, uint16 card, uint16 next,,) = IV3Pool(l.pool).slot0();
        (,,,,,, uint128 held) = market.lines(l.pool);
        if (
            !ok || price == 0 || market.priceAt(l.pool, sqrtP) / 1e10 != price / 1e10 || l.feed.owner() != OWNER
                || !l.feed.operators(address(market)) || IV3Pool(l.pool).liquidity() < held || held == 0 || card == 0
                || next < CARDINALITY
        ) revert BadVenue(string.concat(l.symbol, " pool"));
    }

    function _status() private view {
        console2.log("market", address(market));
        console2.log("market tUSDG", IERC20(USDG).balanceOf(address(market)));
        for (uint256 i; i < venue.length; i++) _statusLine(venue[i]);
    }

    function _statusLine(Line memory l) private view {
        (bool ok, uint256 p,) = l.oracle.lastPriceAt();
        (uint160 sqrtP,,,,,,) = IV3Pool(l.pool).slot0();
        (address oracle, address pool,, bool enabled) = HedgeFunV2Factory(FACTORY).listings(l.stock);
        console2.log(string.concat("--- ", l.symbol), l.pool);
        console2.log("  oracle ok", ok);
        console2.log("  oracle price", p);
        console2.log("  pool price", market.priceAt(l.pool, sqrtP));
        console2.log("  pool liquidity", uint256(IV3Pool(l.pool).liquidity()));
        console2.log("  market stock", IERC20(l.stock).balanceOf(address(market)));
        console2.log("  market could still provide", uint256(market.affordable(l.pool)));
        console2.log("  listed on the release factory", enabled && oracle == address(l.oracle) && pool == l.pool);
    }

    // ------------------------------------------------------------------------------------------------ the venue file

    function _loadVenue() private returns (bool) {
        string memory path = _venuePath();
        if (!vm.exists(path)) return false;
        string memory json = vm.readFile(path);
        if (vm.parseJsonUint(json, ".chainId") != CHAIN_ID) revert BadVenue("chain");
        if ((vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume))
            && !vm.parseJsonBool(json, ".broadcastRequested")) revert BadVenue("a dry-run venue cannot be broadcast against");
        market = TestnetDeployerMarket(vm.parseJsonAddress(json, ".market"));
        if (address(market).code.length == 0 || market.usdg() != USDG) revert BadVenue("market");
        string[] memory symbols = vm.parseJsonKeys(json, ".stocks");
        for (uint256 i; i < symbols.length; i++) {
            string memory key = string.concat(".stocks.", symbols[i]);
            Line memory l;
            l.symbol = symbols[i];
            l.stock = vm.parseJsonAddress(json, string.concat(key, ".token"));
            l.feed = TestFeed(vm.parseJsonAddress(json, string.concat(key, ".feed")));
            l.oracle = PriceOracle(vm.parseJsonAddress(json, string.concat(key, ".oracle")));
            l.pool = vm.parseJsonAddress(json, string.concat(key, ".pool"));
            l.fee = uint24(vm.parseJsonUint(json, string.concat(key, ".fee")));
            l.tickLower = int24(vm.parseJsonInt(json, string.concat(key, ".tickLower")));
            l.tickUpper = int24(vm.parseJsonInt(json, string.concat(key, ".tickUpper")));
            l.priceE18 = vm.parseJsonUint(json, string.concat(key, ".priceE18"));
            (address stock,,,,,,) = market.lines(l.pool);
            if (stock != l.stock || l.oracle.stock() != l.stock) revert BadVenue(l.symbol);
            venue.push(l);
        }
        return true;
    }

    function _writeVenue() private {
        bool requested = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        string memory stocks;
        for (uint256 i; i < venue.length; i++) {
            Line memory l = venue[i];
            string memory k = string.concat("venue-", l.symbol);
            vm.serializeAddress(k, "token", l.stock);
            vm.serializeAddress(k, "feed", address(l.feed));
            vm.serializeAddress(k, "oracle", address(l.oracle));
            vm.serializeAddress(k, "pool", l.pool);
            vm.serializeUint(k, "fee", l.fee);
            vm.serializeInt(k, "tickLower", l.tickLower);
            vm.serializeInt(k, "tickUpper", l.tickUpper);
            vm.serializeUint(k, "decimals", 18);
            vm.serializeUint(k, "maxDeviationBps", MAX_DEVIATION_BPS);
            vm.serializeUint(k, "maxSlippageBps", MAX_SLIPPAGE_BPS);
            vm.serializeUint(k, "sellChunkUsdg", SELL_CHUNK_USDG);
            stocks = vm.serializeString("venue-stocks", l.symbol, vm.serializeString(k, "priceE18", vm.toString(l.priceE18)));
        }
        string memory k2 = "venue";
        vm.serializeString(k2, "schema", "v2-testnet-deployer-venue-v1");
        vm.serializeUint(k2, "chainId", CHAIN_ID);
        vm.serializeBool(k2, "broadcastRequested", requested);
        vm.serializeAddress(k2, "owner", OWNER);
        vm.serializeAddress(k2, "factory", FACTORY);
        vm.serializeAddress(k2, "market", address(market));
        vm.serializeAddress(k2, "usdg", USDG);
        vm.serializeAddress(k2, "usdgFeed", USDG_FEED);
        vm.serializeAddress(k2, "calendar", CALENDAR);
        vm.serializeAddress(k2, "v3Factory", V3_FACTORY);
        vm.serializeUint(k2, "cardinalityNext", CARDINALITY);
        string memory json = vm.serializeString(k2, "stocks", stocks);
        vm.writeJson(json, requested ? OUT : OUT_DRY);
        console2.log("wrote", requested ? OUT : OUT_DRY);
    }

    /// @dev `VENUE`, else the verified file once the verifier wrote it, else this run's own candidate or dry run
    function _venuePath() private view returns (string memory) {
        bool requested = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        return vm.envOr("VENUE", vm.exists(VERIFIED) ? VERIFIED : requested ? OUT : OUT_DRY);
    }

    // ----------------------------------------------------------------------------------------------------- helpers

    function _book() private view returns (string memory json) {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        json = vm.readFile(BOOK);
        HedgeFunV2Factory factory = HedgeFunV2Factory(FACTORY);
        if (
            vm.parseJsonUint(json, ".chainId") != CHAIN_ID || !vm.parseJsonBool(json, ".broadcast")
                || vm.parseJsonAddress(json, ".factory") != FACTORY || vm.parseJsonAddress(json, ".usdg") != USDG
                || vm.parseJsonAddress(json, ".usdgFeed") != USDG_FEED || vm.parseJsonAddress(json, ".calendar") != CALENDAR
                || vm.parseJsonAddress(json, ".v3Factory") != V3_FACTORY || factory.owner() != OWNER
                || factory.usdg() != USDG || address(factory.v3Factory()) != V3_FACTORY
        ) revert BadBook("release book");
    }

    function _symbols() private view returns (string[] memory) {
        return vm.split(vm.envOr("SYMBOLS", string("TSLA")), ",");
    }

    function _indexOf(string memory symbol) private view returns (uint256) {
        for (uint256 i; i < venue.length; i++) {
            if (keccak256(bytes(venue[i].symbol)) == keccak256(bytes(symbol))) return i;
        }
        return type(uint256).max;
    }

    function _index(string memory symbol) private view returns (uint256 i) {
        i = _indexOf(symbol);
        if (i == type(uint256).max) revert BadVenue(string.concat(symbol, " is not on the venue"));
    }

    function _sender() private view {
        if (msg.sender != OWNER) revert WrongSender(msg.sender);
    }
}
