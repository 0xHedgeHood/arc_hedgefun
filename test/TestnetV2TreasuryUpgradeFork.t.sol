// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunV2BuybackTreasury} from "../src/v2/HedgeFunV2BuybackTreasury.sol";
import {HedgeFunV2EngineTreasuryCore, EngineBinding} from "../src/v2/HedgeFunV2EngineTreasury.sol";
import {
    HedgeFunV2UpgradeableBuybackTreasury,
    HedgeFunV2UpgradeableBuybackTreasuryLogic
} from "../src/v2/HedgeFunV2UpgradeableBuybackTreasury.sol";
import {
    HedgeFunV2UpgradeableEngineTreasury,
    HedgeFunV2UpgradeableEngineTreasuryLogic
} from "../src/v2/HedgeFunV2UpgradeableEngineTreasury.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {V2TreasuryUpgradeController} from "../src/v2/V2TreasuryUpgradeController.sol";
import {V2LiquidityVault} from "../src/v2/V2LiquidityVault.sol";
import {EngineConfig} from "../src/v2/strategy/IStrategyPolicy.sol";
import {V2RebalancePolicy} from "../src/v2/strategy/V2RebalancePolicy.sol";
import {RegisterV2UpgradeableKinds} from "../script/RegisterV2UpgradeableKinds.s.sol";
import {TestnetMarket} from "../script/testnet/TestnetMarket.sol";
import {TestnetForkVenue} from "./utils/TestnetForkVenue.sol";
import {PriceOracle} from "../src/PriceOracle.sol";

