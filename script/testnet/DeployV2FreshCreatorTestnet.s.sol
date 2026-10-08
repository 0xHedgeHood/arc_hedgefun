// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployV2CreatorTestnet} from "./DeployV2CreatorTestnet.s.sol";

/// @notice Creator-selected core deployed by the dedicated, funded testnet wallet.
/// @dev Does not require or mutate the legacy venue operator. Fee recipient remains
///      the existing protocol. No signing material or arbitrary target is accepted.
contract DeployV2FreshCreatorTestnet is DeployV2CreatorTestnet {
    address public constant FRESH_OPERATOR = 0xCeCAd0eBB0CAb4fbB2fe6213E3cd6dE82e4D164B;

    function deploymentOperator() public pure override returns (address) {
        return FRESH_OPERATOR;
    }

    function _featureVersion() internal pure override returns (string memory) {
        return "v2-creator-selected-fresh-wallet-v2";
    }

    function _candidatePath(bool requested) internal pure override returns (string memory) {
        return
            requested ? "deploy/testnet-v2-fresh-creator.candidate.json" : "deploy/testnet-v2-fresh-creator.dryrun.json";
    }
}
