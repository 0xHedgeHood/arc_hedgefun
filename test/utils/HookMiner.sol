// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HedgeFunHook} from "../../src/hooks/HedgeFunHook.sol";
import {HedgeFunV2Hook} from "../../src/hooks/HedgeFunV2Hook.sol";

/// Deploys THE hook the way the deploy script does: CREATE2 under a salt mined until the address carries 0x2844 in its
/// low 14 bits (about 16k tries). Once per suite -- a launch no longer mines anything. The hook comes back UNBOUND:
/// hand it to a `HedgeFunFactory` constructor, or `bind()` it from whoever is to play the factory.
abstract contract HookMiner is CommonBase {
    /// where the last search stopped: a suite that deploys a dozen factories needs a dozen hooks (a hook binds once),
    /// and starting each search from zero walks every salt already used
    uint256 private _cursor;

    function _deployHook(IPoolManager pm) internal returns (HedgeFunHook) {
        bytes32 initHash = keccak256(abi.encodePacked(type(HedgeFunHook).creationCode, abi.encode(pm)));
        for (uint256 i = _cursor; i < _cursor + 2_000_000; i++) {
            address at = vm.computeCreate2Address(bytes32(i), initHash, address(this));
            if (uint160(at) & 0x3FFF == 0x2844 && at.code.length == 0) { _cursor = i + 1; return new HedgeFunHook{salt: bytes32(i)}(pm); }
        }
        revert("no hook salt");
    }

    /// V2 uses its own immutable fee handler, at 0x28CC; V1 deployments continue to use `_deployHook`.
    function _deployV2Hook(IPoolManager pm) internal returns (HedgeFunV2Hook) {
        bytes32 initHash = keccak256(abi.encodePacked(type(HedgeFunV2Hook).creationCode, abi.encode(pm)));
        for (uint256 i = _cursor; i < _cursor + 2_000_000; i++) {
            address at = vm.computeCreate2Address(bytes32(i), initHash, address(this));
            if (uint160(at) & 0x3FFF == 0x28CC && at.code.length == 0) {
                _cursor = i + 1;
                return new HedgeFunV2Hook{salt: bytes32(i)}(pm);
            }
        }
        revert("no V2 hook salt");
    }
}
