// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {V2TreasuryDeployer, V2InitCodeChunk} from "../src/v2/V2TreasuryDeployer.sol";
import {V2TreasuryUpgradeController} from "../src/v2/V2TreasuryUpgradeController.sol";
import {HedgeFunV2UpgradeableBuybackTreasury} from "../src/v2/HedgeFunV2UpgradeableBuybackTreasury.sol";
import {HedgeFunV2UpgradeableEngineTreasury} from "../src/v2/HedgeFunV2UpgradeableEngineTreasury.sol";
import {StrategyCapabilities} from "../src/v2/strategy/IStrategyPolicy.sol";
import {ReviewedTreasuryRegistry} from "./helpers/ReviewedTreasuryRegistry.sol";

/// @notice Append upgradeable buyback and spot-engine kinds for FUTURE launches on a reviewed #25 factory.
/// @dev Existing immutable kinds and treasuries are not modified. Kind IDs come from readback, not constants.
/// Each kind uses two operator CREATEs plus one registration: six transactions, simulated before broadcasting.
/// The registry and its upgrade controller must be the reviewed runtimes with every immutable bound: a
/// controller's `owner()` and `UPGRADE_DELAY()` getters alone do not prove that it enforces either.
contract RegisterV2UpgradeableKinds is ReviewedTreasuryRegistry {
    error BadBinding();
    error BadReadback();

    struct Kinds {
        uint8 buyback;
        uint8 engine;
    }

    function run() external returns (Kinds memory k) {
        address operator = vm.envAddress("OPERATOR");
        if (operator == address(0) || msg.sender != operator) revert BadBinding();
        k = register(operator, HedgeFunV2Factory(vm.envAddress("V2_FACTORY")));
        console2.log("upgradeable buyback kind", k.buyback);
        console2.log("upgradeable spot-engine kind", k.engine);
        console2.log("simulation readback passed; verify six receipts and live state after broadcast");
    }

    function register(address operator, HedgeFunV2Factory factory) public returns (Kinds memory k) {
        V2TreasuryDeployer registry = _reviewedRegistry(factory);
        V2TreasuryUpgradeController controller = registry.upgradeController();
        if (
            factory.owner() != operator || registry.factory() != address(factory)
                || registry.kindCount() + 2 > type(uint8).max || address(controller).code.length == 0
                || controller.owner() != operator || controller.UPGRADE_DELAY() != 2 days
        ) revert BadBinding();
        vm.startBroadcast(operator);
        (address a, address b) = _chunks(type(HedgeFunV2UpgradeableBuybackTreasury).creationCode);
        k.buyback = registry.registerKind(a, b);
        (a, b) = _chunks(type(HedgeFunV2UpgradeableEngineTreasury).creationCode);
        k.engine = registry.registerEngineKind(
            a,
            b,
            StrategyCapabilities.SPOT_ENGINE_V1,
            StrategyCapabilities.CONFIG_SCHEMA_V1,
            StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL
        );
        vm.stopBroadcast();
        check(registry, k);
    }

    function check(V2TreasuryDeployer registry, Kinds memory k) public view {
        HedgeFunV2Factory factory = HedgeFunV2Factory(registry.factory());
        if (address(_reviewedRegistry(factory)) != address(registry)) revert BadBinding();
        if (k.buyback == 0 || k.engine == 0 || k.buyback == k.engine) revert BadReadback();
        _same(registry, k.buyback, type(HedgeFunV2UpgradeableBuybackTreasury).creationCode, 0, 0, 0);
        _same(registry, k.engine, type(HedgeFunV2UpgradeableEngineTreasury).creationCode, 1, 1, 3);
    }

    function _same(
        V2TreasuryDeployer registry,
        uint8 kind,
        bytes memory code,
        uint32 version,
        uint32 schema,
        uint256 capabilities
    ) private view {
        (uint32 v, uint32 s, bytes32 hash, uint256 caps) = registry.kindManifest(kind);
        (address a, address b) = registry.kinds(kind);
        if (
            v != version || s != schema || caps != capabilities || hash != keccak256(code)
                || keccak256(bytes.concat(a.code, b.code)) != hash
        ) revert BadReadback();
    }

    /// @dev Direct operator CREATEs avoid registry.makeChunks' publicly advanceable deployment nonce.
    function _chunks(bytes memory code) private returns (address a, address b) {
        uint256 half = code.length / 2;
        bytes memory left = new bytes(half);
        bytes memory right = new bytes(code.length - half);
        assembly ("memory-safe") {
            mcopy(add(left, 32), add(code, 32), half)
            mcopy(add(right, 32), add(add(code, 32), half), mload(right))
        }
        a = address(new V2InitCodeChunk(left));
        b = address(new V2InitCodeChunk(right));
    }
}

contract VerifyV2UpgradeableKinds is Script {
    function run() external {
        HedgeFunV2Factory factory = HedgeFunV2Factory(vm.envAddress("V2_FACTORY"));
        uint256 buyback = vm.envUint("UPGRADEABLE_BUYBACK_KIND");
        uint256 engine = vm.envUint("UPGRADEABLE_ENGINE_KIND");
        require(buyback <= type(uint8).max && engine <= type(uint8).max, "kind id overflow");
        new RegisterV2UpgradeableKinds()
            .check(
                V2TreasuryDeployer(address(factory.treasuryDeployer())),
                RegisterV2UpgradeableKinds.Kinds(uint8(buyback), uint8(engine))
            );
    }
}
