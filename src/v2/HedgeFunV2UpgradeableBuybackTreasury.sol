// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {HedgeFunTreasuryBase} from "../HedgeFunTreasuryBase.sol";
import {HedgeFunV2BuybackTreasury} from "./HedgeFunV2BuybackTreasury.sol";
import {IV2UpgradeRegistry} from "./HedgeFunV2UpgradeableTreasury.sol";
import {V2TreasuryUpgradeController} from "./V2TreasuryUpgradeController.sol";

/// @notice Per-launch kind-1 logic. Graduation principal remains segregated from income.
/// @dev Preserve the complete inherited buyback storage layout in every successor. Append
/// new fields or use namespaced storage; a dividend successor must bind its pool to the proxy.
contract HedgeFunV2UpgradeableBuybackTreasuryLogic is HedgeFunV2BuybackTreasury {
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
        Params memory p
    ) HedgeFunV2BuybackTreasury(usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p) {
        upgradeConfigHash = keccak256(
            abi.encode(
                keccak256("hedgefun.v2.buyback.proxy.storage.v1"),
                usdg_,
                stock_,
                v3Pool_,
                oracle_,
                token_,
                poolManager_,
                factory_,
                p,
                keccak256(abi.encode(_SCALE, _DUST_VALUE_LIMIT, SCALE, poolFeeBps, stockIsToken0))
            )
        );
    }

    /// @dev The base constructors initialize only Params and the reentrancy guard in storage;
    /// all other constructor bindings are immutables and all other ledger fields start at zero.
    /// The modifier leaves the proxy's guard in its constructor-equivalent NOT_ENTERED state.
    /// Deployment-only delegatecall: a live proxy or direct implementation cannot initialize.
    function initializeProxy(Params calldata p) external nonReentrant {
        if (address(this).code.length != 0) revert InvalidInitialization();
        _params = p;
    }
}

/// @notice Upgradeable kind 1 using the existing factory-owner, fixed two-day controller.
/// @dev The separate immutable LP vault retains its positions; this proxy has no LP withdrawal route.
contract HedgeFunV2UpgradeableBuybackTreasury is Proxy {
    V2TreasuryUpgradeController public immutable treasuryUpgradeController;
    address public immutable initialImplementation;
    bytes32 public immutable upgradeConfigHash;
    error NotUpgradeController();

    constructor(
        address usdg_,
        address stock_,
        address v3Pool_,
        address oracle_,
        address token_,
        address poolManager_,
        address factory_,
        HedgeFunTreasuryBase.Params memory p
    ) {
        treasuryUpgradeController = IV2UpgradeRegistry(msg.sender).upgradeController();
        HedgeFunV2UpgradeableBuybackTreasuryLogic logic = new HedgeFunV2UpgradeableBuybackTreasuryLogic(
            usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p
        );
        initialImplementation = address(logic);
        upgradeConfigHash = logic.upgradeConfigHash();
        _call(address(logic), abi.encodeCall(HedgeFunV2UpgradeableBuybackTreasuryLogic.initializeProxy, (p)));
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
