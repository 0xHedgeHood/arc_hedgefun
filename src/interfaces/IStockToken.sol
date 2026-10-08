// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// What this repository asks of a Robinhood Chain stock token beyond ERC-20. The token is upgradeable by its
/// issuer, so every call through this interface is made inside a `try`.
interface IStockToken {
    /// set while a corporate action is processed: the feed is frozen at the last good value
    function oraclePaused() external view returns (bool);
    /// NOT implemented by the token today; reserved for `HedgeFunTreasuryBase.setVoteDelegate`
    function delegate(address delegatee) external;
}
