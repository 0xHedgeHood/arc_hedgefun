// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2AssetPercentEngineTreasury} from "../src/v2/HedgeFunV2AssetPercentEngineTreasury.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {V2AssetPercentRebalancePolicy} from "../src/v2/strategy/V2AssetPercentRebalancePolicy.sol";
import {EngineConfig, StrategyAction, StrategyContext, StrategyIntent} from "../src/v2/strategy/IStrategyPolicy.sol";
import {AssetPercentConfigHarness, V2AssetPercentEngineFixture} from "./V2AssetPercentEngine.t.sol";

contract V2AssetPercentConfigTest is V2AssetPercentEngineFixture {
    function test_wordValidationEdgesAndFullWidthPercentageWords() public {
        AssetPercentConfigHarness h = new AssetPercentConfigHarness();
        EngineConfig memory c = _percentConfig(1, 24, 0);
        assertTrue(h.valid(c.words, 360));
        c.words[2] = bytes32(uint256(25)); assertFalse(h.valid(c.words, 360));
        c = _percentConfig(10_000, 10_000, 10_000); assertTrue(h.valid(c.words, 500));
        c.words[1] = bytes32(uint256(10_001)); assertFalse(h.valid(c.words, 360));
        c = _percentConfig(1000, 10_001, 0); assertFalse(h.valid(c.words, 360));
        c = _percentConfig(1000, 999, 0); assertFalse(h.valid(c.words, 360));
        c = _percentConfig(0, 24, 0); assertFalse(h.valid(c.words, 360));
        c = _percentConfig(1000, 5000, 10_001); assertFalse(h.valid(c.words, 360));
        c = _percentConfig(1000, 5000, 0); c.words[0] |= bytes32(uint256(1) << 80);
        assertFalse(h.valid(c.words, 360));
        c = _percentConfig(1000, 5000, 0); c.words[1] |= bytes32(uint256(1) << 16);
        assertFalse(h.valid(c.words, 360), "percentage words never truncate high bits");
        c = _percentConfig(1000, 5000, 0); c.words[2] = bytes32(type(uint256).max);
        assertFalse(h.valid(c.words, 360), "invalid huge words refuse without multiplication overflow");
    }

    function test_allocationGeometryCooldownAndOptionalToolingMinimum() public {
        AssetPercentConfigHarness h = new AssetPercentConfigHarness();
        EngineConfig memory c = _percentConfig(1000, 5000, 0);
        c.words[0] = bytes32(uint256(2000) | uint256(360) << 16 | uint256(600) << 32);
        assertTrue(h.valid(c.words, 360));
        c.words[0] = bytes32(uint256(2000) | uint256(359) << 16 | uint256(600) << 32);
        assertFalse(h.valid(c.words, 360), "an optional tooling minimum is not the protocol minimum");
        assertTrue(h.valid(c.words, 0), "protocol core and policy impose no economic band minimum");
        c.words[0] = bytes32(uint256(2000) | uint256(600) << 32);
        assertTrue(h.valid(c.words, 0), "zero creator band is valid");
        c.words[0] |= bytes32(uint256(1) << 16);
        assertTrue(h.valid(c.words, 0), "one-bp creator band is valid");
        c.words[0] = bytes32(uint256(1999) | uint256(360) << 16 | uint256(600) << 32);
        assertFalse(h.valid(c.words, 360));
        c.words[0] = bytes32(uint256(9000) | uint256(999) << 16 | uint256(type(uint32).max) << 32);
        assertTrue(h.valid(c.words, 360));
        c.words[0] = bytes32(uint256(9000) | uint256(1000) << 16 | uint256(600) << 32);
        assertFalse(h.valid(c.words, 360));
        c.words[0] = bytes32(uint256(2000) | uint256(2000) << 16 | uint256(600) << 32);
        assertFalse(h.valid(c.words, 360));
        c.words[0] = bytes32(uint256(7000) | uint256(500) << 16 | uint256(599) << 32);
        assertFalse(h.valid(c.words, 360));
    }

    function _params() private view returns (HedgeFunTreasuryBase.Params memory p) {
        HedgeFunFactory.Defaults memory d = factory.getDefaults();
        p = HedgeFunTreasuryBase.Params(500, 1000, 500, 0, 2000, d.bountyBps, d.maxSlippageBps,
            d.maxDeviationBps, d.maxBuybackImpactBps, d.buybackCooldown, d.minLotUsdg, d.buybackChunkUsdg,
            d.sellChunkUsdg, 0);
    }

    function _construct(EngineConfig memory c, HedgeFunTreasuryBase.Params memory p) private returns (bool ok, bytes4 reason) {
        vm.prank(address(deployer));
        try new HedgeFunV2AssetPercentEngineTreasury(address(usdg), address(stock), address(venue),
            address(oracle), address(0x70CE), address(pm), address(factory), p, c)
            returns (HedgeFunV2AssetPercentEngineTreasury) { return (true, bytes4(0)); }
        catch (bytes memory err) { return (false, bytes4(err)); }
    }

    function test_constructorRejectsInvalidSchema2WordsByNameAndAcceptsRuntimeTinyCap() public {
        EngineConfig memory c = _percentConfig(1000, 5000, 0);
        (bool ok,) = _construct(c, _params()); assertTrue(ok);
        c.words[1] = bytes32(uint256(1)); c.words[2] = bytes32(uint256(24));
        (ok,) = _construct(c, _params()); assertTrue(ok, "small NAV is a runtime wait, not a configuration error");
        c.words[2] = bytes32(uint256(25));
        bytes4 error_;
        (ok, error_) = _construct(c, _params()); assertFalse(ok);
        assertEq(error_, HedgeFunV2AssetPercentEngineTreasury.BadEngineConfig.selector);
        c = _percentConfig(1000, 5000, 0); c.schema = 1;
        (ok, error_) = _construct(c, _params()); assertFalse(ok);
        assertEq(error_, HedgeFunV2AssetPercentEngineTreasury.BadEngineConfig.selector);
        c = _percentConfig(1000, 5000, 0);
        HedgeFunTreasuryBase.Params memory p = _params(); p.sellChunkUsdg = p.minLotUsdg - 1;
        (ok, error_) = _construct(c, p); assertFalse(ok);
        assertEq(error_, HedgeFunV2AssetPercentEngineTreasury.BadEngineConfig.selector);
    }

    function test_zeroCreatorBandDeploysWithHighFrictionAndPreservesExecution() public {
        _assertCreatorBand(0, 1002);
    }

    function test_oneBpCreatorBandDeploysWithHighFrictionAndPreservesExecution() public {
        _assertCreatorBand(1, 1003);
    }

    function _assertCreatorBand(uint256 band, uint96 nonce) private {
        HedgeFunFactory.Defaults memory d = factory.getDefaults();
        d.maxSlippageBps = 300;
        d.bountyBps = 200;
        vm.prank(owner); factory.setDefaults(d);
        HedgeFunFactory.Request memory q = _request();
        q.nonce = nonce;
        // These inherited lot-rule fields are not the schema-2 allocation band.
        q.tp1Bps = 2000; q.tp2Bps = 3000; q.dipBps = 2000; q.stopBps = 0;
        EngineConfig memory c = _percentConfig(1000, 5000, 0);
        c.words[0] = bytes32(uint256(7000) | band << 16 | uint256(600) << 32);
        deployer.setEngineConfig(q.symbol, q.nonce, percentKind, c);
        (,, bytes32 terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        (, address treasuryAddress,,,) = factory.strategies(id);
        HedgeFunV2AssetPercentEngineTreasury t = HedgeFunV2AssetPercentEngineTreasury(treasuryAddress);
        {
            HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
            stock.approve(address(curve), type(uint256).max);
            _graduateV2(curve);
        }
        assertEq(t.params().maxSlippageBps, 300);
        assertEq(t.params().bountyBps, 200);
        assertEq(uint16(uint256(t.engineConfig().words[0]) >> 16), band);
        bytes32 frozen = t.configHash();
        // Registry draft changes and future listing defaults cannot rewrite this deployed fund.
        c.words[0] |= bytes32(uint256(500) << 16);
        deployer.setEngineConfig(q.symbol, q.nonce, percentKind, c);
        d.maxSlippageBps = 100; d.bountyBps = 50;
        vm.prank(owner); factory.setDefaults(d);
        assertEq(t.configHash(), frozen);
        assertEq(uint16(uint256(t.engineConfig().words[0]) >> 16), band);
        assertEq(t.params().maxSlippageBps, 300); assertEq(t.params().bountyBps, 200);
        (bool due, StrategyAction action, uint256 amount) = t.preview();
        assertTrue(due); assertEq(uint256(action), uint256(StrategyAction.SellStock));
        uint256 bookedBefore = t.bookedStock(); uint256 reserveBefore = t.reserveUsdg();
        uint256 poolCashBefore = usdg.balanceOf(address(venue));
        Risk memory limits = _risk(t);
        address keeper = address(0xB07);
        vm.prank(keeper); t.execute();
        uint256 gross = poolCashBefore - usdg.balanceOf(address(venue));
        uint256 reward = Math.mulDiv(gross, 200, 10_000);
        assertEq(usdg.balanceOf(keeper), reward, "reward uses the frozen actual-fill rate");
        assertEq(t.reserveUsdg() - reserveBefore, gross - reward);
        assertEq(bookedBefore - t.bookedStock(), amount);
        assertEq(t.bookedStock() + t.buybackStock(), stock.balanceOf(address(t)));
        assertLe(t.turnoverInEpoch(), limits.trade); assertLe(t.turnoverInEpoch(), limits.remaining);
        assertEq(t.strategyNonce(), 1);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector); t.execute();
    }

    function test_constructorRejectsBadGeometryEvenWithoutEconomicBandMinimum() public {
        EngineConfig memory c = _percentConfig(1000, 5000, 0);
        c.words[0] = bytes32(uint256(2000) | uint256(2000) << 16 | uint256(600) << 32);
        (bool ok, bytes4 reason) = _construct(c, _params());
        assertFalse(ok); assertEq(reason, HedgeFunV2AssetPercentEngineTreasury.BadEngineConfig.selector);
        c.words[0] = bytes32(uint256(9000) | uint256(1000) << 16 | uint256(600) << 32);
        (ok, reason) = _construct(c, _params());
        assertFalse(ok); assertEq(reason, HedgeFunV2AssetPercentEngineTreasury.BadEngineConfig.selector);
    }

    function test_existingRegistryMetadataIsGenericAndInvalidWordsCannotDeploy() public {
        HedgeFunFactory.Request memory q = _request(); q.nonce = 1001;
        EngineConfig memory invalid = _percentConfig(1000, 5000, 0); invalid.words[1] = bytes32(0);
        // Existing deployed registries validate generic manifests, while their word checks are schema-1-only.
        deployer.setEngineConfig(q.symbol, q.nonce, percentKind, invalid);
        (, address predicted, bytes32 terms) = factory.predict(q);
        vm.expectRevert(V2TreasuryDeployer.TreasuryDeployFailed.selector); factory.launch(q, terms);
        assertEq(predicted.code.length, 0); assertEq(factory.strategyCount(), 0);
        EngineConfig memory wrongSchema = _percentConfig(1000, 5000, 0); wrongSchema.schema = 1;
        vm.expectRevert(V2TreasuryDeployer.BadPolicy.selector);
        deployer.setEngineConfig(q.symbol, q.nonce, percentKind, wrongSchema);
        wrongSchema = _percentConfig(1000, 5000, 0); wrongSchema.policyKey = policyKey;
        vm.expectRevert(V2TreasuryDeployer.BadPolicy.selector);
        deployer.setEngineConfig(q.symbol, q.nonce, percentKind, wrongSchema);
    }
}

