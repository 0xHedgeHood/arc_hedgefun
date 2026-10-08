// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";

/// @notice Change the keeper reward (`bountyBps`) in a factory's defaults, for FUTURE launches.
/// @dev One owner transaction. `setDefaults` replaces the whole struct and has no compare-and-set guard, so this
///      writes back every other default as the simulation read it. Two things keep that from undoing another
///      owner change:
///
///       * `EXPECTED_DEFAULTS_HASH` pins the complete snapshot that was reviewed. A simulation against any other
///         state reverts `DefaultsChanged`, so a transaction is only ever built from the reviewed snapshot;
///       * the broadcast transaction still carries that snapshot. If another `setDefaults` lands between this
///         simulation and its broadcast, this one overwrites it. Never run it alongside another owner operation,
///         and run `VerifyV2KeeperReward` against the confirmed chain afterwards: the readback in `set` is the
///         simulation's and proves only that the factory accepted the struct.
///
///      A treasury freezes its reward at launch, so live treasuries keep theirs, and a launch quoted before this
///      transaction must be quoted again (the defaults are part of its terms).
///      Requires OPERATOR (the factory owner), V2_FACTORY, KEEPER_REWARD_BPS, EXPECTED_CHAIN_ID and
///      EXPECTED_DEFAULTS_HASH (`keccak256(abi.encode(factory.getDefaults()))` of the reviewed snapshot).
contract SetV2KeeperReward is Script {
    error BadBinding();
    error BadReadback();
    error DefaultsChanged();

    function run() external {
        address operator = vm.envAddress("OPERATOR");
        if (operator == address(0) || msg.sender != operator) revert BadBinding();
        if (block.chainid != vm.envUint("EXPECTED_CHAIN_ID")) revert BadBinding();
        uint256 bps = vm.envUint("KEEPER_REWARD_BPS");
        if (bps > type(uint16).max) revert BadBinding();
        (uint16 before, uint16 afterwards, bytes32 nextHash) = set(
            operator, HedgeFunV2Factory(vm.envAddress("V2_FACTORY")), uint16(bps), vm.envBytes32("EXPECTED_DEFAULTS_HASH")
        );
        console2.log("keeper reward bps, before", before);
        console2.log("keeper reward bps, now", afterwards);
        console2.log("defaults hash after this transaction, for VerifyV2KeeperReward:");
        console2.logBytes32(nextHash);
        console2.log("simulation only unless --broadcast; live treasuries keep the reward they launched with");
    }

    /// @dev `expectedDefaultsHash` is the hash of the complete defaults reviewed before this run; `nextHash` is
    ///      the hash the factory's defaults must have once the transaction is confirmed.
    function set(address operator, HedgeFunV2Factory factory, uint16 bps, bytes32 expectedDefaultsHash)
        public
        returns (uint16 before, uint16 afterwards, bytes32 nextHash)
    {
        if (
            address(factory).code.length == 0 || factory.owner() != operator
                || address(factory.curveDeployer()).code.length == 0
        ) revert BadBinding();
        HedgeFunFactory.Defaults memory d = factory.getDefaults();
        if (keccak256(abi.encode(d)) != expectedDefaultsHash) revert DefaultsChanged();
        before = d.bountyBps;
        d.bountyBps = bps;
        nextHash = keccak256(abi.encode(d));
        vm.startBroadcast(operator);
        factory.setDefaults(d);
        vm.stopBroadcast();
        if (keccak256(abi.encode(factory.getDefaults())) != nextHash) revert BadReadback();
        afterwards = bps;
    }
}

/// @notice Read-only confirmation against the confirmed chain, after the transaction above has landed.
/// @dev Requires V2_FACTORY, KEEPER_REWARD_BPS and EXPECTED_DEFAULTS_HASH_AFTER, the hash `SetV2KeeperReward`
///      logged. It fails if the reward is not the one asked for or if any other default differs from the snapshot
///      the change was built from, which is what a competing `setDefaults` would leave behind.
contract VerifyV2KeeperReward is Script {
    error BadReadback();

    function run() external view {
        check(
            HedgeFunV2Factory(vm.envAddress("V2_FACTORY")),
            vm.envUint("KEEPER_REWARD_BPS"),
            vm.envBytes32("EXPECTED_DEFAULTS_HASH_AFTER")
        );
    }

    function check(HedgeFunV2Factory factory, uint256 bps, bytes32 expectedDefaultsHashAfter) public view {
        HedgeFunFactory.Defaults memory d = factory.getDefaults();
        if (d.bountyBps != bps || keccak256(abi.encode(d)) != expectedDefaultsHashAfter) revert BadReadback();
    }
}
