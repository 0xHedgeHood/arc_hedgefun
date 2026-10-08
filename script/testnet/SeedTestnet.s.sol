// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {TestUsdg, TestStock} from "./TestnetAssets.sol";
import {TestnetMarket, IV3Pool} from "./TestnetMarket.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";

/// @notice Funds team wallets on the Hedgefun V2 testnet deployment (chain 46630) with test assets, and makes each
///         stock's pool ready for treasuries. Reads the address book `DeployV2Testnet` wrote. Operator only: the
///         operator owns every test token and the market.
///
///   run()            TEAM=0xA,0xB,...  tops every TEAM address up to the targets below, and pokes any pool whose
///                                      observation ring is not live yet
///   topUp(address)   the same for one address
///   pokeAll()        only the pool step
///
/// Top-ups mint the shortfall only, so running it again is harmless. Targets: SEED_USDG whole tUSDG (default
/// 100,000) and SEED_STOCK_USD dollars of each test stock at its feed price (default 25,000). Test ETH for gas comes
/// from the public faucet, never from here.
///
///   OPERATOR=0x.. TEAM=0x..,0x.. forge script script/testnet/SeedTestnet.s.sol:SeedTestnet \
///     --rpc-url https://rpc.testnet.chain.robinhood.com --sender $OPERATOR [--account <keystore> --broadcast]
contract SeedTestnet is Script {
    uint256 internal constant CHAIN_ID = 46630;
    uint16 internal constant MIN_CARDINALITY = 660;     // PoolTrader: TWAP_WINDOW + RING_MARGIN

    error WrongChain(uint256 chainId);
    error NotOperator(address sender, address operator);
    error NoTeam();
    error UnverifiedBook();

    struct Book {
        TestUsdg usdg;
        TestnetMarket market;
        string[] symbols;
        TestStock[] stocks;
        PriceOracle[] oracles;
        address[] pools;
    }

    function run() external {
        address[] memory team = vm.envAddress("TEAM", ",");
        if (team.length == 0) revert NoTeam();
        Book memory b = _begin();
        vm.startBroadcast();
        for (uint256 i; i < team.length; i++) _topUp(b, team[i]);
        _pokeAll(b);
        vm.stopBroadcast();
    }

    function topUp(address who) external {
        Book memory b = _begin();
        vm.startBroadcast();
        _topUp(b, who);
        vm.stopBroadcast();
    }

    function pokeAll() external {
        Book memory b = _begin();
        vm.startBroadcast();
        _pokeAll(b);
        vm.stopBroadcast();
    }

    function _begin() internal view returns (Book memory b) {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        string memory json = vm.readFile(vm.envOr("ADDRESS_BOOK", string("deploy/testnet-v2.json")));
        if (vm.parseJsonUint(json, ".chainId") != CHAIN_ID || !vm.parseJsonBool(json, ".broadcast")
            || vm.parseJsonUint(json, ".verification.schema") != 1
            || vm.parseJsonUint(json, ".verification.chainId") != CHAIN_ID
            || vm.parseJsonUint(json, ".verification.blockNumber") > block.number) revert UnverifiedBook();
        address operator = vm.parseJsonAddress(json, ".operator");
        if (msg.sender != operator) revert NotOperator(msg.sender, operator);
        b.usdg = TestUsdg(vm.parseJsonAddress(json, ".usdg"));
        b.market = TestnetMarket(vm.parseJsonAddress(json, ".market"));
        HedgeFunV2Factory factory = HedgeFunV2Factory(vm.parseJsonAddress(json, ".factory"));
        if (address(factory).code.length == 0 || address(b.usdg).code.length == 0 || address(b.market).code.length == 0
            || factory.usdg() != address(b.usdg) || factory.owner() != operator || b.market.owner() != operator
            || b.market.usdg() != address(b.usdg) || b.usdg.owner() != operator) revert UnverifiedBook();
        b.symbols = vm.parseJsonKeys(json, ".stocks");
        uint256 n = b.symbols.length;
        if (n != 4) revert UnverifiedBook();
        b.stocks = new TestStock[](n);
        b.oracles = new PriceOracle[](n);
        b.pools = new address[](n);
        for (uint256 i; i < n; i++) {
            string memory k = string.concat(".stocks.", b.symbols[i]);
            b.stocks[i] = TestStock(vm.parseJsonAddress(json, string.concat(k, ".token")));
            b.oracles[i] = PriceOracle(vm.parseJsonAddress(json, string.concat(k, ".oracle")));
            b.pools[i] = vm.parseJsonAddress(json, string.concat(k, ".pool"));
            (address oracle, address pool,, bool enabled) = factory.listings(address(b.stocks[i]));
            if (!enabled || oracle != address(b.oracles[i]) || pool != b.pools[i]
                || address(b.stocks[i]).code.length == 0 || oracle.code.length == 0 || pool.code.length == 0
                || b.stocks[i].owner() != operator || b.oracles[i].stock() != address(b.stocks[i])
                || address(b.oracles[i].usdgFeed()) != vm.parseJsonAddress(json, ".usdgFeed")
                || address(b.oracles[i].calendar()) != vm.parseJsonAddress(json, ".calendar")) revert UnverifiedBook();
        }
    }

    function _topUp(Book memory b, address who) internal {
        uint256 usdgTarget = vm.envOr("SEED_USDG", uint256(100_000)) * 1e6;
        uint256 stockUsd = vm.envOr("SEED_STOCK_USD", uint256(25_000));
        _mintTo(address(b.usdg), who, usdgTarget, "tUSDG");
        for (uint256 i; i < b.stocks.length; i++) {
            (bool ok, uint256 price,) = b.oracles[i].lastPriceAt();
            if (!ok || price == 0) {
                console2.log("skipped: no feed price for", b.symbols[i]);
                continue;
            }
            _mintTo(address(b.stocks[i]), who, stockUsd * 1e36 / price, b.symbols[i]);
        }
    }

    function _mintTo(address token, address who, uint256 target, string memory symbol) internal {
        uint256 have = TestUsdg(token).balanceOf(who);
        if (have >= target) return;
        TestUsdg(token).mint(who, target - have);
        console2.log(string.concat("minted ", symbol, " to"), who, target - have);
    }

    /// a pool's grown observation ring goes live on its first write in a later second than the last one
    function _pokeAll(Book memory b) internal {
        for (uint256 i; i < b.pools.length; i++) {
            (,,, uint16 card,,,) = IV3Pool(b.pools[i]).slot0();
            if (card >= MIN_CARDINALITY) continue;
            b.market.poke(b.pools[i]);
            console2.log(string.concat("poked ", b.symbols[i], " pool"), b.pools[i]);
        }
    }
}