contract V2AssetPercentPolicyTest is Test {
    V2AssetPercentRebalancePolicy private policy;
    function setUp() public { policy = new V2AssetPercentRebalancePolicy(); vm.warp(1700000000); }

    function _config() private pure returns (EngineConfig memory c) {
        c.schema = 2; c.engineVersion = 1;
        c.words[0] = bytes32(uint256(7000) | uint256(500) << 16 | uint256(600) << 32);
        c.words[1] = bytes32(uint256(1000)); c.words[2] = bytes32(uint256(5000));
    }
    function _context(uint256 stockValue, uint256 cash) private pure returns (StrategyContext memory c) {
        c.configHash = keccak256("percent-config"); c.nonce = 7; c.price = 100e18;
        c.stockInventory = Math.mulDiv(stockValue, 1e30, c.price); c.stockValueUsdg = stockValue;
        c.usdgInventory = cash; c.buybackStock = 1e30;
    }

    function test_metadataAndExact160ByteIntentKeepStateHashAndNonce() public {
        (uint32 v, uint32 schema, uint256 caps) = policy.policyMetadata();
        assertEq(v, 1); assertEq(schema, 2); assertEq(caps, 3);
        StrategyContext memory c = _context(1000e6, 0);
        StrategyIntent memory intent = policy.decide(c, _config(), bytes32(uint256(12)));
        assertEq(abi.encode(intent).length, 160); assertEq(intent.configHash, c.configHash);
        assertEq(intent.nonce, c.nonce); assertEq(intent.nextState, bytes32(uint256(12)));
    }

    function test_proposalsCoverTradableTargetGapLeavingFullNavCapsToCore() public {
        StrategyIntent memory sale = policy.decide(_context(1000e6, 0), _config(), 0);
        assertEq(uint256(sale.action), uint256(StrategyAction.SellStock)); assertEq(sale.amountIn, 3e18);
        sale = policy.decide(_context(2000e6, 0), _config(), 0); assertEq(sale.amountIn, 6e18);
        StrategyIntent memory buy = policy.decide(_context(200e6, 800e6), _config(), 0);
        assertEq(uint256(buy.action), uint256(StrategyAction.BuyStock)); assertEq(buy.amountIn, 500e6);
        buy = policy.decide(_context(400e6, 1600e6), _config(), 0); assertEq(buy.amountIn, 1000e6);
        buy = policy.decide(_context(1, 10), _config(), 0); assertEq(buy.amountIn, 6, "floor target to base unit");
    }

    function test_bandEqualityAndCooldownHoldAreObservationsWithoutStateMutation() public {
        EngineConfig memory config = _config();
        StrategyContext memory c = _context(650e6, 350e6);
        assertEq(uint256(policy.decide(c, config, 0).action), uint256(StrategyAction.Hold));
        c = _context(750e6, 250e6);
        assertEq(uint256(policy.decide(c, config, 0).action), uint256(StrategyAction.Hold));
        c = _context(1000e6, 0); c.lastActionAt = block.timestamp;
        vm.warp(block.timestamp + 599);
        assertEq(uint256(policy.decide(c, config, 0).action), uint256(StrategyAction.Hold));
        vm.warp(block.timestamp + 1);
        assertEq(uint256(policy.decide(c, config, 0).action), uint256(StrategyAction.SellStock));
    }

    function test_zeroAndOneBpBandsFollowCreatorGeometryAndHoldAtTarget() public {
        for (uint256 band; band < 2; ++band) {
            EngineConfig memory c = _config();
            c.words[0] = bytes32(uint256(7000) | band << 16 | uint256(600) << 32);
            assertEq(uint256(policy.decide(_context(700e6, 300e6), c, 0).action), uint256(StrategyAction.Hold));
            assertEq(uint256(policy.decide(_context(701e6, 299e6), c, 0).action), uint256(StrategyAction.SellStock));
            assertEq(uint256(policy.decide(_context(699e6, 301e6), c, 0).action), uint256(StrategyAction.BuyStock));
        }
        EngineConfig memory malformed = _config();
        malformed.words[0] = bytes32(uint256(2000) | uint256(2000) << 16 | uint256(600) << 32);
        vm.expectRevert(V2AssetPercentRebalancePolicy.BadConfig.selector);
        policy.decide(_context(700e6, 300e6), malformed, 0);
    }

    function test_mulDivAcceptsFullWidthNavWhileOverflowSumHoldsAndWrongSchemaRefuses() public {
        StrategyContext memory c = _context(0, type(uint256).max);
        StrategyIntent memory intent = policy.decide(c, _config(), 0);
        assertEq(intent.amountIn, Math.mulDiv(type(uint256).max, 7000, 10_000));
        c.stockValueUsdg = 1;
        assertEq(uint256(policy.decide(c, _config(), 0).action), uint256(StrategyAction.Hold));
        EngineConfig memory old = _config(); old.schema = 1;
        vm.expectRevert(V2AssetPercentRebalancePolicy.BadConfig.selector); policy.decide(c, old, 0);
        old = _config(); old.words[1] = bytes32(uint256(10_001));
        vm.expectRevert(V2AssetPercentRebalancePolicy.BadConfig.selector); policy.decide(c, old, 0);
    }
}
