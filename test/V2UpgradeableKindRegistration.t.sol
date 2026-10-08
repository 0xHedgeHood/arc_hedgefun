// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {HedgeFunV2BuybackTreasury} from "../src/v2/HedgeFunV2BuybackTreasury.sol";
import {HedgeFunV2EngineTreasury} from "../src/v2/HedgeFunV2EngineTreasury.sol";
import {HedgeFunV2UpgradeableBuybackTreasury} from "../src/v2/HedgeFunV2UpgradeableBuybackTreasury.sol";
import {HedgeFunV2UpgradeableEngineTreasury} from "../src/v2/HedgeFunV2UpgradeableEngineTreasury.sol";
import {RegisterV2UpgradeableKinds} from "../script/RegisterV2UpgradeableKinds.s.sol";
import {ReviewedTreasuryRegistry} from "../script/helpers/ReviewedTreasuryRegistry.sol";
import {MisleadingDelayController} from "./V2TradablePercentRegistration.t.sol";

contract V2UpgradeableKindRegistrationTest is V2FactoryFixture {
    RegisterV2UpgradeableKinds private tool;
    V2TreasuryDeployer private registry;

    function setUp() public {
        _setUpV2(18);
        registry = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        tool = new RegisterV2UpgradeableKinds();
    }

    function test_freshRegistryUsesUpgradeableKindsOneAndTwo() public {
        RegisterV2UpgradeableKinds.Kinds memory k = tool.register(owner, factory);
        assertEq(k.buyback, 1);
        assertEq(k.engine, 2);
        assertEq(registry.kindCount(), 3);
        tool.check(registry, k);
        (,, bytes32 buybackHash,) = registry.kindManifest(1);
        (,, bytes32 engineHash,) = registry.kindManifest(2);
        assertEq(buybackHash, keccak256(type(HedgeFunV2UpgradeableBuybackTreasury).creationCode));
        assertEq(engineHash, keccak256(type(HedgeFunV2UpgradeableEngineTreasury).creationCode));
    }

    function test_existingImmutableKindsArePreservedAndNewIdsAreReturned() public {
        (address a, address b) = registry.makeChunks(type(HedgeFunV2BuybackTreasury).creationCode);
        vm.prank(owner);
        assertEq(registry.registerKind(a, b), 1);
        (a, b) = registry.makeChunks(type(HedgeFunV2EngineTreasury).creationCode);
        vm.prank(owner);
        assertEq(registry.registerEngineKind(a, b, 1, 1, 3), 2);
        bytes32[3] memory before;
        for (uint8 i; i < 3; ++i) {
            (,, before[i],) = registry.kindManifest(i);
        }
        RegisterV2UpgradeableKinds.Kinds memory k = tool.register(owner, factory);
        assertEq(k.buyback, 3);
        assertEq(k.engine, 4);
        assertEq(registry.kindCount(), 5);
        for (uint8 i; i < 3; ++i) {
            (,, bytes32 hash,) = registry.kindManifest(i);
            assertEq(hash, before[i], "registration changed an existing kind");
        }
        tool.check(registry, k);
    }

    function test_publicRegistryNonceCannotSubstituteOperatorChunks() public {
        vm.setNonce(owner, 11);
        vm.prank(address(0xBAD));
        registry.makeChunks(hex"60006000");
        RegisterV2UpgradeableKinds.Kinds memory k = tool.register(owner, factory);
        (address a, address b) = registry.kinds(k.buyback);
        assertEq(a, vm.computeCreateAddress(owner, 11));
        assertEq(b, vm.computeCreateAddress(owner, 12));
        (a, b) = registry.kinds(k.engine);
        assertEq(a, vm.computeCreateAddress(owner, 14));
        assertEq(b, vm.computeCreateAddress(owner, 15));
        assertEq(vm.getNonce(owner), 17);
        tool.check(registry, k);
    }

    function test_matchingDelayGettersDoNotSubstituteForControllerCode() public {
        RegisterV2UpgradeableKinds.Kinds memory k = tool.register(owner, factory);
        uint256 count = registry.kindCount();
        vm.etch(address(registry.upgradeController()), address(new MisleadingDelayController()).code);
        vm.expectRevert(ReviewedTreasuryRegistry.IncompatibleTreasuryRegistry.selector);
        tool.register(owner, factory);
        assertEq(registry.kindCount(), count, "nothing registered behind an unreviewed controller");
        vm.expectRevert(ReviewedTreasuryRegistry.IncompatibleTreasuryRegistry.selector);
        tool.check(registry, k);
    }

    function test_wrongOperatorRejectedBeforeAnyRegistration() public {
        uint256 before = registry.kindCount();
        vm.expectRevert(RegisterV2UpgradeableKinds.BadBinding.selector);
        tool.register(address(0xBAD), factory);
        assertEq(registry.kindCount(), before);
    }

    function test_readbackRejectsWrongKindFamilyAndCode() public {
        RegisterV2UpgradeableKinds.Kinds memory k = tool.register(owner, factory);
        vm.expectRevert(RegisterV2UpgradeableKinds.BadReadback.selector);
        tool.check(registry, RegisterV2UpgradeableKinds.Kinds(k.engine, k.buyback));
        (address a,) = registry.kinds(k.engine);
        vm.etch(a, hex"6000");
        vm.expectRevert(RegisterV2UpgradeableKinds.BadReadback.selector);
        tool.check(registry, k);
    }
}
