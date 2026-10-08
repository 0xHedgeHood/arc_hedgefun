// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {HedgeFunFactory, TokenDeployer} from "../../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {V2TreasuryDeployer} from "../../src/v2/V2TreasuryDeployer.sol";
import {CurveDeployer} from "../../src/v2/CurveDeployer.sol";
import {HedgeFunV2Hook} from "../../src/hooks/HedgeFunV2Hook.sol";
import {HedgeFunV2TradeRouter} from "../../src/v2/HedgeFunV2TradeRouter.sol";
import {HedgeFunV2NativeRouter} from "../../src/v2/HedgeFunV2NativeRouter.sol";
import {V2MainnetCore} from "./V2MainnetCore.sol";
import {V2MainnetDefaults} from "./V2MainnetDefaults.sol";

/// @notice Deploys the V2 core on Robinhood Chain (4663). It refuses every other chain.
/// @dev Seven transactions from the broadcaster, which ends with no role. Rehearse first, on a fork, with
///      `RehearseV2Launchpad`: it runs the same `V2MainnetCore` code. See docs/V2_DEPLOYMENT_REHEARSAL.md.
///
///      Requires OWNER and PROTOCOL (Safes), WETH (the chain's wrapped native token), GIT_COMMIT (the 40-hex
///      release commit, recorded only) and EXPECTED_DEFAULTS_HASH: `keccak256(abi.encode(defaults))` of
///      `V2MainnetDefaults.release()`, as reviewed, and EXPECTED_SALE_BPS: the reviewed sale share, which that
///      hash does not cover and which is permanent once the curve deployer exists. HOOK_SALT_START is optional. DEPLOYER_SETS_UP=true makes the
///      broadcaster the factory's first owner, for the setup scripts; it must then run `HandOverV2Mainnet`.
///
///      What this does NOT do, because only the factory owner can: register any strategy kind beyond kind 0 or
///      any policy, list a stock, whitelist a launch router, or open public launch. The factory is born closed
///      and empty. The file it writes is an unverified candidate; `VerifyV2MainnetCore` reads the confirmed chain.
contract DeployV2MainnetCore is V2MainnetCore {
    string internal constant OUT = "deploy/mainnet-v2-core.candidate.json";
    string internal constant OUT_DRY = "deploy/mainnet-v2-core.dryrun.json";

    error WrongChain(uint256 chainId);
    error BadCommit();
    error DefaultsNotReviewed(bytes32 actual);
    error SaleShareNotReviewed(uint16 actual);

    function run() external returns (Deployed memory x) {
        string memory commit = vm.envString("GIT_COMMIT");
        _checkCommit(commit);
        Roles memory r = Roles(vm.envAddress("OWNER"), vm.envAddress("PROTOCOL"), vm.envAddress("WETH"));
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
        if (deployerSetsUp) console2.log("the deployer owns the factory: run HandOverV2Mainnet before opening launch");
        console2.log("V2 factory", address(x.factory));
        console2.log("V2 treasury registry", address(x.treasury));
        console2.log("upgrade controller", address(x.treasury.upgradeController()));
        console2.log("hook", address(x.hook));
        console2.log("trade router", address(x.router));
        console2.log("native router", address(x.nativeRouter));
        console2.log("public launch", x.factory.publicLaunch());
        console2.log("simulation readback passed; nothing is listed, registered beyond kind 0, or open");
    }

    /// @param deployer the broadcasting key; it is neither Safe, and holds a role afterwards only if
    ///        `deployerSetsUp`, and then only until the hand-over
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
        if (V2MainnetDefaults.SALE_BPS != expectedSaleBps) revert SaleShareNotReviewed(V2MainnetDefaults.SALE_BPS);
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
        string memory k = "mainnetCore";
        vm.serializeString(k, "schema", "v2-mainnet-core-v1");
        vm.serializeUint(k, "chainId", CHAIN_ID);
        // Always false: this file is written by the simulation. Receipts and VerifyV2MainnetCore make it true.
        vm.serializeBool(k, "verified", false);
        vm.serializeBool(k, "broadcastRequested", requested);
        vm.serializeUint(k, "block", startBlock);
        vm.serializeString(k, "commit", commit);
        vm.serializeAddress(k, "deployer", deployer);
        vm.serializeAddress(k, "owner", r.owner);
        vm.serializeAddress(k, "factoryOwnerAtDeployment", x.factory.owner());
        vm.serializeAddress(k, "protocol", r.protocol);
        vm.serializeAddress(k, "weth", r.weth);
        vm.serializeAddress(k, "poolManager", PM);
        vm.serializeAddress(k, "v3Factory", V3_FACTORY);
        vm.serializeAddress(k, "usdg", USDG);
        vm.serializeBytes32(k, "defaultsHash", keccak256(abi.encode(x.factory.getDefaults())));
        vm.serializeUint(k, "saleBps", x.curve.DEFAULT_SALE_BPS());
        vm.serializeUint(k, "defaultLpBps", x.treasury.DEFAULT_LP_BPS());
        vm.serializeAddress(k, "factory", address(x.factory));
        vm.serializeAddress(k, "treasuryDeployer", address(x.treasury));
        vm.serializeAddress(k, "upgradeController", address(x.treasury.upgradeController()));
        vm.serializeAddress(k, "tokenDeployer", address(x.token));
        vm.serializeAddress(k, "curveDeployer", address(x.curve));
        vm.serializeAddress(k, "hook", address(x.hook));
        vm.serializeBytes32(k, "hookSalt", x.hookSalt);
        vm.serializeAddress(k, "tradeRouter", address(x.router));
        string memory json = vm.serializeAddress(k, "nativeRouter", address(x.nativeRouter));
        string memory path = requested ? OUT : OUT_DRY;
        vm.writeJson(json, path);
        console2.log("unverified candidate", path);
    }
}

