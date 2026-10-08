// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {V2TreasuryDeployer, V2InitCodeChunk} from "../src/v2/V2TreasuryDeployer.sol";
import {V2TreasuryUpgradeController} from "../src/v2/V2TreasuryUpgradeController.sol";
import {PolicyManifest} from "../src/v2/strategy/IStrategyPolicy.sol";
import {HedgeFunV2TradablePercentEngineTreasury} from "../src/v2/HedgeFunV2TradablePercentEngineTreasury.sol";
import {V2TradablePercentRebalancePolicy} from "../src/v2/strategy/V2TradablePercentRebalancePolicy.sol";
import {ReviewedTreasuryRegistry} from "./helpers/ReviewedTreasuryRegistry.sol";

/// @notice Register the strategy/rebalance product profile for future launches on a reviewed factory.
/// @dev Five operator transactions: policy, policy registration, two code chunks, kind registration.
/// Never overwrite an existing kind. Source/audit manifest hashes must describe this actual candidate.
contract RegisterV2TradablePercent is ReviewedTreasuryRegistry {
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
        console2.log("product profile: strategy/rebalance/continuous");
        console2.log("registered kind", r.kind);
        console2.log("policy", r.policy);
        console2.logBytes32(r.policyKey);
        console2.log("simulation only unless --broadcast; verify live receipts and profile before enabling UI");
    }

    function register(address operator, HedgeFunV2Factory factory, bytes32 dependencies, bytes32 audit)
        public
        returns (Registration memory r)
    {
        V2TreasuryDeployer registry = _reviewedRegistry(factory);
        V2TreasuryUpgradeController controller = registry.upgradeController();
        if (
            operator == address(0) || dependencies == bytes32(0) || audit == bytes32(0) || factory.owner() != operator
                || registry.factory() != address(factory) || registry.kindCount() >= type(uint8).max
                || address(controller).code.length == 0 || controller.owner() != operator
                || controller.UPGRADE_DELAY() != 2 days
        ) revert BadBinding();
        vm.startBroadcast(operator);
        r.policy = address(new V2TradablePercentRebalancePolicy());
        r.policyKey = registry.registerPolicy(r.policy, 400_000, 160, dependencies, audit);
        (address a, address b) = _chunks(type(HedgeFunV2TradablePercentEngineTreasury).creationCode);
        r.kind = registry.registerEngineKind(a, b, 1, 3, 3);
        vm.stopBroadcast();
        check(factory, r, dependencies, audit);
    }

    function check(HedgeFunV2Factory factory, Registration memory r, bytes32 dependencies, bytes32 audit) public view {
        V2TreasuryDeployer registry = _reviewedRegistry(factory);
        if (registry.factory() != address(factory) || r.kind == 0 || dependencies == bytes32(0) || audit == bytes32(0)) revert BadReadback();
        (uint32 version, uint32 schema, bytes32 codeHash, uint256 capabilities) = registry.kindManifest(r.kind);
        (address a, address b) = registry.kinds(r.kind);
        if (
            version != 1 || schema != 3 || capabilities != 3
                || codeHash != keccak256(type(HedgeFunV2TradablePercentEngineTreasury).creationCode)
                || keccak256(bytes.concat(a.code, b.code)) != codeHash
        ) revert BadReadback();
        _checkPolicy(registry, r, dependencies, audit);
        V2TreasuryUpgradeController controller = registry.upgradeController();
        if (
            address(controller).code.length == 0 || controller.owner() != factory.owner()
                || controller.UPGRADE_DELAY() != 2 days
        ) revert BadReadback();
    }

    function _checkPolicy(V2TreasuryDeployer registry, Registration memory r, bytes32 dependencies, bytes32 audit)
        private
        view
    {
        PolicyManifest memory m = registry.policy(r.policyKey);
        bytes32 expectedRuntime = keccak256(type(V2TradablePercentRebalancePolicy).runtimeCode);
        if (
            m.implementation != r.policy || r.policy.codehash != expectedRuntime || m.runtimeCodeHash != expectedRuntime
                || m.engineVersion != 1 || m.configSchema != 3 || m.capabilities != 3 || m.maxGas != 400_000
                || m.maxReturnBytes != 160 || !m.enabledForNewLaunches
                || registry.policyDependencyManifestHash(r.policyKey) != dependencies
                || registry.policyAuditManifestHash(r.policyKey) != audit
                || r.policyKey
                    != keccak256(
                        abi.encode(
                            r.policy,
                            expectedRuntime,
                            uint32(1),
                            uint32(3),
                            uint256(3),
                            uint32(400_000),
                            uint16(160),
                            dependencies,
                            audit
                        )
                    )
        ) revert BadReadback();
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

contract VerifyV2TradablePercent is Script {
    function run() external {
        uint256 kind = vm.envUint("TRADABLE_PERCENT_KIND");
        require(kind <= type(uint8).max, "kind id overflow");
        new RegisterV2TradablePercent()
            .check(
                HedgeFunV2Factory(vm.envAddress("V2_FACTORY")),
                RegisterV2TradablePercent.Registration(
                    uint8(kind), vm.envBytes32("TRADABLE_PERCENT_POLICY_KEY"), vm.envAddress("TRADABLE_PERCENT_POLICY")
                ),
                vm.envBytes32("DEPENDENCY_MANIFEST_HASH"),
                vm.envBytes32("AUDIT_MANIFEST_HASH")
            );
    }
}
