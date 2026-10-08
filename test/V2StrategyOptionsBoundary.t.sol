// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunV2EngineTreasury} from "../src/v2/HedgeFunV2EngineTreasury.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {
    EngineConfig,
    IStrategyPolicy,
    StrategyAction,
    StrategyCapabilities,
    StrategyContext,
    StrategyIntent
} from "../src/v2/strategy/IStrategyPolicy.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

abstract contract BoundaryPolicyBase is IStrategyPolicy {
    function decide(StrategyContext calldata context, EngineConfig calldata, bytes32 state)
        external
        pure
        returns (StrategyIntent memory intent)
    {
        intent = StrategyIntent({
            configHash: context.configHash,
            nonce: context.nonce,
            action: StrategyAction.Hold,
            amountIn: 0,
            nextState: state
        });
    }
}

/// @dev Claims a spot ABI while also asking for an options-only operation.
contract SpotPolicyWithOptionsCapability is BoundaryPolicyBase {
    function policyMetadata() external pure returns (uint32, uint32, uint256) {
        return (
            StrategyCapabilities.SPOT_ENGINE_V1,
            StrategyCapabilities.CONFIG_SCHEMA_V1,
            StrategyCapabilities.SPOT_BUY | StrategyCapabilities.OPTIONS_WRITE
        );
    }
}

/// @dev Models a future capability bit unknown to SpotEngineV1 today.
contract SpotPolicyWithFutureCapability is BoundaryPolicyBase {
    function policyMetadata() external pure returns (uint32, uint32, uint256) {
        return (
            StrategyCapabilities.SPOT_ENGINE_V1,
            StrategyCapabilities.CONFIG_SCHEMA_V1,
            StrategyCapabilities.SPOT_BUY | (uint256(1) << 68)
        );
    }
}

/// @dev Buy-back uses a separate state machine and may not be smuggled into the rebalance engine.
contract SpotPolicyWithBuybackCapability is BoundaryPolicyBase {
    function policyMetadata() external pure returns (uint32, uint32, uint256) {
        return (
            StrategyCapabilities.SPOT_ENGINE_V1,
            StrategyCapabilities.CONFIG_SCHEMA_V1,
            StrategyCapabilities.SPOT_BUY | StrategyCapabilities.BUYBACK_BURN
        );
    }
}

/// @dev A future options policy. The current registry may describe it, but SpotEngineV1 must never instantiate it.
contract OptionsV1BoundaryPolicy is BoundaryPolicyBase {
    function policyMetadata() external pure returns (uint32, uint32, uint256) {
        return (
            StrategyCapabilities.OPTIONS_ENGINE_V1,
            StrategyCapabilities.CONFIG_SCHEMA_V1,
            StrategyCapabilities.OPTIONS_WRITE | StrategyCapabilities.OPTIONS_SETTLE
        );
    }
}

