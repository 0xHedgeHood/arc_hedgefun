// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {HedgeFunFactory} from "../../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {V2MainnetDefaults} from "./V2MainnetDefaults.sol";

/// @notice Bring a live mainnet factory's defaults to the defaults file's, for future launches. One owner
///         transaction. The live snapshot and the target are both pinned by hash, so what is sent is what was
///         reviewed on both sides; the readback requires the chain to carry the target afterwards.
/// @dev OPERATOR must be the factory owner (the deployer before the hand-over, the Safe after).
///      V2_FACTORY OPERATOR EXPECTED_DEFAULTS_HASH=<live now> EXPECTED_NEW_DEFAULTS_HASH=<V2MainnetDefaults.release()>
contract ApplyV2MainnetDefaults is Script {
    function run() external {
        require(block.chainid == 4663, "mainnet only");
        HedgeFunV2Factory factory = HedgeFunV2Factory(vm.envAddress("V2_FACTORY"));
        address operator = vm.envAddress("OPERATOR");
        require(msg.sender == operator && factory.owner() == operator, "factory owner only");
        require(address(factory.curveDeployer()).code.length != 0, "V2 factory required");
        HedgeFunFactory.Defaults memory live = factory.getDefaults();
        require(keccak256(abi.encode(live)) == vm.envBytes32("EXPECTED_DEFAULTS_HASH"), "live defaults changed");
        HedgeFunFactory.Defaults memory target = V2MainnetDefaults.release();
        bytes32 targetHash = keccak256(abi.encode(target));
        require(targetHash == vm.envBytes32("EXPECTED_NEW_DEFAULTS_HASH"), "target is not the reviewed one");
        require(targetHash != keccak256(abi.encode(live)), "nothing to apply");
        console2.log("maxCreatorBps live, target", uint256(live.maxCreatorBps), uint256(target.maxCreatorBps));
        console2.log("new defaults hash");
        console2.logBytes32(targetHash);
        vm.startBroadcast(operator);
        factory.setDefaults(target);
        vm.stopBroadcast();
        require(keccak256(abi.encode(factory.getDefaults())) == targetHash, "readback failed");
    }
}
