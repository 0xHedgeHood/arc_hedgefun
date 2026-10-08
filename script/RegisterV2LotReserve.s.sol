// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LotReserveScheduler} from "../src/v2/strategy/LotReserveScheduler.sol";
import {Script, console2} from "forge-std/Script.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {V2TreasuryDeployer, V2InitCodeChunk} from "../src/v2/V2TreasuryDeployer.sol";
import {V2TreasuryUpgradeController} from "../src/v2/V2TreasuryUpgradeController.sol";
import {PolicyManifest} from "../src/v2/strategy/IStrategyPolicy.sol";
import {HedgeFunV2UpgradeableReserveTreasury} from "../src/v2/HedgeFunV2ReserveTreasury.sol";
import {V2LotReservePolicy, LotReserveConfig} from "../src/v2/strategy/V2LotReservePolicy.sol";
import {ReviewedTreasuryRegistry} from "./helpers/ReviewedTreasuryRegistry.sol";

/// @notice Register the lot strategy with an opening reserve (engine version 3, config schema 4) for future launches.
/// @dev `run()`: five operator transactions when the factory owner is an EOA (the testnet's deployer): the schema's
///      policy, its registration, two code chunks, the kind. Never overwrites a kind. The manifest hashes must
///      describe this actual candidate, including the predeployed, linked LotReserveScheduler.
///      Compile/register/verify with the same --libraries binding; checkScheduler pins its full runtime.
///      `prepare()`: when the owner is a Safe. Any account deploys the policy and the two code chunks (neither is
///      privileged), and the script writes the owner's two calls, `registerPolicy` and `registerEngineKind`, as a Safe
///      Transaction Builder batch to `SAFE_BATCH` (default deploy/safe-register-lot-reserve.json).
contract RegisterV2LotReserve is ReviewedTreasuryRegistry {
    uint32 public constant MAX_GAS = 50_000;
    uint16 public constant MAX_RETURN_BYTES = 160;

    struct Registration {
        uint8 kind;
        bytes32 policyKey;
        address policy;
    }

    error BadBinding();
    error BadReadback();

    function run() external returns (Registration memory r) {
        address operator = vm.envAddress("OPERATOR");
        if (operator == address(0) || msg.sender != operator) revert BadBinding();
        r = register(
            operator,
            HedgeFunV2Factory(vm.envAddress("V2_FACTORY")),
            vm.envBytes32("DEPENDENCY_MANIFEST_HASH"),
            vm.envBytes32("AUDIT_MANIFEST_HASH")
        );
        console2.log("product profile: strategy/lot with an opening reserve (0-50%)");
        console2.log("registered kind", r.kind);
        console2.log("policy", r.policy);
        console2.logBytes32(r.policyKey);
        console2.log("simulation only unless --broadcast; verify live receipts before enabling the kind in the UI");
    }

    function prepare() external returns (address policy, address a, address b) {
        HedgeFunV2Factory factory = HedgeFunV2Factory(vm.envAddress("V2_FACTORY"));
        bytes32 dependencies = vm.envBytes32("DEPENDENCY_MANIFEST_HASH");
        bytes32 audit = vm.envBytes32("AUDIT_MANIFEST_HASH");
        checkScheduler();
        V2TreasuryDeployer registry = _reviewedRegistry(factory);
        if (
            dependencies == bytes32(0) || audit == bytes32(0) || registry.factory() != address(factory)
                || registry.kindCount() >= type(uint8).max
        ) revert BadBinding();
        vm.startBroadcast();
        policy = address(new V2LotReservePolicy());
        (a, b) = registry.makeChunks(type(HedgeFunV2UpgradeableReserveTreasury).creationCode);
        vm.stopBroadcast();
        bytes32 runtime = policy.codehash;
        bytes32 expectedKey = keccak256(
            abi.encode(
                policy,
                runtime,
                LotReserveConfig.ENGINE_VERSION,
                LotReserveConfig.SCHEMA,
                LotReserveConfig.CAPABILITIES,
                MAX_GAS,
                MAX_RETURN_BYTES,
                dependencies,
                audit
            )
        );
        bytes memory first =
            abi.encodeCall(V2TreasuryDeployer.registerPolicy, (policy, MAX_GAS, MAX_RETURN_BYTES, dependencies, audit));
        bytes memory second = abi.encodeCall(
            V2TreasuryDeployer.registerEngineKind,
            (a, b, LotReserveConfig.ENGINE_VERSION, LotReserveConfig.SCHEMA, LotReserveConfig.CAPABILITIES)
        );
        string memory to = vm.toString(address(registry));
        string memory batch = string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(block.chainid),
            '","createdAt":0,"meta":{"name":"Hedgefun V2: register the lot strategy with an opening reserve",',
            '"description":"registerPolicy(V2LotReservePolicy) and registerEngineKind(version 3, schema 4) on the treasury registry; the next kind id is ',
            vm.toString(registry.kindCount()),
            '. Nothing registered before moves.","txBuilderVersion":"1.17.0","createdFromSafeAddress":"',
            vm.toString(factory.owner()),
            '","createdFromOwnerAddress":""},"transactions":[',
            '{"to":"',
            to,
            '","value":"0","data":"',
            vm.toString(first),
            '","contractMethod":null,"contractInputsValues":null},',
            '{"to":"',
            to,
            '","value":"0","data":"',
            vm.toString(second),
            '","contractMethod":null,"contractInputsValues":null}]}'
        );
        string memory out = vm.envOr("SAFE_BATCH", string("deploy/safe-register-lot-reserve.json"));
        vm.writeFile(out, batch);
        console2.log("linked scheduler", address(LotReserveScheduler));
        console2.log("scheduler runtime hash");
        console2.logBytes32(address(LotReserveScheduler).codehash);
        console2.log("policy", policy);
        console2.log("chunks", a, b);
        console2.log("expected kind", registry.kindCount());
        console2.log("expected policy key");
        console2.logBytes32(expectedKey);
        console2.log("Safe batch written to", out);
    }

    function register(address operator, HedgeFunV2Factory factory, bytes32 dependencies, bytes32 audit)
        public
        returns (Registration memory r)
    {
        checkScheduler();
        V2TreasuryDeployer registry = _reviewedRegistry(factory);
        V2TreasuryUpgradeController controller = registry.upgradeController();
        if (
            operator == address(0) || dependencies == bytes32(0) || audit == bytes32(0) || factory.owner() != operator
                || registry.factory() != address(factory) || registry.kindCount() >= type(uint8).max
                || address(controller).code.length == 0 || controller.owner() != operator
                || controller.UPGRADE_DELAY() != 2 days
        ) revert BadBinding();
        vm.startBroadcast(operator);
        r.policy = address(new V2LotReservePolicy());
        r.policyKey = registry.registerPolicy(r.policy, MAX_GAS, MAX_RETURN_BYTES, dependencies, audit);
        (address a, address b) = _chunks(type(HedgeFunV2UpgradeableReserveTreasury).creationCode);
        r.kind = registry.registerEngineKind(
            a, b, LotReserveConfig.ENGINE_VERSION, LotReserveConfig.SCHEMA, LotReserveConfig.CAPABILITIES
        );
        vm.stopBroadcast();
        check(factory, r, dependencies, audit);
    }

    function check(HedgeFunV2Factory factory, Registration memory r, bytes32 dependencies, bytes32 audit) public view {
        checkScheduler();
        V2TreasuryDeployer registry = _reviewedRegistry(factory);
        if (registry.factory() != address(factory) || r.kind == 0 || dependencies == bytes32(0) || audit == bytes32(0)) revert BadReadback();
        (uint32 version, uint32 schema, bytes32 codeHash, uint256 capabilities) = registry.kindManifest(r.kind);
        (address a, address b) = registry.kinds(r.kind);
        if (
            version != LotReserveConfig.ENGINE_VERSION || schema != LotReserveConfig.SCHEMA
                || capabilities != LotReserveConfig.CAPABILITIES
                || codeHash != keccak256(type(HedgeFunV2UpgradeableReserveTreasury).creationCode)
                || keccak256(bytes.concat(a.code, b.code)) != codeHash
        ) revert BadReadback();
        PolicyManifest memory m = registry.policy(r.policyKey);
        bytes32 runtime = keccak256(type(V2LotReservePolicy).runtimeCode);
        if (
            m.implementation != r.policy || r.policy.codehash != runtime || m.runtimeCodeHash != runtime
                || m.engineVersion != LotReserveConfig.ENGINE_VERSION || m.configSchema != LotReserveConfig.SCHEMA
                || m.capabilities != LotReserveConfig.CAPABILITIES || m.maxGas != MAX_GAS
                || m.maxReturnBytes != MAX_RETURN_BYTES || !m.enabledForNewLaunches
                || registry.policyDependencyManifestHash(r.policyKey) != dependencies
                || registry.policyAuditManifestHash(r.policyKey) != audit
        ) revert BadReadback();
        V2TreasuryUpgradeController controller = registry.upgradeController();
        if (
            address(controller).code.length == 0 || controller.owner() != factory.owner()
                || controller.UPGRADE_DELAY() != 2 days
        ) {
            revert BadReadback();
        }
    }

    /// @notice Refuse missing or substituted linked code before creating chunks or verifying a registration.
    function checkScheduler() public view returns (address scheduler) {
        scheduler = address(LotReserveScheduler);
        bytes memory expected = type(LotReserveScheduler).runtimeCode;
        bytes memory actual = scheduler.code;
        // Solidity libraries embed their deployed address in the initial PUSH20 delegatecall guard.
        if (expected.length < 21 || actual.length != expected.length || expected[0] != bytes1(0x73)) {
            revert BadBinding();
        }
        bytes20 self = bytes20(scheduler);
        for (uint256 i; i < 20; ++i) {
            expected[i + 1] = self[i];
        }
        if (keccak256(actual) != keccak256(expected)) revert BadBinding();
    }

    function _chunks(bytes memory code) private returns (address a, address b) {
        uint256 half = code.length / 2;
        bytes memory left = new bytes(half);
        bytes memory right = new bytes(code.length - half);
        assembly ("memory-safe") {
            mcopy(add(left, 32), add(code, 32), half)
            mcopy(add(right, 32), add(add(code, 32), half), mload(right))
        }
        a = address(new V2InitCodeChunk(left));
        b = address(new V2InitCodeChunk(right));
    }
}

contract VerifyV2LotReserve is Script {
    function run() external {
        uint256 kind = vm.envUint("LOT_RESERVE_KIND");
        require(kind <= type(uint8).max, "kind id overflow");
        new RegisterV2LotReserve()
            .check(
                HedgeFunV2Factory(vm.envAddress("V2_FACTORY")),
                RegisterV2LotReserve.Registration(
                    uint8(kind), vm.envBytes32("LOT_RESERVE_POLICY_KEY"), vm.envAddress("LOT_RESERVE_POLICY")
                ),
                vm.envBytes32("DEPENDENCY_MANIFEST_HASH"),
                vm.envBytes32("AUDIT_MANIFEST_HASH")
            );
    }
}
