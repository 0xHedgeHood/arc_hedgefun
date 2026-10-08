// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IncomeKindCompatibility} from "./IncomeKindCompatibility.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {V2TreasuryDeployer} from "../../src/v2/V2TreasuryDeployer.sol";
import {V2TreasuryUpgradeController} from "../../src/v2/V2TreasuryUpgradeController.sol";
import {HedgeFunV2UpgradeableTreasury} from "../../src/v2/HedgeFunV2UpgradeableTreasury.sol";

/// @dev Exact registry/controller runtimes, with every immutable bound. The controller is the reviewed #25
/// runtime. The registry is that runtime with two constants changed, neither covered by the #25 review:
/// `DEFAULT_LP_BPS` 7000 in place of 5000, and the spot engine's minimum cooldown 60 in place of 600, which is one
/// byte shorter and moves the second kind-zero reference from 7163 to 7162. A #25 registry is therefore refused here.
/// Getter values alone do not prove that a controller enforces a delay. Different
/// compiler/runtime builds need a separately reviewed template update.
abstract contract ReviewedTreasuryRegistry is IncomeKindCompatibility {
    error IncompatibleTreasuryRegistry();

    /// @dev The kind-0 creation code the reviewed #25 registries were deployed with. Pinned: this source's own
    ///      kind 0 moves whenever the shared treasury base does, and a registry keeps the code it was built with.
    bytes32 internal constant REVIEWED_KIND_ZERO = 0x09fb34de0fb09901d28f6ccc1cd6a344471209deb9153d8a4801d48f7e47062e;

    function _reviewedRegistry(HedgeFunV2Factory factory) internal view returns (V2TreasuryDeployer registry) {
        _checkIncomeCompatibility(factory);
        registry = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        if (registry.factory() != address(factory)) revert IncompatibleTreasuryRegistry();
        V2TreasuryUpgradeController controller = registry.upgradeController();
        bytes memory code = vm.getDeployedCode("V2TreasuryDeployer.sol:V2TreasuryDeployer");
        if (keccak256(code) != 0x652ca39277dc7b2259bc3ab9ccbfc6a5c04b576618514d888170a3113aed7a12) {
            revert IncompatibleTreasuryRegistry();
        }
        // The reviewed deployment's kind 0, or this source's own for a registry deployed from it.
        bytes32 trigger = registry.allInTriggerCodeHash();
        if (trigger != REVIEWED_KIND_ZERO && trigger != keccak256(type(HedgeFunV2UpgradeableTreasury).creationCode)) {
            revert IncompatibleTreasuryRegistry();
        }
        _bindWord(code, 1335, trigger);
        _bindWord(code, 7162, trigger);
        _bindWord(code, 975, bytes32(uint256(uint160(address(controller)))));
        if (keccak256(code) != address(registry).codehash) revert IncompatibleTreasuryRegistry();
        code = vm.getDeployedCode("V2TreasuryUpgradeController.sol:V2TreasuryUpgradeController");
        if (keccak256(code) != 0x6506bf8c847967c042988fa140a0673ffc0e8338e300850707a0d06f670bc930) {
            revert IncompatibleTreasuryRegistry();
        }
        _bindWord(code, 1856, bytes32(uint256(uint160(address(registry)))));
        if (keccak256(code) != address(controller).codehash) revert IncompatibleTreasuryRegistry();
    }

    function _bindWord(bytes memory code, uint256 offset, bytes32 value) private pure {
        if (offset == 0 || offset + 32 > code.length || code[offset - 1] != bytes1(0x7f)) {
            revert IncompatibleTreasuryRegistry();
        }
        bytes32 before;
        assembly ("memory-safe") { before := mload(add(add(code, 32), offset)) }
        if (before != bytes32(0)) revert IncompatibleTreasuryRegistry();
        assembly ("memory-safe") { mstore(add(add(code, 32), offset), value) }
    }
}
