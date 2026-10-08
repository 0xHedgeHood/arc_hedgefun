// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {HedgeFunFactory, TokenDeployer} from "../../src/HedgeFunFactory.sol";
import {HedgeFunV2ArcFactory} from "../../src/v2/arc/HedgeFunV2ArcFactory.sol";
import {V2TreasuryDeployer} from "../../src/v2/V2TreasuryDeployer.sol";
import {ArcCurveDeployer} from "../../src/v2/arc/ArcCurveDeployer.sol";
import {HedgeFunV2Hook} from "../../src/hooks/HedgeFunV2Hook.sol";
import {HedgeFunV2TradeRouter} from "../../src/v2/HedgeFunV2TradeRouter.sol";
import {ArcCore} from "./ArcCore.sol";
import {ArcDefaults} from "./ArcDefaults.sol";

/// @notice Deploys the V2 core on Arc (5042). It refuses every other chain.
/// @dev Six transactions from the broadcaster. Requires OWNER and PROTOCOL (Safes), GIT_COMMIT (the 40-hex release
///      commit, recorded only), EXPECTED_DEFAULTS_HASH (`keccak256(abi.encode(ArcDefaults.release()))`, as
///      reviewed) and EXPECTED_SALE_BPS. HOOK_SALT_START and DEPLOYER_SETS_UP are optional, as on 4663; a deployer
///      that sets up must run `HandOverArc` before public launch is opened.
///
///      Run it with Circle's arc-forge and `--network arc`; see docs/ARC.md. Like the 4663 deployment it registers
///      nothing beyond kind 0, lists nothing and leaves launch closed.
contract DeployArcCore is ArcCore {
    string internal constant OUT = "deploy/arc-v2-core.candidate.json";
    string internal constant OUT_DRY = "deploy/arc-v2-core.dryrun.json";

    error WrongChain(uint256 chainId);
    error BadCommit();
    error DefaultsNotReviewed(bytes32 actual);
    error SaleShareNotReviewed(uint16 actual);

    function run() external returns (Deployed memory x) {
        string memory commit = vm.envString("GIT_COMMIT");
        _checkCommit(commit);
        Roles memory r = Roles(vm.envAddress("OWNER"), vm.envAddress("PROTOCOL"));
        uint256 startBlock = block.number;
        bool deployerSetsUp = vm.envOr("DEPLOYER_SETS_UP", false);
        x = deploy(
            msg.sender, r, deployerSetsUp, vm.envBytes32("EXPECTED_DEFAULTS_HASH"),
            uint16(vm.envUint("EXPECTED_SALE_BPS")), vm.envOr("HOOK_SALT_START", uint256(0))
        );
        bool requested =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        _writeCandidate(x, r, msg.sender, startBlock, requested, commit);
        console2.log("factory owner now", x.factory.owner());
        if (deployerSetsUp) console2.log("the deployer owns the factory: run HandOverArc before opening launch");
        console2.log("Arc V2 factory", address(x.factory));
        console2.log("V2 treasury registry", address(x.treasury));
        console2.log("upgrade controller", address(x.treasury.upgradeController()));
        console2.log("hook", address(x.hook));
        console2.log("trade router", address(x.router));
        console2.log("public launch", x.factory.publicLaunch());
        console2.log("defaults hash");
        console2.logBytes32(keccak256(abi.encode(x.factory.getDefaults())));
    }

    function deploy(
        address deployer,
        Roles memory r,
        bool deployerSetsUp,
        bytes32 expectedDefaultsHash,
        uint16 expectedSaleBps,
        uint256 saltStart
    ) public returns (Deployed memory x) {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        HedgeFunFactory.Defaults memory d = _defaults();
        bytes32 defaultsHash = keccak256(abi.encode(d));
        if (defaultsHash != expectedDefaultsHash) revert DefaultsNotReviewed(defaultsHash);
        if (ArcDefaults.SALE_BPS != expectedSaleBps) revert SaleShareNotReviewed(ArcDefaults.SALE_BPS);
        _preflight(deployer, r, d);
        (bytes32 salt, address mined) = _mineHook(saltStart);
        address firstOwner = _firstOwner(deployer, r, deployerSetsUp);
        vm.startBroadcast(deployer);
        x = _deployCore(firstOwner, r, d, salt, mined);
        vm.stopBroadcast();
        _readBackCore(x, firstOwner, r, d);
    }

    function _checkCommit(string memory commit) internal pure {
        bytes memory c = bytes(commit);
        if (c.length != 40) revert BadCommit();
        for (uint256 i; i < c.length; ++i) {
            if (!((c[i] >= 0x30 && c[i] <= 0x39) || (c[i] >= 0x61 && c[i] <= 0x66))) revert BadCommit();
        }
    }

    function _writeCandidate(
        Deployed memory x,
        Roles memory r,
        address deployer,
        uint256 startBlock,
        bool requested,
        string memory commit
    ) internal {
        string memory k = "arcCore";
        vm.serializeString(k, "schema", "v2-arc-core-v1");
        vm.serializeUint(k, "chainId", CHAIN_ID);
        // Always false: this file is written by the simulation. Receipts and VerifyArcCore make it true.
        vm.serializeBool(k, "verified", false);
        vm.serializeBool(k, "broadcastRequested", requested);
        vm.serializeUint(k, "block", startBlock);
        vm.serializeString(k, "commit", commit);
        vm.serializeAddress(k, "deployer", deployer);
        vm.serializeAddress(k, "owner", r.owner);
        vm.serializeAddress(k, "factoryOwnerAtDeployment", x.factory.owner());
        vm.serializeAddress(k, "protocol", r.protocol);
        vm.serializeAddress(k, "poolManager", PM);
        vm.serializeAddress(k, "v3Factory", V3_FACTORY);
        vm.serializeAddress(k, "usdg", USDC);
        vm.serializeBytes32(k, "defaultsHash", keccak256(abi.encode(x.factory.getDefaults())));
        vm.serializeUint(k, "openPriceScale", x.factory.OPEN_PRICE_SCALE());
        vm.serializeUint(k, "saleBps", x.curve.DEFAULT_SALE_BPS());
        vm.serializeUint(k, "defaultLpBps", x.treasury.DEFAULT_LP_BPS());
        vm.serializeAddress(k, "factory", address(x.factory));
        vm.serializeAddress(k, "treasuryDeployer", address(x.treasury));
        vm.serializeAddress(k, "upgradeController", address(x.treasury.upgradeController()));
        vm.serializeAddress(k, "tokenDeployer", address(x.token));
        vm.serializeAddress(k, "curveDeployer", address(x.curve));
        vm.serializeAddress(k, "hook", address(x.hook));
        vm.serializeBytes32(k, "hookSalt", x.hookSalt);
        string memory json = vm.serializeAddress(k, "tradeRouter", address(x.router));
        string memory path = requested ? OUT : OUT_DRY;
        vm.writeJson(json, path);
        console2.log("unverified candidate", path);
    }
}

