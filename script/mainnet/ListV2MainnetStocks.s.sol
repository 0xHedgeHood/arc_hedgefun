// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {V2TreasuryDeployer} from "../../src/v2/V2TreasuryDeployer.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {IUniswapV3Factory, IUniswapV3Pool} from "../../src/interfaces/IUniswapV3.sol";

/// @notice List stocks on the mainnet V2 factory at the reference opening price (runbook section C).
/// @dev Inputs per symbol come from the two reviewed files: the eighteen V1 listings' token, oracle, pool and gates
///      (`deploy/v2-listings-plan.json`) and the five oracles deployed for stocks V1 never listed
///      (`deploy/mainnet-v2-oracles.json`, whose gates are the defaults: 50 / 100 / 2,000 USDG, or 125 / 175 on a
///      1% pool as V1 set on MSTR's). `SELL_CHUNK_USDG_<SYMBOL>` overrides a chunk, for a 0.05% pool whose listing check printed a
///      smaller maximum. The opening price comes from each oracle's LIVE `tryPrice()`: a closed market or a stale
///      feed stops the plan. `plan()` is read-only and prints the hash `run()` must be given, so what is listed is
///      what was reviewed: the symbols, their bindings and gates; the opening price follows the oracle's price at
///      the moment of sending by the fixed formula. The factory owner lists; before hand-over that is the deployer.
///
///      SYMBOLS=NVDA,AAPL V2_FACTORY=… OPERATOR=… forge script … --sig 'plan()' --rpc-url …
///      … EXPECTED_PLAN_HASH=… forge script … --sig 'run()' --account deployer --sender … --broadcast
contract ListV2MainnetStocks is Script {
    uint256 public constant CHAIN_ID = 4663;
    uint256 public constant TARGET_GRADUATION_FDV_USD_E18 = 50_000e18;
    uint16 public constant REFERENCE_SALE_BPS = 7931;
    uint256 private constant SUPPLY_TOKENS = 1_000_000_000;
    string private constant PLAN = "deploy/v2-listings-plan.json";
    string private constant ORACLES = "deploy/mainnet-v2-oracles.json";

    struct Listing {
        string symbol;
        address stock;
        address oracle;
        address pool;
        uint24 fee;
        uint256 priceE18;       // the oracle's live price the opening price was computed from
        uint256 openPriceE18;
        uint16 maxDeviationBps;
        uint16 maxSlippageBps;
        uint64 sellChunkUsdg;
    }

    function run() external {
        (HedgeFunV2Factory factory, address operator) = _inputs();
        require(msg.sender == operator && factory.owner() == operator, "factory owner only");
        Listing[] memory p = planFor(factory);
        require(planHash(factory, p) == vm.envBytes32("EXPECTED_PLAN_HASH"), "plan changed");
        vm.startBroadcast(operator);
        for (uint256 i; i < p.length; ++i) {
            factory.list(p[i].stock, p[i].oracle, p[i].pool, p[i].openPriceE18, true);
            factory.setListingGates(p[i].stock, p[i].maxDeviationBps, p[i].maxSlippageBps, p[i].sellChunkUsdg);
        }
        vm.stopBroadcast();
        for (uint256 i; i < p.length; ++i) _readBack(factory, p[i]);
    }

    /// @notice Read-only: what `run()` would list, and the hash it must be given.
    function plan() external view returns (Listing[] memory p) {
        (HedgeFunV2Factory factory,) = _inputs();
        p = planFor(factory);
        uint256 remaining = 10_000 - REFERENCE_SALE_BPS;
        for (uint256 i; i < p.length; ++i) {
            uint256 openingFdv = p[i].openPriceE18 * SUPPLY_TOKENS * p[i].priceE18 / 1e18;
            console2.log("stock", p[i].symbol, p[i].stock);
            console2.log("  oracle, pool, fee", p[i].oracle, p[i].pool, uint256(p[i].fee));
            console2.log("  oracle price, USD e18", p[i].priceE18);
            console2.log("  openPriceE18", p[i].openPriceE18);
            console2.log("  implied raise and graduation FDV, USD",
                openingFdv * REFERENCE_SALE_BPS / remaining / 1e18, openingFdv * 10_000 * 10_000 / (remaining * remaining) / 1e18);
            console2.log("  gates dev / slip / chunk", uint256(p[i].maxDeviationBps), uint256(p[i].maxSlippageBps), uint256(p[i].sellChunkUsdg));
        }
        console2.log("EXPECTED_PLAN_HASH");
        console2.logBytes32(planHash(factory, p));
    }

    /// @dev What the reviewer pins: the symbols in order, their token, oracle, pool, fee and gates, on this factory.
    ///      The price is the oracle's at the moment of sending and the opening price follows from it by the fixed
    ///      formula, so neither is in the hash: Chainlink feeds move between a review and a broadcast.
    function planHash(HedgeFunV2Factory factory, Listing[] memory p) public view returns (bytes32) {
        bytes memory rows;
        for (uint256 i; i < p.length; ++i) {
            Listing memory l = p[i];
            rows = bytes.concat(rows, abi.encode(l.symbol, l.stock, l.oracle, l.pool, l.fee, l.maxDeviationBps, l.maxSlippageBps, l.sellChunkUsdg));
        }
        return keccak256(abi.encode(block.chainid, factory, factory.treasuryDeployer(), rows));
    }

    /// @dev One row per requested symbol, in the order given, each bound to the chain before it is planned.
    function planFor(HedgeFunV2Factory factory) public view returns (Listing[] memory p) {
        require(block.chainid == CHAIN_ID, "mainnet only");
        require(factory.getDefaults().supply == SUPPLY_TOKENS * 1e18, "supply is not the reference's");
        require(factory.curveDeployer().DEFAULT_SALE_BPS() == REFERENCE_SALE_BPS, "sale share is not the reference's");
        string[] memory symbols = vm.split(vm.envString("SYMBOLS"), ",");
        require(symbols.length != 0, "SYMBOLS");
        string memory planJson = vm.readFile(PLAN);
        string memory oraclesJson = vm.readFile(ORACLES);
        require(vm.parseJsonUint(planJson, ".chainId") == CHAIN_ID && vm.parseJsonUint(oraclesJson, ".chainId") == CHAIN_ID, "files");
        p = new Listing[](symbols.length);
        for (uint256 i; i < symbols.length; ++i) {
            for (uint256 j; j < i; ++j) require(keccak256(bytes(symbols[j])) != keccak256(bytes(symbols[i])), "repeated symbol");
            p[i] = _row(factory, planJson, oraclesJson, symbols[i]);
        }
    }

    function _row(HedgeFunV2Factory factory, string memory planJson, string memory oraclesJson, string memory symbol)
        private view returns (Listing memory l)
    {
        l.symbol = symbol;
        string memory key = string.concat(".stocks.", symbol);
        if (vm.keyExistsJson(planJson, key)) {
            l.stock = vm.parseJsonAddress(planJson, string.concat(key, ".token"));
            l.oracle = vm.parseJsonAddress(planJson, string.concat(key, ".oracle"));
            l.pool = vm.parseJsonAddress(planJson, string.concat(key, ".pool"));
            l.fee = uint24(vm.parseJsonUint(planJson, string.concat(key, ".fee")));
            l.maxDeviationBps = uint16(vm.parseJsonUint(planJson, string.concat(key, ".maxDeviationBps")));
            l.maxSlippageBps = uint16(vm.parseJsonUint(planJson, string.concat(key, ".maxSlippageBps")));
            l.sellChunkUsdg = uint64(vm.parseJsonUint(planJson, string.concat(key, ".sellChunkUsdg")));
        } else {
            key = string.concat(".oracles.", symbol);
            require(vm.keyExistsJson(oraclesJson, key), string.concat(symbol, ": in neither file"));
            l.stock = vm.parseJsonAddress(oraclesJson, string.concat(key, ".token"));
            l.oracle = vm.parseJsonAddress(oraclesJson, string.concat(key, ".oracle"));
            l.pool = vm.parseJsonAddress(oraclesJson, string.concat(key, ".usdgPool.address"));
            l.fee = uint24(vm.parseJsonUint(oraclesJson, string.concat(key, ".usdgPool.fee")));
            // the gates V1 set on its own 1% pool (MSTR: 125 / 175), the defaults elsewhere
            (l.maxDeviationBps, l.maxSlippageBps) = l.fee == 10_000 ? (uint16(125), uint16(175)) : (uint16(50), uint16(100));
            l.sellChunkUsdg = 2_000e6;
        }
        l.sellChunkUsdg = uint64(vm.envOr(string.concat("SELL_CHUNK_USDG_", symbol), uint256(l.sellChunkUsdg)));
        // bound to the chain: the token, the oracle's stock, the factory's own V3 factory and USDG
        require(l.stock.code.length != 0 && IERC20Metadata(l.stock).decimals() == 18, string.concat(symbol, ": token"));
        require(keccak256(bytes(IERC20Metadata(l.stock).symbol())) == keccak256(bytes(symbol)), string.concat(symbol, ": symbol"));
        require(PriceOracle(l.oracle).stock() == l.stock, string.concat(symbol, ": oracle"));
        require(IUniswapV3Factory(address(factory.v3Factory())).getPool(factory.usdg(), l.stock, l.fee) == l.pool
            && IUniswapV3Pool(l.pool).fee() == l.fee, string.concat(symbol, ": pool"));
        require(l.maxDeviationBps != 0 && l.maxDeviationBps < l.maxSlippageBps && l.sellChunkUsdg != 0, string.concat(symbol, ": gates"));
        (bool ok, uint256 priceE18) = PriceOracle(l.oracle).tryPrice();
        require(ok && priceE18 != 0, string.concat(symbol, ": no live oracle price"));
        l.priceE18 = priceE18;
        l.openPriceE18 = referenceOpenPriceE18(priceE18);
    }

    function _readBack(HedgeFunV2Factory factory, Listing memory l) private view {
        (address oracle, address pool, uint256 open, bool enabled) = factory.listings(l.stock);
        (uint16 dev, uint16 slip, uint64 chunk) = factory.listingGates(l.stock);
        require(
            enabled && oracle == l.oracle && pool == l.pool && open == l.openPriceE18 && dev == l.maxDeviationBps
                && slip == l.maxSlippageBps && chunk == l.sellChunkUsdg
                && V2TreasuryDeployer(address(factory.treasuryDeployer())).lpBps(l.stock) == 7000,
            string.concat(l.symbol, ": readback")
        );
    }

    /// @notice 18-decimal stock units per token, scaled by 1e18: a $50,000 graduation with 79.31% sold.
    function referenceOpenPriceE18(uint256 stockUsdE18) public pure returns (uint256) {
        uint256 remaining = 10_000 - REFERENCE_SALE_BPS;
        uint256 openingFdv = Math.mulDiv(TARGET_GRADUATION_FDV_USD_E18, remaining * remaining, 10_000 * 10_000);
        return Math.mulDiv(openingFdv, 1e18, stockUsdE18 * SUPPLY_TOKENS);
    }

    function _inputs() private view returns (HedgeFunV2Factory factory, address operator) {
        factory = HedgeFunV2Factory(vm.envAddress("V2_FACTORY"));
        operator = vm.envAddress("OPERATOR");
        require(address(factory).code.length != 0 && operator != address(0), "inputs");
    }
}
