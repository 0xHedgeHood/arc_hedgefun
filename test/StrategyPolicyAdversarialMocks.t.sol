// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    EngineConfig,
    IStrategyPolicy,
    StrategyAction,
    StrategyCapabilities,
    StrategyContext,
    StrategyIntent
} from "../src/v2/strategy/IStrategyPolicy.sol";
import {
    ExcessiveAmountStrategyPolicy,
    GasBombStrategyPolicy,
    HonestBuyPolicy,
    HonestHoldPolicy,
    HugeReturnStrategyPolicy,
    MalformedReturnStrategyPolicy,
    MutableDecisionStrategyPolicy,
    MutableStrategyPolicyProxy,
    OptionsActionStrategyPolicy,
    RevertingStrategyPolicy,
    StateWritingStrategyPolicy,
    WrongConfigHashStrategyPolicy,
    WrongNonceStrategyPolicy
} from "./mocks/StrategyPolicyMocks.sol";

/// @notice Keeps adversarial fixtures executable before EngineTreasury lands. Engine tests should reuse these
///         policies and require every bad response to fail closed without consuming a nonce or changing balances.
contract StrategyPolicyAdversarialMocksTest is Test {
    bytes32 private constant CONFIG_HASH = keccak256("engine-config");
    bytes32 private constant POLICY_KEY = keccak256("policy-key");

    StrategyContext private context;
    EngineConfig private config;

    function setUp() public {
        context = StrategyContext({
            configHash: CONFIG_HASH,
            price: 100e18,
            stockInventory: 3e18,
            stockValueUsdg: 300e6,
            usdgInventory: 200e6,
            buybackStock: 1e18,
            lastActionAt: 1_700_000_000,
            nonce: 7
        });
        config = EngineConfig({
            schema: StrategyCapabilities.CONFIG_SCHEMA_V1,
            engineVersion: StrategyCapabilities.SPOT_ENGINE_V1,
            policyKey: POLICY_KEY,
            words: [bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3))]
        });
    }

    function _call(address policy, uint256 gasLimit) private view returns (bool ok, bytes memory output) {
        bytes memory input = abi.encodeCall(IStrategyPolicy.decide, (context, config, bytes32(0)));
        (ok, output) = policy.staticcall{gas: gasLimit}(input);
    }

    /// @dev Probe returndata length while copying at most `copyCap` bytes. EngineTreasury should use this pattern,
    ///      then require the exact fixed intent length before decoding.
    function _cappedProbe(address policy, uint256 gasLimit, uint256 copyCap)
        private
        view
        returns (bool ok, uint256 returnBytes, bytes memory prefix)
    {
        bytes memory input = abi.encodeCall(IStrategyPolicy.decide, (context, config, bytes32(0)));
        prefix = new bytes(copyCap);
        assembly ("memory-safe") {
            ok := staticcall(gasLimit, policy, add(input, 0x20), mload(input), add(prefix, 0x20), copyCap)
            returnBytes := returndatasize()
        }
    }

    function test_fixture_honestIntentHasFixedEncoding() public {
        (bool ok, bytes memory output) = _call(address(new HonestHoldPolicy()), 100_000);
        assertTrue(ok);
        assertEq(output.length, 160);
        StrategyIntent memory intent = abi.decode(output, (StrategyIntent));
        assertEq(intent.configHash, CONFIG_HASH);
        assertEq(intent.nonce, context.nonce);
        assertEq(uint256(intent.action), uint256(StrategyAction.Hold));
        assertEq(intent.amountIn, 0);
    }

    function test_fixture_revertIsContained() public {
        (bool ok,) = _call(address(new RevertingStrategyPolicy()), 100_000);
        assertFalse(ok);
    }

    function test_fixture_hugeReturnCanBeRejectedBeforeCopy() public {
        (bool ok, uint256 size,) = _cappedProbe(address(new HugeReturnStrategyPolicy()), 300_000, 160);
        assertTrue(ok);
        assertEq(size, 65_536);
        assertGt(size, 160);
    }

    function test_fixture_malformedReturnIsNotAnIntent() public {
        (bool ok, uint256 size,) = _cappedProbe(address(new MalformedReturnStrategyPolicy()), 100_000, 160);
        assertTrue(ok);
        assertEq(size, 159);
    }

    function test_fixture_gasBombIsBoundedByCallGas() public {
        (bool ok,) = _call(address(new GasBombStrategyPolicy()), 25_000);
        assertFalse(ok);
    }

    function test_fixture_wrongCommitmentsAreWellFormedButInvalid() public {
        (bool okHash, bytes memory hashOutput) = _call(address(new WrongConfigHashStrategyPolicy()), 100_000);
        (bool okNonce, bytes memory nonceOutput) = _call(address(new WrongNonceStrategyPolicy()), 100_000);
        assertTrue(okHash && okNonce);
        StrategyIntent memory badHash = abi.decode(hashOutput, (StrategyIntent));
        StrategyIntent memory badNonce = abi.decode(nonceOutput, (StrategyIntent));
        assertNotEq(badHash.configHash, context.configHash);
        assertNotEq(badNonce.nonce, context.nonce);
    }

    function test_fixture_excessiveAmountMustBeCappedByEngine() public {
        (bool ok, bytes memory output) = _call(address(new ExcessiveAmountStrategyPolicy()), 100_000);
        assertTrue(ok);
        assertEq(abi.decode(output, (StrategyIntent)).amountIn, type(uint256).max);
    }

    function test_fixture_optionsActionIsRawOutOfRangeWord() public {
        (bool ok, bytes memory output) = _call(address(new OptionsActionStrategyPolicy()), 100_000);
        assertTrue(ok);
        assertEq(output.length, 160);
        uint256 actionWord;
        assembly ("memory-safe") {
            actionWord := mload(add(output, 0x60))
        }
        assertEq(actionWord, 64);
        assertGt(actionWord, uint256(StrategyAction.BuybackBurn));
    }

    function test_fixture_staticcallTrapsStateWrite() public {
        StateWritingStrategyPolicy policy = new StateWritingStrategyPolicy();
        (bool ok,) = _call(address(policy), 100_000);
        assertFalse(ok);
        assertEq(policy.writes(), 0);

        policy.decide(context, config, bytes32(0));
        assertEq(policy.writes(), 1, "the fixture must really attempt SSTORE outside STATICCALL");
    }

    function test_fixture_codehashDoesNotCommitMutableStorageSemantics() public {
        MutableDecisionStrategyPolicy policy = new MutableDecisionStrategyPolicy();
        bytes32 codehash = address(policy).codehash;
        (bool beforeOk, bytes memory beforeOutput) = _call(address(policy), 100_000);
        policy.setAction(StrategyAction.SellStock);
        (bool afterOk, bytes memory afterOutput) = _call(address(policy), 100_000);
        assertTrue(beforeOk && afterOk);
        assertEq(address(policy).codehash, codehash);
        assertEq(uint256(abi.decode(beforeOutput, (StrategyIntent)).action), uint256(StrategyAction.Hold));
        assertEq(uint256(abi.decode(afterOutput, (StrategyIntent)).action), uint256(StrategyAction.SellStock));
    }

    function test_fixture_proxyCodehashDoesNotCommitImplementation() public {
        HonestHoldPolicy hold = new HonestHoldPolicy();
        HonestBuyPolicy buy = new HonestBuyPolicy();
        MutableStrategyPolicyProxy proxy = new MutableStrategyPolicyProxy(address(hold));
        bytes32 proxyCodehash = address(proxy).codehash;
        (bool beforeOk, bytes memory beforeOutput) = _call(address(proxy), 100_000);
        proxy.setImplementation(address(buy));
        (bool afterOk, bytes memory afterOutput) = _call(address(proxy), 100_000);
        assertTrue(beforeOk && afterOk);
        assertEq(address(proxy).codehash, proxyCodehash);
        assertEq(uint256(abi.decode(beforeOutput, (StrategyIntent)).action), uint256(StrategyAction.Hold));
        assertEq(uint256(abi.decode(afterOutput, (StrategyIntent)).action), uint256(StrategyAction.BuyStock));
    }
}