/// @notice Read-only confirmation against the confirmed chain, after all six transactions have landed.
/// @dev Requires OWNER, PROTOCOL, EXPECTED_DEFAULTS_HASH, EXPECTED_SALE_BPS, FIRST_OWNER and the six addresses:
///      V2_FACTORY, V2_TREASURY_DEPLOYER, V2_TOKEN_DEPLOYER, V2_CURVE_DEPLOYER, V2_HOOK and V2_TRADE_ROUTER.
///      Run it before the owner registers a kind, lists or opens launch: the readback expects the born state.
contract VerifyArcCore is ArcCore {
    error WrongChain(uint256 chainId);
    error DefaultsNotReviewed(bytes32 actual);
    error SaleShareNotReviewed(uint16 actual);

    function run() external view {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        Roles memory r = Roles(vm.envAddress("OWNER"), vm.envAddress("PROTOCOL"));
        Deployed memory x;
        x.factory = HedgeFunV2ArcFactory(vm.envAddress("V2_FACTORY"));
        x.treasury = V2TreasuryDeployer(vm.envAddress("V2_TREASURY_DEPLOYER"));
        x.token = TokenDeployer(vm.envAddress("V2_TOKEN_DEPLOYER"));
        x.curve = ArcCurveDeployer(vm.envAddress("V2_CURVE_DEPLOYER"));
        x.hook = HedgeFunV2Hook(vm.envAddress("V2_HOOK"));
        x.router = HedgeFunV2TradeRouter(vm.envAddress("V2_TRADE_ROUTER"));
        check(x, vm.envAddress("FIRST_OWNER"), r, vm.envBytes32("EXPECTED_DEFAULTS_HASH"), uint16(vm.envUint("EXPECTED_SALE_BPS")));
        console2.log("live Arc V2 core verified", address(x.factory));
    }

    function check(Deployed memory x, address firstOwner, Roles memory r, bytes32 expectedDefaultsHash, uint16 expectedSaleBps)
        public
        view
    {
        HedgeFunFactory.Defaults memory d = _defaults();
        bytes32 defaultsHash = keccak256(abi.encode(d));
        if (defaultsHash != expectedDefaultsHash) revert DefaultsNotReviewed(defaultsHash);
        if (ArcDefaults.SALE_BPS != expectedSaleBps) revert SaleShareNotReviewed(ArcDefaults.SALE_BPS);
        if (uint160(address(x.hook)) & 0x3FFF != HOOK_FLAGS) revert BadHook(address(x.hook), address(x.hook));
        _requireSafe(r.owner);
        _requireSafe(r.protocol);
        _readBackCore(x, firstOwner, r, d);
    }
}

