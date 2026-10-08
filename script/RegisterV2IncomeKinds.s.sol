// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {V2TreasuryDeployer, V2InitCodeChunk} from "../src/v2/V2TreasuryDeployer.sol";
import {IncomeKindCompatibility} from "./helpers/IncomeKindCompatibility.sol";
import {HedgeFunV2DividendTreasury, HedgeFunV2BuybackDividendTreasury} from "../src/v2/HedgeFunV2IncomeTreasury.sol";
import {
    HedgeFunV2StrategyDividend25Treasury, HedgeFunV2StrategyDividend50Treasury
} from "../src/v2/HedgeFunV2StrategyIncomeTreasury.sol";

/// @notice Add the dividend kinds to an existing V2 factory's treasury registry, for future launches.
/// @dev Requires OPERATOR and V2_FACTORY. The operator must be the factory owner. Twelve transactions: each kind's
///      creation code is stored as two chunks the operator creates, then registered. The registry's own
///      `makeChunks` is public, so anyone can move the addresses it would use between this script's simulation
///      and its broadcast, and the recorded `registerKind` would then name someone else's bytes for good.
///      Existing kinds and launched treasuries are untouched;
///      a creator opts in per launch with `V2TreasuryDeployer.setStrategyKind(symbol, nonce, kind)`.
///      Run a fork simulation before broadcasting, then `VerifyV2IncomeKinds` against the confirmed chain.
contract RegisterV2IncomeKinds is IncomeKindCompatibility {
    error BadBinding(string what);
    error ReadbackFailed(string what);

    /// Kind ids are assigned by registration order on each registry. Read them; do not hard-code them.
    struct Kinds {
        uint8 strategy25;   // stock strategy; 25% of profit and tax income to stakers
        uint8 strategy50;   // stock strategy; 50%
        uint8 dividend;     // no stock strategy; 100% of income to stakers
        uint8 split;        // no stock strategy; 50% to stakers, 50% to the buy-back
    }

    function run() external returns (Kinds memory k) {
        address operator = vm.envAddress("OPERATOR");
        if (operator == address(0) || msg.sender != operator) revert BadBinding("operator sender");
        k = register(operator, HedgeFunV2Factory(vm.envAddress("V2_FACTORY")));
        console2.log("strategy + 25% dividend kind", k.strategy25);
        console2.log("strategy + 50% dividend kind", k.strategy50);
        console2.log("dividend kind, no strategy (100% of income to stakers)", k.dividend);
        console2.log("buyback + dividend kind, no strategy (50% / 50%)", k.split);
        console2.log("simulation readback passed; verify twelve receipts and live state after broadcast");
    }

    /// @notice every transaction, broadcast from `operator`; `run` adds the environment and the log
    function register(address operator, HedgeFunV2Factory factory) public returns (Kinds memory k) {
        // Every binding and graduation-compatibility check runs before the first broadcast transaction.
        if (address(factory).code.length == 0 || factory.owner() != operator) revert BadBinding("factory owner");
        V2TreasuryDeployer registry = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        if (address(registry).code.length == 0 || registry.factory() != address(factory)) revert BadBinding("registry");
        if (registry.kindCount() + 4 > type(uint8).max) revert BadBinding("registry full");
        _checkIncomeCompatibility(factory);

        vm.startBroadcast(operator);
        k.strategy25 = _add(registry, type(HedgeFunV2StrategyDividend25Treasury).creationCode);
        k.strategy50 = _add(registry, type(HedgeFunV2StrategyDividend50Treasury).creationCode);
        k.dividend = _add(registry, type(HedgeFunV2DividendTreasury).creationCode);
        k.split = _add(registry, type(HedgeFunV2BuybackDividendTreasury).creationCode);
        vm.stopBroadcast();

        // These checks are against Foundry's simulated state when broadcasting.
        check(registry, k);
    }

    /// @dev The chunk addresses come from the operator's own nonce, which nobody else can advance.
    function _add(V2TreasuryDeployer registry, bytes memory code) private returns (uint8) {
        uint256 half = code.length / 2;
        bytes memory left = new bytes(half);
        bytes memory right = new bytes(code.length - half);
        assembly ("memory-safe") {
            mcopy(add(left, 32), add(code, 32), half)
            mcopy(add(right, 32), add(add(code, 32), half), mload(right))
        }
        return registry.registerKind(address(new V2InitCodeChunk(left)), address(new V2InitCodeChunk(right)));
    }

    /// @notice The registered chunks hold exactly this source's creation code, and no kind is an engine kind.
    function check(V2TreasuryDeployer registry, Kinds memory k) public view {
        HedgeFunV2Factory factory = HedgeFunV2Factory(registry.factory());
        if (address(factory.treasuryDeployer()) != address(registry)) revert BadBinding("registry");
        _checkIncomeCompatibility(factory);
        _same(registry, k.strategy25, type(HedgeFunV2StrategyDividend25Treasury).creationCode, "strategy 25 kind");
        _same(registry, k.strategy50, type(HedgeFunV2StrategyDividend50Treasury).creationCode, "strategy 50 kind");
        _same(registry, k.dividend, type(HedgeFunV2DividendTreasury).creationCode, "dividend kind");
        _same(registry, k.split, type(HedgeFunV2BuybackDividendTreasury).creationCode, "split kind");
    }

    function _same(V2TreasuryDeployer registry, uint8 kind, bytes memory code, string memory what) private view {
        if (kind == 0) revert ReadbackFailed(what);
        (uint32 engineVersion, uint32 schema, bytes32 codeHash,) = registry.kindManifest(kind);
        (address a, address b) = registry.kinds(kind);
        if (engineVersion != 0 || schema != 0 || codeHash != keccak256(code)
            || keccak256(bytes.concat(a.code, b.code)) != keccak256(code)) revert ReadbackFailed(what);
    }
}

/// @notice Read-only confirmation after all twelve registration transactions have succeeded on chain.
/// @dev Requires V2_FACTORY, STRATEGY25_KIND, STRATEGY50_KIND, DIVIDEND_KIND and SPLIT_KIND from the reviewed
///      registration.
contract VerifyV2IncomeKinds is Script {
    function run() external {
        HedgeFunV2Factory factory = HedgeFunV2Factory(vm.envAddress("V2_FACTORY"));
        V2TreasuryDeployer registry = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        RegisterV2IncomeKinds.Kinds memory k = RegisterV2IncomeKinds.Kinds(
            uint8(vm.envUint("STRATEGY25_KIND")), uint8(vm.envUint("STRATEGY50_KIND")),
            uint8(vm.envUint("DIVIDEND_KIND")), uint8(vm.envUint("SPLIT_KIND")));
        new RegisterV2IncomeKinds().check(registry, k);
        console2.log("live dividend kinds verified");
    }
}
