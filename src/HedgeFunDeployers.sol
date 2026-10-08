// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HedgeFunToken} from "./HedgeFunToken.sol";
import {HedgeFunTreasury} from "./HedgeFunTreasury.sol";

/// The treasury's creation code lives in its own deployer, because with the factory's own it does not fit in one
/// contract (EIP-170). Token and treasury are both CREATE2, so a launch's addresses are known before it happens.
///
/// A deployer answers to exactly one factory. An open `deploy` would be a permanent denial of service: every salt
/// is keccak of public data and every constructor argument is readable, so anyone could rebuild a pending launch's
/// arguments and occupy its address first. `create2` to an occupied address returns zero, the launch reverts, and
/// a reverted launch leaves the salt exactly where it was — so that launch could never succeed, for the price of
/// one transaction and no launch fee.
abstract contract BoundDeployer {
    address public factory;

    error AlreadyBound();
    error NotFactory();

    /// @notice claim this deployer. `HedgeFunFactory` does it from its own constructor, so a deployer someone else
    ///         has already claimed fails that constructor loudly, before anything is live — deploy fresh ones.
    function bind() external {
        if (factory != address(0)) revert AlreadyBound();
        factory = msg.sender;
    }

    function _onlyFactory() internal view { if (msg.sender != factory) revert NotFactory(); }

    function _at(bytes32 salt, bytes32 h) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, h)))));
    }
}

contract TreasuryDeployer is BoundDeployer {
    /// a constructor's revert reason does not survive CREATE2: this is all a refused treasury ever says
    error TreasuryDeployFailed();

    function deploy(bytes32 salt, bytes calldata args) external returns (address a) {
        _onlyFactory();
        bytes memory code = abi.encodePacked(type(HedgeFunTreasury).creationCode, args);
        assembly { a := create2(0, add(code, 0x20), mload(code), salt) }
        if (a == address(0)) revert TreasuryDeployFailed();
    }
    function predict(bytes32 salt, bytes calldata args) external view returns (address) {
        return _at(salt, keccak256(abi.encodePacked(type(HedgeFunTreasury).creationCode, args)));
    }
}

/// The token's creation code lives here for the same reason the treasury's lives in `TreasuryDeployer`: whatever a
/// contract can `new` counts against that contract's own 24,576 bytes. The token carries its creator's metadata
/// (logo, description, links), which is bytecode the factory does not have to spare.
contract TokenDeployer is BoundDeployer {
    error TokenDeployFailed();

    function deploy(bytes32 salt, bytes calldata args) external returns (address a) {
        _onlyFactory();
        bytes memory code = abi.encodePacked(type(HedgeFunToken).creationCode, args);
        assembly { a := create2(0, add(code, 0x20), mload(code), salt) }
        if (a == address(0)) revert TokenDeployFailed();
    }
    function predict(bytes32 salt, bytes calldata args) external view returns (address) {
        return _at(salt, keccak256(abi.encodePacked(type(HedgeFunToken).creationCode, args)));
    }
}
