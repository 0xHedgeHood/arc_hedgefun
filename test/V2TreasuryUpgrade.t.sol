// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {V2LiquidityVault} from "../src/v2/V2LiquidityVault.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {V2TreasuryUpgradeController, IV2TreasuryProxy} from "../src/v2/V2TreasuryUpgradeController.sol";
import {HedgeFunV2UpgradeableTreasury, HedgeFunV2UpgradeableTreasuryLogic} from "../src/v2/HedgeFunV2UpgradeableTreasury.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

contract NextTreasuryLogic is HedgeFunV2UpgradeableTreasuryLogic {
    uint256 public distributionEpoch;
    bool public replaySucceeded;
    // A deliberately minimal migration-test implementation; production strategy continuity is tested separately.
    function execute() external pure override returns (Action, uint256) { revert UseExecute(); }
    error MigrationRejected();
    constructor(address u, address s, address venue, address o, address t, address pm, address f, Params memory p)
        HedgeFunV2UpgradeableTreasuryLogic(u, s, venue, o, t, pm, f, p) {}
    function migrate(uint256 epoch) external {
        require(msg.sender == IV2TreasuryProxy(address(this)).treasuryUpgradeController(), "controller only");
        distributionEpoch = epoch;
        address control = IV2TreasuryProxy(address(this)).treasuryUpgradeController();
        (replaySucceeded,) = control.call(abi.encodeCall(V2TreasuryUpgradeController.execute,
            (address(this), abi.encodeCall(this.migrate, (epoch)))));
    }
    function rejectMigration() external pure { revert MigrationRejected(); }
    function probeVault(address vault) external returns (bool ok) {
        (ok,) = vault.call(abi.encodeCall(V2LiquidityVault.unlockCallback, (bytes("withdraw"))));
    }
    function scribbleImplementationSlot(address value) external {
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        assembly ("memory-safe") { sstore(slot, value) }
    }
}

