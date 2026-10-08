// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {HedgeFunTreasuryBase} from "../HedgeFunTreasuryBase.sol";
import {HedgeFunV2EngineTreasuryCore, EngineBinding} from "./HedgeFunV2EngineTreasury.sol";
import {EngineConfig, PolicyManifest, IV2StrategyRegistry} from "./strategy/IStrategyPolicy.sol";
import {V2TreasuryUpgradeController} from "./V2TreasuryUpgradeController.sol";
import {IV2UpgradeRegistry} from "./HedgeFunV2UpgradeableTreasury.sol";

/// @notice Spot-engine implementation with the same storage layout as the direct engine.
/// @dev Asset and policy immutables are per treasury. Future implementations preserve all inherited slots.
/// The policy's mutable listing flag is not an upgrade identity: disabling NEW launches cannot strand old ones.
contract HedgeFunV2UpgradeableEngineTreasuryLogic is HedgeFunV2EngineTreasuryCore {
    bytes32 public immutable upgradeConfigHash;
    error InvalidInitialization();

    constructor(
        address usdg_,
        address stock_,
        address v3Pool_,
        address oracle_,
        address token_,
        address poolManager_,
        address factory_,
        Params memory p,
        EngineBinding memory binding
    ) HedgeFunV2EngineTreasuryCore(usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p, binding) {
        binding.manifest.enabledForNewLaunches = false;
        upgradeConfigHash = keccak256(
            abi.encode(
                keccak256("hedgefun.v2.spot-engine.proxy.storage.v1"),
                block.chainid,
                binding.treasury,
                [usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_],
                p,
                binding.config,
                binding.manifest,
                keccak256(abi.encode(_SCALE, _DUST_VALUE_LIMIT, SCALE, poolFeeBps, stockIsToken0, tradingCalendar))
            )
        );
    }

    /// @dev Both constructor-owned storage fields, including the guard, are initialized in the proxy.
    /// Direct implementation calls and post-construction replay fail. This is not the later migration entrypoint.
    function initializeProxy(Params calldata p, EngineConfig calldata c) external nonReentrant {
        if (address(this).code.length != 0) revert InvalidInitialization();
        _params = p;
        _engineConfig = c;
    }
}

/// @notice Upgradeable spot-policy treasury for future engine launches; fixed two-day controller notice.
/// @dev The constructor ABI remains the engine registry's ordinary args plus EngineConfig.
contract HedgeFunV2UpgradeableEngineTreasury is Proxy {
    V2TreasuryUpgradeController public immutable treasuryUpgradeController;
    address public immutable initialImplementation;
    bytes32 public immutable upgradeConfigHash;
    error NotUpgradeController();
    error PolicyUnavailable();

    constructor(
        address usdg_,
        address stock_,
        address v3Pool_,
        address oracle_,
        address token_,
        address poolManager_,
        address factory_,
        HedgeFunTreasuryBase.Params memory p,
        EngineConfig memory c
    ) {
        treasuryUpgradeController = IV2UpgradeRegistry(msg.sender).upgradeController();
        PolicyManifest memory manifest = IV2StrategyRegistry(msg.sender).policy(c.policyKey);
        if (!manifest.enabledForNewLaunches) revert PolicyUnavailable();
        HedgeFunV2UpgradeableEngineTreasuryLogic logic = new HedgeFunV2UpgradeableEngineTreasuryLogic(
            usdg_,
            stock_,
            v3Pool_,
            oracle_,
            token_,
            poolManager_,
            factory_,
            p,
            EngineBinding(c, manifest, address(this))
        );
        initialImplementation = address(logic);
        upgradeConfigHash = logic.upgradeConfigHash();
        _call(address(logic), abi.encodeCall(HedgeFunV2UpgradeableEngineTreasuryLogic.initializeProxy, (p, c)));
    }

    function implementation() public view returns (address) {
        address next = treasuryUpgradeController.implementationOf(address(this));
        return next == address(0) ? initialImplementation : next;
    }

    function _implementation() internal view override returns (address) {
        return implementation();
    }

    function applyUpgrade(bytes calldata data) external {
        if (msg.sender != address(treasuryUpgradeController)) revert NotUpgradeController();
        if (data.length != 0) _call(implementation(), data);
    }

    function _call(address target, bytes memory data) private {
        (bool ok, bytes memory result) = target.delegatecall(data);
        if (!ok) assembly ("memory-safe") { revert(add(result, 0x20), mload(result)) }
    }
}
