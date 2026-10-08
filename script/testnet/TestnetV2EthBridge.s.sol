// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {V2TreasuryDeployer} from "../../src/v2/V2TreasuryDeployer.sol";
import {HedgeFunV2TradeRouter} from "../../src/v2/HedgeFunV2TradeRouter.sol";
import {HedgeFunV2NativeRouter, IWrappedNative} from "../../src/v2/HedgeFunV2NativeRouter.sol";
import {IV3Factory, IV3Pool} from "./TestnetMarket.sol";
import {TestnetEthBridgeLiquidity} from "./TestnetEthBridgeLiquidity.sol";

interface IBridgeV3Position {
    function positions(bytes32 key) external view returns (uint128 liquidity, uint256, uint256, uint128, uint128);
}

/// @notice Small, recoverable WETH/tUSDG V3 payment bridge on chain 46630.
/// @dev This does not list WETH, configure an oracle, or enable ETH as a strategy underlying.
contract TestnetV2EthBridge is Script {
    address public constant OPERATOR = 0x75Cee941B0eF3A83feA0397BbF903C12c1D7e96D;
    address public constant WETH = 0x7943e237c7F95DA44E0301572D358911207852Fa;
    address public constant USDG = 0x539574139BB4Ac74Fd2183ba0E38ed777E30B58d;
    address public constant V3_FACTORY = 0x0b0a96D7EB396E7471998889C4803dD0F529Eb01;
    uint24 public constant FEE = 3000;
    uint256 public constant PRICE = 3000e18; // Synthetic test price, not a production price feed.
    uint256 public constant SEED_ETH = 0.0055 ether;
    uint256 public constant POSITION_ETH = 0.005 ether;
    uint256 public constant SEED_USDG = 20e6;
    uint256 public constant GAS_RESERVE = 0.005 ether;

    struct Base {
        address factory;
        address treasuryDeployer;
        address tradeRouter;
        address nativeRouter;
        string path;
        bytes32 bookSha256;
    }
    struct Deployment {
        Base base;
        address pool;
        TestnetEthBridgeLiquidity liquidityManager;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 providedUsdg;
        uint256 providedWeth;
    }

    error BadSource();
    error BadBinding();
    error BadStage();
    error InsufficientNative(uint256 available, uint256 required);
    error InsufficientUsdg(uint256 available, uint256 required);
    error TransferMismatch();

    /// @notice Simulate using a verified base book supplied in memory; writes no candidate file.
    function deploy(string calldata baseJson, bytes32 expectedBaseSha256) external returns (Deployment memory x) {
        return _deploy(_base(baseJson, expectedBaseSha256));
    }

    /// @notice Seed the bridge and write an unverified candidate for independent receipt publication.
    function initialize(string calldata basePath, bytes32 expectedBaseSha256) external returns (Deployment memory x) {
        _basePath(basePath);
        x = _deploy(_base(vm.readFile(basePath), expectedBaseSha256));
        x.base.path = basePath;
        _write(x);
    }

    /// @notice Read back a seeded bridge without making any state changes. Historical transactions still need receipt review.
    function verify(Deployment memory x, bytes32 expectedManagerCodeHash) external view {
        _checkBase(x.base);
        _verifyBridge(x, expectedManagerCodeHash);
    }

    /// @notice Read only an allowlisted candidate and its exact base book, then check current on-chain state.
    function verifyFile(string calldata candidatePath) external view returns (Deployment memory x) {
        bytes32 pathHash = keccak256(bytes(candidatePath));
        if (pathHash != keccak256("deploy/testnet-v2-native-bridge.candidate.json")
            && pathHash != keccak256("deploy/testnet-v2-native-bridge.dryrun.json")) revert BadSource();
        string memory json = vm.readFile(candidatePath);
        if (keccak256(bytes(vm.parseJsonString(json, ".schema"))) != keccak256("v2-testnet-native-bridge-candidate-v1")
            || vm.parseJsonUint(json, ".chainId") != 46630 || vm.parseJsonBool(json, ".broadcast")
            || !vm.parseJsonBool(json, ".bridgeOnly") || vm.parseJsonBool(json, ".wethListingEnabled")
            || vm.parseJsonUint(json, ".plannedTransactionCount") != 7
            || vm.parseJsonUint(json, ".fee") != FEE
            || vm.parseUint(vm.parseJsonString(json, ".priceE18")) != PRICE
            || vm.parseUint(vm.parseJsonString(json, ".seedEth")) != SEED_ETH
            || vm.parseUint(vm.parseJsonString(json, ".positionEth")) != POSITION_ETH
            || vm.parseUint(vm.parseJsonString(json, ".seedUsdg")) != SEED_USDG
            || vm.parseUint(vm.parseJsonString(json, ".gasReserve")) != GAS_RESERVE
            || vm.parseJsonAddress(json, ".operator") != OPERATOR
            || vm.parseJsonAddress(json, ".weth") != WETH
            || vm.parseJsonAddress(json, ".usdg") != USDG
            || vm.parseJsonAddress(json, ".v3Factory") != V3_FACTORY) revert BadSource();
        string memory basePath = vm.parseJsonString(json, ".baseBookPath");
        _basePath(basePath);
        x.base = _base(vm.readFile(basePath), vm.parseBytes32(string.concat("0x", vm.parseJsonString(json, ".baseBookSha256"))));
        x.base.path = basePath;
        if (vm.parseJsonAddress(json, ".factory") != x.base.factory
            || vm.parseJsonAddress(json, ".treasuryDeployer") != x.base.treasuryDeployer
            || vm.parseJsonAddress(json, ".tradeRouter") != x.base.tradeRouter
            || vm.parseJsonAddress(json, ".nativeRouter") != x.base.nativeRouter) revert BadSource();
        x.pool = vm.parseJsonAddress(json, ".pool");
        x.liquidityManager = TestnetEthBridgeLiquidity(vm.parseJsonAddress(json, ".liquidityManager"));
        int256 lo = vm.parseJsonInt(json, ".tickLower");
        int256 hi = vm.parseJsonInt(json, ".tickUpper");
        uint256 amount = vm.parseUint(vm.parseJsonString(json, ".liquidity"));
        if (lo < type(int24).min || lo > type(int24).max || hi < type(int24).min || hi > type(int24).max
            || amount == 0 || amount > type(uint128).max) revert BadSource();
        x.tickLower = int24(lo); x.tickUpper = int24(hi); x.liquidity = uint128(amount);
        x.providedUsdg = vm.parseUint(vm.parseJsonString(json, ".providedUsdg"));
        x.providedWeth = vm.parseUint(vm.parseJsonString(json, ".providedWeth"));
        _verifyBridge(x, vm.parseJsonBytes32(json, ".liquidityManagerCodeHash"));
    }

    function _deploy(Base memory base) internal returns (Deployment memory x) {
        if (msg.sender != OPERATOR || block.chainid != 46630) revert BadBinding();
        _checkBase(base);
        if (OPERATOR.balance < SEED_ETH + GAS_RESERVE) revert InsufficientNative(OPERATOR.balance, SEED_ETH + GAS_RESERVE);
        uint256 availableUsdg = IERC20(USDG).balanceOf(OPERATOR);
        if (availableUsdg < SEED_USDG) revert InsufficientUsdg(availableUsdg, SEED_USDG);
        (address listedOracle, address listedPool,, bool enabled) = HedgeFunV2Factory(base.factory).listings(WETH);
        if (listedOracle != address(0) || listedPool != address(0) || enabled
            || IV3Factory(V3_FACTORY).getPool(WETH, USDG, FEE) != address(0)
            || IV3Factory(V3_FACTORY).getPool(WETH, USDG, 500) != address(0)) revert BadStage();
        if (IV3Factory(V3_FACTORY).feeAmountTickSpacing(FEE) != 60) revert BadBinding();

        x.base = base;
        uint256 wrappedBefore = IERC20(WETH).balanceOf(OPERATOR);
        vm.startBroadcast(OPERATOR);
        x.pool = IV3Factory(V3_FACTORY).createPool(WETH, USDG, FEE);
        uint160 sqrtP = _sqrtFor(PRICE);
        IV3Pool(x.pool).initialize(sqrtP);
        (x.tickLower, x.tickUpper, x.liquidity) = _position(sqrtP);
        x.liquidityManager = new TestnetEthBridgeLiquidity(
            OPERATOR, V3_FACTORY, WETH, USDG, x.pool, x.tickLower, x.tickUpper
        );
        IWrappedNative(WETH).deposit{value: SEED_ETH}();
        if (IERC20(WETH).balanceOf(OPERATOR) != wrappedBefore + SEED_ETH) revert TransferMismatch();
        if (!IERC20(WETH).transfer(address(x.liquidityManager), SEED_ETH)
            || !IERC20(USDG).transfer(address(x.liquidityManager), SEED_USDG)) revert TransferMismatch();
        (x.providedUsdg, x.providedWeth) = x.liquidityManager.provide(x.liquidity, SEED_USDG, POSITION_ETH);
        vm.stopBroadcast();
        if (IERC20(WETH).balanceOf(OPERATOR) != wrappedBefore) revert TransferMismatch();
        _verifyBridge(x, address(x.liquidityManager).codehash);
    }

    function _base(string memory json, bytes32 expectedSha256) internal view returns (Base memory b) {
        if (expectedSha256 == bytes32(0) || sha256(bytes(json)) != expectedSha256
            || vm.parseJsonUint(json, ".chainId") != 46630 || !vm.parseJsonBool(json, ".broadcast")
            || vm.parseJsonAddress(json, ".weth") != WETH || vm.parseJsonAddress(json, ".usdg") != USDG
            || vm.parseJsonAddress(json, ".v3Factory") != V3_FACTORY
            || keccak256(bytes(vm.parseJsonString(json, ".verification.schema"))) != keccak256("two-sided-fee-upgrade-readback-v1")) revert BadSource();
        b.bookSha256 = expectedSha256;
        b.factory = vm.parseJsonAddress(json, ".factory");
        b.treasuryDeployer = vm.parseJsonAddress(json, ".treasuryDeployer");
        b.tradeRouter = vm.parseJsonAddress(json, ".tradeRouter");
        b.nativeRouter = vm.parseJsonAddress(json, ".nativeRouter");
        string memory feature = vm.parseJsonString(json, ".featureVersion");
        bool creator = keccak256(bytes(feature)) == keccak256("v2-creator-selected-stock-fees-v1");
        if ((!creator && keccak256(bytes(feature)) != keccak256("v2-two-sided-stock-fees-v1"))
            || vm.parseJsonStringArray(json, ".verification.transactionHashes").length != (creator ? 40 : 38)
            || vm.parseJsonUint(json, ".verification.blockNumber") == 0
            || vm.parseJsonBytes32(json, ".verification.blockHash") == bytes32(0)) revert BadSource();
        for (uint256 i; i < 6; ++i) {
            string memory field = i == 0 ? "factory" : i == 1 ? "treasuryDeployer" : i == 2 ? "tradeRouter"
                : i == 3 ? "nativeRouter" : i == 4 ? "weth" : "v3Factory";
            address target = vm.parseJsonAddress(json, string.concat(".", field));
            if (target.codehash != vm.parseJsonBytes32(json, string.concat(".verification.upgradeProof.codeHashes.core.", field)))
                revert BadSource();
        }
        _checkBase(b);
    }

    function _checkBase(Base memory b) internal view {
        if (block.chainid != 46630) revert BadBinding();
        HedgeFunV2Factory factory = HedgeFunV2Factory(b.factory);
        V2TreasuryDeployer registry = V2TreasuryDeployer(b.treasuryDeployer);
        if (factory.owner() != OPERATOR || factory.protocol() != OPERATOR || factory.usdg() != USDG
            || address(factory.v3Factory()) != V3_FACTORY || address(factory.treasuryDeployer()) != b.treasuryDeployer
            || registry.factory() != b.factory || registry.version() != 2
            || address(HedgeFunV2TradeRouter(b.tradeRouter).factory()) != b.factory
            || address(HedgeFunV2NativeRouter(payable(b.nativeRouter)).router()) != b.tradeRouter
            || address(HedgeFunV2NativeRouter(payable(b.nativeRouter)).wrappedNative()) != WETH) revert BadBinding();
    }

    function _checkBridge(Deployment memory x) internal view {
        (address oracle, address listedPool,, bool enabled) = HedgeFunV2Factory(x.base.factory).listings(WETH);
        if (oracle != address(0) || listedPool != address(0) || enabled
            || IV3Factory(V3_FACTORY).getPool(WETH, USDG, FEE) != x.pool
            || IV3Factory(V3_FACTORY).getPool(WETH, USDG, 500) != address(0)
            || IV3Pool(x.pool).fee() != FEE || IV3Pool(x.pool).tickSpacing() != 60
            || IV3Pool(x.pool).token0() != USDG || IV3Pool(x.pool).token1() != WETH
            || IV3Pool(x.pool).liquidity() < x.liquidity
            || x.liquidityManager.owner() != OPERATOR || x.liquidityManager.liquidityOwned() != x.liquidity
            || address(x.liquidityManager.pool()) != x.pool
            || x.liquidityManager.weth() != WETH || x.liquidityManager.usdg() != USDG
            || x.liquidityManager.tickLower() != x.tickLower || x.liquidityManager.tickUpper() != x.tickUpper
            || x.providedUsdg == 0 || x.providedUsdg > SEED_USDG
            || x.providedWeth == 0 || x.providedWeth > POSITION_ETH
            || IERC20(WETH).balanceOf(address(x.liquidityManager)) < SEED_ETH - POSITION_ETH) revert BadBinding();
    }

    function _verifyBridge(Deployment memory x, bytes32 expectedManagerCodeHash) internal view {
        _checkBridge(x);
        if (expectedManagerCodeHash == bytes32(0) || address(x.liquidityManager).codehash != expectedManagerCodeHash
            || IERC20(WETH).balanceOf(x.pool) == 0 || IERC20(USDG).balanceOf(x.pool) == 0) revert BadBinding();
        (int24 lower, int24 upper, uint128 expectedLiquidity) = _position(_sqrtFor(PRICE));
        if (x.tickLower != lower || x.tickUpper != upper || x.liquidity != expectedLiquidity) revert BadBinding();
        bytes32 key = keccak256(abi.encodePacked(address(x.liquidityManager), lower, upper));
        (uint128 positionLiquidity,,,,) = IBridgeV3Position(x.pool).positions(key);
        if (positionLiquidity != x.liquidity) revert BadBinding();
        uint160 start = _sqrtFor(PRICE);
        if (x.providedUsdg != SqrtPriceMath.getAmount0Delta(start, TickMath.getSqrtPriceAtTick(upper), x.liquidity, true)
            || x.providedWeth != SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(lower), start, x.liquidity, true))
            revert BadBinding();
    }

    function _position(uint160 sqrtP) internal pure returns (int24 lo, int24 hi, uint128 liquidity) {
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 centre = tick / 60 * 60;
        if (tick < 0 && tick % 60 != 0) centre -= 60;
        lo = centre - 6000; hi = centre + 6000;
        uint256 value = Math.mulDiv(POSITION_ETH, 1 << 96, uint256(sqrtP) - TickMath.getSqrtPriceAtTick(lo));
        if (value == 0 || value > type(uint128).max) revert BadBinding();
        liquidity = uint128(value);
    }

    function _sqrtFor(uint256 price) internal pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(1e30, 1 << 192, price)));
    }

    function _basePath(string memory path) private pure {
        bytes32 value = keccak256(bytes(path));
        if (value != keccak256("deploy/testnet-v2-fees.json") && value != keccak256("deploy/testnet-v2-creator.json")) revert BadSource();
    }

    function _write(Deployment memory x) internal {
        bool requested = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        string memory k = "native-bridge-candidate";
        vm.serializeString(k, "schema", "v2-testnet-native-bridge-candidate-v1");
        vm.serializeUint(k, "chainId", 46630);
        vm.serializeBool(k, "broadcast", false);
        vm.serializeBool(k, "broadcastRequested", requested);
        vm.serializeBool(k, "bridgeOnly", true);
        vm.serializeBool(k, "wethListingEnabled", false);
        vm.serializeUint(k, "plannedTransactionCount", 7);
        vm.serializeString(k, "baseBookPath", x.base.path);
        vm.serializeString(k, "baseBookSha256", _hex(x.base.bookSha256));
        vm.serializeAddress(k, "operator", OPERATOR);
        vm.serializeAddress(k, "factory", x.base.factory);
        vm.serializeAddress(k, "treasuryDeployer", x.base.treasuryDeployer);
        vm.serializeAddress(k, "tradeRouter", x.base.tradeRouter);
        vm.serializeAddress(k, "nativeRouter", x.base.nativeRouter);
        vm.serializeAddress(k, "weth", WETH);
        vm.serializeAddress(k, "usdg", USDG);
        vm.serializeAddress(k, "v3Factory", V3_FACTORY);
        vm.serializeAddress(k, "pool", x.pool);
        vm.serializeAddress(k, "liquidityManager", address(x.liquidityManager));
        vm.serializeBytes32(k, "liquidityManagerCodeHash", address(x.liquidityManager).codehash);
        vm.serializeUint(k, "fee", FEE);
        vm.serializeString(k, "priceE18", vm.toString(PRICE));
        vm.serializeInt(k, "tickLower", x.tickLower);
        vm.serializeInt(k, "tickUpper", x.tickUpper);
        vm.serializeString(k, "liquidity", vm.toString(x.liquidity));
        vm.serializeString(k, "seedEth", vm.toString(SEED_ETH));
        vm.serializeString(k, "positionEth", vm.toString(POSITION_ETH));
        vm.serializeString(k, "seedUsdg", vm.toString(SEED_USDG));
        vm.serializeString(k, "gasReserve", vm.toString(GAS_RESERVE));
        vm.serializeString(k, "providedUsdg", vm.toString(x.providedUsdg));
        string memory result = vm.serializeString(k, "providedWeth", vm.toString(x.providedWeth));
        string memory path = string.concat("deploy/testnet-v2-native-bridge.", requested ? "candidate" : "dryrun", ".json");
        if (vm.exists(path)) revert BadSource(); // Preserve any earlier candidate or rehearsal result for review.
        vm.writeJson(result, path);
    }

    function _hex(bytes32 value) private pure returns (string memory) {
        bytes memory chars = "0123456789abcdef"; bytes memory result = new bytes(64);
        for (uint256 i; i < 32; ++i) { result[2*i] = chars[uint8(value[i]) >> 4]; result[2*i+1] = chars[uint8(value[i]) & 15]; }
        return string(result);
    }
}
