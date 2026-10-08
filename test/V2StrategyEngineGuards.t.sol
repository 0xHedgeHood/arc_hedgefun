// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2EngineTreasury, HedgeFunV2EngineTreasuryCore} from "../src/v2/HedgeFunV2EngineTreasury.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {V2LiquidityVault} from "../src/v2/V2LiquidityVault.sol";
import {BoundDeployer} from "../src/HedgeFunDeployers.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {
    EngineConfig,
    IStrategyPolicy,
    StrategyAction,
    StrategyCapabilities,
    StrategyContext,
    StrategyIntent
} from "../src/v2/strategy/IStrategyPolicy.sol";
import {V2RebalancePolicy} from "../src/v2/strategy/V2RebalancePolicy.sol";
import {SwitchableCalendar} from "./mocks/Mocks.sol";
import {EngineAccountingVenue} from "./V2StrategyEngineAccounting.t.sol";
import {GasBombStrategyPolicy, HonestBuyPolicy, SpotRawActionStrategyPolicy} from "./mocks/StrategyPolicyMocks.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

/// @dev Proposes a real 50 USDG buy, echoing `nonce + offset`. With offset 1 only the engine's nonce check stops it.
///      (The repository's `WrongNonceStrategyPolicy` proposes 1 wei, which the minimum-lot gate refuses with the same
///      `NotDue` whether or not the nonce is checked, so it cannot pin the nonce check.)
contract NonceOffsetBuyPolicy is IStrategyPolicy {
    uint64 internal immutable offset;

    constructor(uint64 offset_) {
        offset = offset_;
    }

    function policyMetadata() external pure returns (uint32, uint32, uint256) {
        return (
            StrategyCapabilities.SPOT_ENGINE_V1,
            StrategyCapabilities.CONFIG_SCHEMA_V1,
            StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL
        );
    }

    function decide(StrategyContext calldata context, EngineConfig calldata, bytes32 state)
        external
        view
        returns (StrategyIntent memory)
    {
        return StrategyIntent(context.configHash, context.nonce + offset, StrategyAction.BuyStock, 50e6, state);
    }
}

/// @dev Registered as SELL-only, proposes a BUY. The engine's capability check is the only thing that stops it.
contract SellOnlyPolicyThatBuys is IStrategyPolicy {
    function policyMetadata() external pure returns (uint32, uint32, uint256) {
        return (StrategyCapabilities.SPOT_ENGINE_V1, StrategyCapabilities.CONFIG_SCHEMA_V1, StrategyCapabilities.SPOT_SELL);
    }

    function decide(StrategyContext calldata context, EngineConfig calldata, bytes32 state)
        external
        pure
        returns (StrategyIntent memory)
    {
        return StrategyIntent(context.configHash, context.nonce, StrategyAction.BuyStock, 50e6, state);
    }
}

/// @dev Always proposes to sell everything, whatever the allocation says. Buy and sell capable.
contract AlwaysSellPolicy is IStrategyPolicy {
    function policyMetadata() external pure returns (uint32, uint32, uint256) {
        return (
            StrategyCapabilities.SPOT_ENGINE_V1,
            StrategyCapabilities.CONFIG_SCHEMA_V1,
            StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL
        );
    }

    function decide(StrategyContext calldata context, EngineConfig calldata, bytes32 state)
        external
        pure
        returns (StrategyIntent memory)
    {
        return StrategyIntent(context.configHash, context.nonce, StrategyAction.SellStock, type(uint256).max, state);
    }
}