/// Real deployed #25 factory/registry/stock venue, with all changes confined to an
/// in-memory fork. No private key and no RPC transaction submission are used.
/// The script's broadcast cheatcodes are simulations under `forge test`.
///
/// UPGRADEABLE_KINDS_FORK=true UPGRADEABLE_KINDS_FORK_BLOCK=<fresh block>
///   forge test --match-contract TestnetV2TreasuryUpgradeForkTest -vv
contract TestnetV2TreasuryUpgradeForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    HedgeFunV2Factory internal factory;
    V2TreasuryDeployer internal registry;
    V2TreasuryUpgradeController internal controller;
    RegisterV2UpgradeableKinds.Kinds internal kinds;
    TestnetMarket internal market;
    IERC20 internal stock;
    IERC20 internal usdg;
    address internal oracle;
    address internal venue;
    address internal creator = makeAddr("upgradeable kinds fork creator");
    address internal keeper = makeAddr("upgradeable kinds fork keeper");
    bytes32 internal policyKey;
    bytes32[] internal oldKinds;
    uint8 internal firstNewKind;

    struct Launch {
        uint256 id;
        HedgeFunBondingCurve curve;
        HedgeFunV2Treasury treasury;
        IERC20 token;
        PoolKey key;
    }

    struct Snapshot {
        bytes32 storageState;
        bytes32 balances;
        bytes32 lp;
    }

    function setUp() public {
        vm.skip(!vm.envOr("UPGRADEABLE_KINDS_FORK", false), "set UPGRADEABLE_KINDS_FORK=true");
        uint256 forkBlock = vm.envUint("UPGRADEABLE_KINDS_FORK_BLOCK");
        vm.createSelectFork(
            vm.envOr("UPGRADEABLE_KINDS_FORK_RPC", string("https://rpc.testnet.chain.robinhood.com")), forkBlock
        );
        assertEq(block.chainid, 46630, "Robinhood testnet only");
        emit log_named_uint("upgradeable kinds fork block", forkBlock);
        factory = HedgeFunV2Factory(vm.envOr("V2_FACTORY", address(0x6847318D28aB2f9343DDd2067871DC4f48609383)));
        registry = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        controller = registry.upgradeController();
        usdg = IERC20(factory.usdg());
        market = TestnetMarket(vm.envOr("TESTNET_MARKET", address(0xc1AF2f52980F8A7AA4E90A8E30D5c3FaF0375f21)));
        // From the venue, not from `strategies(0)`: a freshly deployed factory has no strategy yet.
        address listed = TestnetForkVenue.listedStock(factory, market);
        stock = IERC20(listed);
        (oracle, venue,,) = factory.listings(listed);
        // The registry is append-only and this runs at a floating block: whatever is registered there now is
        // the baseline, and must still be there, unchanged, after this registration.
        firstNewKind = uint8(registry.kindCount());
        assertGe(firstNewKind, 3, "recorded deployment has at least the legacy kinds 0/1/2");
        for (uint8 i; i < firstNewKind; ++i) {
            oldKinds.push(_kindDigest(i));
        }
        kinds = new RegisterV2UpgradeableKinds().register(factory.owner(), factory);
        assertEq(kinds.buyback, firstNewKind);
        assertEq(kinds.engine, firstNewKind + 1);
        assertEq(registry.kindCount(), uint256(firstNewKind) + 2);
        _assertLegacyKindsUnchanged();

        V2RebalancePolicy policy = new V2RebalancePolicy();
        vm.prank(factory.owner());
        policyKey = registry.registerPolicy(
            address(policy),
            400_000,
            160,
            keccak256("upgradeable-kind-fork-dependencies"),
            keccak256("upgradeable-kind-fork-test-evidence")
        );
    }

    function test_registrationAppendsKindsAndPreservesLegacyManifestsAndChunks() public {
        new RegisterV2UpgradeableKinds().check(registry, kinds);
        _assertLegacyKindsUnchanged();
        assertEq(controller.owner(), factory.owner());
        assertEq(controller.UPGRADE_DELAY(), 2 days);
        assertEq(registry.policy(policyKey).implementation.codehash, registry.policy(policyKey).runtimeCodeHash);
    }

    function test_buybackUpgradePreservesRealBalancesAndLpThenBooksAndBuys() public {
        _openSession();
        Launch memory l = _launch(false);
        HedgeFunV2BuybackTreasury t = HedgeFunV2BuybackTreasury(address(l.treasury));
        _graduate(l);
        uint256 principal = t.protectedGraduationStock();
        assertGt(principal, 0);
        assertEq(stock.balanceOf(address(t)), principal);
        assertEq(t.buybackStock(), 0);
        l.curve.claimFees(address(t));
        assertTrue(t.book(), "real curve fees fund income");
        {
            (uint256 spentBefore, uint256 burnedBefore) = t.buyback();
            assertGt(spentBefore, 0);
            assertGt(burnedBefore, 0);
        }
        Snapshot memory before = _snapshot(l);
        {
            HedgeFunV2UpgradeableBuybackTreasury proxy = HedgeFunV2UpgradeableBuybackTreasury(payable(address(t)));
            HedgeFunV2UpgradeableBuybackTreasuryLogic next = new HedgeFunV2UpgradeableBuybackTreasuryLogic(
                address(usdg),
                address(stock),
                venue,
                oracle,
                address(l.token),
                address(factory.poolManager()),
                address(factory),
                t.params()
            );
            assertEq(proxy.upgradeConfigHash(), next.upgradeConfigHash());
            _upgradeAfterDelay(address(proxy), address(next));
            assertEq(proxy.implementation(), address(next));
        }
        _assertSnapshot(l, before);

        _syncMarket();
        vm.prank(creator);
        stock.transfer(address(t), 1e18);
        uint256 budgetBefore = t.buybackStock();
        assertTrue(t.book(), "post-upgrade income booking works");
        assertEq(t.buybackStock(), budgetBefore + 1e18);
        uint256 supply = l.token.totalSupply();
        uint256 budget = t.buybackStock();
        vm.prank(keeper);
        (uint256 spent, uint256 burned) = t.buyback();
        assertGt(spent, 0, "replacement performs a real deployed V4 swap");
        assertGt(burned, 0);
        assertEq(l.token.totalSupply(), supply - burned);
        assertEq(t.buybackStock(), budget - spent);
        assertEq(t.bookedStock(), principal);
        assertEq(t.protectedGraduationStock(), principal);
        assertEq(stock.balanceOf(address(t)), principal + t.buybackStock());
        assertEq(_lpDigest(l), before.lp);
        _assertLegacyKindsUnchanged();
        emit log_named_uint("post-upgrade buyback stock spent", spent);
        emit log_named_uint("post-upgrade FUN burned", burned);
    }

    function test_engineUpgradePreservesRealInventoryAndLpThenExecutesAgain() public {
        _openSession();
        Launch memory l = _launch(true);
        HedgeFunV2EngineTreasuryCore t = HedgeFunV2EngineTreasuryCore(address(l.treasury));
        _graduate(l);
        assertGt(t.bookedStock(), 0, "live session books graduation inventory");
        assertEq(t.buybackStock(), 0);
        _sellOnce(t);
        uint64 nonceBefore = t.strategyNonce();
        assertEq(nonceBefore, 1);
        assertGt(t.reserveUsdg(), 0);
        Snapshot memory before = _snapshot(l);
        {
            bytes32 configBefore = t.configHash();
            HedgeFunV2UpgradeableEngineTreasury proxy = HedgeFunV2UpgradeableEngineTreasury(payable(address(t)));
            HedgeFunV2UpgradeableEngineTreasuryLogic next = new HedgeFunV2UpgradeableEngineTreasuryLogic(
                address(usdg),
                address(stock),
                venue,
                oracle,
                address(l.token),
                address(factory.poolManager()),
                address(factory),
                t.params(),
                EngineBinding(t.engineConfig(), registry.policy(policyKey), address(proxy))
            );
            assertEq(proxy.upgradeConfigHash(), next.upgradeConfigHash());
            _upgradeAfterDelay(address(proxy), address(next));
            assertEq(proxy.implementation(), address(next));
            assertEq(t.configHash(), configBefore);
        }
        _assertSnapshot(l, before);
        assertEq(t.strategyNonce(), nonceBefore);

        _syncMarket();
        // Actual new stock income makes the 50% target due even if the first
        // capped execution reached it. No treasury storage/balance is patched.
        uint256 donation = t.bookedStock() + 1e18;
        vm.prank(creator);
        stock.transfer(address(t), donation);
        assertTrue(t.book());
        _sellOnce(t);
        assertEq(t.strategyNonce(), nonceBefore + 1);
        assertGt(t.turnoverInEpoch(), 0);
        assertEq(stock.balanceOf(address(t)), t.bookedStock() + t.buybackStock());
        assertEq(_lpDigest(l), before.lp);
        _assertLegacyKindsUnchanged();
        emit log_named_uint("post-upgrade engine nonce", t.strategyNonce());
        emit log_named_uint("post-upgrade engine USDG reserve", t.reserveUsdg());
    }

    function _sellOnce(HedgeFunV2EngineTreasuryCore t) private {
        uint256 inventory = t.bookedStock();
        uint256 reserve = t.reserveUsdg();
        vm.prank(keeper);
        (HedgeFunV2Treasury.Action action,) = t.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.RebalanceSell));
        assertLt(t.bookedStock(), inventory);
        assertGt(t.reserveUsdg(), reserve, "stock really traded for USDG on the deployed venue");
    }

    function _launch(bool engine) private returns (Launch memory l) {
        HedgeFunFactory.Defaults memory d = factory.getDefaults();
        HedgeFunFactory.Request memory q;
        q.name = "Upgradeable kind fork rehearsal";
        q.symbol = "UPGRADE";
        q.nonce = engine ? kinds.engine : kinds.buyback;
        q.stock = address(stock);
        q.creator = creator;
        q.taxBps = d.minTaxBps;
        q.creatorBps = 1000;
        q.tp1Bps = 500;
        q.tp2Bps = 1000;
        q.dipBps = 500;
        q.lotBps = 2000;
        q.maxFee = d.launchFeeAmount;
        (,, q.expectedOpenPriceE18,) = factory.listings(address(stock));
        bool nativeFee = d.launchFeeCurrency == HedgeFunFactory.FeeCurrency.Native;
        if (nativeFee) vm.deal(creator, d.launchFeeAmount);
        else deal(address(usdg), creator, d.launchFeeAmount);
        deal(address(stock), creator, 10_000e18);
        vm.startPrank(creator);
        if (engine) registry.setEngineConfig(q.symbol, q.nonce, kinds.engine, _engineConfig(d));
        else registry.setStrategyKind(q.symbol, q.nonce, kinds.buyback);
        usdg.approve(address(factory), d.launchFeeAmount);
        (address predictedToken, address predictedTreasury, bytes32 terms) = factory.predict(q);
        l.id = nativeFee ? factory.launch{value: d.launchFeeAmount}(q, terms) : factory.launch(q, terms);
        vm.stopPrank();
        l.curve = HedgeFunBondingCurve(factory.curves(l.id));
        (address token_, address treasury_,,,) = factory.strategies(l.id);
        assertEq(token_, predictedToken);
        assertEq(treasury_, predictedTreasury);
        l.treasury = HedgeFunV2Treasury(treasury_);
        l.token = IERC20(token_);
        (l.key,) = factory.graduationConfig(l.id);
    }

    function _engineConfig(HedgeFunFactory.Defaults memory d) private view returns (EngineConfig memory c) {
        (,, uint64 listedChunk) = factory.listingGates(address(stock));
        uint256 maxTrade = listedChunk == 0 ? d.sellChunkUsdg : uint256(listedChunk);
        c.schema = 1;
        c.engineVersion = 1;
        c.policyKey = policyKey;
        c.words[0] = bytes32(uint256(5000) | uint256(500) << 16 | uint256(600) << 32);
        c.words[1] = bytes32(maxTrade);
        c.words[2] = bytes32(maxTrade * 5);
    }

    function _graduate(Launch memory l) private {
        uint256 supply = l.token.totalSupply();
        vm.startPrank(creator);
        stock.approve(address(l.curve), type(uint256).max);
        l.curve.buy(type(uint256).max, 1, creator, block.timestamp);
        vm.stopPrank();
        assertEq(uint256(l.curve.status()), uint256(HedgeFunBondingCurve.Status.Graduated));
        assertEq(l.token.totalSupply(), supply, "graduation does not burn FUN");
        assertGt(l.treasury.liquidityVault().code.length, 0);
    }

    function _upgradeAfterDelay(address proxy, address next) private {
        vm.prank(factory.owner());
        controller.schedule(proxy, next, "");
        vm.warp(block.timestamp + 2 days - 1);
        vm.expectRevert(V2TreasuryUpgradeController.NotReady.selector);
        controller.execute(proxy, "");
        vm.warp(block.timestamp + 1);
        controller.execute(proxy, "");
        emit log_named_address("upgraded fork treasury", proxy);
        emit log_named_address("replacement implementation", next);
    }

    function _openSession() private {
        uint256 day = block.timestamp / 1 days + 1;
        while ((day + 4) % 7 != 2) ++day;
        vm.warp(day * 1 days + 15 hours);
        _syncMarket();
    }

    function _syncMarket() private {
        vm.prank(market.owner());
        market.syncFeed(venue);
        (bool live,) = PriceOracle(oracle).tryPrice();
        assertTrue(live, "test market has a live oracle within the US session");
    }

    function _storageDigest(address treasury) private view returns (bytes32 digest) {
        // These two kinds use only fixed-size ledger state (no strategy lots).
        // Covers every inherited slot and additional Engine config/nonce/limits.
        for (uint256 i; i < 96; ++i) {
            digest = keccak256(abi.encode(digest, vm.load(treasury, bytes32(i))));
        }
    }

    function _snapshot(Launch memory l) private view returns (Snapshot memory) {
        return Snapshot(_storageDigest(address(l.treasury)), _balancesDigest(l), _lpDigest(l));
    }

    function _assertSnapshot(Launch memory l, Snapshot memory before) private view {
        assertEq(_storageDigest(address(l.treasury)), before.storageState, "existing storage changed during upgrade");
        assertEq(_balancesDigest(l), before.balances, "balances changed during upgrade");
        assertEq(_lpDigest(l), before.lp, "vault LP changed during upgrade");
    }

    function _balancesDigest(Launch memory l) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                stock.balanceOf(address(l.treasury)),
                usdg.balanceOf(address(l.treasury)),
                l.token.balanceOf(address(l.treasury)),
                l.token.totalSupply(),
                l.treasury.liquidityVault()
            )
        );
    }

    function _lpDigest(Launch memory l) private view returns (bytes32) {
        V2LiquidityVault vault = V2LiquidityVault(l.treasury.liquidityVault());
        IPoolManager manager = factory.poolManager();
        (uint128 base,,) = manager.getPositionInfo(
            l.key.toId(),
            address(vault),
            TickMath.minUsableTick(l.key.tickSpacing),
            TickMath.maxUsableTick(l.key.tickSpacing),
            bytes32(0)
        );
        (uint128 extra,,) = manager.getPositionInfo(
            l.key.toId(), address(vault), vault.surplusTickLower(), vault.surplusTickUpper(), bytes32(uint256(1))
        );
        assertGt(base, 0, "vault owns the base position");
        assertGt(extra, 0, "vault owns the surplus position");
        return keccak256(abi.encode(address(vault), base, extra, vault.surplusLiquidity(), vault.lockedSeedTokens()));
    }

    function _kindDigest(uint8 kind) private view returns (bytes32) {
        (address a, address b) = registry.kinds(kind);
        (uint32 version, uint32 schema, bytes32 hash, uint256 caps) = registry.kindManifest(kind);
        return keccak256(abi.encode(a, b, a.codehash, b.codehash, version, schema, hash, caps));
    }

    function _assertLegacyKindsUnchanged() private view {
        for (uint8 i; i < firstNewKind; ++i) {
            assertEq(_kindDigest(i), oldKinds[i], "legacy kind manifest/chunks changed");
        }
    }
}
