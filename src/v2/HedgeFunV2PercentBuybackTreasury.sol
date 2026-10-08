// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunTreasuryBase} from "../HedgeFunTreasuryBase.sol";
import {HedgeFunV2UpgradeableTreasuryLogic, IV2UpgradeRegistry} from "./HedgeFunV2UpgradeableTreasury.sol";
import {V2TreasuryUpgradeController} from "./V2TreasuryUpgradeController.sol";

/// @notice The ordinary stock strategy (kind 0) whose buy-back spends a share of its budget, not a fixed amount.
///
/// Kind 0 offers the token pool `buybackChunkUsdg` per `buyback()`, a number the factory owner sets for every
/// launch: too large for a small treasury, which burns a take-profit's whole gain in one or two calls, and too
/// small for a large one. Here one call offers `BUYBACK_BPS` of what is waiting, so a budget of any size leaves in
/// the same number of steps, each smaller than the last, one per `buybackCooldown`. A share that would fall under
/// the listing's minimum lot is raised to it, and the last remainder under a lot goes whole, so the tail ends.
///
/// Nothing else differs from kind 0: the same lots, the same take-profit, dip and stop rungs, the same price
/// limit, impact cap, cooldown and bounty on the buy-back. `buybackChunkUsdg` is accepted and ignored.
///
/// The logic keeps kind 0's storage family and identity, so it is also a compatible upgrade for a kind-0 treasury
/// that is already live: the owner schedules it through the controller, with the two-day notice.
contract HedgeFunV2PercentBuybackTreasuryLogic is HedgeFunV2UpgradeableTreasuryLogic {
    /// @notice the share of the waiting buy-back budget one `buyback()` offers, in bps. A different share is a new kind.
    uint256 public constant BUYBACK_BPS = 1000;

    constructor(address usdg_, address stock_, address v3Pool_, address oracle_, address token_,
        address poolManager_, address factory_, Params memory p)
        HedgeFunV2UpgradeableTreasuryLogic(usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p) {}

    function _buybackChunk(uint256 p) internal view override returns (uint256) {
        return Math.max(buybackStock * BUYBACK_BPS / 10000, _ruleStockFor(_params.minLotUsdg, p));
    }
}

/// @notice Upgradeable strategy treasury with the percentage buy-back; the same controller and notice as kind 0.
contract HedgeFunV2PercentBuybackTreasury is Proxy {
    V2TreasuryUpgradeController public immutable treasuryUpgradeController;
    address public immutable initialImplementation;
    bytes32 public immutable upgradeConfigHash;
    error NotUpgradeController();

    constructor(address usdg_, address stock_, address v3Pool_, address oracle_, address token_,
        address poolManager_, address factory_, HedgeFunTreasuryBase.Params memory p)
    {
        treasuryUpgradeController = IV2UpgradeRegistry(msg.sender).upgradeController();
        HedgeFunV2PercentBuybackTreasuryLogic logic = new HedgeFunV2PercentBuybackTreasuryLogic(
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

    function applyUpgrade(bytes calldata data) external {
        if (msg.sender != address(treasuryUpgradeController)) revert NotUpgradeController();
        if (data.length != 0) _call(implementation(), data);
    }

    function _call(address target, bytes memory data) private {
        (bool ok, bytes memory result) = target.delegatecall(data);
        if (!ok) assembly ("memory-safe") { revert(add(result, 0x20), mload(result)) }
    }
}
