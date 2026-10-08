// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {RegisterV2TradablePercent} from "../script/RegisterV2TradablePercent.s.sol";
import {ReviewedTreasuryRegistry} from "../script/helpers/ReviewedTreasuryRegistry.sol";

contract MisleadingDelayController {
    function owner() external pure returns (address) {
        return address(0xA11CE);
    }

    function UPGRADE_DELAY() external pure returns (uint256) {
        return 2 days;
    }
}

contract V2TradablePercentRegistrationTest is V2FactoryFixture {
    RegisterV2TradablePercent private tool;
    V2TreasuryDeployer private registry;
    bytes32 private constant DEPS = keccak256("test-only dependencies");
    bytes32 private constant AUDIT = keccak256("test-only evidence, not production sign-off");

    function setUp() public {
        _setUpV2(18);
        registry = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        tool = new RegisterV2TradablePercent();
    }

    function test_appendAndExactReadbackLeaveExistingKindUnchanged() public {
        (address a, address b) = registry.kinds(0);
        (,, bytes32 beforeHash,) = registry.kindManifest(0);
        RegisterV2TradablePercent.Registration memory r = tool.register(owner, factory, DEPS, AUDIT);
        assertEq(r.kind, 1);
        assertEq(registry.kindCount(), 2);
        tool.check(factory, r, DEPS, AUDIT);
        (address nextA, address nextB) = registry.kinds(0);
        (,, bytes32 afterHash,) = registry.kindManifest(0);
        assertEq(a, nextA);
        assertEq(b, nextB);
        assertEq(beforeHash, afterHash);
        assertEq(registry.policyDependencyManifestHash(r.policyKey), DEPS);
        assertEq(registry.policyAuditManifestHash(r.policyKey), AUDIT);
    }

    function test_publicRegistryNonceCannotRedirectFiveOperatorTransactions() public {
        vm.setNonce(owner, 19);
        registry.makeChunks(hex"60006000");
        RegisterV2TradablePercent.Registration memory r = tool.register(owner, factory, DEPS, AUDIT);
        assertEq(r.policy, vm.computeCreateAddress(owner, 19));
        (address a, address b) = registry.kinds(r.kind);
        assertEq(a, vm.computeCreateAddress(owner, 21));
        assertEq(b, vm.computeCreateAddress(owner, 22));
        assertEq(vm.getNonce(owner), 24);
    }

    function test_invalidAuthorityOrMissingEvidenceRejectedBeforeRegistration() public {
        vm.expectRevert(RegisterV2TradablePercent.BadBinding.selector);
        tool.register(address(0xBAD), factory, DEPS, AUDIT);
        vm.expectRevert(RegisterV2TradablePercent.BadBinding.selector);
        tool.register(owner, factory, DEPS, 0);
        assertEq(registry.kindCount(), 1);
    }

    function test_readbackRejectsDisabledPolicyAndFalseEvidence() public {
        RegisterV2TradablePercent.Registration memory r = tool.register(owner, factory, DEPS, AUDIT);
        vm.expectRevert(RegisterV2TradablePercent.BadReadback.selector);
        tool.check(factory, r, DEPS, keccak256("different audit"));
        vm.prank(owner);
        registry.disablePolicy(r.policyKey);
        vm.expectRevert(RegisterV2TradablePercent.BadReadback.selector);
        tool.check(factory, r, DEPS, AUDIT);
    }

    function test_readbackRejectsReplacedKindChunksOrPolicyCode() public {
        RegisterV2TradablePercent.Registration memory r = tool.register(owner, factory, DEPS, AUDIT);
        bytes memory original = r.policy.code;
        vm.etch(r.policy, hex"60006000");
        vm.expectRevert(RegisterV2TradablePercent.BadReadback.selector);
        tool.check(factory, r, DEPS, AUDIT);
        vm.etch(r.policy, original);
        (address a,) = registry.kinds(r.kind);
        vm.etch(a, hex"60006000");
        vm.expectRevert(RegisterV2TradablePercent.BadReadback.selector);
        tool.check(factory, r, DEPS, AUDIT);
    }

    function test_matchingDelayGettersDoNotSubstituteForControllerCode() public {
        address controller = address(registry.upgradeController());
        vm.etch(controller, address(new MisleadingDelayController()).code);
        vm.expectRevert(ReviewedTreasuryRegistry.IncompatibleTreasuryRegistry.selector);
        tool.register(owner, factory, DEPS, AUDIT);
        assertEq(registry.kindCount(), 1);
    }
}
