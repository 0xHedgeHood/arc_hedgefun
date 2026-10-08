// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployV2CreatorTestnet} from "./DeployV2CreatorTestnet.s.sol";

/// @notice The release-candidate core on the testnet, deployed by the current deployer wallet.
/// @dev The same forty transactions as `DeployV2FreshCreatorTestnet`, from the source being released: a new
///      registry, deployers, hook, factory and routers, the eight existing synthetic stock markets listed on it,
///      and public launch open. Nothing of the earlier cores or of the venue is touched. The deployer owns the new
///      factory; the fee recipient remains the existing protocol address. No signing material or arbitrary target
///      is accepted: the deployer is pinned here, and a different wallet needs its own reviewed script.
///
///      This registers kinds 1 and 2 only. The rebalance, percentage buy-back and cycle kinds are appended
///      afterwards with their own registration scripts, and the keeper reward is set with `SetV2KeeperReward`.
contract DeployV2ReleaseTestnet is DeployV2CreatorTestnet {
    address public constant RELEASE_OPERATOR = 0x36437b878415EdA1a24186CF79AFffBc9ecEd298;

    function deploymentOperator() public pure override returns (address) {
        return RELEASE_OPERATOR;
    }

    function _featureVersion() internal pure override returns (string memory) {
        return "v2-release-candidate-v2";
    }

    function _candidatePath(bool requested) internal pure override returns (string memory) {
        return requested ? "deploy/testnet-v2-release.candidate.json" : "deploy/testnet-v2-release.dryrun.json";
    }
}
