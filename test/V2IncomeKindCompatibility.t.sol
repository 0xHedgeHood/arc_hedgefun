// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {CurveDeployer} from "../src/v2/CurveDeployer.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {RegisterV2IncomeKinds} from "../script/RegisterV2IncomeKinds.s.sol";
import {IncomeKindCompatibility} from "../script/helpers/IncomeKindCompatibility.sol";
import {V2IncomeKindsFixture} from "./V2IncomeKinds.t.sol";

contract IncomeCompatibilityHarness is IncomeKindCompatibility {
    function check(HedgeFunV2Factory factory) external view { _checkIncomeCompatibility(factory); }
    function factoryRuntime(HedgeFunV2Factory factory) external view returns (bytes memory) {
        return _factoryRuntime(factory);
    }
    function curveRuntime(CurveDeployer curve) external view returns (bytes memory) { return _curveRuntime(curve); }
}

/// Getters return the reviewed deployment's values, but this contract has entirely different executable code.
contract FakeIncomeFactoryGetters {
    address private immutable target;
    constructor(address target_) { target = target_; }
    fallback(bytes calldata input) external returns (bytes memory output) {
        (bool ok, bytes memory result) = target.staticcall(input);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        return result;
    }
}

contract V2IncomeKindCompatibilityTest is V2IncomeKindsFixture {
    function test_runtimeTemplatesReconstructEveryImmutableAcrossDifferentDeployments() public {
        IncomeCompatibilityHarness h = new IncomeCompatibilityHarness();
        address firstFactory = address(factory);
        address firstModule = address(factory.curveDeployer());
        assertEq(keccak256(h.factoryRuntime(factory)), firstFactory.codehash);
        assertEq(keccak256(h.curveRuntime(factory.curveDeployer())), firstModule.codehash);
        h.check(factory);
        // A second valid deployment changes every address-bound immutable; no address allowlist is needed.
        _setUpV2(6);
        assertTrue(address(factory) != firstFactory);
        assertTrue(address(factory.curveDeployer()) != firstModule);
        assertEq(keccak256(h.factoryRuntime(factory)), address(factory).codehash);
        assertEq(keccak256(h.curveRuntime(factory.curveDeployer())), address(factory.curveDeployer()).codehash);
        RegisterV2IncomeKinds.Kinds memory next = script.register(owner, factory);
        script.check(V2TreasuryDeployer(address(factory.treasuryDeployer())), next);
    }

    function test_forgedGettersDoNotApproveUnreviewedFactoryCode() public {
        HedgeFunV2Factory fake = HedgeFunV2Factory(address(new FakeIncomeFactoryGetters(address(factory))));
        // Simulate a registry that reports the forged binding too; getter agreement still is not code identity.
        vm.mockCall(address(deployer), abi.encodeWithSelector(deployer.factory.selector), abi.encode(address(fake)));
        uint256 before = deployer.kindCount();
        vm.expectRevert(_error("factory runtime"));
        script.register(owner, fake);
        vm.expectRevert(_error("factory runtime"));
        script.check(deployer, kinds);
        vm.clearMockedCalls();
        assertEq(deployer.kindCount(), before);
    }

    function test_everyFactoryImmutableReferenceIsCheckedNotOnlyTheGetter() public {
        bytes memory offsets = hex"06ea0dcc0e830f720fe5107719f4047515c0078e15ef19c437e105361cc6370f382e027e07f409511dab22d902b10a0d223404a823e9256739963a1105a908941bfb1e57282029ec340a34b935b83865";
        _rejectEachImmutable(address(factory), offsets, "factory runtime");
    }

    function test_everyGraduationModuleImmutableReferenceIncludingPrivateSelfIsChecked() public {
        _rejectEachImmutable(address(factory.curveDeployer()), hex"09830d36014d11c401e208e801bb04b6118f", "graduation module runtime");
    }

    function test_readbackRepeatsFactoryCompatibilityCheck() public {
        _flip(address(factory), 2196 + 31);
        vm.expectRevert(_error("factory runtime"));
        script.check(deployer, kinds);
    }

    function test_registryCountUnchangedAfterIncompatibleModuleRejected() public {
        uint256 before = deployer.kindCount();
        _flip(address(factory.curveDeployer()), 2435 + 31); // one private SELF reference only
        vm.expectRevert(_error("graduation module runtime"));
        script.register(owner, factory);
        assertEq(deployer.kindCount(), before);
    }

    function test_moduleMustBeBoundToThisFactory() public {
        CurveDeployer curve = factory.curveDeployer();
        vm.mockCall(address(curve), abi.encodeWithSelector(curve.factory.selector), abi.encode(address(0xBAD)));
        vm.expectRevert(_error("graduation module binding"));
        script.register(owner, factory);
        vm.clearMockedCalls();
    }

    function test_curveCreationChunkMustMatchReviewedCode() public {
        uint256 before = deployer.kindCount();
        vm.etch(factory.curveDeployer().curveChunk(), hex"6000");
        vm.expectRevert(_error("curve creation code"));
        script.register(owner, factory);
        assertEq(deployer.kindCount(), before);
    }

    function test_vaultCreationChunkMustMatchReviewedCode() public {
        uint256 before = deployer.kindCount();
        vm.etch(factory.curveDeployer().vaultChunk(), hex"6000");
        vm.expectRevert(_error("vault creation code"));
        script.register(owner, factory);
        assertEq(deployer.kindCount(), before);
    }

    function _rejectEachImmutable(address target, bytes memory offsets, string memory component) private {
        IncomeCompatibilityHarness h = new IncomeCompatibilityHarness();
        bytes memory original = target.code;
        for (uint256 i; i < offsets.length; i += 2) {
            uint256 offset = (uint256(uint8(offsets[i])) << 8) | uint256(uint8(offsets[i + 1]));
            _flip(target, offset + 31);
            vm.expectRevert(_error(component));
            h.check(factory);
            vm.etch(target, original);
        }
        h.check(factory);
    }

    function _flip(address target, uint256 offset) private {
        bytes memory code = target.code;
        code[offset] = bytes1(uint8(code[offset]) ^ 1);
        vm.etch(target, code);
    }

    function _error(string memory component) private pure returns (bytes memory) {
        return abi.encodeWithSelector(IncomeKindCompatibility.IncompatibleIncomeDeployment.selector, component);
    }
}

