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
import {EngineBinding} from "../src/v2/HedgeFunV2EngineTreasury.sol";
import {
    HedgeFunV2TradablePercentEngineTreasury,
    HedgeFunV2TradablePercentEngineTreasuryLogic,
    HedgeFunV2TradablePercentEngineTreasuryCore
} from "../src/v2/HedgeFunV2TradablePercentEngineTreasury.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {V2TreasuryUpgradeController} from "../src/v2/V2TreasuryUpgradeController.sol";
import {V2LiquidityVault} from "../src/v2/V2LiquidityVault.sol";
import {EngineConfig} from "../src/v2/strategy/IStrategyPolicy.sol";
import {RegisterV2TradablePercent} from "../script/RegisterV2TradablePercent.s.sol";
import {TestnetMarket} from "../script/testnet/TestnetMarket.sol";
import {TestnetForkVenue} from "./utils/TestnetForkVenue.sol";
import {PriceOracle} from "../src/PriceOracle.sol";

/// Real deployed #25 factory/registry/stock venue, with all changes confined to an
/// in-memory fork. No private key and no RPC transaction submission are used.
/// The script's broadcast cheatcodes are simulations under `forge test`.
///
/// TRADABLE_PERCENT_FORK=true TRADABLE_PERCENT_FORK_BLOCK=<fresh block>
///   forge test --match-contract TestnetV2TradablePercentForkTest -vv
contract TestnetV2TradablePercentForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    HedgeFunV2Factory internal factory;
    V2TreasuryDeployer internal registry;
    V2TreasuryUpgradeController internal controller;
    RegisterV2TradablePercent.Registration internal registration;
    bytes32 internal constant DEPENDENCIES = keccak256("tradable-percent-fork-dependencies");
    bytes32 internal constant AUDIT = keccak256("tradable-percent-fork-evidence");
    TestnetMarket internal market;
    IERC20 internal stock;
    IERC20 internal usdg;
    address internal oracle;
    address internal venue;
    address internal creator = makeAddr("tradable percent fork creator");
    address internal keeper = makeAddr("tradable percent fork keeper");
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
        vm.skip(!vm.envOr("TRADABLE_PERCENT_FORK", false), "set TRADABLE_PERCENT_FORK=true");
        uint256 forkBlock = vm.envUint("TRADABLE_PERCENT_FORK_BLOCK");
        vm.createSelectFork(
            vm.envOr("TRADABLE_PERCENT_FORK_RPC", string("https://rpc.testnet.chain.robinhood.com")), forkBlock
        );
        assertEq(block.chainid, 46630, "Robinhood testnet only");
        emit log_named_uint("tradable percent fork block", forkBlock);
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
        registration = new RegisterV2TradablePercent().register(factory.owner(), factory, DEPENDENCIES, AUDIT);
        assertEq(registration.kind, firstNewKind);
        assertEq(registry.kindCount(), uint256(firstNewKind) + 1);
        _assertLegacyKindsUnchanged();
    }

    function test_registrationAppendsSchemaThreeAndPreservesLegacyManifestsAndChunks() public {
        new RegisterV2TradablePercent().check(factory, registration, DEPENDENCIES, AUDIT);
        _assertLegacyKindsUnchanged();
        assertEq(controller.owner(), factory.owner());
        assertEq(controller.UPGRADE_DELAY(), 2 days);
        assertEq(
            registry.policy(registration.policyKey).implementation.codehash,
            registry.policy(registration.policyKey).runtimeCodeHash
        );
    }

    function test_launchGraduationTradableRebalanceAndUpgradePreserveInventoryAndLpThenExecuteAgain() public {
        _openSession();
        Launch memory l = _launch();
        HedgeFunV2TradablePercentEngineTreasuryCore t = HedgeFunV2TradablePercentEngineTreasuryCore(address(l.treasury));
        _graduate(l);
        assertGt(t.bookedStock(), 0, "live session books graduation inventory");
        assertEq(t.buybackStock(), 0);
        {
            (bool healthy, uint256 capital, uint256 maxBuy, uint256 maxSell, uint256 daily,,,) = t.riskLimits();
            assertTrue(healthy);
            assertEq(capital, t.bookedStock() * t.avgCost() / 1e30, "only tradable stock, not locked LP, funds limits");
            assertEq(maxBuy, 0);
            assertEq(maxSell, t.bookedStock() / 5);
            assertEq(daily, (capital / 2) * 2);
        }
        _sellOnce(t);
        uint64 nonceBefore = t.strategyNonce();
        assertEq(nonceBefore, 1);
        assertGt(t.reserveUsdg(), 0);
        Snapshot memory before = _snapshot(l);
        {
            bytes32 configBefore = t.configHash();
            HedgeFunV2TradablePercentEngineTreasury proxy = HedgeFunV2TradablePercentEngineTreasury(payable(address(t)));
            HedgeFunV2TradablePercentEngineTreasuryLogic next = new HedgeFunV2TradablePercentEngineTreasuryLogic(
                address(usdg),
                address(stock),
                venue,
                oracle,
                address(l.token),
                address(factory.poolManager()),
                address(factory),
                t.params(),
                EngineBinding(t.engineConfig(), registry.policy(registration.policyKey), address(proxy))
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

    function _sellOnce(HedgeFunV2TradablePercentEngineTreasuryCore t) private {
        uint256 inventory = t.bookedStock();
        uint256 reserve = t.reserveUsdg();
        (bool due,, uint256 proposed) = t.preview();
        assertTrue(due);
        (,,, uint256 maxSell,,,,) = t.riskLimits();
        uint256 remaining = _sellRemaining(t);
        assertLe(proposed, maxSell);
        uint256 beforeUsed = t.turnoverInEpoch();
        uint64 previousEpoch = t.turnoverEpoch();
        vm.prank(keeper);
        (HedgeFunV2Treasury.Action action,) = t.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.RebalanceSell));
        assertLt(t.bookedStock(), inventory);
        assertGt(t.reserveUsdg(), reserve, "stock really traded for USDG on the deployed venue");
        uint256 usedNow = t.turnoverInEpoch();
        uint256 increment = previousEpoch == t.turnoverEpoch() ? usedNow - beforeUsed : usedNow;
        assertLe(increment, remaining, "actual fill respects the remaining daily budget");
        assertLe(inventory - t.bookedStock(), proposed);
        emit log_named_uint("proposed sell stock", proposed);
        emit log_named_uint("actual turnover USDG", increment);
    }

    function _sellRemaining(HedgeFunV2TradablePercentEngineTreasuryCore t) private view returns (uint256) {
        (,,, uint256 cap,, uint256 sold) = t.dailyRiskLimits();
        return cap > sold ? cap - sold : 0;
    }

    function _launch() private returns (Launch memory l) {
        HedgeFunFactory.Defaults memory d = factory.getDefaults();
        HedgeFunFactory.Request memory q;
        q.name = "Tradable percentage fork rehearsal";
        q.symbol = "TRADABLE";
        q.nonce = registration.kind;
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
        registry.setEngineConfig(q.symbol, q.nonce, registration.kind, _engineConfig());
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

    function _engineConfig() private view returns (EngineConfig memory c) {
        c.schema = 3;
        c.engineVersion = 1;
        c.policyKey = registration.policyKey;
        c.words[0] = bytes32(uint256(5000) | uint256(500) << 16 | uint256(600) << 32);
        c.words[1] = bytes32(uint256(2000) | uint256(2000) << 16);
        c.words[2] = bytes32(uint256(5000));
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
        // This kind uses only fixed-size ledger state (no strategy lots).
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
