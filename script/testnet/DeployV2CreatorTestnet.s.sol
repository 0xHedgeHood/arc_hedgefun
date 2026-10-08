// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployV2FeeUpgradeTestnet} from "./DeployV2FeeUpgradeTestnet.s.sol";
import {V2InitCodeChunk} from "../../src/v2/V2TreasuryDeployer.sol";
import {HedgeFunV2UpgradeableBuybackTreasury} from "../../src/v2/HedgeFunV2UpgradeableBuybackTreasury.sol";
import {HedgeFunV2UpgradeableEngineTreasury} from "../../src/v2/HedgeFunV2UpgradeableEngineTreasury.sol";
import {V2RebalancePolicy} from "../../src/v2/strategy/V2RebalancePolicy.sol";
import {StrategyCapabilities} from "../../src/v2/strategy/IStrategyPolicy.sol";

/// @notice Fresh creator-selected ordinary V2 core, reusing the eight screened testnet stock markets.
/// @dev Same pinned actors/venues as the fee core; 40 transactions deploy the additional chunks from the
///      operator EOA. Output is always an
///      unverified candidate. A separate canonical receipt audit is required before frontend publication.
contract DeployV2CreatorTestnet is DeployV2FeeUpgradeTestnet {
    function plannedTransactionCount() public pure override returns (uint256) {
        return 40;
    }

    /// @dev Public registry.makeChunks uses a third-party-mutable CREATE nonce. Separate broadcast transactions
    ///      must instead use the operator's nonce, so an intervening public helper call cannot occupy a chunk
    ///      address recorded during simulation. The ordinary default chunks are already atomic in its constructor.
    function _register(Deployment memory x) internal override {
        (address a, address b) = _makeOperatorChunks(type(HedgeFunV2UpgradeableBuybackTreasury).creationCode);
        if (x.treasury.registerKind(a, b) != 1) revert BadBinding("buyback kind");
        x.policy = new V2RebalancePolicy();
        x.policyKey = x.treasury
            .registerPolicy(
                address(x.policy),
                150_000,
                x.treasury.POLICY_RETURN_BYTES(),
                keccak256("hedgefun testnet 46630: V2RebalancePolicy dependencies (none audited for testnet)"),
                keccak256("hedgefun testnet 46630: V2RebalancePolicy audit manifest (testnet placeholder)")
            );
        (a, b) = _makeOperatorChunks(type(HedgeFunV2UpgradeableEngineTreasury).creationCode);
        x.engineKind = x.treasury
            .registerEngineKind(
                a,
                b,
                StrategyCapabilities.SPOT_ENGINE_V1,
                StrategyCapabilities.CONFIG_SCHEMA_V1,
                StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL
            );
        if (x.engineKind != 2) revert BadBinding("engine kind");
    }

    function _makeOperatorChunks(bytes memory code) private returns (address a, address b) {
        uint256 half = code.length / 2;
        a = address(new V2InitCodeChunk(_slice(code, 0, half)));
        b = address(new V2InitCodeChunk(_slice(code, half, code.length - half)));
    }

    function _slice(bytes memory src, uint256 offset, uint256 length) private pure returns (bytes memory part) {
        part = new bytes(length);
        assembly ("memory-safe") {
            mcopy(add(part, 0x20), add(add(src, 0x20), offset), length)
        }
    }

    function _featureVersion() internal pure virtual override returns (string memory) {
        return "v2-creator-selected-stock-fees-v2";
    }

    function _candidatePath(bool requested) internal pure virtual override returns (string memory) {
        return requested ? "deploy/testnet-v2-creator.candidate.json" : "deploy/testnet-v2-creator.dryrun.json";
    }
}
