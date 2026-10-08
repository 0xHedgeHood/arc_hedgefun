// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {
    HedgeFunV2EngineTreasury,
    HedgeFunV2EngineTreasuryCore,
    EngineBinding
} from "../src/v2/HedgeFunV2EngineTreasury.sol";
import {
    HedgeFunV2UpgradeableEngineTreasury,
    HedgeFunV2UpgradeableEngineTreasuryLogic
} from "../src/v2/HedgeFunV2UpgradeableEngineTreasury.sol";
import {HedgeFunV2UpgradeableTreasuryLogic} from "../src/v2/HedgeFunV2UpgradeableTreasury.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {V2TreasuryUpgradeController, IV2TreasuryProxy} from "../src/v2/V2TreasuryUpgradeController.sol";
import {V2StakingIncome} from "../src/v2/V2StakingIncome.sol";
import {
    EngineConfig,
    PolicyManifest,
    IStrategyPolicy,
    StrategyCapabilities,
    StrategyContext,
    StrategyIntent
} from "../src/v2/strategy/IStrategyPolicy.sol";
import {V2RebalancePolicy} from "../src/v2/strategy/V2RebalancePolicy.sol";
import {EngineAccountingVenue} from "./V2StrategyEngineAccounting.t.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

/// @dev Keeps the production decision logic but changes its opaque state after a successful action.
/// This makes accidental policy-state resets observable, unlike a policy that always returns zero.
contract UpgradeStatefulRebalancePolicy is IStrategyPolicy {
    V2RebalancePolicy private immutable rebalance = new V2RebalancePolicy();

    function policyMetadata() external pure returns (uint32, uint32, uint256) {
        return (1, 1, StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL);
    }

    function decide(StrategyContext calldata context, EngineConfig calldata config, bytes32 state)
        external
        view
        returns (StrategyIntent memory intent)
    {
        intent = rebalance.decide(context, config, state);
        intent.nextState = bytes32(uint256(state) + 1);
    }
}

/// @dev Test-only extension, not a production distribution feature. Appends storage after the whole Engine layout.
contract NextEngineDistributionLogic is HedgeFunV2UpgradeableEngineTreasuryLogic {
    uint256 public distributionEpoch;
    address public distributionSource;
    address public migrationCaller;
    bool public replaySucceeded;
    error MigrationRejected();

    constructor(
        address u,
        address s,
        address venue,
        address o,
        address t,
        address pm,
        address f,
        Params memory p,
        EngineBinding memory binding
    ) HedgeFunV2UpgradeableEngineTreasuryLogic(u, s, venue, o, t, pm, f, p, binding) {}

    function migrateDistribution(uint256 epoch) external {
        address control = IV2TreasuryProxy(address(this)).treasuryUpgradeController();
        require(msg.sender == control, "controller only");
        distributionEpoch = epoch;
        distributionSource = address(this);
        migrationCaller = msg.sender;
        (replaySucceeded,) = control.call(
            abi.encodeCall(
                V2TreasuryUpgradeController.execute, (address(this), abi.encodeCall(this.migrateDistribution, (epoch)))
            )
        );
    }

    function rejectMigration() external {
        distributionEpoch = 999;
        revert MigrationRejected();
    }
}

/// @dev Test-only one-time migration of already realised income into a real external staking pool.
/// All production trading methods remain present. This is not the production recurring dividend strategy.
contract EngineStakingMigrationLogic is HedgeFunV2UpgradeableEngineTreasuryLogic {
    V2StakingIncome public immutable distribution;

    constructor(
        address u,
        address s,
        address venue,
        address o,
        address t,
        address pm,
        address f,
        Params memory p,
        EngineBinding memory binding
    ) HedgeFunV2UpgradeableEngineTreasuryLogic(u, s, venue, o, t, pm, f, p, binding) {
        distribution = new V2StakingIncome(IERC20(t), IERC20(s), binding.treasury, 1 hours, 1 hours);
    }

    function migrateIncome(uint256 amount) external nonReentrant {
        require(msg.sender == IV2TreasuryProxy(address(this)).treasuryUpgradeController(), "controller only");
        buybackStock -= amount;
        // This test's stock fixture returns the standard ERC20 bool. Production recurring distributions
        // need their own reviewed token-compatibility rules and accounting, as the income kinds have.
        require(_stock.approve(address(distribution), amount), "approve");
        distribution.fund(amount);
    }
}

