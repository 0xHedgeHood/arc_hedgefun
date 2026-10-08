// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    EngineConfig,
    StrategyAction,
    StrategyCapabilities,
    StrategyContext,
    StrategyIntent
} from "../src/v2/strategy/IStrategyPolicy.sol";
import {V2RebalancePolicy} from "../src/v2/strategy/V2RebalancePolicy.sol";

contract V2RebalancePolicyTest is Test {
    V2RebalancePolicy private policy;

    function setUp() public {
        policy = new V2RebalancePolicy();
    }

    function _config(uint16 target, uint16 deadband, uint32 cooldown, uint256 maxTrade, uint256 maxDaily)
        private
        pure
        returns (EngineConfig memory c)
    {
        c.schema = StrategyCapabilities.CONFIG_SCHEMA_V1;
        c.engineVersion = StrategyCapabilities.SPOT_ENGINE_V1;
        c.policyKey = keccak256("V2_REBALANCE_POLICY");
        c.words[0] = bytes32(uint256(target) | uint256(deadband) << 16 | uint256(cooldown) << 32);
        c.words[1] = bytes32(maxTrade);
        c.words[2] = bytes32(maxDaily);
    }

    function _context(EngineConfig memory c, uint256 stock, uint256 stockValue, uint256 usdg)
        private
        pure
        returns (StrategyContext memory x)
    {
        x.configHash = keccak256(abi.encode(c));
        x.price = 100e18;
        x.stockInventory = stock;
        x.stockValueUsdg = stockValue;
        x.usdgInventory = usdg;
        x.nonce = 17;
    }

    function test_metadataCommitsToSpotSchemaAndBuySellCapabilities() public view {
        (uint32 engine, uint32 schema, uint256 capabilities) = policy.policyMetadata();
        assertEq(engine, StrategyCapabilities.SPOT_ENGINE_V1);
        assertEq(schema, StrategyCapabilities.CONFIG_SCHEMA_V1);
        assertEq(capabilities, StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL);
    }

    function test_intentEchoesConfigNonceAndPreservesStatelessPolicyState() public view {
        EngineConfig memory c = _config(5000, 500, 60, 100e6, 500e6);
        StrategyContext memory x = _context(c, 80e18, 800e6, 200e6);
        bytes32 state = keccak256("opaque engine state");
        StrategyIntent memory got = policy.decide(x, c, state);
        assertEq(got.configHash, x.configHash);
        assertEq(got.nonce, x.nonce);
        assertEq(got.nextState, state);
    }

    function test_sellUsesStockUnitsAndCapsTheirUsdNotional() public view {
        EngineConfig memory c = _config(5000, 500, 0, 100e6, 500e6);
        StrategyIntent memory got = policy.decide(_context(c, 80e18, 800e6, 200e6), c, bytes32(0));
        assertEq(uint256(got.action), uint256(StrategyAction.SellStock));
        assertEq(got.amountIn, 10e18, "80 stock are worth 800 USDG, so 10 stock are the capped 100 USDG trade");
    }

    function test_sellStopsAtTargetWhenCloserThanTheCap() public view {
        EngineConfig memory c = _config(5000, 500, 0, 200e6, 500e6);
        StrategyIntent memory got = policy.decide(_context(c, 60e18, 600e6, 400e6), c, bytes32(0));
        assertEq(uint256(got.action), uint256(StrategyAction.SellStock));
        assertEq(got.amountIn, 10e18);
    }

    function test_buyUsesUsdgUnitsAndIsCapped() public view {
        EngineConfig memory c = _config(5000, 500, 0, 100e6, 500e6);
        StrategyIntent memory got = policy.decide(_context(c, 20e18, 200e6, 800e6), c, bytes32(0));
        assertEq(uint256(got.action), uint256(StrategyAction.BuyStock));
        assertEq(got.amountIn, 100e6);
    }

    function test_deadbandBoundariesHoldAndValuesBeyondAct() public view {
        EngineConfig memory c = _config(5000, 500, 0, 1_000e6, 1_000e6);
        assertEq(uint256(policy.decide(_context(c, 55e18, 550e6, 450e6), c, 0).action), uint256(StrategyAction.Hold));
        assertEq(uint256(policy.decide(_context(c, 45e18, 450e6, 550e6), c, 0).action), uint256(StrategyAction.Hold));
        assertEq(
            uint256(policy.decide(_context(c, 56e18, 560e6, 440e6), c, 0).action), uint256(StrategyAction.SellStock)
        );
        assertEq(
            uint256(policy.decide(_context(c, 44e18, 440e6, 560e6), c, 0).action), uint256(StrategyAction.BuyStock)
        );
    }

    function test_cooldownHoldsUntilItsExactBoundary() public {
        EngineConfig memory c = _config(5000, 500, 60, 100e6, 500e6);
        StrategyContext memory x = _context(c, 80e18, 800e6, 200e6);
        x.lastActionAt = 1_000;
        vm.warp(1_059);
        assertEq(uint256(policy.decide(x, c, 0).action), uint256(StrategyAction.Hold));
        vm.warp(1_060);
        assertEq(uint256(policy.decide(x, c, 0).action), uint256(StrategyAction.SellStock));
    }

    function test_zeroOrInconsistentObservationsFailClosedToHold() public view {
        EngineConfig memory c = _config(5000, 500, 0, 100e6, 500e6);
        StrategyContext memory x = _context(c, 0, 0, 0);
        assertEq(uint256(policy.decide(x, c, 0).action), uint256(StrategyAction.Hold));
        x = _context(c, 80e18, 800e6, 200e6);
        x.price = 0;
        assertEq(uint256(policy.decide(x, c, 0).action), uint256(StrategyAction.Hold));
        x = _context(c, 0, 800e6, 200e6);
        assertEq(uint256(policy.decide(x, c, 0).action), uint256(StrategyAction.Hold));
    }

    function test_policyEchoesTheCoreBoundHashWithoutRecomputingItsDomain() public view {
        EngineConfig memory c = _config(5000, 500, 0, 100e6, 500e6);
        StrategyContext memory x = _context(c, 80e18, 800e6, 200e6);
        x.configHash = keccak256("domain-separated by the core");
        c.words[2] = bytes32(uint256(600e6));
        StrategyIntent memory got = policy.decide(x, c, 0);
        assertEq(got.configHash, x.configHash);
        assertEq(got.nonce, x.nonce);
    }

    function test_rejectsMalformedOrUnsafeConfigurations() public {
        EngineConfig memory good = _config(5000, 500, 60, 100e6, 500e6);
        StrategyContext memory x = _context(good, 80e18, 800e6, 200e6);

        // each case from a fresh config: `bad = good` would alias memory, and the first mutation would then make
        // every later case fail on the schema instead of on what it tests
        EngineConfig memory bad = _config(5000, 500, 60, 100e6, 500e6);
        bad.schema++;
        vm.expectRevert(V2RebalancePolicy.BadConfig.selector);
        policy.decide(x, bad, 0);
        bad = _config(5000, 500, 60, 100e6, 500e6);
        bad.engineVersion++;
        vm.expectRevert(V2RebalancePolicy.BadConfig.selector);
        policy.decide(x, bad, 0);
        bad = _config(5000, 500, 60, 100e6, 500e6);
        bad.words[0] |= bytes32(uint256(1) << 80); // the lowest reserved bit
        vm.expectRevert(V2RebalancePolicy.BadConfig.selector);
        policy.decide(x, bad, 0);
        // bits 64..79 are the engine's `payoutBps`: the policy ignores them and decides exactly as without them
        EngineConfig memory paid = _config(5000, 500, 60, 100e6, 500e6);
        paid.words[0] |= bytes32(uint256(10_000) << 64);
        StrategyIntent memory withPayout = policy.decide(x, paid, 0);
        StrategyIntent memory without = policy.decide(x, good, 0);
        assertEq(uint256(withPayout.action), uint256(without.action));
        assertEq(withPayout.amountIn, without.amountIn);
        bad = _config(0, 0, 0, 100e6, 500e6);
        vm.expectRevert(V2RebalancePolicy.BadConfig.selector);
        policy.decide(x, bad, 0);
        bad = _config(10_000, 0, 0, 100e6, 500e6);
        vm.expectRevert(V2RebalancePolicy.BadConfig.selector);
        policy.decide(x, bad, 0);
        bad = _config(4000, 4001, 0, 100e6, 500e6);
        vm.expectRevert(V2RebalancePolicy.BadConfig.selector);
        policy.decide(x, bad, 0);
        bad = _config(7000, 3001, 0, 100e6, 500e6);
        vm.expectRevert(V2RebalancePolicy.BadConfig.selector);
        policy.decide(x, bad, 0);
        bad = _config(5000, 500, 0, 0, 500e6);
        vm.expectRevert(V2RebalancePolicy.BadConfig.selector);
        policy.decide(x, bad, 0);
        bad = _config(5000, 500, 0, 100e6, 0);
        vm.expectRevert(V2RebalancePolicy.BadConfig.selector);
        policy.decide(x, bad, 0);
        bad = _config(5000, 500, 0, 100e6, 99e6);
        vm.expectRevert(V2RebalancePolicy.BadConfig.selector);
        policy.decide(x, bad, 0);
    }

    function testFuzz_eachProposedActionIsCappedAndUsesItsInputAsset(
        uint96 stockInventory,
        uint96 stockValue,
        uint96 usdgInventory,
        uint64 maxTrade
    ) public view {
        stockInventory = uint96(bound(stockInventory, 1, 1e30));
        stockValue = uint96(bound(stockValue, 1, 1e24));
        usdgInventory = uint96(bound(usdgInventory, 1, 1e24));
        maxTrade = uint64(bound(maxTrade, 1, type(uint64).max));
        EngineConfig memory c = _config(5000, 500, 0, maxTrade, uint256(maxTrade) * 2);
        StrategyContext memory x = _context(c, stockInventory, stockValue, usdgInventory);
        StrategyIntent memory got = policy.decide(x, c, bytes32(0));

        if (got.action == StrategyAction.BuyStock) {
            assertLe(got.amountIn, maxTrade);
            assertLe(got.amountIn, usdgInventory);
        } else if (got.action == StrategyAction.SellStock) {
            assertLe(got.amountIn, stockInventory);
            assertLe(Math.mulDiv(got.amountIn, stockValue, stockInventory), maxTrade);
        } else {
            assertEq(got.amountIn, 0);
        }
        assertEq(got.configHash, x.configHash);
        assertEq(got.nonce, x.nonce);
    }
}