/// @notice The deploying key offers the factory to the owner Safe; the Safe then calls `acceptOwnership()`.
/// @dev Only after a `DEPLOYER_SETS_UP` deployment, and before public launch is opened. Requires V2_FACTORY and OWNER.
contract HandOverArc is ArcCore {
    error WrongChain(uint256 chainId);
    error NotFactoryOwner(address sender);
    error LaunchAlreadyOpen();

    function run() external {
        handOver(msg.sender, HedgeFunV2ArcFactory(vm.envAddress("V2_FACTORY")), vm.envAddress("OWNER"));
        console2.log("ownership offered to the Safe; it takes effect when the Safe calls acceptOwnership()");
    }

    function handOver(address deployer, HedgeFunV2ArcFactory factory, address safe) public {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        if (address(factory).code.length == 0) revert MissingCode(address(factory));
        if (factory.owner() != deployer) revert NotFactoryOwner(deployer);
        if (factory.publicLaunch()) revert LaunchAlreadyOpen();
        _requireSafe(safe);
        vm.startBroadcast(deployer);
        factory.transferOwnership(safe);
        vm.stopBroadcast();
        if (factory.pendingOwner() != safe || factory.owner() != deployer) revert ReadbackFailed("pending owner");
    }
}

/// @notice Read-only: the Safe owns the factory, and with it the registry and the upgrade controller.
contract VerifyArcHandOver is ArcCore {
    error WrongChain(uint256 chainId);

    function run() external view {
        check(HedgeFunV2ArcFactory(vm.envAddress("V2_FACTORY")), vm.envAddress("OWNER"));
        console2.log("the Safe owns the Arc V2 factory");
    }

    function check(HedgeFunV2ArcFactory factory, address safe) public view {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        _requireSafe(safe);
        if (factory.owner() != safe || factory.pendingOwner() != address(0)) revert ReadbackFailed("owner");
        V2TreasuryDeployer registry = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        if (registry.factory() != address(factory) || registry.upgradeController().owner() != safe) {
            revert ReadbackFailed("upgrade controller owner");
        }
    }
}