/// @dev Independent wrapper fixture: existing direct-engine suites retain their original registration.
abstract contract V2UpgradeableEngineFixture is V2FactoryFixture {
    V2TreasuryDeployer internal deployer;
    V2TreasuryUpgradeController internal controller;
    EngineAccountingVenue internal venue;
    bytes32 internal policyKey;
    uint8 internal engineKind;

    function _setUpUpgradeableEngine(bool stateful) internal {
        _setUpV2(18);
        venue = new EngineAccountingVenue(address(stock), address(usdg), 3000, 1e30, 100e18);
        stockPool = venue;
        v3f.set(address(stock), address(usdg), 3000, address(venue));
        vm.prank(owner);
        factory.list(address(stock), address(oracle), address(venue), openPrice, true);
        usdg.mint(address(venue), 10_000_000e6);
        stock.mint(address(venue), 100_000e18);
        deployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        controller = deployer.upgradeController();
        address policy = stateful ? address(new UpgradeStatefulRebalancePolicy()) : address(new V2RebalancePolicy());
        (address a, address b) = deployer.makeChunks(type(HedgeFunV2UpgradeableEngineTreasury).creationCode);
        vm.startPrank(owner);
        policyKey = deployer.registerPolicy(
            policy, 400_000, 160, keccak256("proxy-engine-dependencies-v1"), keccak256("proxy-engine-audit-v1")
        );
        engineKind =
            deployer.registerEngineKind(a, b, 1, 1, StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL);
        vm.stopPrank();
    }

    function _config(uint256 payout) internal view returns (EngineConfig memory c) {
        c.schema = 1;
        c.engineVersion = 1;
        c.policyKey = policyKey;
        c.words[0] = bytes32(uint256(5000) | uint256(500) << 16 | uint256(600) << 32 | payout << 64);
        c.words[1] = bytes32(uint256(100e6));
        c.words[2] = bytes32(uint256(500e6));
    }

    function _launchProxy(uint96 nonce, uint256 payout)
        internal
        returns (HedgeFunV2EngineTreasury t, HedgeFunBondingCurve curve)
    {
        HedgeFunFactory.Request memory q = _request();
        q.nonce = nonce;
        deployer.setEngineConfig(q.symbol, q.nonce, engineKind, _config(payout));
        (address predictedToken, address predictedTreasury, bytes32 terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        (address token, address treasury,,,) = factory.strategies(id);
        assertEq(token, predictedToken);
        assertEq(treasury, predictedTreasury);
        t = HedgeFunV2EngineTreasury(treasury);
        curve = HedgeFunBondingCurve(factory.curves(id));
        stock.approve(address(curve), type(uint256).max);
    }

    function _binding(HedgeFunV2EngineTreasury t) internal view returns (EngineBinding memory) {
        return EngineBinding(t.engineConfig(), deployer.policy(t.strategyId()), address(t));
    }

    function _replacement(HedgeFunV2EngineTreasury t) internal returns (HedgeFunV2UpgradeableEngineTreasuryLogic) {
        return _replacement(t, address(t.token()), t.params(), _binding(t));
    }

    function _replacement(
        HedgeFunV2EngineTreasury t,
        address token,
        HedgeFunTreasuryBase.Params memory p,
        EngineBinding memory binding
    ) internal returns (HedgeFunV2UpgradeableEngineTreasuryLogic next) {
        next = new HedgeFunV2UpgradeableEngineTreasuryLogic(
            address(usdg),
            address(stock),
            address(venue),
            address(oracle),
            token,
            address(pm),
            address(factory),
            p,
            binding
        );
        assertLe(address(next).code.length, 24_576, "replacement runtime");
        t; // same helper deliberately also constructs candidates with one mismatched identity
    }

    function _market(uint256 price) internal {
        venue.setPrice(price);
        stockFeed.set(int256(price / 1e10));
        usdgFeed.set(1e8);
    }
}

contract V2EngineTreasuryUpgradeTest is V2UpgradeableEngineFixture {
    HedgeFunV2EngineTreasury private treasury;
    HedgeFunV2UpgradeableEngineTreasury private proxy;
    HedgeFunBondingCurve private curve;

    function setUp() public {
        _setUpUpgradeableEngine(true);
        (treasury, curve) = _launchProxy(501, 5000);
        proxy = HedgeFunV2UpgradeableEngineTreasury(payable(address(treasury)));
    }

    function _schedule(address next, bytes memory data) private {
        vm.prank(owner);
        controller.schedule(address(proxy), next, data);
    }

    function _migrationLogic() private returns (NextEngineDistributionLogic next) {
        next = new NextEngineDistributionLogic(
            address(usdg),
            address(stock),
            address(venue),
            address(oracle),
            curve.token(),
            address(pm),
            address(factory),
            treasury.params(),
            _binding(treasury)
        );
        assertLe(address(next).code.length, 24_576, "migration candidate runtime");
    }

    function _digest() private view returns (bytes32) {
        bytes32 strategy = keccak256(
            abi.encode(
                treasury.engineConfig(),
                treasury.configHash(),
                treasury.policyState(),
                treasury.avgCost(),
                treasury.strategyNonce(),
                treasury.lastStrategyAt(),
                treasury.turnoverEpoch(),
                treasury.turnoverInEpoch()
            )
        );
        bytes32 accounts = keccak256(
            abi.encode(
                treasury.bookedStock(),
                treasury.buybackStock(),
                treasury.totalStockReceived(),
                treasury.totalStockSpentOnBuybacks(),
                treasury.totalBurned(),
                stock.balanceOf(address(treasury)),
                usdg.balanceOf(address(treasury)),
                IERC20(curve.token()).totalSupply()
            )
        );
        bytes32 base = keccak256(
            abi.encode(
                treasury.params(),
                treasury.liquidityVault(),
                treasury.hook(),
                treasury.buybackAnchorSqrtP(),
                treasury.buybackAnchorAt(),
                treasury.lastGoodPrice(),
                treasury.lastGoodPriceAt(),
                treasury.lastBuybackAt(),
                treasury.lotCount()
            )
        );
        return keccak256(abi.encode(strategy, accounts, base));
    }

    function test_proxyInitializesParamsConfigAndUsesProxyDomain() public {
        assertEq(address(proxy.treasuryUpgradeController()), address(controller));
        assertEq(proxy.implementation(), proxy.initialImplementation());
        assertEq(keccak256(abi.encode(treasury.engineConfig())), keccak256(abi.encode(_config(5000))));
        assertEq(treasury.params().tp1Bps, _request().tp1Bps);
        assertEq(treasury.payoutBps(), 5000);
        assertEq(address(treasury.tradingCalendar()), address(oracle.calendar()));
        assertEq(treasury.factory(), address(factory));
        assertEq(address(treasury.token()), curve.token());
        assertEq(treasury.strategyId(), policyKey);
        EngineBinding memory binding = _binding(treasury);
        PolicyManifest memory m = binding.manifest;
        bytes32 expected = keccak256(
            abi.encode(
                block.chainid,
                address(proxy),
                address(factory),
                address(stock),
                address(usdg),
                binding.config,
                m.implementation,
                m.runtimeCodeHash,
                m.capabilities,
                m.maxGas,
                m.maxReturnBytes
            )
        );
        assertEq(treasury.configHash(), expected, "intent domain is proxy, never implementation");
        HedgeFunV2UpgradeableEngineTreasuryLogic next = _replacement(treasury);
        assertEq(next.configHash(), expected);
        assertEq(next.upgradeConfigHash(), proxy.upgradeConfigHash());
        HedgeFunTreasuryBase.Params memory p = treasury.params();
        EngineConfig memory c = treasury.engineConfig();
        address initial = proxy.initialImplementation();
        vm.expectRevert(HedgeFunV2UpgradeableEngineTreasuryLogic.InvalidInitialization.selector);
        HedgeFunV2UpgradeableEngineTreasuryLogic(address(proxy)).initializeProxy(p, c);
        vm.expectRevert(HedgeFunV2UpgradeableEngineTreasuryLogic.InvalidInitialization.selector);
        HedgeFunV2UpgradeableEngineTreasuryLogic(initial).initializeProxy(p, c);
    }

    function test_allBytecodeAndConstructorArgumentsFitEvmLimits() public {
        assertLe(address(proxy).code.length, 24_576, "proxy runtime");
        assertLe(proxy.initialImplementation().code.length, 24_576, "production logic runtime");
        (address a, address b) = deployer.kinds(engineKind);
        assertLe(a.code.length, 24_576, "chunk A");
        assertLe(b.code.length, 24_576, "chunk B");
        bytes memory ordinary = abi.encode(
            address(usdg),
            address(stock),
            address(venue),
            address(oracle),
            curve.token(),
            address(pm),
            address(factory),
            treasury.params(),
            treasury.engineConfig()
        );
        bytes memory replacement = abi.encode(
            address(usdg),
            address(stock),
            address(venue),
            address(oracle),
            curve.token(),
            address(pm),
            address(factory),
            treasury.params(),
            _binding(treasury)
        );
        assertLe(
            type(HedgeFunV2UpgradeableEngineTreasury).creationCode.length + ordinary.length,
            49_152,
            "proxy initcode including registry-appended config"
        );
        assertLe(
            type(HedgeFunV2UpgradeableEngineTreasuryLogic).creationCode.length + replacement.length,
            49_152,
            "logic initcode including frozen manifest and proxy domain"
        );
        _migrationLogic();
    }

    function test_upgradePreservesTradingStateAndCannotResetSameDayLimits() public {
        _graduateV2(curve);
        HedgeFunV2UpgradeableEngineTreasuryLogic next = _replacement(treasury);
        _schedule(address(next), "");
        // Mature the proposal BEFORE the action so a two-day warp cannot hide a reset of the daily bucket.
        vm.warp((block.timestamp / 1 days + 3) * 1 days + 1 hours);
        _market(160e18);
        treasury.execute();
        assertEq(treasury.strategyNonce(), 1);
        assertEq(treasury.policyState(), bytes32(uint256(1)));
        assertGt(treasury.buybackStock(), 0, "profitable sale funded the buyback");
        assertEq(treasury.avgCost(), 100e18);
        assertEq(treasury.turnoverInEpoch(), 100e6);
        bytes32 beforeUpgrade = _digest();
        controller.execute(address(proxy), "");
        assertEq(_digest(), beforeUpgrade, "all execution and custody state survives upgrade");
        assertEq(proxy.implementation(), address(next));
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        treasury.execute();
        for (uint256 i; i < 4; ++i) {
            vm.warp(block.timestamp + 600);
            _market(160e18);
            treasury.execute();
        }
        assertEq(treasury.turnoverInEpoch(), 500e6);
        assertEq(treasury.strategyNonce(), 5);
        assertEq(treasury.policyState(), bytes32(uint256(5)));
        vm.warp(block.timestamp + 600);
        _market(160e18);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        treasury.execute();
        uint256 budget = treasury.buybackStock();
        uint256 principal = treasury.bookedStock();
        (uint256 spent, uint256 burned) = treasury.buyback();
        assertGt(spent, 0);
        assertGt(burned, 0);
        assertEq(treasury.buybackStock(), budget - spent);
        assertEq(treasury.bookedStock(), principal, "buyback never consumes strategy inventory");
        assertEq(
            HedgeFunV2EngineTreasuryCore(proxy.initialImplementation()).strategyNonce(),
            0,
            "delegatecall leaves implementation ledger untouched"
        );
    }

    function testFuzz_upgradePreservesLedgerAfterPartialProfitSale(uint16 rawFill, uint16 rawPrice) public {
        _graduateV2(curve);
        HedgeFunV2UpgradeableEngineTreasuryLogic next = _replacement(treasury);
        _schedule(address(next), "");
        vm.warp(block.timestamp + 2 days);
        _market(bound(uint256(rawPrice), 110, 200) * 1e18);
        venue.setFillBps(uint16(bound(uint256(rawFill), 1000, 10_000)));
        treasury.execute();
        assertGt(treasury.buybackStock(), 0);
        assertEq(treasury.strategyNonce(), 1);
        assertGe(treasury.turnoverInEpoch(), treasury.params().minLotUsdg);
        assertLe(treasury.turnoverInEpoch(), 100e6);
        bytes32 beforeUpgrade = _digest();
        controller.execute(address(proxy), "");
        assertEq(_digest(), beforeUpgrade);
        assertEq(treasury.bookedStock() + treasury.buybackStock(), stock.balanceOf(address(treasury)));
    }

    function test_realStakingMigrationBindsProxyAndFundsClaimsWithoutRemovingTrading() public {
        _graduateV2(curve);
        EngineStakingMigrationLogic next = new EngineStakingMigrationLogic(
            address(usdg),
            address(stock),
            address(venue),
            address(oracle),
            curve.token(),
            address(pm),
            address(factory),
            treasury.params(),
            _binding(treasury)
        );
        assertLe(address(next).code.length, 24_576, "full engine plus staking migration must fit");
        bytes memory args = abi.encode(
            address(usdg),
            address(stock),
            address(venue),
            address(oracle),
            curve.token(),
            address(pm),
            address(factory),
            treasury.params(),
            _binding(treasury)
        );
        assertLe(type(EngineStakingMigrationLogic).creationCode.length + args.length, 49_152, "migration initcode");
        V2StakingIncome pool = next.distribution();
        assertEq(pool.incomeSource(), address(proxy));
        assertEq(address(pool.stakeToken()), curve.token());
        assertEq(address(pool.rewardToken()), address(stock));
        IERC20(curve.token()).approve(address(pool), 100e18);
        pool.stake(100e18);
        _market(160e18);
        treasury.execute();
        uint256 amount = treasury.buybackStock() / 3600 * 3600;
        assertGt(amount, 0);
        bytes memory data = abi.encodeCall(EngineStakingMigrationLogic.migrateIncome, (amount));
        _schedule(address(next), data);
        vm.warp(block.timestamp + 2 days);
        uint256 principal = treasury.bookedStock();
        uint256 budget = treasury.buybackStock();
        uint256 balance = stock.balanceOf(address(proxy));
        controller.execute(address(proxy), data);
        assertEq(treasury.bookedStock(), principal);
        assertEq(treasury.buybackStock(), budget - amount);
        assertEq(stock.balanceOf(address(proxy)), balance - amount);
        assertEq(pool.totalFunded(), amount);
        assertEq(stock.balanceOf(address(pool)), amount);
        assertEq(stock.allowance(address(proxy), address(pool)), 0);
        vm.expectRevert(V2StakingIncome.NotIncomeSource.selector);
        pool.fund(1);
        vm.expectRevert("controller only");
        EngineStakingMigrationLogic(address(proxy)).migrateIncome(1);
        _market(160e18);
        treasury.execute();
        assertEq(treasury.strategyNonce(), 2, "full production trading remains available after migration");
        vm.warp(block.timestamp + 1 hours);
        uint256 beforeClaim = stock.balanceOf(address(this));
        assertEq(pool.claim(address(this)), amount);
        assertEq(stock.balanceOf(address(this)), beforeClaim + amount);
        assertEq(pool.totalClaimed(), amount);
        pool.withdraw(100e18, address(this));
        assertEq(pool.totalStaked(), 0);
    }

    function test_migrationAppendsDistributionStateUsesProxySourceAndCannotReplay() public {
        _graduateV2(curve);
        NextEngineDistributionLogic next = _migrationLogic();
        bytes memory data = abi.encodeCall(NextEngineDistributionLogic.migrateDistribution, (17));
        _schedule(address(next), data);
        vm.expectRevert(V2TreasuryUpgradeController.NotReady.selector);
        controller.execute(address(proxy), data);
        vm.warp(block.timestamp + 2 days);
        _market(160e18);
        treasury.execute();
        bytes32 beforeUpgrade = _digest();
        controller.execute(address(proxy), data);
        assertEq(_digest(), beforeUpgrade);
        NextEngineDistributionLogic upgraded = NextEngineDistributionLogic(address(proxy));
        assertEq(upgraded.distributionEpoch(), 17);
        assertEq(upgraded.distributionSource(), address(proxy));
        assertEq(upgraded.migrationCaller(), address(controller));
        assertFalse(upgraded.replaySucceeded());
        assertEq(next.distributionEpoch(), 0);
        assertEq(next.distributionSource(), address(0));
        vm.expectRevert(V2TreasuryUpgradeController.NotReady.selector);
        controller.execute(address(proxy), data);
        vm.expectRevert("controller only");
        upgraded.migrateDistribution(18);
        vm.expectRevert(HedgeFunV2UpgradeableEngineTreasury.NotUpgradeController.selector);
        proxy.applyUpgrade(data);
    }

    function test_rejectedMigrationRollsBackPointerStateAndProposalConsumption() public {
        _graduateV2(curve);
        NextEngineDistributionLogic next = _migrationLogic();
        bytes memory data = abi.encodeCall(NextEngineDistributionLogic.rejectMigration, ());
        _schedule(address(next), data);
        vm.warp(block.timestamp + 2 days);
        bytes32 beforeUpgrade = _digest();
        vm.expectRevert(NextEngineDistributionLogic.MigrationRejected.selector);
        controller.execute(address(proxy), data);
        assertEq(proxy.implementation(), proxy.initialImplementation());
        assertEq(_digest(), beforeUpgrade);
        assertEq(controller.implementationOf(address(proxy)), address(0));
        (address pending,,,, uint256 readyAt) = controller.proposals(address(proxy));
        assertEq(pending, address(next));
        assertGt(readyAt, 0);
        // A later successful migration sees zero appended storage, not the rejected write of 999.
        vm.prank(owner);
        controller.cancel(address(proxy));
        _schedule(address(next), "");
        vm.warp(block.timestamp + 2 days);
        controller.execute(address(proxy), "");
        assertEq(NextEngineDistributionLogic(address(proxy)).distributionEpoch(), 0);
    }

    function test_onlyOwnerCanScheduleOrCancelAndNoticeCannotBeSkipped() public {
        HedgeFunV2UpgradeableEngineTreasuryLogic next = _replacement(treasury);
        vm.expectRevert(V2TreasuryUpgradeController.NotOwner.selector);
        controller.schedule(address(proxy), address(next), "");
        _schedule(address(next), "");
        vm.warp(block.timestamp + 2 days - 1);
        vm.prank(owner);
        vm.expectRevert(V2TreasuryUpgradeController.NotReady.selector);
        controller.execute(address(proxy), "");
        vm.expectRevert(V2TreasuryUpgradeController.NotOwner.selector);
        controller.cancel(address(proxy));
        vm.prank(owner);
        controller.cancel(address(proxy));
        vm.warp(block.timestamp + 1);
        vm.expectRevert(V2TreasuryUpgradeController.NotReady.selector);
        controller.execute(address(proxy), "");
    }

    function _assertRejected(HedgeFunV2UpgradeableEngineTreasuryLogic next) private {
        assertNotEq(next.upgradeConfigHash(), proxy.upgradeConfigHash());
        vm.prank(owner);
        vm.expectRevert(V2TreasuryUpgradeController.InvalidUpgrade.selector);
        controller.schedule(address(proxy), address(next), "");
    }

    function test_rejectsOtherProxyEvenWhenItsAssetsParamsAndPolicyMatch() public {
        EngineBinding memory binding = _binding(treasury);
        binding.treasury = address(0x123456);
        _assertRejected(_replacement(treasury, curve.token(), treasury.params(), binding));
    }

    function test_rejectsDifferentTokenParamsAndEngineConfig() public {
        _assertRejected(_replacement(treasury, address(0x1234), treasury.params(), _binding(treasury)));
        HedgeFunTreasuryBase.Params memory p = treasury.params();
        p.tp1Bps += 1;
        _assertRejected(_replacement(treasury, curve.token(), p, _binding(treasury)));
        EngineBinding memory binding = _binding(treasury);
        binding.config.words[2] = bytes32(uint256(600e6));
        _assertRejected(_replacement(treasury, curve.token(), treasury.params(), binding));
    }

    function test_rejectsChangedStockDecimalsEvenWhenEveryAddressIsUnchanged() public {
        // Simulate an issuer changing its token metadata behind the same address. Both values are otherwise
        // valid constructor inputs; rejection must come from the pinned unit conversion, not deployment failure.
        vm.mockCall(address(stock), abi.encodeWithSignature("decimals()"), abi.encode(uint8(17)));
        HedgeFunV2UpgradeableEngineTreasuryLogic next = _replacement(treasury);
        vm.clearMockedCalls();
        assertEq(next.configHash(), treasury.configHash(), "the policy domain alone cannot detect decimal drift");
        _assertRejected(next);
    }

    function test_rejectsDifferentPolicyAndPolicyLimits() public {
        EngineBinding memory binding = _binding(treasury);
        binding.manifest.maxGas -= 1;
        _assertRejected(_replacement(treasury, curve.token(), treasury.params(), binding));
        binding = _binding(treasury);
        address another = address(new UpgradeStatefulRebalancePolicy());
        binding.manifest.implementation = another;
        binding.manifest.runtimeCodeHash = another.codehash;
        _assertRejected(_replacement(treasury, curve.token(), treasury.params(), binding));
        binding = _binding(treasury);
        binding.config.policyKey = keccak256("different policy key");
        _assertRejected(_replacement(treasury, curve.token(), treasury.params(), binding));
    }

    function test_rejectsDifferentStorageFamily() public {
        HedgeFunV2UpgradeableTreasuryLogic allIn = new HedgeFunV2UpgradeableTreasuryLogic(
            address(usdg),
            address(stock),
            address(venue),
            address(oracle),
            curve.token(),
            address(pm),
            address(factory),
            treasury.params()
        );
        vm.prank(owner);
        vm.expectRevert(V2TreasuryUpgradeController.InvalidUpgrade.selector);
        controller.schedule(address(proxy), address(allIn), "");
    }

    function test_policyDelistingKeepsSameIdentityUpgradeableButBlocksNewLaunch() public {
        _graduateV2(curve);
        bytes32 commitment = treasury.configHash();
        vm.prank(owner);
        deployer.disablePolicy(policyKey);
        assertFalse(deployer.policy(policyKey).enabledForNewLaunches);
        HedgeFunV2UpgradeableEngineTreasuryLogic next = _replacement(treasury);
        assertEq(next.upgradeConfigHash(), proxy.upgradeConfigHash(), "listing state is not an upgrade identity");
        _schedule(address(next), "");
        vm.warp(block.timestamp + 2 days);
        _market(100e18);
        controller.execute(address(proxy), "");
        assertEq(treasury.configHash(), commitment);
        treasury.execute();
        assertEq(treasury.strategyNonce(), 1);
        HedgeFunFactory.Request memory q = _request();
        q.nonce = 502;
        EngineConfig memory c = _config(5000);
        vm.expectRevert(V2TreasuryDeployer.BadPolicy.selector);
        deployer.setEngineConfig(q.symbol, q.nonce, engineKind, c);
        HedgeFunTreasuryBase.Params memory p = treasury.params();
        address token = curve.token();
        vm.prank(address(deployer));
        vm.expectRevert(HedgeFunV2UpgradeableEngineTreasury.PolicyUnavailable.selector);
        new HedgeFunV2UpgradeableEngineTreasury(
            address(usdg), address(stock), address(venue), address(oracle), token, address(pm), address(factory), p, c
        );
    }

    function test_noticeCommitsMigrationDataAndCandidateRuntime() public {
        NextEngineDistributionLogic next = _migrationLogic();
        bytes memory data = abi.encodeCall(NextEngineDistributionLogic.migrateDistribution, (17));
        _schedule(address(next), data);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(V2TreasuryUpgradeController.InvalidUpgrade.selector);
        controller.execute(address(proxy), abi.encodeCall(NextEngineDistributionLogic.migrateDistribution, (18)));
        vm.etch(address(next), hex"00");
        vm.expectRevert(V2TreasuryUpgradeController.InvalidUpgrade.selector);
        controller.execute(address(proxy), data);
        assertEq(proxy.implementation(), proxy.initialImplementation());
    }
}
