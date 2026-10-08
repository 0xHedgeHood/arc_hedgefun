// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunTreasuryBase} from "../HedgeFunTreasuryBase.sol";
import {HedgeFunV2CycleTreasuryCore} from "./HedgeFunV2CycleTreasury.sol";
import {IV2UpgradeRegistry} from "./HedgeFunV2UpgradeableTreasury.sol";
import {V2TreasuryUpgradeController} from "./V2TreasuryUpgradeController.sol";

/// @notice The cycle stock strategy behind the upgrade controller, with the percentage buy-back.
///
/// The cycle rule is the lot rule with one more entry. A lot is sold above its cost and bought again `dipBps`
/// under the last sale, as in every strategy kind; and after a real sale, a rise of `dipBps` over that sale's price
/// buys once more, up to the listing's chunk. Without that entry a stock that keeps climbing leaves the treasury in
/// cash for good after its first take-profits. `HedgeFunV2CycleTreasury` is the same rule deployed directly.
///
/// Two things differ from that contract, and neither is the rule:
///
///  * a `buyback()` offers a tenth of the waiting budget, raised to the minimum lot, in place of the listing's
///    fixed `buybackChunkUsdg`; the price limit, impact cap, cooldown and bounty are unchanged;
///  * the two convenience views, `reentryPending()` and `recoveryDue()`, are not here. `reentrySaleAt != 0` is the
///    first, and a keeper simulates `execute()` for the second, as it has to anyway.
///
/// The rungs keep the legacy floor: `tp1Bps` and `dipBps` at least twice the listing's slippage limit plus pool fee.
///
/// The runtime is 44 bytes under EIP-170. That is why the proxy's parameters are initialised as five raw storage
/// words, which the proxy's constructor packs, and not by a struct copy in this contract: the copy alone is some
/// 550 bytes of runtime. Anything added here has to take something out.
contract HedgeFunV2UpgradeableCycleTreasuryLogic is HedgeFunV2CycleTreasuryCore {
    bytes32 public immutable upgradeConfigHash;
    error InvalidInitialization();

    constructor(address usdg_, address stock_, address v3Pool_, address oracle_, address token_,
        address poolManager_, address factory_, Params memory p)
        HedgeFunV2CycleTreasuryCore(usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p)
    {
        upgradeConfigHash = keccak256(abi.encode(keccak256("hedgefun.v2.cycle.proxy.storage.v1"),
            usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p));
    }

    /// @dev Deployment-only delegatecall from the proxy's constructor: a live proxy and the implementation itself
    ///      both have code and are refused. The argument is `Params` exactly as storage holds it, five words from
    ///      `_params.slot`; `HedgeFunV2UpgradeableCycleTreasury` packs them and a test compares every field.
    function initializeProxy(bytes32[5] calldata) external {
        if (address(this).code.length != 0) revert InvalidInitialization();
        assembly ("memory-safe") {
            let slot := _params.slot
            for { let i := 0 } lt(i, 5) { i := add(i, 1) } { sstore(add(slot, i), calldataload(add(4, mul(i, 32)))) }
        }
    }

    /// @dev A tenth of the waiting budget, or the minimum lot if that is more.
    function _buybackChunk(uint256 p) internal view override returns (uint256) {
        return Math.max(buybackStock / 10, _ruleStockFor(_params.minLotUsdg, p));
    }
}

/// @notice Upgradeable cycle treasury; the same controller and two-day notice as kind 0.
contract HedgeFunV2UpgradeableCycleTreasury is Proxy {
    V2TreasuryUpgradeController public immutable treasuryUpgradeController;
    address public immutable initialImplementation;
    bytes32 public immutable upgradeConfigHash;
    error NotUpgradeController();

    constructor(address usdg_, address stock_, address v3Pool_, address oracle_, address token_,
        address poolManager_, address factory_, HedgeFunTreasuryBase.Params memory p)
    {
        treasuryUpgradeController = IV2UpgradeRegistry(msg.sender).upgradeController();
        HedgeFunV2UpgradeableCycleTreasuryLogic logic = new HedgeFunV2UpgradeableCycleTreasuryLogic(
            usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p);
        initialImplementation = address(logic);
        upgradeConfigHash = logic.upgradeConfigHash();
        _call(address(logic), abi.encodeCall(HedgeFunV2UpgradeableCycleTreasuryLogic.initializeProxy, (_words(p))));
    }

    /// @dev `Params` as Solidity lays it out in storage: the ten small fields share the first word, first field
    ///      lowest, then one word each for the three amounts and the band.
    function _words(HedgeFunTreasuryBase.Params memory p) private pure returns (bytes32[5] memory w) {
        w[0] = bytes32(
            uint256(p.tp1Bps) | uint256(p.tp2Bps) << 32 | uint256(p.dipBps) << 64 | uint256(p.stopBps) << 80
                | uint256(p.lotBps) << 96 | uint256(p.bountyBps) << 112 | uint256(p.maxSlippageBps) << 128
                | uint256(p.maxDeviationBps) << 144 | uint256(p.maxBuybackImpactBps) << 160
                | uint256(p.buybackCooldown) << 176
        );
        w[1] = bytes32(p.minLotUsdg);
        w[2] = bytes32(p.buybackChunkUsdg);
        w[3] = bytes32(p.sellChunkUsdg);
        w[4] = bytes32(uint256(p.bandBpsPerHour));
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
