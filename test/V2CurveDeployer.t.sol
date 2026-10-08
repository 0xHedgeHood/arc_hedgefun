// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {HedgeFunFactory, TokenDeployer} from "../src/HedgeFunFactory.sol";
import {BoundDeployer} from "../src/HedgeFunDeployers.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {CurveDeployer} from "../src/v2/CurveDeployer.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {V2LiquidityVault} from "../src/v2/V2LiquidityVault.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

/// The curve's creation code moved out of `CurveDeployer`'s runtime into a chunk the deployer creates in its own
/// constructor, to make room under EIP-170. These pin what that move must not change: the bytes a curve is created
/// from, every CREATE2 address derived from them, and who may use the deployer.
contract V2CurveDeployerTest is V2FactoryFixture {
    using PoolIdLibrary for PoolKey;

    address internal stranger = address(uint160(uint256(keccak256("curve deployer stranger"))));

    function setUp() public {
        _setUpV2(18);
    }

    function test_curveChunkIsTheCompilersCurveCreationCode() public view {
        address chunk = factory.curveDeployer().curveChunk();
        assertEq(chunk.code.length, type(HedgeFunBondingCurve).creationCode.length);
        assertEq(keccak256(chunk.code), keccak256(type(HedgeFunBondingCurve).creationCode));
        // The room the chunk made: with the curve's creation code embedded again this module would not fit.
        assertGt(address(factory.curveDeployer()).code.length + chunk.code.length
            + factory.curveDeployer().vaultChunk().code.length, 24_576);
    }


    function test_vaultChunkIsExactAndWithinRuntimeLimit() public view {
        address chunk = factory.curveDeployer().vaultChunk();
        assertEq(keccak256(chunk.code), keccak256(type(V2LiquidityVault).creationCode));
        assertLe(chunk.code.length, 24_576);
    }

    /// The addresses are recomputed here from `type(...).creationCode`, the derivation the deployer used before the
    /// chunk existed, and must equal both the deployer's own predictions and what was actually deployed.
    function test_predictedCurveAndVaultAreTheDeployedAddresses() public {
        HedgeFunFactory.Request memory q = _request();
        address predicted = factory.predictCurve(q);
        (,, bytes32 terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        assertEq(address(curve), predicted, "factory.predictCurve");

        HedgeFunBondingCurve.Init memory p = HedgeFunBondingCurve.Init({
            factory: address(factory), token: curve.token(), stock: curve.stock(), treasury: curve.treasury(),
            protocol: curve.protocol(), creator: curve.creator(), supply: curve.initialSupply(),
            virtualStock: curve.virtualStock(), saleBps: factory.curveDeployer().DEFAULT_SALE_BPS(), taxBps: curve.taxBps(),
            protocolBps: curve.protocolBps(), creatorBps: curve.creatorBps(), snipeBps: curve.snipeBps(),
            snipeSeconds: curve.snipeSeconds(), openingTaxExemptions: new address[](0)
        });
        CurveDeployer d = factory.curveDeployer();
        bytes32 salt = keccak256(abi.encode(q.symbol, q.creator, q.nonce));
        bytes32 curveInitHash = keccak256(abi.encodePacked(type(HedgeFunBondingCurve).creationCode, abi.encode(p)));
        assertEq(address(curve), vm.computeCreate2Address(salt, curveInitHash, address(d)), "independent CREATE2");
        assertEq(d.predict(salt, abi.encode(p)), address(curve), "deployer.predict");

        (PoolKey memory key,) = factory.graduationConfig(id);
        bytes memory vaultArgs = abi.encode(address(factory), pm, key, curve.token(), address(stock), curve.treasury());
        address vault = vm.computeCreate2Address(
            bytes32(id), keccak256(abi.encodePacked(type(V2LiquidityVault).creationCode, vaultArgs)), address(d)
        );
        assertEq(vault.code.length, 0);
        stock.approve(address(curve), type(uint256).max);
        _graduateV2(curve);
        assertEq(hook.liquidityVaultOf(key.toId()), vault, "graduated vault");
        assertEq(V2LiquidityVault(vault).factory(), address(factory));
        assertTrue(V2LiquidityVault(vault).seeded());
    }

    function test_onlyTheBoundFactoryCanUseTheDeployer() public {
        CurveDeployer d = factory.curveDeployer();
        assertEq(d.factory(), address(factory));
        bytes memory args = abi.encode(_init());
        vm.startPrank(stranger);
        vm.expectRevert(BoundDeployer.AlreadyBound.selector);
        d.bind();
        vm.expectRevert(BoundDeployer.NotFactory.selector);
        d.deploy(bytes32(uint256(1)), args);
        vm.expectRevert(BoundDeployer.NotFactory.selector);
        d.deployVault(bytes32(uint256(1)), args);
        vm.expectRevert(BoundDeployer.NotFactory.selector);
        d.executeGraduation(0, uint160(1 << 96), 1, 1);
        vm.stopPrank();
        assertEq(d.factory(), address(factory));
    }

    /// The chunk is data. Called directly it runs the curve's constructor with no constructor arguments in its own
    /// code, which cannot decode, so every call reverts and nothing it holds can be changed.
    function test_curveChunkIsInertWhenCalled() public {
        address chunk = factory.curveDeployer().curveChunk();
        bytes32 codeHash = chunk.codehash;
        vm.startPrank(stranger);
        (bool ok,) = chunk.call("");
        assertFalse(ok);
        (ok,) = chunk.call(abi.encode(_init()));
        assertFalse(ok);
        vm.stopPrank();
        assertEq(chunk.codehash, codeHash);
    }

    /// Binding is first-caller-wins, as for every `BoundDeployer`: a deployer someone else claimed fails the factory
    /// constructor loudly, before anything is live, and the Safe deploys a fresh one.
    function test_frontRunBindFailsTheFactoryConstructor() public {
        CurveDeployer d = new CurveDeployer(7931);
        assertEq(d.factory(), address(0));
        assertEq(keccak256(d.curveChunk().code), keccak256(type(HedgeFunBondingCurve).creationCode));
        vm.prank(stranger);
        d.bind();
        address treasuryDeployer = address(new V2TreasuryDeployer());
        address tokenDeployer = address(new TokenDeployer());
        address freshHook = address(_deployV2Hook(pm));
        vm.expectRevert(BoundDeployer.AlreadyBound.selector);
        new HedgeFunV2Factory(owner, address(pm), address(v3f), address(usdg), protocol,
            treasuryDeployer, tokenDeployer, freshHook, address(d), _defaults());
    }

    function _init() private view returns (HedgeFunBondingCurve.Init memory p) {
        p = HedgeFunBondingCurve.Init({
            factory: address(factory), token: address(usdg), stock: address(stock), treasury: address(this),
            protocol: protocol, creator: address(this), supply: 1_000_000e18, virtualStock: 50e18, saleBps: 8000,
            taxBps: 1000, protocolBps: 2000, creatorBps: 1000, snipeBps: 9900, snipeSeconds: 3,
            openingTaxExemptions: new address[](0)
        });
    }
}
