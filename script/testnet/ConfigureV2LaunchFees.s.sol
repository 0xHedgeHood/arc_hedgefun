// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {HedgeFunFactory} from "../../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {V2LaunchFeeDefaults} from "./V2LaunchFeeDefaults.sol";

/// @notice Update future-launch fees on a reviewed V2 testnet factory; no redeployment or implementation upgrade.
/// @dev EXPECTED_DEFAULTS_HASH pins the complete snapshot reviewed before broadcast. Re-read immediately before
///      sending: setDefaults itself has no compare-and-set guard. Never run alongside another owner operation.
contract ConfigureV2LaunchFees is Script {
    function run() external {
        require(block.chainid == 46630, "testnet only");
        HedgeFunV2Factory factory = HedgeFunV2Factory(vm.envAddress("V2_FACTORY"));
        address operator = vm.envAddress("OPERATOR");
        require(msg.sender == operator && factory.owner() == operator, "factory owner only");
        require(address(factory.curveDeployer()).code.length != 0, "V2 factory required");
        HedgeFunFactory.Defaults memory d = factory.getDefaults();
        require(keccak256(abi.encode(d)) == vm.envBytes32("EXPECTED_DEFAULTS_HASH"), "defaults changed");
        d = V2LaunchFeeDefaults.applyTo(d);
        vm.startBroadcast(operator);
        factory.setDefaults(d);
        vm.stopBroadcast();
        require(keccak256(abi.encode(factory.getDefaults())) == keccak256(abi.encode(d)), "readback failed");
    }
}
