// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2EngineTreasury, HedgeFunV2EngineTreasuryCore} from "../src/v2/HedgeFunV2EngineTreasury.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {
    EngineConfig,
    IStrategyPolicy,
    StrategyCapabilities,
    StrategyContext,
    StrategyIntent
} from "../src/v2/strategy/IStrategyPolicy.sol";
import {SpotEngineConfig} from "../src/v2/strategy/SpotEngineConfig.sol";
import {V2RebalancePolicy} from "../src/v2/strategy/V2RebalancePolicy.sol";
import {EngineVenue} from "./V2StrategyEngine.t.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

/// @dev A policy for some future engine version that reuses config schema 1 with its own meaning for the words.
contract OtherEngineSchemaOnePolicy is IStrategyPolicy {
    function policyMetadata() external pure returns (uint32, uint32, uint256) {
        return (
            StrategyCapabilities.OPTIONS_ENGINE_V1,
            StrategyCapabilities.CONFIG_SCHEMA_V1,
            StrategyCapabilities.OPTIONS_WRITE
        );
    }

    function decide(StrategyContext calldata, EngineConfig calldata, bytes32)
        external
        pure
        returns (StrategyIntent memory intent)
    {}
}

/// @notice The engine's config words are validated by ONE function, `SpotEngineConfig.valid`, run by the engine
///         constructor (the authority) and by `V2TreasuryDeployer` (`setEngineConfig`, `predict`, `deploy`). A
///         constructor's revert reason does not survive CREATE2, so every refusal must also happen in the deployer,
///         by name, before a quote is given -- audit round 4 E-1, E-6, C-4, X-5.
///
/// Every case below hands the SAME words and the SAME listing `Params` to both paths: the deployer's
/// `setEngineConfig` then `predict` (the factory's own call), and the engine constructor directly, as the deployer
/// would run it. They must agree: both accept, or both refuse with `BadEngineConfig`.
///
/// The floors are tested at their edges: `deadbandBps >= 2 x (maxSlippageBps + poolFeeBps + bountyBps)`,
/// `cooldown >= 600`, `targetBps` in [2,000, 9,000], `maxDailyTurnoverUsdg <= 24 x maxTradeUsdg`.
contract V2StrategyEngineConfigTest is V2FactoryFixture {
    address private constant TOKEN = address(0x70CE);
    uint256 private constant MIN_LOT = 5e6; // the fixture's `minLotUsdg`
    uint256 private constant CHUNK = 1_000e6; // a binding `sellChunkUsdg` (the fixture's default is uint128.max)

    V2TreasuryDeployer internal deployer;
    EngineVenue internal venue;
    bytes32 internal policyKey;
    uint8 internal engineKind;
    address internal chunkA;
    address internal chunkB;
    uint96 internal nextNonce = 1_000;

    struct Verdict {
        bool ok;
        bytes4 error;
        bool atConfiguration; // refused by `setEngineConfig`, before the listing's `Params` are known
    }

    function setUp() public {
        _setUpV2(18);
        venue = new EngineVenue(address(stock), address(usdg), 3000, 1e30, 100e18);
        stockPool = venue;
        v3f.set(address(stock), address(usdg), 3000, address(venue));
        vm.prank(owner);
        factory.list(address(stock), address(oracle), address(venue), openPrice, true);
        deployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        (chunkA, chunkB) = deployer.makeChunks(type(HedgeFunV2EngineTreasury).creationCode);
        vm.startPrank(owner);
        policyKey = deployer.registerPolicy(
            address(new V2RebalancePolicy()), 150_000, 160, keccak256("config-deps"), keccak256("config-audit")
        );
        engineKind = deployer.registerEngineKind(
            chunkA,
            chunkB,
            StrategyCapabilities.SPOT_ENGINE_V1,
            StrategyCapabilities.CONFIG_SCHEMA_V1,
            StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------ helpers

    function _config(uint256 target, uint256 deadband, uint256 cooldown, uint256 maxTrade, uint256 maxDaily)
        internal
        view
        returns (EngineConfig memory c)
    {
        c.schema = StrategyCapabilities.CONFIG_SCHEMA_V1;
        c.engineVersion = StrategyCapabilities.SPOT_ENGINE_V1;
        c.policyKey = policyKey;
        c.words[0] = bytes32(target | deadband << 16 | cooldown << 32);
        c.words[1] = bytes32(maxTrade);
        c.words[2] = bytes32(maxDaily);
    }

    /// the fixture listing's `Params`, as `HedgeFunFactory._lotParams` builds them, with a chosen chunk and slippage
    function _params(uint256 sellChunkUsdg, uint16 maxSlippageBps)
        internal
        pure
        returns (HedgeFunTreasuryBase.Params memory p)
    {
        p.tp1Bps = 1000;
        p.tp2Bps = 2000;
        p.dipBps = 1000;
        p.stopBps = 500;
        p.lotBps = 2000;
        p.bountyBps = 50;
        p.maxSlippageBps = maxSlippageBps;
        p.maxDeviationBps = 50;
        p.maxBuybackImpactBps = 300;
        p.buybackCooldown = 60;
        p.minLotUsdg = MIN_LOT;
        p.buybackChunkUsdg = 500e6;
        p.sellChunkUsdg = sellChunkUsdg;
    }

    function _params() internal pure returns (HedgeFunTreasuryBase.Params memory) {
        return _params(CHUNK, 100);
    }

    /// what the deployer says about (c, p): `setEngineConfig`, then `predict` with the factory's argument layout
    function _deployerVerdict(EngineConfig memory c, HedgeFunTreasuryBase.Params memory p)
        internal
        returns (Verdict memory v)
    {
        uint96 nonce = nextNonce++;
        try deployer.setEngineConfig("CFG", nonce, engineKind, c) {}
        catch (bytes memory err) {
            return Verdict(false, bytes4(err), true);
        }
        bytes memory args = abi.encode(
            address(usdg), address(stock), address(venue), address(oracle), TOKEN, address(pm), address(factory), p
        );
        try deployer.predict(keccak256(abi.encode("CFG", address(this), nonce)), args) returns (address) {
            v.ok = true;
        } catch (bytes memory err) {
            v.error = bytes4(err);
        }
    }

    /// what the engine constructor says about (c, p), run exactly as the deployer's CREATE2 runs it
    function _constructorVerdict(EngineConfig memory c, HedgeFunTreasuryBase.Params memory p)
        internal
        returns (Verdict memory v)
    {
        vm.prank(address(deployer));
        try new HedgeFunV2EngineTreasury(
            address(usdg), address(stock), address(venue), address(oracle), TOKEN, address(pm), address(factory), p, c
        ) returns (HedgeFunV2EngineTreasury) {
            v.ok = true;
        } catch (bytes memory err) {
            v.error = bytes4(err);
        }
    }

    function _assertBothAccept(EngineConfig memory c, HedgeFunTreasuryBase.Params memory p, string memory what)
        internal
    {
        Verdict memory d = _deployerVerdict(c, p);
        Verdict memory k = _constructorVerdict(c, p);
        assertTrue(d.ok, string.concat("deployer refused: ", what));
        assertTrue(k.ok, string.concat("constructor refused: ", what));
    }

    /// @param atConfiguration whether the deployer can refuse it at `setEngineConfig`, with no listing data
    function _assertBothRefuse(
        EngineConfig memory c,
        HedgeFunTreasuryBase.Params memory p,
        bool atConfiguration,
        string memory what
    ) internal {
        Verdict memory d = _deployerVerdict(c, p);
        Verdict memory k = _constructorVerdict(c, p);
        assertFalse(d.ok, string.concat("deployer accepted: ", what));
        assertEq(d.error, V2TreasuryDeployer.BadEngineConfig.selector, string.concat("deployer error: ", what));
        assertEq(d.atConfiguration, atConfiguration, string.concat("deployer stage: ", what));
        assertFalse(k.ok, string.concat("constructor accepted: ", what));
        assertEq(k.error, HedgeFunV2EngineTreasuryCore.BadEngineConfig.selector, string.concat("constructor error: ", what));
    }

    // ------------------------------------------------------------------------------ the bounds (E-1, E-6, C-4)

    function test_aCompliantConfigIsAcceptedByBothPaths() public {
        _assertBothAccept(_config(5000, 500, 600, 100e6, 500e6), _params(), "the fixture config");
        EngineConfig memory allGains = _config(5000, 500, 600, 100e6, 500e6);
        allGains.words[0] |= bytes32(uint256(10_000) << 64);
        _assertBothAccept(allGains, _params(), "payoutBps == BPS");
    }

    /// E-1: an action under the core's minimum lot can never execute; such a treasury is inert for life
    function test_maxTradeBelowTheMinimumLotIsRefusedByBothPaths() public {
        _assertBothRefuse(_config(5000, 500, 600, MIN_LOT - 1, 50e6), _params(), false, "maxTrade < minLot");
        _assertBothAccept(_config(5000, 500, 600, MIN_LOT, 50e6), _params(), "maxTrade == minLot");
    }

    /// E-6 coverage note: no test had ever made the `maxTrade <= sellChunkUsdg` limb binding
    function test_maxTradeAboveTheListingChunkIsRefusedByBothPaths() public {
        _assertBothRefuse(_config(5000, 500, 600, CHUNK + 1, 2 * CHUNK + 2), _params(), false, "maxTrade > chunk");
        _assertBothAccept(_config(5000, 500, 600, CHUNK, 2 * CHUNK), _params(), "maxTrade == chunk");
    }

    /// C-4: every bound that needs no listing data is refused by name at configuration and by the constructor
    function test_everyWordBoundIsRefusedByBothPaths() public {
        EngineConfig memory reserved = _config(5000, 500, 600, 100e6, 500e6);
        reserved.words[0] |= bytes32(uint256(1) << 80); // the lowest reserved bit: 64..79 are `payoutBps`
        _assertBothRefuse(reserved, _params(), true, "reserved bits");
        EngineConfig memory overPaid = _config(5000, 500, 600, 100e6, 500e6);
        overPaid.words[0] |= bytes32(uint256(10_001) << 64);
        _assertBothRefuse(overPaid, _params(), true, "payoutBps > BPS");
        _assertBothRefuse(_config(0, 500, 600, 100e6, 500e6), _params(), true, "target == 0");
        _assertBothRefuse(_config(10_000, 500, 600, 100e6, 500e6), _params(), true, "target == BPS");
        _assertBothRefuse(_config(5000, 0, 600, 100e6, 500e6), _params(), true, "deadband == 0");
        _assertBothRefuse(_config(3000, 3000, 600, 100e6, 500e6), _params(), true, "deadband == target");
        _assertBothRefuse(_config(8000, 2000, 600, 100e6, 500e6), _params(), true, "target + deadband == BPS");
        _assertBothRefuse(_config(5000, 500, 0, 100e6, 500e6), _params(), true, "cooldown == 0");
        _assertBothRefuse(_config(5000, 500, 600, 0, 500e6), _params(), true, "maxTrade == 0");
        _assertBothRefuse(_config(5000, 500, 600, 100e6, 100e6 - 1), _params(), true, "maxDaily < maxTrade");
    }

    /// E-6: the factory's own `predict` names the refusal instead of quoting a launch CREATE2 would fail opaquely
    function test_factoryPredictNamesTheRefusalInsteadOfQuotingAnUnlaunchableConfig() public {
        HedgeFunFactory.Request memory q = _request();
        deployer.setEngineConfig(q.symbol, q.nonce, engineKind, _config(5000, 500, 600, MIN_LOT - 1, 50e6));
        vm.expectRevert(V2TreasuryDeployer.BadEngineConfig.selector);
        factory.predict(q);
    }

    // ------------------------------------------------------------------------------------ the floors (E-2, X-5)

    /// E-2: V1's tp1/dip rule -- the band must clear its own execution friction twice over -- and it follows the
    ///      listing's gates, so it is refused at `predict`, where the pool fee and `maxSlippageBps` are known
    function test_deadbandFloorIsTwiceTheListingFrictionOnBothPaths() public {
        assertEq(SpotEngineConfig.minDeadbandBps(100, 30, 50), 360, "slippage + pool + executor reward");
        _assertBothRefuse(_config(5000, 1, 600, 100e6, 500e6), _params(), false, "deadband 1 bp");
        _assertBothRefuse(_config(5000, 359, 600, 100e6, 500e6), _params(), false, "deadband 359 < 2 x 180");
        _assertBothAccept(_config(5000, 360, 600, 100e6, 500e6), _params(), "deadband 360 == 2 x 180");
        _assertBothRefuse(_config(5000, 559, 600, 100e6, 500e6), _params(CHUNK, 200), false, "deadband 559 < 2 x 280");
        _assertBothAccept(_config(5000, 560, 600, 100e6, 500e6), _params(CHUNK, 200), "deadband 560 == 2 x 280");
        HedgeFunTreasuryBase.Params memory free = _params();
        free.bountyBps = 0;
        _assertBothAccept(_config(5000, 260, 600, 100e6, 500e6), free, "zero bounty preserves prior floor");
        free.bountyBps = 200;
        _assertBothRefuse(_config(5000, 659, 600, 100e6, 500e6), free, false, "maximum bounty needs 660 bps");
        _assertBothAccept(_config(5000, 660, 600, 100e6, 500e6), free, "maximum bounty floor");
    }

    /// X-5: one V3 TWAP window, so two actions never share one pinned mean and a day holds at most 144 actions
    function test_cooldownFloorIsSixtySecondsOnBothPaths() public {
        _assertBothRefuse(_config(5000, 500, 0, 100e6, 500e6), _params(), true, "cooldown 0 s");
        _assertBothRefuse(_config(5000, 500, 1, 100e6, 500e6), _params(), true, "cooldown 1 s");
        _assertBothRefuse(_config(5000, 500, 59, 100e6, 500e6), _params(), true, "cooldown 59 s");
        _assertBothAccept(_config(5000, 500, 60, 100e6, 500e6), _params(), "cooldown 60 s");
        _assertBothAccept(_config(5000, 500, 600, 100e6, 500e6), _params(), "cooldown 600 s");
    }

    /// X-5: under 20% the engine liquidates the graduation lot; over 90% the band has no room
    function test_targetIsBetweenTwentyAndNinetyPercentOnBothPaths() public {
        _assertBothRefuse(_config(1, 500, 600, 100e6, 500e6), _params(), true, "target 1 bp");
        _assertBothRefuse(_config(1999, 500, 600, 100e6, 500e6), _params(), true, "target 1,999");
        _assertBothAccept(_config(2000, 500, 600, 100e6, 500e6), _params(), "target 2,000");
        _assertBothAccept(_config(9000, 500, 600, 100e6, 500e6), _params(), "target 9,000");
        _assertBothRefuse(_config(9001, 500, 600, 100e6, 500e6), _params(), true, "target 9,001");
    }

    /// X-5: a daily cap over 24 actions no longer bounds a day; the ceiling's own product cannot overflow
    function test_dailyTurnoverIsAtMostTwentyFourActionsOnBothPaths() public {
        _assertBothAccept(_config(5000, 500, 600, 100e6, 2_400e6), _params(), "maxDaily == 24 x maxTrade");
        _assertBothRefuse(_config(5000, 500, 600, 100e6, 2_400e6 + 1), _params(), true, "maxDaily > 24 x maxTrade");
        _assertBothRefuse(
            _config(5000, 500, 600, type(uint256).max / 24 + 1, type(uint256).max),
            _params(type(uint256).max, 100),
            true,
            "24 x maxTrade overflows"
        );
    }

    /// X-5's own example -- 1 bp band, 1 s cooldown, an unbounded day -- no longer launches
    function test_theRoundFourUnboundedConfigNoLongerLaunches() public {
        _assertBothRefuse(_config(5000, 1, 1, 100e6, type(uint256).max), _params(), true, "X-5 example");
    }

    /// Whatever the words, the deployer and the constructor give the same answer.
    function testFuzz_deployerAndConstructorAgree(
        uint16 target,
        uint16 deadband,
        uint32 cooldown,
        uint256 maxTrade,
        uint256 maxDaily,
        bool reservedBit,
        uint16 payout
    ) public {
        maxTrade = bound(maxTrade, 0, 2 * CHUNK);
        maxDaily = bound(maxDaily, 0, 30 * CHUNK);
        EngineConfig memory c = _config(target % 10_001, deadband % 5_001, cooldown % 2_001, maxTrade, maxDaily);
        if (reservedBit) c.words[0] |= bytes32(uint256(1) << 200);
        c.words[0] |= bytes32(uint256(payout % 10_002) << 64); // up to one over BPS
        Verdict memory d = _deployerVerdict(c, _params());
        Verdict memory k = _constructorVerdict(c, _params());
        assertEq(d.ok, k.ok, "the deployer and the constructor disagree");
        if (!d.ok) {
            assertEq(d.error, V2TreasuryDeployer.BadEngineConfig.selector);
            assertEq(k.error, HedgeFunV2EngineTreasuryCore.BadEngineConfig.selector);
        }
    }

    /// The spot engine's word layout is the spot engine's alone: a kind registered for another engine version that
    /// reuses schema 1 is not refused by it at `setEngineConfig` or `predict` (that engine's own constructor is its
    /// authority). The same words under the spot kind are refused.
    function test_spotBoundsApplyOnlyToTheSpotEngineVersion() public {
        vm.startPrank(owner);
        uint8 otherKind = deployer.registerEngineKind(
            chunkA,
            chunkB,
            StrategyCapabilities.OPTIONS_ENGINE_V1,
            StrategyCapabilities.CONFIG_SCHEMA_V1,
            StrategyCapabilities.OPTIONS_WRITE
        );
        bytes32 otherKey = deployer.registerPolicy(
            address(new OtherEngineSchemaOnePolicy()), 150_000, 160, keccak256("other-deps"), keccak256("other-audit")
        );
        vm.stopPrank();
        EngineConfig memory c; // every word zero: under the spot layout, every bound fails
        c.schema = StrategyCapabilities.CONFIG_SCHEMA_V1;
        c.engineVersion = StrategyCapabilities.OPTIONS_ENGINE_V1;
        c.policyKey = otherKey;
        deployer.setEngineConfig("OTHER", 1, otherKind, c);
        bytes memory args = abi.encode(
            address(usdg), address(stock), address(venue), address(oracle), TOKEN, address(pm), address(factory),
            _params()
        );
        deployer.predict(keccak256(abi.encode("OTHER", address(this), uint96(1))), args);

        c.engineVersion = StrategyCapabilities.SPOT_ENGINE_V1;
        c.policyKey = policyKey;
        vm.expectRevert(V2TreasuryDeployer.BadEngineConfig.selector);
        deployer.setEngineConfig("OTHER", 2, engineKind, c);
    }
}
