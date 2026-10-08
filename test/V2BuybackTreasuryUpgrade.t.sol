// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2BuybackTreasury} from "../src/v2/HedgeFunV2BuybackTreasury.sol";
import {HedgeFunV2UpgradeableTreasuryLogic} from "../src/v2/HedgeFunV2UpgradeableTreasury.sol";
import {
    HedgeFunV2UpgradeableBuybackTreasury,
    HedgeFunV2UpgradeableBuybackTreasuryLogic
} from "../src/v2/HedgeFunV2UpgradeableBuybackTreasury.sol";
import {V2TreasuryUpgradeController, IV2TreasuryProxy} from "../src/v2/V2TreasuryUpgradeController.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {V2LiquidityVault} from "../src/v2/V2LiquidityVault.sol";
import {V2StakingIncome} from "../src/v2/V2StakingIncome.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

/// Keeps staking creation code outside the migration logic's runtime. The caller
/// is the proxy executing migration, so it becomes the immutable income source.
contract BuybackMigrationPoolFactory {
    function create(IERC20 token, IERC20 stock) external returns (V2StakingIncome) {
        return new V2StakingIncome(token, stock, msg.sender, 7 days, 7 days);
    }
}

/// Migration feasibility fixture, NOT a production dividend policy. All fields
/// append after protectedGraduationStock; existing assets/Params retain identity.
contract NextBuybackDividendLogic is HedgeFunV2UpgradeableBuybackTreasuryLogic {
    using SafeERC20 for IERC20;
    BuybackMigrationPoolFactory private immutable stakingFactory;
    V2StakingIncome public stakingIncome;
    uint256 public distributionEpoch;
    uint256 public totalDividend;
    bool public replaySucceeded;
    error AlreadyMigrated();
    error MigrationRejected();

    constructor(address u, address s, address venue, address o, address t, address pm, address f, Params memory p)
        HedgeFunV2UpgradeableBuybackTreasuryLogic(u, s, venue, o, t, pm, f, p)
    {
        stakingFactory = new BuybackMigrationPoolFactory();
    }

    function migrate(uint256 epoch, bool reject) external {
        address controller = IV2TreasuryProxy(address(this)).treasuryUpgradeController();
        require(msg.sender == controller, "controller only");
        if (address(stakingIncome) != address(0)) revert AlreadyMigrated();
        distributionEpoch = epoch;
        stakingIncome = stakingFactory.create(token, _stock);
        (replaySucceeded,) = controller.call(
            abi.encodeCall(
                V2TreasuryUpgradeController.execute, (address(this), abi.encodeCall(this.migrate, (epoch, reject)))
            )
        );
        if (reject) revert MigrationRejected();
    }

    function fundDividend(uint256 amount) external nonReentrant {
        require(address(stakingIncome) != address(0) && amount != 0 && amount <= buybackStock, "income only");
        buybackStock -= amount;
        totalDividend += amount;
        _stock.forceApprove(address(stakingIncome), amount);
        stakingIncome.fund(amount);
        _stock.forceApprove(address(stakingIncome), 0);
    }

    function migrationSlots() external pure returns (uint256 poolSlot, uint256 epochSlot) {
        assembly ("memory-safe") {
            poolSlot := stakingIncome.slot
            epochSlot := distributionEpoch.slot
        }
    }

    function probeVault(address vault) external returns (bool ok) {
        (ok,) = vault.call(abi.encodeCall(V2LiquidityVault.unlockCallback, (bytes("withdraw"))));
    }

    function scribbleImplementationSlot(address value) external {
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        assembly ("memory-safe") { sstore(slot, value) }
    }
}

