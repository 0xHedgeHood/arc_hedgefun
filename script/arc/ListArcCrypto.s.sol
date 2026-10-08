// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunV2ArcFactory} from "../../src/v2/arc/HedgeFunV2ArcFactory.sol";
import {V2TreasuryDeployer} from "../../src/v2/V2TreasuryDeployer.sol";
import {CryptoPriceOracle} from "../../src/CryptoPriceOracle.sol";
import {IUniswapV3Factory, IUniswapV3Pool} from "../../src/interfaces/IUniswapV3.sol";
import {ArcAssets} from "./ArcAssets.sol";

/// @notice List crypto assets on the Arc V2 factory at the reference opening price.
/// @dev The 4663 listing (`ListV2MainnetStocks`) for `ArcAssets`, with the opening price in the Arc factory's 1e36
///      scale and the asset's own decimals. Each SYMBOL needs ORACLE_<SYMBOL>, the `CryptoPriceOracle` from
///      `DeployArcOracles`. The opening price comes from that oracle's LIVE price; `plan()` is read-only and prints
///      the hash `run()` must be given. The factory owner lists; before hand-over that is the deployer.
///
///      SYMBOLS=cirBTC ORACLE_cirBTC=… V2_FACTORY=… OPERATOR=… arc-forge script … --sig 'plan()' --network arc
///      … EXPECTED_PLAN_HASH=… arc-forge script … --sig 'run()' --broadcast
contract ListArcCrypto is Script {
    uint256 public constant CHAIN_ID = 5042;
    /// the same $50,000 graduation FDV the 4663 listings are priced for
    uint256 public constant TARGET_GRADUATION_FDV_USD_E18 = 50_000e18;
    uint16 public constant REFERENCE_SALE_BPS = 7931;
    uint256 private constant SUPPLY = 1_000_000_000e18;
    /// the treasury needs a 600-second window and 60 slots of margin; cirBTC's ring is 3,600
    uint16 private constant MIN_RING = 660;

    struct Listing {
        string symbol;
        address stock;
        address oracle;
        address pool;
        uint24 fee;
        uint256 priceE18;
        uint256 openPrice;
        uint16 maxDeviationBps;
        uint16 maxSlippageBps;
        uint64 sellChunkUsdg;
    }

    function run() external {
        (HedgeFunV2ArcFactory factory, address operator) = _inputs();
        Listing[] memory p = planFor(factory);
        require(planHash(factory, p) == vm.envBytes32("EXPECTED_PLAN_HASH"), "plan changed");
        list(factory, operator, p);
    }

    function list(HedgeFunV2ArcFactory factory, address operator, Listing[] memory p) public {
        require(factory.owner() == operator, "factory owner only");
        vm.startBroadcast(operator);
        for (uint256 i; i < p.length; ++i) {
            factory.list(p[i].stock, p[i].oracle, p[i].pool, p[i].openPrice, true);
            factory.setListingGates(p[i].stock, p[i].maxDeviationBps, p[i].maxSlippageBps, p[i].sellChunkUsdg);
        }
        vm.stopBroadcast();
        for (uint256 i; i < p.length; ++i) _readBack(factory, p[i]);
    }

    /// @notice Read-only: what `run()` would list, and the hash it must be given.
    function plan() external view returns (Listing[] memory p) {
        (HedgeFunV2ArcFactory factory,) = _inputs();
        p = planFor(factory);
        for (uint256 i; i < p.length; ++i) {
            console2.log("asset", p[i].symbol, p[i].stock);
            console2.log("  oracle, pool, fee", p[i].oracle, p[i].pool, uint256(p[i].fee));
            console2.log("  oracle price, USD e18", p[i].priceE18);
            console2.log("  openPrice (raw stock per raw token, e36)", p[i].openPrice);
            console2.log("  opening virtual stock, raw", Math.mulDiv(p[i].openPrice, SUPPLY, 1e36, Math.Rounding.Ceil));
            console2.log("  gates dev / slip / chunk", uint256(p[i].maxDeviationBps), uint256(p[i].maxSlippageBps), uint256(p[i].sellChunkUsdg));
        }
        console2.log("EXPECTED_PLAN_HASH");
        console2.logBytes32(planHash(factory, p));
    }

    /// @dev The price is the oracle's at the moment of sending and the opening price follows from it, so neither is
    ///      in the hash, as on 4663.
    function planHash(HedgeFunV2ArcFactory factory, Listing[] memory p) public view returns (bytes32) {
        bytes memory rows;
        for (uint256 i; i < p.length; ++i) {
            Listing memory l = p[i];
            rows = bytes.concat(rows, abi.encode(l.symbol, l.stock, l.oracle, l.pool, l.fee, l.maxDeviationBps, l.maxSlippageBps, l.sellChunkUsdg));
        }
        return keccak256(abi.encode(block.chainid, factory, factory.treasuryDeployer(), rows));
    }

    function planFor(HedgeFunV2ArcFactory factory) public view returns (Listing[] memory p) {
        string[] memory symbols = vm.split(vm.envString("SYMBOLS"), ",");
        address[] memory oracles = new address[](symbols.length);
        for (uint256 i; i < symbols.length; ++i) oracles[i] = vm.envAddress(string.concat("ORACLE_", symbols[i]));
        return planFor(factory, symbols, oracles);
    }

    function planFor(HedgeFunV2ArcFactory factory, string[] memory symbols, address[] memory oracles)
        public view returns (Listing[] memory p)
    {
        require(block.chainid == CHAIN_ID, "Arc only");
        require(factory.OPEN_PRICE_SCALE() == 1e36, "not the Arc factory");
        require(factory.getDefaults().supply == SUPPLY, "supply is not the reference's");
        require(factory.curveDeployer().DEFAULT_SALE_BPS() == REFERENCE_SALE_BPS, "sale share is not the reference's");
        require(symbols.length != 0 && symbols.length == oracles.length, "SYMBOLS");
        p = new Listing[](symbols.length);
        for (uint256 i; i < symbols.length; ++i) {
            for (uint256 j; j < i; ++j) require(keccak256(bytes(symbols[j])) != keccak256(bytes(symbols[i])), "repeated symbol");
            p[i] = _row(factory, symbols[i], oracles[i]);
        }
    }

    function _row(HedgeFunV2ArcFactory factory, string memory symbol, address oracle) private view returns (Listing memory l) {
        ArcAssets.Asset memory a = ArcAssets.get(symbol);
        require(a.pool != address(0), string.concat(symbol, ": no tradable Uniswap V3 pool yet"));
        l = Listing(symbol, a.token, oracle, a.pool, a.fee, 0, 0, a.maxDeviationBps, a.maxSlippageBps, a.sellChunkUsdg);
        require(IERC20Metadata(a.token).decimals() == a.decimals, string.concat(symbol, ": decimals"));
        CryptoPriceOracle o = CryptoPriceOracle(oracle);
        require(oracle.code.length != 0 && o.stock() == a.token && address(o.stockFeed()) == a.feed
            && address(o.usdgFeed()) == ArcAssets.USDC_USD_FEED, string.concat(symbol, ": oracle"));
        require(IUniswapV3Factory(address(factory.v3Factory())).getPool(factory.usdg(), a.token, a.fee) == a.pool
            && IUniswapV3Pool(a.pool).fee() == a.fee, string.concat(symbol, ": pool"));
        (,,, uint16 cardinality,,,) = IUniswapV3Pool(a.pool).slot0();
        require(cardinality >= MIN_RING, string.concat(symbol, ": observation ring"));
        require(a.maxDeviationBps != 0 && a.maxDeviationBps < a.maxSlippageBps && a.sellChunkUsdg != 0, string.concat(symbol, ": gates"));
        (bool ok, uint256 priceE18) = o.tryPrice();
        require(ok && priceE18 != 0, string.concat(symbol, ": no live oracle price"));
        l.priceE18 = priceE18;
        l.openPrice = referenceOpenPrice(priceE18, a.decimals);
    }

    function _readBack(HedgeFunV2ArcFactory factory, Listing memory l) private view {
        (address oracle, address pool, uint256 open, bool enabled) = factory.listings(l.stock);
        (uint16 dev, uint16 slip, uint64 chunk) = factory.listingGates(l.stock);
        require(
            enabled && oracle == l.oracle && pool == l.pool && open == l.openPrice && dev == l.maxDeviationBps
                && slip == l.maxSlippageBps && chunk == l.sellChunkUsdg && factory.bandCeiling(l.stock) == 0
                && V2TreasuryDeployer(address(factory.treasuryDeployer())).lpBps(l.stock) == 7000,
            string.concat(l.symbol, ": readback")
        );
    }

    /// @notice Raw stock per raw token, scaled by 1e36: a $50,000 graduation with 79.31% sold, as on 4663.
    /// @dev virtual stock (raw) = opening FDV / price * 10^decimals, and openPrice = virtual stock * 1e36 / supply.
    ///      For cirBTC at $83,400 that is about 2.57e15, a 2,566,000-satoshi (~$2,140) virtual reserve.
    function referenceOpenPrice(uint256 assetUsdE18, uint8 decimals) public pure returns (uint256) {
        uint256 remaining = 10_000 - REFERENCE_SALE_BPS;
        uint256 openingFdv = Math.mulDiv(TARGET_GRADUATION_FDV_USD_E18, remaining * remaining, 10_000 * 10_000);
        return Math.mulDiv(openingFdv * 10 ** uint256(decimals), 1e36, assetUsdE18 * SUPPLY);
    }

    function _inputs() private view returns (HedgeFunV2ArcFactory factory, address operator) {
        factory = HedgeFunV2ArcFactory(vm.envAddress("V2_FACTORY"));
        operator = vm.envAddress("OPERATOR");
        require(address(factory).code.length != 0 && operator != address(0), "inputs");
    }
}