contract V2TreasuryUpgradeTest is V2FactoryFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    V2TreasuryUpgradeController private controller;
    HedgeFunV2UpgradeableTreasury private proxy;
    HedgeFunV2Treasury private treasury;
    HedgeFunBondingCurve private curve;
    PoolKey private key;

    function setUp() public {
        _setUpV2(18);
        (, curve, key) = _launchV2(true);
        treasury = HedgeFunV2Treasury(curve.treasury());
        proxy = HedgeFunV2UpgradeableTreasury(payable(address(treasury)));
        controller = V2TreasuryDeployer(address(factory.treasuryDeployer())).upgradeController();
    }

    function _next(address projectToken) private returns (NextTreasuryLogic) {
        NextTreasuryLogic next = new NextTreasuryLogic(address(usdg), address(stock), address(stockPool), address(oracle), projectToken,
            address(pm), address(factory), treasury.params());
        assertLe(address(next).code.length, 24_576, "migration test candidate must be deployable");
        return next;
    }

    function _schedule(NextTreasuryLogic next, bytes memory data) private {
        vm.prank(owner);
        controller.schedule(address(proxy), address(next), data);
    }

    function test_productionBytecodeFitsEvmDeploymentLimits() public {
        _graduateV2(curve);
        V2TreasuryDeployer deployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        assertLe(address(deployer).code.length, 24_576, "registry runtime");
        assertLe(address(factory).code.length, 24_576, "factory runtime");
        assertLe(address(factory.curveDeployer()).code.length, 24_576, "curve module runtime");
        assertLe(address(proxy).code.length, 24_576, "proxy runtime");
        assertLe(proxy.initialImplementation().code.length, 24_576, "logic runtime");
        assertLe(address(controller).code.length, 24_576, "controller runtime");
        assertLe(treasury.liquidityVault().code.length, 24_576, "LP vault runtime");
        (address a, address b) = deployer.kinds(0);
        assertLe(a.code.length, 24_576, "first code chunk");
        assertLe(b.code.length, 24_576, "second code chunk");
        assertLe(vm.getCode("V2TreasuryDeployer.sol:V2TreasuryDeployer").length, 49_152, "registry initcode");
        assertLe(vm.getCode("CurveDeployer.sol:CurveDeployer").length, 49_152, "curve module initcode");
        bytes memory args = abi.encode(address(usdg), address(stock), address(stockPool), address(oracle),
            curve.token(), address(pm), address(factory), treasury.params());
        assertLe(vm.getCode("HedgeFunV2UpgradeableTreasury.sol:HedgeFunV2UpgradeableTreasury").length
            + args.length, 49_152, "proxy initcode plus args");
        assertLe(vm.getCode("HedgeFunV2UpgradeableTreasury.sol:HedgeFunV2UpgradeableTreasuryLogic").length
            + args.length, 49_152, "logic initcode plus args");
    }

    function test_defaultLaunchUsesInitializedProxyAndLockedImplementation() public {
        assertEq(address(proxy.treasuryUpgradeController()), address(controller));
        assertEq(controller.owner(), owner);
        assertEq(controller.UPGRADE_DELAY(), 2 days);
        assertEq(proxy.implementation(), proxy.initialImplementation());
        assertEq(address(treasury.token()), curve.token());
        assertEq(treasury.factory(), address(factory));
        HedgeFunTreasuryBase.Params memory p = treasury.params();
        address initial = proxy.initialImplementation();
        assertEq(p.tp1Bps, _request().tp1Bps);
        vm.expectRevert(HedgeFunV2UpgradeableTreasuryLogic.InvalidInitialization.selector);
        HedgeFunV2UpgradeableTreasuryLogic(address(proxy)).initializeProxy(p);
        vm.expectRevert(HedgeFunV2UpgradeableTreasuryLogic.InvalidInitialization.selector);
        HedgeFunV2UpgradeableTreasuryLogic(initial).initializeProxy(p);
    }

    function test_upgradePreservesAccountingAndAddsFutureDistributionState() public {
        _graduateV2(curve);
        uint256 principal = treasury.bookedStock();
        uint256 balance = stock.balanceOf(address(treasury));
        uint256 supply = IERC20(curve.token()).totalSupply();
        bytes32 paramsHash = keccak256(abi.encode(treasury.params()));
        address vault = treasury.liquidityVault();
        NextTreasuryLogic next = _next(curve.token());
        bytes memory migration = abi.encodeCall(NextTreasuryLogic.migrate, (17));
        _schedule(next, migration);
        vm.expectRevert(V2TreasuryUpgradeController.NotReady.selector);
        controller.execute(address(proxy), migration);
        vm.warp(block.timestamp + 2 days);
        controller.execute(address(proxy), migration);
        assertEq(proxy.implementation(), address(next));
        assertEq(NextTreasuryLogic(address(proxy)).distributionEpoch(), 17);
        assertFalse(NextTreasuryLogic(address(proxy)).replaySucceeded());
        assertEq(treasury.bookedStock(), principal);
        assertEq(stock.balanceOf(address(treasury)), balance);
        assertEq(IERC20(curve.token()).totalSupply(), supply);
        assertEq(keccak256(abi.encode(treasury.params())), paramsHash);
        assertEq(treasury.liquidityVault(), vault);
        assertEq(treasury.lotCount(), 1);
        vm.expectRevert(V2TreasuryUpgradeController.NotReady.selector);
        controller.execute(address(proxy), migration);
        // Pointer storage is independent of the proxy's delegatecall storage.
        NextTreasuryLogic(address(proxy)).scribbleImplementationSlot(address(0xBAD));
        assertEq(proxy.implementation(), address(next));
    }

    function test_upgradeToOrdinaryCoreKeepsStrategyBookingAvailable() public {
        _graduateV2(curve);
        uint256 principal = treasury.bookedStock();
        HedgeFunV2UpgradeableTreasuryLogic next = new HedgeFunV2UpgradeableTreasuryLogic(
            address(usdg), address(stock), address(stockPool), address(oracle), curve.token(),
            address(pm), address(factory), treasury.params());
        assertLe(address(next).code.length, 24_576);
        vm.prank(owner);
        controller.schedule(address(proxy), address(next), "");
        vm.warp(block.timestamp + 2 days);
        controller.execute(address(proxy), "");
        assertEq(treasury.bookedStock(), principal);
        assertEq(treasury.lotCount(), 1);
        // The same initialized strategy surface survives a real, deployable implementation replacement.
        assertEq(address(treasury.token()), curve.token());
        assertEq(treasury.factory(), address(factory));
        assertEq(treasury.buybackStock(), 0);
        stockFeed.set(100e8);
        usdgFeed.set(1e8);
        stock.mint(address(treasury), 1e18);
        assertTrue(treasury.book());
        assertEq(treasury.bookedStock(), principal + 1e18);
    }

    function test_upgradeCannotGiveTreasuryTheLockedLpPosition() public {
        _graduateV2(curve);
        V2LiquidityVault vault = V2LiquidityVault(treasury.liquidityVault());
        NextTreasuryLogic next = _next(curve.token());
        _schedule(next, "");
        vm.warp(block.timestamp + 2 days);
        controller.execute(address(proxy), "");
        assertFalse(NextTreasuryLogic(address(proxy)).probeVault(address(vault)));
        (uint128 base,,) = pm.getPositionInfo(key.toId(), address(vault),
            TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), bytes32(0));
        (uint128 extra,,) = pm.getPositionInfo(key.toId(), address(vault),
            vault.surplusTickLower(), vault.surplusTickUpper(), bytes32(uint256(1)));
        assertGt(base, 0);
        assertEq(extra, vault.surplusLiquidity());
        assertGt(extra, 0);
    }

    function test_onlyOwnerSchedulesAndCancelsAndCannotSkipNotice() public {
        NextTreasuryLogic next = _next(curve.token());
        vm.expectRevert(V2TreasuryUpgradeController.NotOwner.selector);
        controller.schedule(address(proxy), address(next), "");
        _schedule(next, "");
        vm.prank(owner);
        vm.expectRevert(V2TreasuryUpgradeController.NotReady.selector);
        controller.execute(address(proxy), "");
        vm.expectRevert(V2TreasuryUpgradeController.NotOwner.selector);
        controller.cancel(address(proxy));
        vm.prank(owner);
        controller.cancel(address(proxy));
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(V2TreasuryUpgradeController.NotReady.selector);
        controller.execute(address(proxy), "");
        vm.expectRevert(HedgeFunV2UpgradeableTreasury.NotUpgradeController.selector);
        proxy.applyUpgrade("");
    }

    function test_rejectsAnotherTokensImplementation() public {
        NextTreasuryLogic next = _next(address(0x1234));
        vm.prank(owner);
        vm.expectRevert(V2TreasuryUpgradeController.InvalidUpgrade.selector);
        controller.schedule(address(proxy), address(next), "");
    }

    function test_commitsMigrationCalldataAndRuntimeCode() public {
        NextTreasuryLogic next = _next(curve.token());
        bytes memory data = abi.encodeCall(NextTreasuryLogic.migrate, (17));
        _schedule(next, data);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(V2TreasuryUpgradeController.InvalidUpgrade.selector);
        controller.execute(address(proxy), abi.encodeCall(NextTreasuryLogic.migrate, (18)));
        vm.etch(address(next), hex"00");
        vm.expectRevert(V2TreasuryUpgradeController.InvalidUpgrade.selector);
        controller.execute(address(proxy), data);
        assertEq(proxy.implementation(), proxy.initialImplementation());
    }

    function test_failedMigrationRollsBackPointerAndKeepsProposal() public {
        NextTreasuryLogic next = _next(curve.token());
        bytes memory data = abi.encodeCall(NextTreasuryLogic.rejectMigration, ());
        _schedule(next, data);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(NextTreasuryLogic.MigrationRejected.selector);
        controller.execute(address(proxy), data);
        assertEq(proxy.implementation(), proxy.initialImplementation());
        (address pending,,,, uint256 readyAt) = controller.proposals(address(proxy));
        assertEq(pending, address(next));
        assertGt(readyAt, 0);
    }

    function test_ownerTransferInvalidatesPriorOwnersProposal() public {
        NextTreasuryLogic next = _next(curve.token());
        _schedule(next, "");
        address successor = address(0x123);
        vm.prank(owner);
        factory.transferOwnership(successor);
        vm.prank(successor);
        factory.acceptOwnership();
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(V2TreasuryUpgradeController.InvalidUpgrade.selector);
        controller.execute(address(proxy), "");
    }

    function test_ownerRoundTripPermanentlyInvalidatesProposalAndRequiresFreshDelay() public {
        NextTreasuryLogic next = _next(curve.token());
        _schedule(next, "");
        uint256 epoch = factory.ownershipEpoch();
        address successor = address(0x123);
        vm.prank(owner);
        factory.transferOwnership(successor);
        vm.prank(successor);
        factory.acceptOwnership();
        vm.warp(block.timestamp + 2 days);
        vm.prank(successor);
        factory.transferOwnership(owner);
        vm.prank(owner);
        factory.acceptOwnership();
        assertEq(factory.ownershipEpoch(), epoch + 2);
        vm.expectRevert(V2TreasuryUpgradeController.InvalidUpgrade.selector);
        controller.execute(address(proxy), "");
        assertEq(proxy.implementation(), proxy.initialImplementation());

        _schedule(next, "");
        vm.warp(block.timestamp + 2 days - 1);
        vm.expectRevert(V2TreasuryUpgradeController.NotReady.selector);
        controller.execute(address(proxy), "");
        vm.warp(block.timestamp + 1);
        controller.execute(address(proxy), "");
        assertEq(proxy.implementation(), address(next));
    }

    function test_unacceptedOrCancelledHandoverDoesNotInvalidateProposal() public {
        NextTreasuryLogic next = _next(curve.token());
        _schedule(next, "");
        uint256 epoch = factory.ownershipEpoch();
        vm.prank(owner);
        factory.transferOwnership(address(0x123));
        assertEq(factory.ownershipEpoch(), epoch);
        vm.prank(owner);
        factory.transferOwnership(address(0));
        assertEq(factory.ownershipEpoch(), epoch);
        vm.warp(block.timestamp + 2 days);
        controller.execute(address(proxy), "");
        assertEq(proxy.implementation(), address(next));
    }
}