/// Only registration compatibility is exercised here; the separate 16-case suite covers the new factory lifecycle.
/// Both tests use one pinned block and an in-memory fork; no key or broadcast is involved.
contract TestnetV2IncomeCompatibilityForkTest is Test {
    function setUp() public {
        vm.skip(!vm.envOr("INCOME_COMPAT_FORK", false), "set INCOME_COMPAT_FORK=true");
        uint256 atBlock = vm.envUint("INCOME_COMPAT_FORK_BLOCK");
        emit log_named_uint("compatibility fork block", atBlock);
        vm.createSelectFork(
            vm.envOr("INCOME_COMPAT_FORK_RPC", string("https://rpc.testnet.chain.robinhood.com")), atBlock
        );
        assertEq(block.chainid, 46630);
    }

    function test_fork_legacyFactoryRejectsBeforeRegistrationAndDuringReadback() public {
        HedgeFunV2Factory old = HedgeFunV2Factory(0xACEB03aAeE5494Aa54929Ec840630ae32A9ade0A);
        V2TreasuryDeployer registry = V2TreasuryDeployer(address(old.treasuryDeployer()));
        RegisterV2IncomeKinds script = new RegisterV2IncomeKinds();
        uint256 before = registry.kindCount();
        address owner = old.owner();
        bytes memory expected = abi.encodeWithSelector(
            IncomeKindCompatibility.IncompatibleIncomeDeployment.selector, "factory runtime");
        vm.expectRevert(expected);
        script.register(owner, old);
        assertEq(registry.kindCount(), before, "no kinds published on incompatible legacy factory");
        RegisterV2IncomeKinds.Kinds memory none;
        vm.expectRevert(expected);
        script.check(registry, none);
    }

    function test_fork_reviewedFactoryAcceptsRegistrationAndReadback() public {
        HedgeFunV2Factory factory = HedgeFunV2Factory(vm.envOr("V2_FACTORY", address(0x6847318D28aB2f9343DDd2067871DC4f48609383)));
        V2TreasuryDeployer registry = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        RegisterV2IncomeKinds script = new RegisterV2IncomeKinds();
        uint256 before = registry.kindCount();
        RegisterV2IncomeKinds.Kinds memory kinds = script.register(factory.owner(), factory);
        assertEq(registry.kindCount(), before + 4);
        script.check(registry, kinds);
    }
}
