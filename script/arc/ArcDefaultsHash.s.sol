// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ArcDefaults} from "./ArcDefaults.sol";

/// @notice Prints EXPECTED_DEFAULTS_HASH for `DeployArcCore`: `keccak256(abi.encode(ArcDefaults.release()))`.
contract ArcDefaultsHash is Script {
    function run() external pure {
        console2.log("ARC_DEFAULTS_HASH", vm.toString(keccak256(abi.encode(ArcDefaults.release()))));
    }
}