contract V2BuybackTreasuryUpgradeTest is V2FactoryFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    V2TreasuryDeployer internal deployer;
    V2TreasuryUpgradeController internal controller;
    HedgeFunV2UpgradeableBuybackTreasury internal proxy;
    HedgeFunV2BuybackTreasury internal treasury;
    HedgeFunBondingCurve internal curve;
    PoolKey internal key;

    function setUp() public {
        _setUpV2(18);
        deployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        controller = deployer.upgradeController();
        (address a, address b) = deployer.makeChunks(type(HedgeFunV2UpgradeableBuybackTreasury).creationCode);
        vm.prank(owner);
        assertEq(deployer.registerKind(a, b), 1);
        HedgeFunFactory.Request memory q = _request();
        deployer.setStrategyKind(q.symbol, q.nonce, 1);
        (,, bytes32 terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        curve = HedgeFunBondingCurve(factory.curves(id));
        treasury = HedgeFunV2BuybackTreasury(curve.treasury());
        proxy = HedgeFunV2UpgradeableBuybackTreasury(payable(address(treasury)));
        (key,) = factory.graduationConfig(id);
        stock.approve(address(curve), type(uint256).max);
        vm.warp(curve.launchedAt() + curve.snipeSeconds());
    }

    function _next(address projectToken, HedgeFunTreasuryBase.Params memory p)
        internal
        returns (NextBuybackDividendLogic next)
    {
        next = new NextBuybackDividendLogic(
            address(usdg),
            address(stock),
            address(stockPool),
            address(oracle),
            projectToken,
            address(pm),
            address(factory),
            p
        );
        assertLe(address(next).code.length, 24_576, "migration candidate runtime must deploy");
    }

    function _schedule(address next, bytes memory data) internal {
        vm.prank(owner);
        controller.schedule(address(proxy), next, data);
    }

    function _migrate(NextBuybackDividendLogic next) internal {
        bytes memory data = abi.encodeCall(NextBuybackDividendLogic.migrate, (17, false));
        _schedule(address(next), data);
        vm.warp(block.timestamp + 2 days);
        controller.execute(address(proxy), data);
    }

    function _feeIncome(uint256 amount) internal {
        address vault = treasury.liquidityVault();
        stock.mint(vault, amount);
        vm.startPrank(vault);
        stock.approve(address(treasury), amount);
        treasury.creditLiquidityFee(amount);
        vm.stopPrank();
    }

    function _ledgerDigest() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                treasury.protectedGraduationStock(),
                treasury.bookedStock(),
                treasury.buybackStock(),
                treasury.totalStockReceived(),
                treasury.totalStockSpentOnBuybacks(),
                treasury.totalBurned(),
                treasury.liquidityVault(),
                treasury.hook(),
                keccak256(abi.encode(treasury.params())),
                stock.balanceOf(address(treasury)),
                IERC20(curve.token()).totalSupply()
            )
        );
    }

    function test_proxyConstructorMatchesAllInitialStorageAndLocksInitialization() public {
        address initial = proxy.initialImplementation();
        assertEq(proxy.implementation(), initial);
        assertEq(address(proxy.treasuryUpgradeController()), address(controller));
        assertEq(controller.UPGRADE_DELAY(), 2 days);
        // Includes PoolTrader's zero _swapping, the initialized ReentrancyGuard,
        // all Params slots, and the complete inherited buyback ledger.
        for (uint256 i; i < 64; ++i) {
            assertEq(vm.load(address(proxy), bytes32(i)), vm.load(initial, bytes32(i)));
        }
        assertEq(address(treasury.token()), curve.token());
        assertEq(treasury.factory(), address(factory));
        assertEq(address(treasury.stock()), address(stock));
        assertEq(address(treasury.usdg()), address(usdg));
        assertEq(address(treasury.pool()), address(stockPool));
        assertEq(address(treasury.oracle()), address(oracle));
        HedgeFunTreasuryBase.Params memory p = treasury.params();
        vm.expectRevert(HedgeFunV2UpgradeableBuybackTreasuryLogic.InvalidInitialization.selector);
        HedgeFunV2UpgradeableBuybackTreasuryLogic(address(proxy)).initializeProxy(p);
        vm.expectRevert(HedgeFunV2UpgradeableBuybackTreasuryLogic.InvalidInitialization.selector);
        HedgeFunV2UpgradeableBuybackTreasuryLogic(initial).initializeProxy(p);
        assertFalse(treasury.book());
    }

    function test_proxyAndLogicFitRuntimeAndInitcodeLimits() public {
        assertLe(address(proxy).code.length, 24_576);
        assertLe(proxy.initialImplementation().code.length, 24_576);
        bytes memory args = abi.encode(
            address(usdg),
            address(stock),
            address(stockPool),
            address(oracle),
            curve.token(),
            address(pm),
            address(factory),
            treasury.params()
        );
        assertLe(type(HedgeFunV2UpgradeableBuybackTreasury).creationCode.length + args.length, 49_152);
        assertLe(type(HedgeFunV2UpgradeableBuybackTreasuryLogic).creationCode.length + args.length, 49_152);
        (address a, address b) = deployer.kinds(1);
        assertLe(a.code.length, 24_576);
        assertLe(b.code.length, 24_576);
        _next(curve.token(), treasury.params());
    }

    function test_graduationAndIncomeKeepPrincipalProtectedThroughUpgrade() public {
        curve.buy(1e18, 1, address(this), block.timestamp);
        uint256 fees = curve.claimable(address(treasury));
        curve.claimFees(address(treasury));
        assertFalse(treasury.book());
        uint256 tokenSupply = IERC20(curve.token()).totalSupply();
        _graduateV2(curve);
        uint256 principal = stock.balanceOf(address(treasury)) - fees;
        assertGt(principal, 0);
        assertEq(treasury.protectedGraduationStock(), principal);
        assertEq(treasury.bookedStock(), principal);
        assertEq(treasury.buybackStock(), fees);
        assertEq(IERC20(curve.token()).totalSupply(), tokenSupply, "graduation cannot burn FUN");
        assertEq(treasury.lotCount(), 0);
        bytes32 beforeLedger = _ledgerDigest();
        NextBuybackDividendLogic next = _next(curve.token(), treasury.params());
        _migrate(next);
        assertEq(_ledgerDigest(), beforeLedger, "migration changed existing treasury accounting");
        stock.mint(address(proxy), 3e18);
        assertTrue(treasury.book());
        assertEq(treasury.buybackStock(), fees + 3e18);
        assertEq(treasury.bookedStock(), principal);
        assertEq(treasury.protectedGraduationStock(), principal);
        assertFalse(treasury.book(), "income cannot be recorded twice");
    }

    function test_failedOptionalGraduationBookStillCannotExposePrincipal() public {
        vm.mockCallRevert(address(treasury), abi.encodeWithSelector(treasury.book.selector), bytes("book failed"));
        _graduateV2(curve);
        vm.clearMockedCalls();
        uint256 principal = stock.balanceOf(address(treasury));
        assertEq(treasury.protectedGraduationStock(), principal);
        assertEq(treasury.buybackStock(), 0);
        stock.mint(address(treasury), 3e18);
        assertTrue(treasury.book());
        assertEq(treasury.buybackStock(), 3e18);
        assertEq(treasury.bookedStock(), principal);
    }

    function testFuzz_upgradePreservesPreclaimedFeesAndPendingIncome(
        uint96 beforeRaw,
        uint96 afterRaw,
        bool failOptionalBook
    ) public {
        uint256 beforeIncome = bound(uint256(beforeRaw), 0, 3e18);
        uint256 afterIncome = bound(uint256(afterRaw), 0, 3e18);
        curve.buy(1e18, 1, address(this), block.timestamp);
        beforeIncome += curve.claimable(address(treasury));
        curve.claimFees(address(treasury));
        if (beforeRaw != 0) stock.mint(address(treasury), bound(uint256(beforeRaw), 0, 3e18));
        if (failOptionalBook) {
            vm.mockCallRevert(address(treasury), abi.encodeWithSelector(treasury.book.selector), bytes("book failed"));
        }
        _graduateV2(curve);
        vm.clearMockedCalls();
        uint256 principal = stock.balanceOf(address(treasury)) - beforeIncome;
        bytes32 beforeLedger = _ledgerDigest();
        HedgeFunV2UpgradeableBuybackTreasuryLogic next = new HedgeFunV2UpgradeableBuybackTreasuryLogic(
            address(usdg),
            address(stock),
            address(stockPool),
            address(oracle),
            curve.token(),
            address(pm),
            address(factory),
            treasury.params()
        );
        _schedule(address(next), "");
        vm.warp(block.timestamp + 2 days);
        controller.execute(address(proxy), "");
        assertEq(_ledgerDigest(), beforeLedger);
        if (afterIncome != 0) stock.mint(address(treasury), afterIncome);
        treasury.book();
        assertEq(treasury.protectedGraduationStock(), principal);
        assertEq(treasury.bookedStock(), principal);
        assertEq(treasury.buybackStock(), beforeIncome + afterIncome);
        assertEq(treasury.totalStockReceived(), principal + beforeIncome + afterIncome);
        assertEq(treasury.unbookedStock(), 0);
        assertFalse(treasury.book(), "upgrade cannot enable duplicate income booking");
    }

    function test_buybackAndBurnRemainFunctionalAfterAnOrdinaryLogicUpgrade() public {
        _graduateV2(curve);
        uint256 principal = treasury.protectedGraduationStock();
        _feeIncome(100e18);
        (uint256 spent, uint256 burned) = treasury.buyback();
        assertGt(spent, 0);
        assertGt(burned, 0);
        bytes32 beforeLedger = _ledgerDigest();
        HedgeFunV2UpgradeableBuybackTreasuryLogic next = new HedgeFunV2UpgradeableBuybackTreasuryLogic(
            address(usdg),
            address(stock),
            address(stockPool),
            address(oracle),
            curve.token(),
            address(pm),
            address(factory),
            treasury.params()
        );
        _schedule(address(next), "");
        vm.warp(block.timestamp + 2 days);
        controller.execute(address(proxy), "");
        assertEq(_ledgerDigest(), beforeLedger);
        stockFeed.set(100e8);
        usdgFeed.set(1e8);
        uint256 supply = IERC20(curve.token()).totalSupply();
        uint256 budget = treasury.buybackStock();
        (uint256 spentAfter, uint256 burnedAfter) = treasury.buyback();
        assertGt(spentAfter, 0);
        assertGt(burnedAfter, 0);
        assertEq(treasury.buybackStock(), budget - spentAfter);
        assertEq(IERC20(curve.token()).totalSupply(), supply - burnedAfter);
        assertEq(treasury.protectedGraduationStock(), principal);
        assertEq(treasury.bookedStock(), principal);
        assertGe(stock.balanceOf(address(treasury)), principal);
        vm.expectRevert(HedgeFunTreasuryBase.Cooldown.selector);
        treasury.buyback();
        vm.expectRevert(HedgeFunV2BuybackTreasury.UseBuyback.selector);
        treasury.execute();
    }

    function test_dividendMigrationAppendsStorageAndUsesProxyAsIncomeSource() public {
        _graduateV2(curve);
        _feeIncome(10e18);
        uint256 principal = treasury.protectedGraduationStock();
        bytes32 beforeLedger = _ledgerDigest();
        NextBuybackDividendLogic next = _next(curve.token(), treasury.params());
        _migrate(next);
        assertEq(_ledgerDigest(), beforeLedger);
        NextBuybackDividendLogic upgraded = NextBuybackDividendLogic(address(proxy));
        assertEq(upgraded.distributionEpoch(), 17);
        assertFalse(upgraded.replaySucceeded(), "proposal replay through migration must fail");
        V2StakingIncome staking = upgraded.stakingIncome();
        assertEq(staking.incomeSource(), address(proxy));
        assertEq(address(staking.stakeToken()), curve.token());
        assertEq(address(staking.rewardToken()), address(stock));
        assertEq(address(next.stakingIncome()), address(0), "migration must not initialize implementation storage");
        address holder = address(0xB0B);
        IERC20(curve.token()).transfer(holder, 1e18);
        vm.startPrank(holder);
        IERC20(curve.token()).approve(address(staking), 1e18);
        staking.stake(1e18);
        vm.stopPrank();
        upgraded.fundDividend(7e18);
        assertEq(treasury.buybackStock(), 3e18);
        assertEq(treasury.bookedStock(), principal);
        assertEq(treasury.protectedGraduationStock(), principal);
        assertEq(stock.balanceOf(address(treasury)), principal + 3e18);
        assertEq(stock.allowance(address(proxy), address(staking)), 0);
        vm.prank(address(next));
        vm.expectRevert(V2StakingIncome.NotIncomeSource.selector);
        staking.fund(1);
        vm.expectRevert(bytes("income only"));
        upgraded.fundDividend(principal + 3e18);
        vm.warp(block.timestamp + 7 days);
        vm.prank(holder);
        assertApproxEqAbs(staking.claim(holder), 7e18, 1);
        assertEq(treasury.bookedStock(), principal);
        vm.expectRevert(bytes("controller only"));
        upgraded.migrate(99, false);
        bytes memory again = abi.encodeCall(NextBuybackDividendLogic.migrate, (99, false));
        _schedule(address(next), again);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(NextBuybackDividendLogic.AlreadyMigrated.selector);
        controller.execute(address(proxy), again);
        assertEq(upgraded.distributionEpoch(), 17);
    }

    function test_noticeOwnerCancelAndMigrationCommitmentCannotBeBypassed() public {
        NextBuybackDividendLogic next = _next(curve.token(), treasury.params());
        bytes memory data = abi.encodeCall(NextBuybackDividendLogic.migrate, (17, false));
        vm.expectRevert(V2TreasuryUpgradeController.NotOwner.selector);
        controller.schedule(address(proxy), address(next), data);
        _schedule(address(next), data);
        vm.warp(block.timestamp + 2 days - 1);
        vm.expectRevert(V2TreasuryUpgradeController.NotReady.selector);
        controller.execute(address(proxy), data);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(V2TreasuryUpgradeController.InvalidUpgrade.selector);
        controller.execute(address(proxy), abi.encodeCall(NextBuybackDividendLogic.migrate, (18, false)));
        vm.expectRevert(V2TreasuryUpgradeController.NotOwner.selector);
        controller.cancel(address(proxy));
        vm.prank(owner);
        controller.cancel(address(proxy));
        vm.expectRevert(V2TreasuryUpgradeController.NotReady.selector);
        controller.execute(address(proxy), data);
        vm.expectRevert(HedgeFunV2UpgradeableBuybackTreasury.NotUpgradeController.selector);
        proxy.applyUpgrade(data);
    }

    function test_wrongTokenParamsAndCrossKindImplementationsAreRejected() public {
        NextBuybackDividendLogic wrongToken = _next(address(0xBAD), treasury.params());
        vm.prank(owner);
        vm.expectRevert(V2TreasuryUpgradeController.InvalidUpgrade.selector);
        controller.schedule(address(proxy), address(wrongToken), "");
        HedgeFunTreasuryBase.Params memory changed = treasury.params();
        changed.tp1Bps += 10;
        NextBuybackDividendLogic wrongParams = _next(curve.token(), changed);
        vm.prank(owner);
        vm.expectRevert(V2TreasuryUpgradeController.InvalidUpgrade.selector);
        controller.schedule(address(proxy), address(wrongParams), "");
        HedgeFunV2UpgradeableTreasuryLogic wrongKind = new HedgeFunV2UpgradeableTreasuryLogic(
            address(usdg),
            address(stock),
            address(stockPool),
            address(oracle),
            curve.token(),
            address(pm),
            address(factory),
            treasury.params()
        );
        vm.prank(owner);
        vm.expectRevert(V2TreasuryUpgradeController.InvalidUpgrade.selector);
        controller.schedule(address(proxy), address(wrongKind), "");
    }

    function test_failedMigrationRollsBackStoragePointerAndProposalConsumption() public {
        _graduateV2(curve);
        _feeIncome(10e18);
        bytes32 beforeLedger = _ledgerDigest();
        NextBuybackDividendLogic next = _next(curve.token(), treasury.params());
        bytes memory data = abi.encodeCall(NextBuybackDividendLogic.migrate, (17, true));
        _schedule(address(next), data);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(NextBuybackDividendLogic.MigrationRejected.selector);
        controller.execute(address(proxy), data);
        assertEq(proxy.implementation(), proxy.initialImplementation());
        assertEq(_ledgerDigest(), beforeLedger);
        (uint256 poolSlot, uint256 epochSlot) = next.migrationSlots();
        assertEq(vm.load(address(proxy), bytes32(poolSlot)), bytes32(0));
        assertEq(vm.load(address(proxy), bytes32(epochSlot)), bytes32(0));
        (address pending,,,, uint256 readyAt) = controller.proposals(address(proxy));
        assertEq(pending, address(next));
        assertGt(readyAt, 0);
    }

    function test_replacementWithChangedAssetDecimalsIsRejectedEvenAtSameAddresses() public {
        uint256 originalPrice = treasury.spotPrice();
        vm.mockCall(address(stock), abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        HedgeFunV2UpgradeableBuybackTreasuryLogic next = new HedgeFunV2UpgradeableBuybackTreasuryLogic(
            address(usdg),
            address(stock),
            address(stockPool),
            address(oracle),
            curve.token(),
            address(pm),
            address(factory),
            treasury.params()
        );
        vm.clearMockedCalls();
        assertEq(treasury.spotPrice(), originalPrice);
        assertTrue(next.spotPrice() != originalPrice, "replacement must capture a different unit scale");
        assertTrue(next.upgradeConfigHash() != proxy.upgradeConfigHash(), "identity must include derived math units");
        vm.prank(owner);
        vm.expectRevert(V2TreasuryUpgradeController.InvalidUpgrade.selector);
        controller.schedule(address(proxy), address(next), "");
        assertEq(proxy.implementation(), proxy.initialImplementation());
    }

    function test_consumedProposalAndStorageScribbleCannotChangeControllerPointer() public {
        NextBuybackDividendLogic next = _next(curve.token(), treasury.params());
        _migrate(next);
        bytes memory data = abi.encodeCall(NextBuybackDividendLogic.migrate, (17, false));
        vm.expectRevert(V2TreasuryUpgradeController.NotReady.selector);
        controller.execute(address(proxy), data);
        NextBuybackDividendLogic(address(proxy)).scribbleImplementationSlot(address(0xBAD));
        assertEq(proxy.implementation(), address(next));
        assertFalse(NextBuybackDividendLogic(address(proxy)).replaySucceeded());
    }

    function test_codeMutationAndOwnershipHandoverInvalidatePendingUpgrade() public {
        NextBuybackDividendLogic next = _next(curve.token(), treasury.params());
        _schedule(address(next), "");
        vm.warp(block.timestamp + 2 days);
        vm.etch(address(next), hex"00");
        vm.expectRevert(V2TreasuryUpgradeController.InvalidUpgrade.selector);
        controller.execute(address(proxy), "");
        NextBuybackDividendLogic replacement = _next(curve.token(), treasury.params());
        _schedule(address(replacement), "");
        address successor = address(0xB0B);
        vm.prank(owner);
        factory.transferOwnership(successor);
        vm.prank(successor);
        factory.acceptOwnership();
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(V2TreasuryUpgradeController.InvalidUpgrade.selector);
        controller.execute(address(proxy), "");
        assertEq(proxy.implementation(), proxy.initialImplementation());
    }

    function test_upgradedTreasuryCannotWithdrawLockedLpPositions() public {
        _graduateV2(curve);
        V2LiquidityVault vault = V2LiquidityVault(treasury.liquidityVault());
        (uint128 baseBefore,,) = pm.getPositionInfo(
            key.toId(),
            address(vault),
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            bytes32(0)
        );
        uint128 extraBefore = vault.surplusLiquidity();
        NextBuybackDividendLogic next = _next(curve.token(), treasury.params());
        _migrate(next);
        assertFalse(NextBuybackDividendLogic(address(proxy)).probeVault(address(vault)));
        (uint128 baseAfter,,) = pm.getPositionInfo(
            key.toId(),
            address(vault),
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            bytes32(0)
        );
        (uint128 extraAfter,,) = pm.getPositionInfo(
            key.toId(), address(vault), vault.surplusTickLower(), vault.surplusTickUpper(), bytes32(uint256(1))
        );
        assertGt(baseBefore, 0);
        assertGt(extraBefore, 0);
        assertEq(baseAfter, baseBefore);
        assertEq(extraAfter, extraBefore);
        assertEq(treasury.liquidityVault(), address(vault));
    }
}