/// @notice The guards `docs/STRATEGY_ENGINE.md` and the engine's NatSpec promise, each pinned by a test that fails
///         when the guard is deleted.
///
/// Adopted from audit round 4's claims lane (`audit/round-4-2026-09-27/poc/claims/AuditClaims4.t.sol` on
/// `audit/round-4-lane-claims`), whose mutation campaign deleted each of these guards with the whole suite green
/// (findings C-1 to C-4, C-8). Every test is named for the mutation in that lane's `mutations.md` it catches, so
/// the campaign can be replayed: `git apply` the diff, run this file, expect red. C14 is new: the `tryPrice()` limb of
/// C-2, which the lane left without a proof because no engine fixture ran a band launch through a closure.
///
/// C1 now uses a wrong-nonce policy that proposes a real amount: the lane's 1-wei version passed with the nonce check
/// deleted, because the minimum-lot gate refused it first. Configs follow the structural floors as first set (cooldown >= 600 s, now 60, deadband >= 2 x friction, target in 20..90%,
/// daily <= 24 x per action); the lane wrote them against a 60 s cooldown.
contract V2StrategyEngineGuardsTest is V2FactoryFixture {
    using PoolIdLibrary for PoolKey;

    uint256 private constant PRICE = 100e18;
    uint256 private constant SCALE = 1e30;
    uint256 private constant COOLDOWN = 600;
    address private constant TOKEN = address(0x70CE);

    V2TreasuryDeployer internal deployer;
    EngineAccountingVenue internal venue;
    uint8 internal engineKind;
    uint96 internal nextNonce = 400;

    function setUp() public {
        _setUpV2(18);
        venue = new EngineAccountingVenue(address(stock), address(usdg), 3000, SCALE, PRICE);
        stockPool = venue;
        v3f.set(address(stock), address(usdg), 3000, address(venue));
        vm.prank(owner);
        factory.list(address(stock), address(oracle), address(venue), openPrice, true);
        usdg.mint(address(venue), 10_000_000e6);
        stock.mint(address(venue), 100_000e18);
        deployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        (address a, address b) = deployer.makeChunks(type(HedgeFunV2EngineTreasury).creationCode);
        vm.prank(owner);
        engineKind = deployer.registerEngineKind(
            a,
            b,
            StrategyCapabilities.SPOT_ENGINE_V1,
            StrategyCapabilities.CONFIG_SCHEMA_V1,
            StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL
        );
    }

    // ------------------------------------------------------------------------------------------------ helpers

    function _register(address implementation, uint32 maxGas, bytes32 label) internal returns (bytes32 key) {
        vm.prank(owner);
        key = deployer.registerPolicy(
            implementation, maxGas, 160, keccak256(abi.encode("deps", label)), keccak256(abi.encode("audit", label))
        );
    }

    function _config(bytes32 key, uint256 target, uint256 deadband, uint256 cooldown, uint256 maxTrade, uint256 maxDaily)
        internal
        pure
        returns (EngineConfig memory c)
    {
        c.schema = StrategyCapabilities.CONFIG_SCHEMA_V1;
        c.engineVersion = StrategyCapabilities.SPOT_ENGINE_V1;
        c.policyKey = key;
        c.words[0] = bytes32(target | deadband << 16 | cooldown << 32);
        c.words[1] = bytes32(maxTrade);
        c.words[2] = bytes32(maxDaily);
    }

    function _defaultConfig(bytes32 key) internal pure returns (EngineConfig memory) {
        return _config(key, 5000, 500, COOLDOWN, 100e6, 500e6);
    }

    /// the `Params` the factory builds for this fixture's listing (`HedgeFunFactory._lotParams` over `_request()`)
    function _listingParams() internal pure returns (HedgeFunTreasuryBase.Params memory p) {
        p.tp1Bps = 500;
        p.tp2Bps = 1000;
        p.dipBps = 500;
        p.stopBps = 500;
        p.lotBps = 2000;
        p.bountyBps = 50;
        p.maxSlippageBps = 100;
        p.maxDeviationBps = 50;
        p.maxBuybackImpactBps = 300;
        p.buybackCooldown = 60;
        p.minLotUsdg = 5e6;
        p.buybackChunkUsdg = 500e6;
        p.sellChunkUsdg = type(uint128).max;
    }

    function _launch(EngineConfig memory c, HedgeFunFactory.Request memory q)
        internal
        returns (HedgeFunV2EngineTreasury treasury)
    {
        q.nonce = nextNonce++;
        deployer.setEngineConfig(q.symbol, q.nonce, engineKind, c);
        (,, bytes32 terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        (, address t,,,) = factory.strategies(id);
        treasury = HedgeFunV2EngineTreasury(t);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        stock.approve(address(curve), type(uint256).max);
        _graduateV2(curve);
    }

    function _launchPolicy(address implementation, uint32 maxGas, bytes32 label)
        internal
        returns (HedgeFunV2EngineTreasury)
    {
        return _launch(_defaultConfig(_register(implementation, maxGas, label)), _request());
    }

    function _stockValue(HedgeFunV2EngineTreasury t) internal view returns (uint256) {
        return Math.mulDiv(t.bookedStock(), PRICE, SCALE);
    }

    /// @dev mint USDG so that the stock share of total value is `shareBps`
    function _setShare(HedgeFunV2EngineTreasury t, uint256 shareBps) internal {
        uint256 v = _stockValue(t);
        uint256 usdgNeeded = v * (10_000 - shareBps) / shareBps;
        uint256 have = t.reserveUsdg();
        if (usdgNeeded > have) usdg.mint(address(t), usdgNeeded - have);
    }

    function _refreshFeeds() internal {
        stockFeed.set(100e8);
        usdgFeed.set(1e8);
    }

    // ------------------------------------------------------------------------------------------------ E01
    /// catches E01-nonce: a policy that echoes nonce + 1 must be refused and consume nothing. Adapted: the lane's
    /// version used a 1-wei buy, which never reaches the nonce check's absence (see `NonceOffsetBuyPolicy`)
    function test_C1_nonceMismatchFailsClosedAtTheCore() public {
        HedgeFunV2EngineTreasury t = _launchPolicy(address(new NonceOffsetBuyPolicy(1)), 100_000, "nonce");
        _setShare(t, 2500);
        uint256 usdgBefore = t.reserveUsdg();
        uint256 bookedBefore = t.bookedStock();
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        t.execute();
        assertEq(t.strategyNonce(), 0);
        assertEq(t.reserveUsdg(), usdgBefore);
        assertEq(t.bookedStock(), bookedBefore);
        // control: the same buy with the right nonce executes, so the refusal above is the nonce's
        HedgeFunV2EngineTreasury c = _launchPolicy(address(new NonceOffsetBuyPolicy(0)), 100_000, "nonce-control");
        _setShare(c, 2500);
        c.execute();
        assertEq(c.strategyNonce(), 1);
    }

    // ------------------------------------------------------------------------------------------------ E03
    /// catches E03-codehash-exec: code replaced AFTER launch must be refused at execute() and preview()
    function test_C2_policyCodeReplacementAfterLaunchFailsClosed() public {
        V2RebalancePolicy honest = new V2RebalancePolicy();
        HedgeFunV2EngineTreasury t = _launchPolicy(address(honest), 150_000, "honest");
        (bool due,,) = t.preview();
        assertTrue(due, "control: overweight after graduation, a sell is due");
        vm.etch(address(honest), address(new HonestBuyPolicy()).code);
        vm.expectRevert(HedgeFunV2EngineTreasuryCore.PolicyUnavailable.selector);
        t.execute();
        vm.expectRevert(HedgeFunV2EngineTreasuryCore.PolicyUnavailable.selector);
        t.preview();
        assertEq(t.strategyNonce(), 0);
    }

    // ------------------------------------------------------------------------------------------------ E04
    /// catches E04-gas: an infinite-loop policy must cost the caller about maxGas, not the whole block
    function test_C3_gasBombIsBoundedByTheRegisteredGas() public {
        HedgeFunV2EngineTreasury t = _launchPolicy(address(new GasBombStrategyPolicy()), 100_000, "bomb");
        uint256 before = gasleft();
        vm.expectRevert(HedgeFunV2EngineTreasuryCore.PolicyFailure.selector);
        t.execute();
        uint256 used = before - gasleft();
        assertLt(used, 1_500_000, "policy gas must be bounded by the registered maxGas, not gas()");
    }

    // ------------------------------------------------------------------------------------------------ E08
    /// catches E08-capability: SELL-only policy proposing a BUY on an underweight treasury
    function test_C4_sellOnlyPolicyCannotBuy() public {
        HedgeFunV2EngineTreasury t = _launchPolicy(address(new SellOnlyPolicyThatBuys()), 100_000, "sellonly");
        assertEq(t.policyCapabilities(), StrategyCapabilities.SPOT_SELL);
        _setShare(t, 2500);
        uint256 usdgBefore = t.reserveUsdg();
        vm.expectRevert(HedgeFunV2EngineTreasuryCore.BadIntent.selector);
        t.execute();
        assertEq(t.reserveUsdg(), usdgBefore);
        assertEq(t.strategyNonce(), 0);
    }

    // ------------------------------------------------------------------------------------------------ E10
    /// catches E10-direction: a sell proposed INSIDE the deadband (above target, below upper) must be refused
    function test_C5_sellInsideTheDeadbandIsRefused() public {
        HedgeFunV2EngineTreasury t = _launchPolicy(address(new AlwaysSellPolicy()), 100_000, "alwayssell");
        _setShare(t, 5300); // target 50%, deadband 5% -> upper band 55%
        uint256 bookedBefore = t.bookedStock();
        vm.expectRevert(HedgeFunV2EngineTreasuryCore.BadIntent.selector);
        t.execute();
        assertEq(t.bookedStock(), bookedBefore);
        (bool due,,) = t.preview();
        assertFalse(due);
        // control: outside the band the same policy sells
        HedgeFunV2EngineTreasury t2 = _launchPolicy(address(new AlwaysSellPolicy()), 100_000, "alwayssell2");
        _setShare(t2, 5700);
        t2.execute();
        assertEq(t2.strategyNonce(), 1);
    }

    // ------------------------------------------------------------------------------------------------ E18
    /// catches E18-action-range (ported: the range check now runs on the raw word, before the enum decode): an
    /// undeclared action word is `BadPolicyReturn`, where `abi.decode` alone reverts with empty data (the lane's C6
    /// recorded that empty revert at 5aedceb, when the check sat after the decode and could never fire)
    function test_C6_outOfRangeActionWordIsRefusedByNameBeforeTheDecode() public {
        HedgeFunV2EngineTreasury t = _launchPolicy(address(new SpotRawActionStrategyPolicy()), 100_000, "raw");
        vm.expectRevert(HedgeFunV2EngineTreasuryCore.BadPolicyReturn.selector);
        t.execute();
        assertEq(t.strategyNonce(), 0);
    }

    // ------------------------------------------------------------------------------------------------ E24
    /// catches E24-enabled-both: a salt configured BEFORE the disable must not predict or launch AFTER it
    function test_C7_disabledPolicyCannotLaunchAnAlreadyConfiguredSalt() public {
        bytes32 key = _register(address(new V2RebalancePolicy()), 150_000, "disable");
        HedgeFunFactory.Request memory q = _request();
        q.nonce = nextNonce++;
        deployer.setEngineConfig(q.symbol, q.nonce, engineKind, _defaultConfig(key));
        (,, bytes32 terms) = factory.predict(q);
        vm.prank(owner);
        deployer.disablePolicy(key);
        vm.expectRevert(V2TreasuryDeployer.BadPolicy.selector);
        factory.predict(q);
        vm.expectRevert();
        factory.launch(q, terms);
    }

    // ------------------------------------------------------------------------------------------------ doc claim
    /// STRATEGY_ENGINE.md: "The cooldown remains active across the epoch boundary" -- no other test pins it
    function test_C8_cooldownSurvivesTheEpochBoundary() public {
        HedgeFunV2EngineTreasury t = _launchPolicy(address(new AlwaysSellPolicy()), 100_000, "epoch");
        uint256 boundary = (block.timestamp / 1 days + 1) * 1 days;
        vm.warp(boundary - COOLDOWN / 2);
        _refreshFeeds();
        t.execute();
        assertEq(t.turnoverEpoch(), uint64((boundary - COOLDOWN / 2) / 1 days));
        vm.warp(boundary + 1); // a new UTC day, still inside the cooldown
        _refreshFeeds();
        vm.expectRevert(HedgeFunTreasuryBase.Cooldown.selector);
        t.execute();
        vm.warp(boundary + COOLDOWN / 2);
        _refreshFeeds();
        t.execute();
        assertEq(t.turnoverEpoch(), uint64(boundary / 1 days), "the epoch rolled while the cooldown held");
        assertEq(t.turnoverInEpoch(), 100e6, "the new epoch starts its turnover from zero");
    }

    /// The floor is the least a creator may choose: at 60 seconds an engine acts again a minute later, and not a
    /// second sooner.
    function test_aSixtySecondCooldownActsAgainAfterAMinute() public {
        bytes32 key = _register(address(new AlwaysSellPolicy()), 100_000, "minute");
        HedgeFunV2EngineTreasury t = _launch(_config(key, 5000, 500, 60, 100e6, 500e6), _request());
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1 hours); // well inside one UTC day
        _refreshFeeds();
        t.execute();
        uint256 first = block.timestamp;
        assertEq(t.turnoverInEpoch(), 100e6);
        vm.warp(first + 59);
        _refreshFeeds();
        vm.expectRevert(HedgeFunTreasuryBase.Cooldown.selector);
        t.execute();
        vm.warp(first + 60);
        _refreshFeeds();
        t.execute();
        assertEq(t.turnoverInEpoch(), 200e6, "a second action one minute after the first");
    }

    // ------------------------------------------------------------------------------------------------ D01-D03
    /// catches D01/D02/D03: registry writes are factory-owner only
    function test_C9_registryWritesAreOwnerOnly() public {
        address stranger = address(0xBAD);
        V2RebalancePolicy p = new V2RebalancePolicy();
        (address a, address b) = deployer.makeChunks(type(HedgeFunV2EngineTreasury).creationCode);
        bytes32 key = _register(address(p), 150_000, "owner");
        vm.startPrank(stranger);
        vm.expectRevert(V2TreasuryDeployer.NotOwner.selector);
        deployer.registerPolicy(address(p), 150_000, 160, keccak256("x"), keccak256("y"));
        vm.expectRevert(V2TreasuryDeployer.NotOwner.selector);
        deployer.registerEngineKind(a, b, 1, 1, 3);
        vm.expectRevert(V2TreasuryDeployer.NotOwner.selector);
        deployer.disablePolicy(key);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------ D05
    /// catches D05-deploy-onlyFactory
    function test_C10_deployIsFactoryOnly() public {
        vm.expectRevert(BoundDeployer.NotFactory.selector);
        deployer.deploy(bytes32(0), "");
    }

    // ------------------------------------------------------------------------------------------------ V02
    /// catches V02-no-clear: a second stock-fee collection must deliver again and leave the vault empty
    function test_C11_secondStockFeeCollectionDeliversAgain() public {
        (, HedgeFunBondingCurve curve, PoolKey memory key) = _launchV2(true);
        _graduateV2(curve);
        HedgeFunV2Treasury treasury = HedgeFunV2Treasury(curve.treasury());
        V2LiquidityVault vault = V2LiquidityVault(hook.liquidityVaultOf(key.toId()));
        PoolSwapTest router = new PoolSwapTest(pm);
        stock.approve(address(router), type(uint256).max);
        bool stockIs0 = address(stock) < address(curve.token());
        for (uint256 i; i < 2; ++i) {
            router.swap(
                key,
                SwapParams({
                    zeroForOne: stockIs0,
                    amountSpecified: -int256(5e18),
                    sqrtPriceLimitX96: stockIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
            uint256 buybackBefore = treasury.buybackStock();
            (uint256 stockFee,) = vault.collectFees();
            assertGt(stockFee, 0, "each collection must deliver the new fee");
            assertEq(treasury.buybackStock(), buybackBefore + stockFee);
            assertEq(stock.balanceOf(address(vault)), 0, "nothing may stay parked after a successful delivery");
        }
    }

    // ------------------------------------------------------------------------------------------------ E17
    /// catches E17-config-bounds: every bound and floor is refused by the engine constructor ITSELF, not only by
    /// the deployer's mirror of it (a constructor that stopped checking would otherwise go unnoticed, since the
    /// deployer now refuses first). And the deployer refuses each one by name, before any quote.
    function test_C12_engineConfigBoundsAreEnforcedAtConstruction() public {
        bytes32 key = _register(address(new V2RebalancePolicy()), 150_000, "bounds");
        EngineConfig[12] memory bad = [
            _config(key, 5000, 5000, COOLDOWN, 100e6, 500e6), // deadband >= target
            _config(key, 9000, 1000, COOLDOWN, 100e6, 500e6), // target + deadband >= 10000
            _config(key, 5000, 500, 0, 100e6, 500e6), // cooldown == 0
            _config(key, 5000, 500, COOLDOWN, 0, 500e6), // maxTrade == 0
            _config(key, 5000, 500, COOLDOWN, 100e6, 99e6), // maxDaily < maxTrade
            _config(key, 5000, 500, COOLDOWN, uint256(1) << 128, uint256(1) << 129), // maxTrade > sellChunkUsdg
            _config(key, 5000, 500, COOLDOWN, 4e6, 40e6), // maxTrade < minLotUsdg (E-1)
            _config(key, 5000, 259, COOLDOWN, 100e6, 500e6), // deadband < 2 x (100 + 30) (E-2)
            _config(key, 5000, 500, 59, 100e6, 500e6), // cooldown < 60 (X-5)
            _config(key, 1999, 500, COOLDOWN, 100e6, 500e6), // target < 20% (X-5)
            _config(key, 9001, 500, COOLDOWN, 100e6, 500e6), // target > 90% (X-5)
            _config(key, 5000, 500, COOLDOWN, 100e6, 2_400e6 + 1) // maxDaily > 24 x maxTrade (X-5)
        ];
        HedgeFunTreasuryBase.Params memory p = _listingParams();
        for (uint256 i; i < bad.length; ++i) {
            HedgeFunFactory.Request memory q = _request();
            q.nonce = nextNonce++;
            bool configured;
            try deployer.setEngineConfig(q.symbol, q.nonce, engineKind, bad[i]) {
                configured = true;
            } catch (bytes memory err) {
                assertEq(bytes4(err), V2TreasuryDeployer.BadEngineConfig.selector, "named at configuration");
            }
            if (configured) {
                vm.expectRevert(V2TreasuryDeployer.BadEngineConfig.selector);
                factory.predict(q);
            }
            vm.prank(address(deployer));
            vm.expectRevert(HedgeFunV2EngineTreasuryCore.BadEngineConfig.selector);
            new HedgeFunV2EngineTreasury(
                address(usdg), address(stock), address(venue), address(oracle), TOKEN, address(pm), address(factory),
                p, bad[i]
            );
        }
        // control: the same constructor, the same params, a compliant config
        vm.prank(address(deployer));
        new HedgeFunV2EngineTreasury(
            address(usdg), address(stock), address(venue), address(oracle), TOKEN, address(pm), address(factory), p,
            _defaultConfig(key)
        );
    }

    // ------------------------------------------------------------------------------------------------ E06
    /// catches E06-health: a venue 0.6% off the oracle (past the 50 bps gate, inside the 1% slippage bound)
    function test_C13_unhealthyVenueBlocksExecution() public {
        HedgeFunV2EngineTreasury t = _launchPolicy(address(new AlwaysSellPolicy()), 100_000, "health");
        venue.setPrice(1006e17);
        (bool ok,) = t.health();
        assertFalse(ok, "control: the deviation gate is shut");
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        t.execute();
        assertEq(t.strategyNonce(), 0);
    }

    // ------------------------------------------------------------------------------------------------ E07
    /// catches E07-live: a launch with a band (`bandBpsPerHour > 0`) in a SCHEDULED closure has `health()` ok off the
    /// frozen feed, which kind 0 may act on; the engine must still refuse, because `tryPrice()` is not live
    function test_C14_bandHealthInAScheduledClosureCannotTradeWithoutALiveOracle() public {
        SwitchableCalendar calendar = new SwitchableCalendar();
        PriceOracle closable = new PriceOracle(
            address(stock), address(stockFeed), address(usdgFeed), address(calendar), 26 hours, 26 hours
        );
        vm.startPrank(owner);
        factory.list(address(stock), address(closable), address(venue), openPrice, true);
        factory.setBandCeiling(address(stock), 200);
        vm.stopPrank();
        HedgeFunFactory.Request memory q = _request();
        q.bandBpsPerHour = 200;
        HedgeFunV2EngineTreasury t =
            _launch(_defaultConfig(_register(address(new AlwaysSellPolicy()), 100_000, "closure")), q);
        (bool due,,) = t.preview();
        assertTrue(due, "control: overweight after graduation, a sell is due while the market is open");

        calendar.setClosed(true);
        (bool ok,) = t.health();
        assertTrue(ok, "control: the band serves the frozen feed through a scheduled closure");
        (bool live,) = closable.tryPrice();
        assertFalse(live, "control: the oracle is not live while the market is shut");
        (due,,) = t.preview();
        assertFalse(due);
        uint256 bookedBefore = t.bookedStock();
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        t.execute();
        assertEq(t.strategyNonce(), 0);
        assertEq(t.bookedStock(), bookedBefore);
    }
}
