// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {PolicyManifest} from "../src/v2/strategy/IStrategyPolicy.sol";
import {V2RebalancePolicy} from "../src/v2/strategy/V2RebalancePolicy.sol";
import {ReviewedTreasuryRegistry} from "./helpers/ReviewedTreasuryRegistry.sol";

/// @notice Register the schema-1 policy the spot engine (kind 2) launches with, on a reviewed factory.
/// @dev Two operator transactions: the policy, its registration. Kind 2 must already be registered
///      (`RegisterV2UpgradeableKinds`); without this policy no kind-2 launch can be configured. The testnet
///      deployments and the mainnet end-to-end test make this call inline; this is the same call as a script,
///      with the readback the other registrations have. Manifest hashes must describe this actual candidate.
contract RegisterV2RebalancePolicy is ReviewedTreasuryRegistry {
    uint32 public constant MAX_GAS = 150_000;
    uint16 public constant MAX_RETURN_BYTES = 160;

    struct Registration {
        uint8 kind;        // the engine kind the policy serves: schema 1
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
        console2.log("product profile: strategy/spot-engine (schema 1)");
        console2.log("serves kind", r.kind);
        console2.log("policy", r.policy);
        console2.logBytes32(r.policyKey);
        console2.log("simulation only unless --broadcast; verify live receipts before enabling kind 2 in the UI");
    }

    function register(address operator, HedgeFunV2Factory factory, bytes32 dependencies, bytes32 audit)
        public
        returns (Registration memory r)
    {
        V2TreasuryDeployer registry = _reviewedRegistry(factory);
        r.kind = _schemaOneKind(registry);
        if (
            operator == address(0) || dependencies == bytes32(0) || audit == bytes32(0) || factory.owner() != operator
                || registry.factory() != address(factory) || r.kind == 0
        ) revert BadBinding();
        vm.startBroadcast(operator);
        r.policy = address(new V2RebalancePolicy());
        r.policyKey = registry.registerPolicy(r.policy, MAX_GAS, MAX_RETURN_BYTES, dependencies, audit);
        vm.stopBroadcast();
        check(factory, r, dependencies, audit);
    }

    function check(HedgeFunV2Factory factory, Registration memory r, bytes32 dependencies, bytes32 audit) public view {
        V2TreasuryDeployer registry = _reviewedRegistry(factory);
        if (
            registry.factory() != address(factory) || r.kind == 0 || r.kind != _schemaOneKind(registry)
                || dependencies == bytes32(0) || audit == bytes32(0)
        ) revert BadReadback();
        PolicyManifest memory m = registry.policy(r.policyKey);
        bytes32 expectedRuntime = keccak256(type(V2RebalancePolicy).runtimeCode);
        if (
            m.implementation != r.policy || r.policy.codehash != expectedRuntime || m.runtimeCodeHash != expectedRuntime
                || m.engineVersion != 1 || m.configSchema != 1 || m.capabilities != 3 || m.maxGas != MAX_GAS
                || m.maxReturnBytes != MAX_RETURN_BYTES || !m.enabledForNewLaunches
                || registry.policyDependencyManifestHash(r.policyKey) != dependencies
                || registry.policyAuditManifestHash(r.policyKey) != audit
                || r.policyKey
                    != keccak256(
                        abi.encode(
                            r.policy, expectedRuntime, uint32(1), uint32(1), uint256(3), MAX_GAS, MAX_RETURN_BYTES, dependencies, audit
                        )
                    )
        ) revert BadReadback();
    }

    /// @dev the one registered kind whose config schema is 1: the spot engine, kind 2 on every deployment so far
    function _schemaOneKind(V2TreasuryDeployer registry) private view returns (uint8 found) {
        uint256 count = registry.kindCount();
        for (uint256 i = 1; i < count; ++i) {
            (uint32 version, uint32 schema,,) = registry.kindManifest(uint8(i));
            if (schema == 1) {
                if (found != 0 || version != 1) return 0;
                found = uint8(i);
            }
        }
    }
}

contract VerifyV2RebalancePolicy is Script {
    function run() external {
        uint256 kind = vm.envUint("REBALANCE_POLICY_KIND");
        require(kind <= type(uint8).max, "kind id overflow");
        new RegisterV2RebalancePolicy()
            .check(
                HedgeFunV2Factory(vm.envAddress("V2_FACTORY")),
                RegisterV2RebalancePolicy.Registration(
                    uint8(kind), vm.envBytes32("REBALANCE_POLICY_KEY"), vm.envAddress("REBALANCE_POLICY")
                ),
                vm.envBytes32("DEPENDENCY_MANIFEST_HASH"),
                vm.envBytes32("AUDIT_MANIFEST_HASH")
            );
    }
}
