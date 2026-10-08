// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IV2UpgradeSource { function factory() external view returns (address); }
interface IV2UpgradeOwner {
    function owner() external view returns (address);
    function ownershipEpoch() external view returns (uint256);
}
interface IV2UpgradeableIdentity {
    function upgradeConfigHash() external view returns (bytes32);
}
interface IV2TreasuryProxy is IV2UpgradeableIdentity {
    function treasuryUpgradeController() external view returns (address);
    function implementation() external view returns (address);
    function applyUpgrade(bytes calldata data) external;
}

/// @notice Public, per-treasury upgrades with a fixed two-day notice period and cancellation.
/// @dev Implementation pointers live HERE, not in delegatecall-writable treasury storage. LP vaults are not proxies.
/// Governance can change treasury custody logic; the delay is notice, not a proof that new code is trustworthy.
contract V2TreasuryUpgradeController {
    uint256 public constant UPGRADE_DELAY = 2 days;
    address private immutable deployer;
    mapping(address => address) public implementationOf;
    struct Proposal { address implementation; uint256 ownershipEpoch; bytes32 codeHash; bytes32 dataHash; uint256 readyAt; }
    mapping(address => Proposal) public proposals;
    event UpgradeScheduled(address indexed treasury, address indexed implementation, bytes32 codeHash, bytes32 dataHash, uint256 readyAt);
    event UpgradeCancelled(address indexed treasury);
    event UpgradeExecuted(address indexed treasury, address indexed oldImplementation, address indexed newImplementation);
    error NotOwner();
    error InvalidUpgrade();
    error NotReady();

    constructor() { deployer = msg.sender; }

    function owner() public view returns (address) {
        IV2UpgradeOwner f = _factory();
        return address(f) == address(0) ? address(0) : f.owner();
    }

    function _factory() private view returns (IV2UpgradeOwner) {
        return IV2UpgradeOwner(IV2UpgradeSource(deployer).factory());
    }

    function schedule(address treasury, address next, bytes calldata migration) external {
        if (msg.sender != owner()) revert NotOwner();
        _check(treasury, next);
        uint256 readyAt = block.timestamp + UPGRADE_DELAY;
        proposals[treasury] = Proposal(next, _factory().ownershipEpoch(), next.codehash, keccak256(migration), readyAt);
        emit UpgradeScheduled(treasury, next, next.codehash, keccak256(migration), readyAt);
    }

    function cancel(address treasury) external {
        if (msg.sender != owner()) revert NotOwner();
        delete proposals[treasury];
        emit UpgradeCancelled(treasury);
    }

    function execute(address treasury, bytes calldata migration) external {
        Proposal memory p = proposals[treasury];
        if (p.readyAt == 0 || block.timestamp < p.readyAt) revert NotReady();
        if (p.ownershipEpoch != _factory().ownershipEpoch()
            || p.codeHash != p.implementation.codehash || p.dataHash != keccak256(migration))
            revert InvalidUpgrade();
        _check(treasury, p.implementation);
        address previous = IV2TreasuryProxy(treasury).implementation();
        // Consume before the external migration call: this proposal cannot execute again through reentrancy.
        delete proposals[treasury];
        implementationOf[treasury] = p.implementation;
        // Failed state migration reverts the pointer, proposal consumption and all migrated state atomically.
        IV2TreasuryProxy(treasury).applyUpgrade(migration);
        emit UpgradeExecuted(treasury, previous, p.implementation);
    }

    function _check(address treasury, address next) private view {
        if (treasury.code.length == 0 || next.code.length == 0 || treasury == next
            || IV2TreasuryProxy(treasury).treasuryUpgradeController() != address(this)
            || IV2UpgradeableIdentity(next).upgradeConfigHash() != IV2UpgradeableIdentity(treasury).upgradeConfigHash())
            revert InvalidUpgrade();
    }
}
