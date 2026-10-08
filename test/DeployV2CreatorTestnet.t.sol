// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployV2CreatorTestnet} from "../script/testnet/DeployV2CreatorTestnet.s.sol";
import {DeployV2FeeUpgradeTestnet} from "../script/testnet/DeployV2FeeUpgradeTestnet.s.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {HedgeFunV2UpgradeableBuybackTreasury} from "../src/v2/HedgeFunV2UpgradeableBuybackTreasury.sol";
import {HedgeFunV2UpgradeableEngineTreasury} from "../src/v2/HedgeFunV2UpgradeableEngineTreasury.sol";

contract CreatorRegistrationOwner {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function bind(V2TreasuryDeployer registry) external {
        registry.bind();
    }
}

contract CreatorRegistrationHarness is DeployV2CreatorTestnet {
    function writeDryCandidate() external {
        Deployment memory x;
        _writeCandidate(x, block.number, false, "947b1f8a35c2cb4f79908e8886c9aee7ef03a7ae");
    }

    function registerOnly(V2TreasuryDeployer registry) external {
        Deployment memory x;
        x.treasury = registry;
        vm.startBroadcast(OPERATOR);
        _register(x);
        vm.stopBroadcast();
    }
}

contract DeployV2CreatorTestnetTest is Test {
    function test_publicChunkNonceInterferenceCannotChangeCreatorRegistrations() public {
        CreatorRegistrationHarness tool = new CreatorRegistrationHarness();
        V2TreasuryDeployer registry = new V2TreasuryDeployer();
        new CreatorRegistrationOwner(tool.OPERATOR()).bind(registry);
        vm.setNonce(tool.OPERATOR(), 11);
        uint256 operatorNonce = vm.getNonce(tool.OPERATOR());

        // A third party occupies both addresses the registry's public helper would have produced next.
        address attacker = makeAddr("chunk-nonce-attacker");
        vm.prank(attacker);
        (address injectedA, address injectedB) = registry.makeChunks(hex"60006000");
        assertEq(injectedA.code, hex"6000");
        assertEq(injectedB.code, hex"6000");
        assertEq(vm.getNonce(tool.OPERATOR()), operatorNonce);

        tool.registerOnly(registry);
        (address buybackA, address buybackB) = registry.kinds(1);
        (address engineA, address engineB) = registry.kinds(2);
        // Chunks originate directly from operator CREATEs; registry nonce interference is irrelevant.
        assertEq(buybackA, vm.computeCreateAddress(tool.OPERATOR(), operatorNonce));
        assertEq(buybackB, vm.computeCreateAddress(tool.OPERATOR(), operatorNonce + 1));
        assertEq(engineA, vm.computeCreateAddress(tool.OPERATOR(), operatorNonce + 5));
        assertEq(engineB, vm.computeCreateAddress(tool.OPERATOR(), operatorNonce + 6));
        assertEq(vm.getNonce(tool.OPERATOR()), operatorNonce + 8);
        assertEq(bytes.concat(buybackA.code, buybackB.code), type(HedgeFunV2UpgradeableBuybackTreasury).creationCode);
        assertEq(bytes.concat(engineA.code, engineB.code), type(HedgeFunV2UpgradeableEngineTreasury).creationCode);
        (,, bytes32 buybackHash,) = registry.kindManifest(1);
        (,, bytes32 engineHash,) = registry.kindManifest(2);
        assertEq(buybackHash, keccak256(type(HedgeFunV2UpgradeableBuybackTreasury).creationCode));
        assertEq(engineHash, keccak256(type(HedgeFunV2UpgradeableEngineTreasury).creationCode));
        assertEq(registry.kindCount(), 3);
        assertEq(tool.plannedTransactionCount(), 40);
        assertEq(new DeployV2FeeUpgradeTestnet().plannedTransactionCount(), 38);
    }

    function test_creatorCandidateHasSeparateFeatureAndFortyUnverifiedTransactions() public {
        CreatorRegistrationHarness tool = new CreatorRegistrationHarness();
        tool.writeDryCandidate();
        string memory json = vm.readFile("deploy/testnet-v2-creator.dryrun.json");
        assertEq(vm.parseJsonUint(json, ".plannedTransactionCount"), 40);
        assertEq(vm.parseJsonString(json, ".featureVersion"), "v2-creator-selected-stock-fees-v2");
        assertFalse(vm.parseJsonBool(json, ".broadcast"));
        assertFalse(vm.parseJsonBool(json, ".broadcastRequested"));
    }
}
