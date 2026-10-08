// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IUniswapV3Pool} from "../../src/interfaces/IUniswapV3.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {V2TreasuryDeployer} from "../../src/v2/V2TreasuryDeployer.sol";
import {HedgeFunV2AllInTreasury} from "../../src/v2/HedgeFunV2AllInTreasury.sol";
import {HedgeFunV2TradeRouter} from "../../src/v2/HedgeFunV2TradeRouter.sol";
import {HedgeFunV2NativeRouter, IWrappedNative} from "../../src/v2/HedgeFunV2NativeRouter.sol";
import {TestFeed} from "./TestnetAssets.sol";
import {IV3Factory, IV3Pool} from "./TestnetMarket.sol";
import {TestnetCryptoCalendar, TestnetCryptoOracle} from "./TestnetCryptoOracle.sol";
import {TestnetNativeMarket} from "./TestnetNativeMarket.sol";

/// @notice Independent 12+1+4 transaction ETH venue extension, never a modification of the 38/40 core proof.
/// @dev Real WETH prefunding is mandatory. Candidate output is always unverified, including broadcast runs.
/// Use the reviewed temporary --config-path with scoped public book/candidate permissions; never change compiler settings.
contract TestnetV2EthMarket is Script {
    address public constant OPERATOR = 0x75Cee941B0eF3A83feA0397BbF903C12c1D7e96D;
    address public constant WETH = 0x7943e237c7F95DA44E0301572D358911207852Fa;
    address public constant USDG = 0x539574139BB4Ac74Fd2183ba0E38ed777E30B58d;
    address public constant USDG_FEED = 0x6beF5980dDa88F8B925f814C5033959A13ae535A;
    address public constant V3_FACTORY = 0x0b0a96D7EB396E7471998889C4803dD0F529Eb01;
    address public constant FEE_FACTORY = 0xACEB03aAeE5494Aa54929Ec840630ae32A9ade0A;
    address public constant FEE_REGISTRY = 0xe874fE425e14f3CBa3aDBA2Dd10B50E153Ac6064;
    uint24 public constant FEE = 500;
    uint256 public constant PRICE = 3000e18; // Synthetic initial pool price; strategy reads the canonical 600-second pool TWAP.
    uint256 public constant OPEN_PRICE = 25_454_546;
    uint256 public constant SEED_ETH = 1 ether;
    uint256 public constant SEED_USDG = 3100e6;
    uint256 public constant PROVIDED_ETH = 0.9 ether;
    uint256 public constant GAS_RESERVE = 0.001 ether;
    uint256 public constant POKE_USDG = 20e6;
    uint256 public constant POKE_WETH = 0.01 ether;
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct Base {
        address factory; address treasuryDeployer; address tradeRouter; address nativeRouter;
        string feature; string path; string sourceCommit; string sourceBookSha256;
        bytes32 bookSha256; bytes32 verificationBlockHash; uint256 verificationBlock;
    }
    struct Deployment {
        Base base;
        TestnetCryptoCalendar calendar; TestFeed feed; TestnetCryptoOracle oracle; TestnetNativeMarket seeder;
        address pool; address wethImplementation; bytes32 wethCodeHash; bytes32 wethImplementationCodeHash;
        int24 tickLower; int24 tickUpper; uint128 liquidity;
        uint256 initializedAt; uint256 initializedBlock; uint256 deadline;
        uint256 provided0; uint256 provided1;
    }

    error BadBinding();
    error BadSource();
    error BadStage();
    error InsufficientNative(uint256 available, uint256 required);
    error InsufficientUsdg(uint256 available, uint256 required);
    error TransferMismatch();

    /// @notice In-memory simulation entry point; writes no candidate file.
    function deploy(string calldata baseJson, bytes32 expectedBaseSha256) external returns (Deployment memory x) {
        return _deploy(_base(baseJson, expectedBaseSha256));
    }

    function initialize(string calldata basePath, bytes32 expectedBaseSha256) external returns (Deployment memory x) {
        _basePath(basePath);
        x = _deploy(_base(vm.readFile(basePath), expectedBaseSha256));
        x.base.path = basePath;
        _write(x, "init");
    }

    function poke(Deployment memory x) public {
        _sender(); _checkBase(x.base); _checkMarket(x);
        if (block.timestamp <= x.initializedAt) revert BadStage();
        vm.startBroadcast(OPERATOR);
        x.seeder.poke(POKE_USDG, POKE_WETH, block.timestamp + 300);
        vm.stopBroadcast();
    }

    function pokeFile(string calldata initCandidate) external {
        Deployment memory x = _read(initCandidate);
        x.deadline = block.timestamp + 300;
        poke(x); _write(x, "poke");
    }

    function activate(Deployment memory x) public {
        _sender(); _checkBase(x.base); _checkMarket(x); _warm(x);
        (,,, bool enabled) = HedgeFunV2Factory(x.base.factory).listings(WETH);
        if (enabled) revert BadStage();
        vm.startBroadcast(OPERATOR);
        HedgeFunV2Factory(x.base.factory).setListingGates(WETH, 50, 100, 0);
        V2TreasuryDeployer(x.base.treasuryDeployer).setLpBps(WETH, 5000);
        HedgeFunV2Factory(x.base.factory).setBandCeiling(WETH, 0);
        // Publish last: an intervening public launch must not freeze the default asset gates or LP split.
        HedgeFunV2Factory(x.base.factory).list(WETH, address(x.oracle), x.pool, OPEN_PRICE, true);
        vm.stopBroadcast();
    }

    function activateFile(string calldata initCandidate) external {
        Deployment memory x = _read(initCandidate);
        activate(x); _write(x, "activate");
    }

    function _deploy(Base memory base) internal returns (Deployment memory x) {
        _sender(); _checkBase(base);
        if (OPERATOR.balance < SEED_ETH + GAS_RESERVE) revert InsufficientNative(OPERATOR.balance, SEED_ETH + GAS_RESERVE);
        uint256 balance = IERC20(USDG).balanceOf(OPERATOR);
        if (balance < SEED_USDG) revert InsufficientUsdg(balance, SEED_USDG);
        (address oracle,,, bool listed) = HedgeFunV2Factory(base.factory).listings(WETH);
        if (listed || oracle != address(0) || IV3Factory(V3_FACTORY).getPool(WETH, USDG, FEE) != address(0)) revert BadStage();
        if (IV3Factory(V3_FACTORY).feeAmountTickSpacing(FEE) != 10) revert BadBinding();
        x.base = base; x.initializedAt = block.timestamp; x.initializedBlock = block.number; x.deadline = block.timestamp + 300;
        x.wethImplementation = _wethImplementation();
        x.wethCodeHash = WETH.codehash; x.wethImplementationCodeHash = x.wethImplementation.codehash;
        vm.startBroadcast(OPERATOR);
        x.calendar = new TestnetCryptoCalendar(OPERATOR);
        x.feed = new TestFeed("ETH / USD (testnet, operator-set)", 3000e8, OPERATOR);
        x.pool = IV3Factory(V3_FACTORY).createPool(WETH, USDG, FEE);
        uint160 sqrtP = _sqrtFor(PRICE);
        IV3Pool(x.pool).initialize(sqrtP);
        IV3Pool(x.pool).increaseObservationCardinalityNext(720);
        (x.tickLower, x.tickUpper, x.liquidity) = _position(sqrtP);
        x.oracle = new TestnetCryptoOracle(WETH, USDG, x.pool, address(x.calendar), x.liquidity / 2);
        x.seeder = new TestnetNativeMarket(OPERATOR, V3_FACTORY, USDG, WETH, x.pool, x.feed, x.tickLower, x.tickUpper);
        x.feed.setOperator(address(x.seeder), true);
        uint256 beforeWrapped = IERC20(WETH).balanceOf(OPERATOR);
        IWrappedNative(WETH).deposit{value: SEED_ETH}();
        if (IERC20(WETH).balanceOf(OPERATOR) != beforeWrapped + SEED_ETH) revert TransferMismatch();
        if (!IERC20(WETH).transfer(address(x.seeder), SEED_ETH) || !IERC20(USDG).transfer(address(x.seeder), SEED_USDG)) revert TransferMismatch();
        (x.provided0, x.provided1) = x.seeder.provide(x.liquidity, SEED_USDG, PROVIDED_ETH, x.deadline);
        vm.stopBroadcast();
        if (IERC20(WETH).balanceOf(OPERATOR) != beforeWrapped) revert TransferMismatch();
        _checkMarket(x);
    }

    function _base(string memory json, bytes32 expected) internal view returns (Base memory b) {
        if (sha256(bytes(json)) != expected || expected == bytes32(0)
            || vm.parseJsonUint(json, ".chainId") != 46630 || !vm.parseJsonBool(json, ".broadcast")
            || keccak256(bytes(vm.parseJsonString(json, ".verification.schema"))) != keccak256("two-sided-fee-upgrade-readback-v1")) revert BadSource();
        b.factory = vm.parseJsonAddress(json, ".factory"); b.treasuryDeployer = vm.parseJsonAddress(json, ".treasuryDeployer");
        b.tradeRouter = vm.parseJsonAddress(json, ".tradeRouter"); b.nativeRouter = vm.parseJsonAddress(json, ".nativeRouter");
        b.feature = vm.parseJsonString(json, ".featureVersion"); b.bookSha256 = expected;
        b.sourceCommit = vm.parseJsonString(json, ".verification.sourceCommit");
        b.sourceBookSha256 = vm.parseJsonString(json, ".verification.sourceBookSha256");
        b.verificationBlock = vm.parseJsonUint(json, ".verification.blockNumber");
        b.verificationBlockHash = vm.parseJsonBytes32(json, ".verification.blockHash");
        bool creator = keccak256(bytes(b.feature)) == keccak256("v2-creator-selected-stock-fees-v1");
        if ((!creator && keccak256(bytes(b.feature)) != keccak256("v2-two-sided-stock-fees-v1"))
            || bytes(b.sourceCommit).length != 40 || bytes(b.sourceBookSha256).length != 64
            || keccak256(bytes(b.sourceCommit)) != keccak256(bytes(vm.parseJsonString(json, ".commit")))
            || b.verificationBlock == 0 || b.verificationBlock > block.number || b.verificationBlockHash == bytes32(0)
            || vm.parseJsonStringArray(json, ".verification.transactionHashes").length != (creator ? 40 : 38)
            || vm.parseJsonAddress(json, ".weth") != WETH || vm.parseJsonAddress(json, ".usdg") != USDG
            || vm.parseJsonAddress(json, ".usdgFeed") != USDG_FEED || vm.parseJsonAddress(json, ".v3Factory") != V3_FACTORY) revert BadSource();
        for (uint256 i; i < 8; ++i) {
            string memory field = i == 0 ? "factory" : i == 1 ? "treasuryDeployer" : i == 2 ? "tradeRouter" : i == 3 ? "nativeRouter" : i == 4 ? "weth" : i == 5 ? "v3Factory" : i == 6 ? "usdg" : "usdgFeed";
            address target = vm.parseJsonAddress(json, string.concat(".", field));
            if (target.codehash != vm.parseJsonBytes32(json, string.concat(".verification.upgradeProof.codeHashes.core.", field))) revert BadSource();
        }
        _checkBase(b);
    }

    function _checkBase(Base memory b) internal view {
        if (block.chainid != 46630) revert BadBinding();
        bool creator = keccak256(bytes(b.feature)) == keccak256("v2-creator-selected-stock-fees-v1");
        if (!creator && keccak256(bytes(b.feature)) != keccak256("v2-two-sided-stock-fees-v1")) revert BadBinding();
        if (!creator && (b.factory != FEE_FACTORY || b.treasuryDeployer != FEE_REGISTRY)) revert BadBinding();
        HedgeFunV2Factory f = HedgeFunV2Factory(b.factory);
        V2TreasuryDeployer r = V2TreasuryDeployer(b.treasuryDeployer);
        if (f.owner() != OPERATOR || f.protocol() != OPERATOR || address(f.treasuryDeployer()) != b.treasuryDeployer
            || f.usdg() != USDG || address(f.v3Factory()) != V3_FACTORY || r.factory() != b.factory || r.version() != 2
            || address(HedgeFunV2TradeRouter(b.tradeRouter).factory()) != b.factory
            || address(HedgeFunV2NativeRouter(payable(b.nativeRouter)).router()) != b.tradeRouter
            || address(HedgeFunV2NativeRouter(payable(b.nativeRouter)).wrappedNative()) != WETH) revert BadBinding();
        if (creator && (b.factory == FEE_FACTORY || r.allInTriggerCodeHash() != keccak256(type(HedgeFunV2AllInTreasury).creationCode))) revert BadBinding();
    }

    function _checkMarket(Deployment memory x) internal {
        if (x.wethImplementation != _wethImplementation() || WETH.codehash != x.wethCodeHash
            || x.wethImplementation.codehash != x.wethImplementationCodeHash || x.calendar.owner() != OPERATOR || x.calendar.halted()
            || x.feed.owner() != OPERATOR || x.feed.answer() != 3000e8 || !x.feed.alwaysFresh()
            || !x.feed.operators(address(x.seeder)) || address(x.oracle.calendar()) != address(x.calendar)
            || x.oracle.stock() != WETH || x.oracle.usdg() != USDG || address(x.oracle.pool()) != x.pool
            || x.oracle.v3Factory() != V3_FACTORY || x.oracle.version() != 2 || x.oracle.twapSeconds() != 600
            || x.oracle.minLiquidity() != x.liquidity / 2
            || x.seeder.owner() != OPERATOR || x.seeder.stock() != WETH || x.seeder.usdg() != USDG
            || address(x.seeder.pool()) != x.pool || address(x.seeder.feed()) != address(x.feed)
            || x.seeder.tickLower() != x.tickLower || x.seeder.tickUpper() != x.tickUpper
            || IV3Factory(V3_FACTORY).getPool(WETH, USDG, FEE) != x.pool || IV3Pool(x.pool).fee() != FEE
            || IV3Pool(x.pool).token0() != USDG || IV3Pool(x.pool).token1() != WETH || IV3Pool(x.pool).liquidity() < x.liquidity) revert BadBinding();
        // Reconstruct exactly the reviewed immutable-filled helper runtimes, without broadcasting these fixtures.
        TestnetCryptoOracle expectedOracle = new TestnetCryptoOracle(WETH, USDG, x.pool, address(x.calendar), x.liquidity / 2);
        TestnetNativeMarket expectedSeeder = new TestnetNativeMarket(OPERATOR, V3_FACTORY, USDG, WETH, x.pool, x.feed, x.tickLower, x.tickUpper);
        if (address(x.calendar).codehash != keccak256(type(TestnetCryptoCalendar).runtimeCode)
            || address(x.oracle).codehash != address(expectedOracle).codehash || address(x.seeder).codehash != address(expectedSeeder).codehash) revert BadBinding();
    }

    function _warm(Deployment memory x) internal view {
        if (block.timestamp < x.initializedAt + 600) revert BadStage();
        (,,, uint16 cardinality, uint16 next,,) = IV3Pool(x.pool).slot0();
        if (cardinality < 720 || next < 720) revert BadStage();
        uint32[] memory secondsAgo = new uint32[](2); secondsAgo[0] = 600;
        (int56[] memory cumulative,) = IUniswapV3Pool(x.pool).observe(secondsAgo);
        (uint160 sqrtP, int24 tick,,,,,) = IV3Pool(x.pool).slot0();
        int256 delta = int256(cumulative[1]) - int256(cumulative[0]);
        int256 mean = delta / 600; if (delta < 0 && delta % 600 != 0) mean--;
        int256 difference = int256(tick) - mean;
        uint256 spot = x.seeder.priceAt(sqrtP);
        uint256 gap = spot > PRICE ? spot - PRICE : PRICE - spot;
        if (gap > Math.mulDiv(PRICE, 50, 10000) || uint256(difference < 0 ? -difference : difference) > 50) revert BadStage();
        (bool healthy, uint256 price) = x.oracle.tryPrice();
        if (!healthy || (price > PRICE ? price - PRICE : PRICE - price) > Math.mulDiv(PRICE, 2, 10000) || IERC20(WETH).balanceOf(x.pool) == 0 || IERC20(USDG).balanceOf(x.pool) == 0) revert BadStage();
    }

    function _position(uint160 sqrtP) internal pure returns (int24 lo, int24 hi, uint128 liquidity) {
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP); int24 centre = tick / 10 * 10;
        if (tick < 0 && tick % 10 != 0) centre -= 10;
        lo = centre - 6000; hi = centre + 6000;
        // WETH is token1; prefund one ETH but reserve 0.1 ETH outside the position for bounded pokes/price moves.
        uint256 value = Math.mulDiv(PROVIDED_ETH, 1 << 96, uint256(sqrtP) - TickMath.getSqrtPriceAtTick(lo));
        if (value == 0 || value > type(uint128).max) revert BadBinding();
        liquidity = uint128(value);
    }

    function _sqrtFor(uint256 price) internal pure returns (uint160) { return uint160(Math.sqrt(Math.mulDiv(1e30, 1 << 192, price))); }
    function _wethImplementation() internal view returns (address value) {
        value = address(uint160(uint256(vm.load(WETH, IMPLEMENTATION_SLOT))));
        if (value.code.length == 0) revert BadBinding();
    }
    function _sender() private view { if (msg.sender != OPERATOR || block.chainid != 46630) revert BadBinding(); }
    function _basePath(string memory path) private pure {
        bytes32 value = keccak256(bytes(path));
        if (value != keccak256("deploy/testnet-v2-fees.json") && value != keccak256("deploy/testnet-v2-creator.json")) revert BadSource();
    }

    function _read(string memory path) internal view returns (Deployment memory x) {
        bool permitted;
        for (uint256 i; i < 2; ++i) if (keccak256(bytes(path)) == keccak256(bytes(i == 0 ? "deploy/testnet-v2-native-market.init.candidate.json" : "deploy/testnet-v2-native-market.init.dryrun.json"))) permitted = true;
        if (!permitted) revert BadSource();
        string memory json = vm.readFile(path);
        if (keccak256(bytes(vm.parseJsonString(json, ".schema"))) != keccak256("v2-testnet-native-market-candidate-v1")
            || vm.parseJsonUint(json, ".chainId") != 46630 || vm.parseJsonBool(json, ".broadcast")
            || keccak256(bytes(vm.parseJsonString(json, ".phase"))) != keccak256("init")
            || keccak256(bytes(vm.parseJsonString(json, ".commit"))) != keccak256(bytes(_commit()))) revert BadSource();
        string memory basePath = vm.parseJsonString(json, ".baseBookPath"); _basePath(basePath);
        bytes32 rawSha = vm.parseBytes32(string.concat("0x", vm.parseJsonString(json, ".baseBookSha256")));
        x.base = _base(vm.readFile(basePath), rawSha); x.base.path = basePath;
        x.calendar = TestnetCryptoCalendar(vm.parseJsonAddress(json, ".calendar")); x.feed = TestFeed(vm.parseJsonAddress(json, ".feed"));
        x.oracle = TestnetCryptoOracle(vm.parseJsonAddress(json, ".oracle")); x.seeder = TestnetNativeMarket(vm.parseJsonAddress(json, ".seeder"));
        x.pool = vm.parseJsonAddress(json, ".pool"); x.wethImplementation = vm.parseJsonAddress(json, ".wethImplementation");
        x.wethCodeHash = vm.parseJsonBytes32(json, ".wethCodeHash"); x.wethImplementationCodeHash = vm.parseJsonBytes32(json, ".wethImplementationCodeHash");
        int256 lo = vm.parseJsonInt(json, ".tickLower"); int256 hi = vm.parseJsonInt(json, ".tickUpper");
        uint256 liquidity = vm.parseUint(vm.parseJsonString(json, ".liquidity"));
        if (lo < type(int24).min || lo > type(int24).max || hi < type(int24).min || hi > type(int24).max
            || liquidity == 0 || liquidity > type(uint128).max) revert BadSource();
        x.tickLower = int24(lo); x.tickUpper = int24(hi); x.liquidity = uint128(liquidity);
        x.initializedAt = vm.parseJsonUint(json, ".initializedAt"); x.initializedBlock = vm.parseJsonUint(json, ".initializedBlock");
        x.deadline = vm.parseJsonUint(json, ".deadline");
        x.provided0 = vm.parseUint(vm.parseJsonString(json, ".provided0")); x.provided1 = vm.parseUint(vm.parseJsonString(json, ".provided1"));
    }

    function _write(Deployment memory x, string memory phase) internal {
        string memory k = "native-market-candidate";
        bool requested = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        vm.serializeString(k, "schema", "v2-testnet-native-market-candidate-v1"); vm.serializeString(k, "phase", phase);
        vm.serializeBool(k, "broadcast", false); vm.serializeBool(k, "broadcastRequested", requested); vm.serializeUint(k, "chainId", 46630);
        vm.serializeUint(k, "block", block.number);
        vm.serializeString(k, "commit", _commit()); vm.serializeString(k, "baseBookPath", x.base.path);
        vm.serializeString(k, "baseFeatureVersion", x.base.feature); vm.serializeString(k, "baseBookSha256", _hex(x.base.bookSha256));
        string memory v = "native-base-verification";
        vm.serializeUint(v, "blockNumber", x.base.verificationBlock); vm.serializeBytes32(v, "blockHash", x.base.verificationBlockHash);
        vm.serializeString(v, "sourceCommit", x.base.sourceCommit);
        vm.serializeString(k, "baseVerification", vm.serializeString(v, "sourceBookSha256", x.base.sourceBookSha256));
        vm.serializeAddress(k, "factory", x.base.factory); vm.serializeAddress(k, "treasuryDeployer", x.base.treasuryDeployer);
        vm.serializeAddress(k, "tradeRouter", x.base.tradeRouter); vm.serializeAddress(k, "nativeRouter", x.base.nativeRouter);
        vm.serializeAddress(k, "operator", OPERATOR); vm.serializeAddress(k, "owner", OPERATOR);
        vm.serializeAddress(k, "weth", WETH); vm.serializeAddress(k, "usdg", USDG); vm.serializeAddress(k, "usdgFeed", USDG_FEED); vm.serializeAddress(k, "v3Factory", V3_FACTORY);
        vm.serializeAddress(k, "calendar", address(x.calendar)); vm.serializeAddress(k, "feed", address(x.feed)); vm.serializeAddress(k, "oracle", address(x.oracle));
        vm.serializeAddress(k, "seeder", address(x.seeder)); vm.serializeAddress(k, "pool", x.pool);
        vm.serializeAddress(k, "wethImplementation", x.wethImplementation); vm.serializeBytes32(k, "wethCodeHash", x.wethCodeHash);
        vm.serializeBytes32(k, "wethImplementationCodeHash", x.wethImplementationCodeHash);
        vm.serializeString(k, "priceSource", "pool-twap"); vm.serializeUint(k, "oracleVersion", 2);
        vm.serializeUint(k, "twapSeconds", 600); vm.serializeString(k, "minLiquidity", vm.toString(x.liquidity / 2));
        vm.serializeUint(k, "fee", FEE); vm.serializeString(k, "priceE18", vm.toString(PRICE)); vm.serializeString(k, "openPriceE18", vm.toString(OPEN_PRICE));
        vm.serializeInt(k, "tickLower", x.tickLower); vm.serializeInt(k, "tickUpper", x.tickUpper); vm.serializeString(k, "liquidity", vm.toString(x.liquidity));
        vm.serializeUint(k, "initializedAt", x.initializedAt); vm.serializeUint(k, "initializedBlock", x.initializedBlock); vm.serializeUint(k, "deadline", x.deadline);
        vm.serializeString(k, "provided0", vm.toString(x.provided0)); vm.serializeString(k, "provided1", vm.toString(x.provided1));
        vm.serializeString(k, "seedEth", vm.toString(SEED_ETH)); vm.serializeString(k, "seedUsdg", vm.toString(SEED_USDG));
        vm.serializeUint(k, "maxDeviationBps", 50); vm.serializeUint(k, "maxSlippageBps", 100); vm.serializeString(k, "sellChunkUsdg", "0");
        vm.serializeUint(k, "lpBps", 5000); vm.serializeUint(k, "bandCeiling", 0);
        vm.serializeUint(k, "plannedTransactionCount", 17);
        vm.serializeUint("native-phase-counts", "init", 12); vm.serializeUint("native-phase-counts", "poke", 1);
        vm.serializeString(k, "phaseCounts", vm.serializeUint("native-phase-counts", "activate", 4));
        string memory m = "native-ETH-market";
        vm.serializeAddress(m, "token", WETH); vm.serializeAddress(m, "feed", address(x.feed)); vm.serializeAddress(m, "oracle", address(x.oracle));
        vm.serializeAddress(m, "pool", x.pool); vm.serializeAddress(m, "calendar", address(x.calendar)); vm.serializeUint(m, "fee", 500); vm.serializeUint(m, "decimals", 18);
        vm.serializeString(m, "priceSource", "pool-twap"); vm.serializeUint(m, "twapSeconds", 600);
        vm.serializeString(m, "minLiquidity", vm.toString(x.liquidity / 2));
        vm.serializeString(m, "priceE18", vm.toString(PRICE)); vm.serializeString(m, "openPriceE18", vm.toString(OPEN_PRICE));
        vm.serializeInt(m, "tickLower", x.tickLower); vm.serializeInt(m, "tickUpper", x.tickUpper); vm.serializeString(m, "liquidity", vm.toString(x.liquidity));
        vm.serializeUint(m, "maxDeviationBps", 50); vm.serializeUint(m, "maxSlippageBps", 100); vm.serializeString(m, "sellChunkUsdg", "0");
        vm.serializeUint(m, "lpBps", 5000);
        vm.serializeString(k, "market", vm.serializeUint(m, "bandCeiling", 0));
        vm.serializeString(k, "pokeMax0", vm.toString(POKE_USDG));
        string memory result = vm.serializeString(k, "pokeMax1", vm.toString(POKE_WETH));
        vm.writeJson(result, string.concat("deploy/testnet-v2-native-market.", phase, requested ? ".candidate.json" : ".dryrun.json"));
    }

    function _hex(bytes32 value) private pure returns (string memory) {
        bytes memory chars = "0123456789abcdef"; bytes memory result = new bytes(64);
        for (uint256 i; i < 32; ++i) { result[2*i] = chars[uint8(value[i]) >> 4]; result[2*i+1] = chars[uint8(value[i]) & 15]; }
        return string(result);
    }

    function _commit() private view returns (string memory value) {
        value = vm.envString("GIT_COMMIT"); bytes memory data = bytes(value);
        if (data.length != 40) revert BadSource();
        for (uint256 i; i < data.length; ++i) if (!((data[i] >= "0" && data[i] <= "9") || (data[i] >= "a" && data[i] <= "f") || (data[i] >= "A" && data[i] <= "F"))) revert BadSource();
    }
}