/// @notice Read-only confirmation against the confirmed chain, after all seven transactions have landed.
/// @dev Requires OWNER, PROTOCOL, WETH, EXPECTED_DEFAULTS_HASH, FIRST_OWNER (the Safe, or the deployer if it set
///      up) and the seven addresses from the receipts: V2_FACTORY, V2_TREASURY_DEPLOYER, V2_TOKEN_DEPLOYER,
///      V2_CURVE_DEPLOYER, V2_HOOK, V2_TRADE_ROUTER and V2_NATIVE_ROUTER. It runs the deployment's own readback,
///      so it also fails once the owner has registered a kind, listed a stock or opened public launch: run it
///      before any of those.
contract VerifyV2MainnetCore is V2MainnetCore {
    error WrongChain(uint256 chainId);
    error DefaultsNotReviewed(bytes32 actual);
    error SaleShareNotReviewed(uint16 actual);

    function run() external view {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        Roles memory r = Roles(vm.envAddress("OWNER"), vm.envAddress("PROTOCOL"), vm.envAddress("WETH"));
        Deployed memory x;
        x.factory = HedgeFunV2Factory(vm.envAddress("V2_FACTORY"));
        x.treasury = V2TreasuryDeployer(vm.envAddress("V2_TREASURY_DEPLOYER"));
        x.token = TokenDeployer(vm.envAddress("V2_TOKEN_DEPLOYER"));
        x.curve = CurveDeployer(vm.envAddress("V2_CURVE_DEPLOYER"));
        x.hook = HedgeFunV2Hook(vm.envAddress("V2_HOOK"));
        x.router = HedgeFunV2TradeRouter(vm.envAddress("V2_TRADE_ROUTER"));
        x.nativeRouter = HedgeFunV2NativeRouter(payable(vm.envAddress("V2_NATIVE_ROUTER")));
        check(
            x, vm.envAddress("FIRST_OWNER"), r, vm.envBytes32("EXPECTED_DEFAULTS_HASH"),
            uint16(vm.envUint("EXPECTED_SALE_BPS"))
        );
        console2.log("live V2 mainnet core verified", address(x.factory));
    }

    function check(
        Deployed memory x,
        address firstOwner,
        Roles memory r,
        bytes32 expectedDefaultsHash,
        uint16 expectedSaleBps
    ) public view {
        HedgeFunFactory.Defaults memory d = _defaults();
        bytes32 defaultsHash = keccak256(abi.encode(d));
        if (defaultsHash != expectedDefaultsHash) revert DefaultsNotReviewed(defaultsHash);
        if (V2MainnetDefaults.SALE_BPS != expectedSaleBps) revert SaleShareNotReviewed(V2MainnetDefaults.SALE_BPS);
        if (uint160(address(x.hook)) & 0x3FFF != HOOK_FLAGS) revert BadHook(address(x.hook), address(x.hook));
        _requireSafe(r.owner);
        _requireSafe(r.protocol);
        _readBackCore(x, firstOwner, r, d);
    }
}

/// @notice The deploying key gives the factory to the owner Safe. One transaction; the Safe then accepts.
/// @dev Only after a `DEPLOYER_SETS_UP` deployment, and before public launch is opened: opening is the Safe's
///      decision. Requires V2_FACTORY and OWNER (the Safe). Ownership is two-step, so nothing changes until the
///      Safe calls `acceptOwnership()` on the factory; until then the deployer is still the owner and can call
///      this again. Accepting moves the registry's and the upgrade controller's authority with it, and advances
///      `ownershipEpoch`, which voids any upgrade proposal scheduled before.
contract HandOverV2Mainnet is V2MainnetCore {
    error WrongChain(uint256 chainId);
    error NotFactoryOwner(address sender);
    error LaunchAlreadyOpen();

    function run() external {
        handOver(msg.sender, HedgeFunV2Factory(vm.envAddress("V2_FACTORY")), vm.envAddress("OWNER"));
        console2.log("ownership offered to the Safe; it takes effect when the Safe calls acceptOwnership()");
    }

    function handOver(address deployer, HedgeFunV2Factory factory, address safe) public {
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
/// @dev Requires V2_FACTORY and OWNER. Run after the Safe has accepted, and before it opens public launch.
contract VerifyV2MainnetHandOver is V2MainnetCore {
    error WrongChain(uint256 chainId);

    function run() external view {
        check(HedgeFunV2Factory(vm.envAddress("V2_FACTORY")), vm.envAddress("OWNER"));
        console2.log("the Safe owns the V2 factory");
    }

    function check(HedgeFunV2Factory factory, address safe) public view {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        _requireSafe(safe);
        if (factory.owner() != safe || factory.pendingOwner() != address(0)) revert ReadbackFailed("owner");
        V2TreasuryDeployer registry = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        if (registry.factory() != address(factory) || registry.upgradeController().owner() != safe) {
            revert ReadbackFailed("upgrade controller owner");
        }
    }
}