/// @notice Defense-in-depth tests for the architectural boundary between the shared policy registry and the
///         current stock/USDG engine. Engine-kind registration is owner-governed, so these tests deliberately
///         include an over-broad kind declaration and require the concrete SpotEngineV1 constructor to fail shut.
contract V2StrategyOptionsBoundaryTest is V2FactoryFixture {
    V2TreasuryDeployer private deployer;

    function setUp() public {
        _setUpV2(18);
        deployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
    }

    function _registerEngineKind(uint256 capabilities) private returns (uint8 kind) {
        (address a, address b) = deployer.makeChunks(type(HedgeFunV2EngineTreasury).creationCode);
        vm.prank(owner);
        kind = deployer.registerEngineKind(
            a, b, StrategyCapabilities.SPOT_ENGINE_V1, StrategyCapabilities.CONFIG_SCHEMA_V1, capabilities
        );
    }

    function _registerPolicy(address implementation) private returns (bytes32 key) {
        uint16 returnBytes = deployer.POLICY_RETURN_BYTES();
        vm.prank(owner);
        key = deployer.registerPolicy(
            implementation, 100_000, returnBytes, keccak256("dependencies"), keccak256("audit")
        );
    }

    function _config(bytes32 key, uint32 engineVersion) private pure returns (EngineConfig memory c) {
        c.schema = StrategyCapabilities.CONFIG_SCHEMA_V1;
        c.engineVersion = engineVersion;
        c.policyKey = key;
        c.words[0] = bytes32(uint256(5000) | uint256(500) << 16 | uint256(600) << 32);
        c.words[1] = bytes32(uint256(10e6));
        c.words[2] = bytes32(uint256(100e6));
    }

    function test_spotOnlyKindRejectsPolicyContainingAnyOptionsCapabilityAtConfiguration() public {
        uint8 kind = _registerEngineKind(StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL);
        bytes32 key = _registerPolicy(address(new SpotPolicyWithOptionsCapability()));
        HedgeFunFactory.Request memory q = _request();

        vm.expectRevert(V2TreasuryDeployer.BadPolicy.selector);
        deployer.setEngineConfig(q.symbol, q.nonce, kind, _config(key, StrategyCapabilities.SPOT_ENGINE_V1));
    }

    function test_overBroadKindCannotSmuggleOptionsCapabilityIntoSpotEngine() public {
        uint256 advertised = StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL
            | StrategyCapabilities.OPTIONS_WRITE | StrategyCapabilities.OPTIONS_SETTLE;
        uint8 kind = _registerEngineKind(advertised);
        bytes32 key = _registerPolicy(address(new SpotPolicyWithOptionsCapability()));
        HedgeFunFactory.Request memory q = _request();

        // The generic registry intentionally accepts a policy whose capabilities are a subset of an advertised
        // kind. The concrete engine is the final authority and rejects every options capability in its constructor.
        deployer.setEngineConfig(q.symbol, q.nonce, kind, _config(key, StrategyCapabilities.SPOT_ENGINE_V1));
        (,, bytes32 terms) = factory.predict(q);
        vm.expectRevert(V2TreasuryDeployer.TreasuryDeployFailed.selector);
        factory.launch(q, terms);
    }

    function test_optionsEngineVersionCannotBeConfiguredAgainstSpotEngineKind() public {
        uint256 advertised = StrategyCapabilities.OPTIONS_WRITE | StrategyCapabilities.OPTIONS_SETTLE;
        uint8 kind = _registerEngineKind(advertised);
        bytes32 key = _registerPolicy(address(new OptionsV1BoundaryPolicy()));
        HedgeFunFactory.Request memory q = _request();

        vm.expectRevert(V2TreasuryDeployer.BadPolicy.selector);
        deployer.setEngineConfig(q.symbol, q.nonce, kind, _config(key, StrategyCapabilities.OPTIONS_ENGINE_V1));
    }

    function test_futureUnknownCapabilityFailsClosedInsideSpotEngine() public {
        uint256 futureCapability = uint256(1) << 68;
        uint8 kind = _registerEngineKind(StrategyCapabilities.SPOT_BUY | futureCapability);
        bytes32 key = _registerPolicy(address(new SpotPolicyWithFutureCapability()));
        HedgeFunFactory.Request memory q = _request();

        deployer.setEngineConfig(q.symbol, q.nonce, kind, _config(key, StrategyCapabilities.SPOT_ENGINE_V1));
        (,, bytes32 terms) = factory.predict(q);
        vm.expectRevert(V2TreasuryDeployer.TreasuryDeployFailed.selector);
        factory.launch(q, terms);
    }

    function test_buybackCapabilityCannotEnterRebalanceEngine() public {
        uint256 advertised = StrategyCapabilities.SPOT_BUY | StrategyCapabilities.BUYBACK_BURN;
        uint8 kind = _registerEngineKind(advertised);
        bytes32 key = _registerPolicy(address(new SpotPolicyWithBuybackCapability()));
        HedgeFunFactory.Request memory q = _request();

        deployer.setEngineConfig(q.symbol, q.nonce, kind, _config(key, StrategyCapabilities.SPOT_ENGINE_V1));
        (,, bytes32 terms) = factory.predict(q);
        vm.expectRevert(V2TreasuryDeployer.TreasuryDeployFailed.selector);
        factory.launch(q, terms);
    }
}
