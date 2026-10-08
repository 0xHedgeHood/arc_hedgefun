// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {V2TreasuryDeployer, V2InitCodeChunk} from "../src/v2/V2TreasuryDeployer.sol";
import {V2TreasuryUpgradeController} from "../src/v2/V2TreasuryUpgradeController.sol";
import {HedgeFunV2UpgradeableCycleTreasury} from "../src/v2/HedgeFunV2UpgradeableCycleTreasury.sol";
import {ReviewedTreasuryRegistry} from "./helpers/ReviewedTreasuryRegistry.sol";

/// @notice Append the upgradeable cycle strategy kind for FUTURE launches on a reviewed factory.
/// @dev Three operator transactions: two code chunks the operator creates, then the registration. The kind id
///      comes from the result, never from a constant.
contract RegisterV2UpgradeableCycle is ReviewedTreasuryRegistry {
    error BadBinding();
    error BadReadback();

    function run() external returns (uint8 kind) {
        address operator = vm.envAddress("OPERATOR");
        if (operator == address(0) || msg.sender != operator) revert BadBinding();
        kind = register(operator, HedgeFunV2Factory(vm.envAddress("V2_FACTORY")));
        console2.log("upgradeable cycle strategy kind", kind);
        console2.log("simulation readback passed; verify three receipts and live state after broadcast");
    }

    function register(address operator, HedgeFunV2Factory factory) public returns (uint8 kind) {
        V2TreasuryDeployer registry = _reviewedRegistry(factory);
        V2TreasuryUpgradeController controller = registry.upgradeController();
        if (
            operator == address(0) || factory.owner() != operator || registry.kindCount() >= type(uint8).max
                || controller.owner() != operator || controller.UPGRADE_DELAY() != 2 days
        ) revert BadBinding();
        bytes memory code = type(HedgeFunV2UpgradeableCycleTreasury).creationCode;
        uint256 half = code.length / 2;
        bytes memory left = new bytes(half);
        bytes memory right = new bytes(code.length - half);
        assembly ("memory-safe") {
            mcopy(add(left, 32), add(code, 32), half)
            mcopy(add(right, 32), add(add(code, 32), half), mload(right))
        }
        vm.startBroadcast(operator);
        // operator CREATEs: the registry's public makeChunks would let anyone move these addresses
        kind = registry.registerKind(address(new V2InitCodeChunk(left)), address(new V2InitCodeChunk(right)));
        vm.stopBroadcast();
        check(factory, kind);
    }

    function check(HedgeFunV2Factory factory, uint8 kind) public view {
        V2TreasuryDeployer registry = _reviewedRegistry(factory);
        if (kind == 0) revert BadReadback();
        (uint32 version, uint32 schema, bytes32 hash, uint256 capabilities) = registry.kindManifest(kind);
        (address a, address b) = registry.kinds(kind);
        if (
            version != 0 || schema != 0 || capabilities != 0
                || hash != keccak256(type(HedgeFunV2UpgradeableCycleTreasury).creationCode)
                || keccak256(bytes.concat(a.code, b.code)) != hash
        ) revert BadReadback();
    }
}

contract VerifyV2UpgradeableCycle is Script {
    function run() external {
        uint256 kind = vm.envUint("UPGRADEABLE_CYCLE_KIND");
        require(kind <= type(uint8).max, "kind id overflow");
        new RegisterV2UpgradeableCycle().check(HedgeFunV2Factory(vm.envAddress("V2_FACTORY")), uint8(kind));
    }
}
