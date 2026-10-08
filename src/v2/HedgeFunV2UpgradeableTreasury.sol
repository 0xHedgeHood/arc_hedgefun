// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {HedgeFunTreasuryBase} from "../HedgeFunTreasuryBase.sol";
import {HedgeFunV2AllInTreasury} from "./HedgeFunV2AllInTreasury.sol";
import {V2TreasuryUpgradeController} from "./V2TreasuryUpgradeController.sol";

interface IV2UpgradeRegistry { function upgradeController() external view returns (V2TreasuryUpgradeController); }

/// @dev Per-launch implementation: asset/pool identities remain constructor immutables; all ledger state is in the proxy.
/// Future implementations must preserve this complete storage layout and append new storage, or use namespaced storage.
contract HedgeFunV2UpgradeableTreasuryLogic is HedgeFunV2AllInTreasury {
    /// @notice Commits to the storage-schema identifier, all asset/pool identities and initial strategy parameters.
    bytes32 public immutable upgradeConfigHash;
    error InvalidInitialization();

    constructor(address usdg_, address stock_, address v3Pool_, address oracle_, address token_,
        address poolManager_, address factory_, Params memory p)
        HedgeFunV2AllInTreasury(usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p)
    {
        upgradeConfigHash = keccak256(abi.encode(keccak256("hedgefun.v2.all-in.proxy.storage.v1"),
            usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p));
    }

    /// @dev Callable only by delegatecall during proxy construction. Constructors initialized the implementation,
    /// not proxy storage. Repeated initialization after deployment and direct implementation calls both fail.
    function initializeProxy(Params calldata p) external {
        if (address(this).code.length != 0)
            revert InvalidInitialization();
        _params = p;
    }
}

/// @notice New default strategy treasury. Upgrade authority is the factory owner, through a fixed two-day controller.
/// @dev Its LP vault is a separate immutable contract. No upgrade of this proxy grants ownership of LP positions.
contract HedgeFunV2UpgradeableTreasury is Proxy {
    V2TreasuryUpgradeController public immutable treasuryUpgradeController;
    address public immutable initialImplementation;
    /// @notice Commits to the storage-schema identifier, all asset/pool identities and initial strategy parameters.
    bytes32 public immutable upgradeConfigHash;
    error NotUpgradeController();

    constructor(address usdg_, address stock_, address v3Pool_, address oracle_, address token_,
        address poolManager_, address factory_, HedgeFunTreasuryBase.Params memory p)
    {
        treasuryUpgradeController = IV2UpgradeRegistry(msg.sender).upgradeController();
        HedgeFunV2UpgradeableTreasuryLogic logic = new HedgeFunV2UpgradeableTreasuryLogic(
            usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p);
        initialImplementation = address(logic);
        upgradeConfigHash = logic.upgradeConfigHash();
        _call(address(logic), abi.encodeCall(HedgeFunV2UpgradeableTreasuryLogic.initializeProxy, (p)));
    }

    function implementation() public view returns (address) {
        address next = treasuryUpgradeController.implementationOf(address(this));
        return next == address(0) ? initialImplementation : next;
    }

    function _implementation() internal view override returns (address) { return implementation(); }

    /// @dev No public arbitrary-call surface: only the controller's matured, hash-committed upgrade can call this.
    function applyUpgrade(bytes calldata data) external {
        if (msg.sender != address(treasuryUpgradeController)) revert NotUpgradeController();
        if (data.length != 0) _call(implementation(), data);
    }

    function _call(address target, bytes memory data) private {
        (bool ok, bytes memory result) = target.delegatecall(data);
        if (!ok) assembly ("memory-safe") { revert(add(result, 0x20), mload(result)) }
    }
}
