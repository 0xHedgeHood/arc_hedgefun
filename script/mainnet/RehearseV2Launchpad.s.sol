// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {HedgeFunFactory} from "../../src/HedgeFunFactory.sol";
import {V2TreasuryDeployer, V2InitCodeChunk} from "../../src/v2/V2TreasuryDeployer.sol";
import {HedgeFunV2UpgradeableBuybackTreasury} from "../../src/v2/HedgeFunV2UpgradeableBuybackTreasury.sol";
import {CurveDeployer} from "../../src/v2/CurveDeployer.sol";
import {V2MainnetCore} from "./V2MainnetCore.sol";

/// @notice Simulates the V2 core deployment against a local Robinhood Chain fork.
/// @dev Deliberately refuses chain 4663 and every broadcast. It runs `V2MainnetCore`, the code
///      `DeployV2MainnetCore` broadcasts, with the same roles and the same preflight, so what passes here is what
///      would be sent. This script neither lists a stock nor opens public launch.
///      Use `forge script` without `--broadcast` as described in docs/V2_DEPLOYMENT_REHEARSAL.md.
///      Requires OWNER, PROTOCOL, WETH and CALENDAR; DEPLOYER_SETS_UP and HOOK_SALT_START are optional.
contract RehearseV2Launchpad is V2MainnetCore {
    error ForkOnly();
    error BroadcastForbidden();

    function run() external {
        rehearse(
            msg.sender,
            Roles(vm.envAddress("OWNER"), vm.envAddress("PROTOCOL"), vm.envAddress("WETH")),
            vm.envAddress("CALENDAR"),
            vm.envOr("DEPLOYER_SETS_UP", false),
            vm.envOr("HOOK_SALT_START", uint256(0))
        );
    }

    function rehearse(address deployer, Roles memory r, address calendar, bool deployerSetsUp, uint256 saltStart)
        public
        returns (Deployed memory x)
    {
        if (block.chainid != 31337) revert ForkOnly();
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
            || vm.isContext(VmSafe.ForgeContext.ScriptResume)) revert BroadcastForbidden();
        if (calendar.code.length == 0) revert MissingCode(calendar);
        HedgeFunFactory.Defaults memory d = _defaults();
        _preflight(deployer, r, d);
        (bytes32 salt, address mined) = _mineHook(saltStart);
        address firstOwner = _firstOwner(deployer, r, deployerSetsUp);
        console2.log("V2 fork rehearsal; chain", block.chainid);
        console2.log("owner Safe", r.owner);
        console2.log("protocol Safe", r.protocol);
        console2.log("wrapped native", r.weth);
        console2.log("factory owner at deployment", firstOwner);
        console2.log("existing calendar", calendar);
        console2.log("hook salt", uint256(salt));
        console2.log("hook address", mined);
        console2.log("defaults hash, for EXPECTED_DEFAULTS_HASH once reviewed:");
        console2.logBytes32(keccak256(abi.encode(d)));

        // forge script without --broadcast simulates these transactions and discards them.
        vm.startBroadcast(deployer);
        x = _deployCore(firstOwner, r, d, salt, mined);
        (address a, address b) = _chunks(type(HedgeFunV2UpgradeableBuybackTreasury).creationCode);
        vm.stopBroadcast();
        _readBackCore(x, firstOwner, r, d);

        _rehearseKindRegistration(x.treasury, firstOwner, a, b);
        _readBackCurveChoices(x.curve, d.snipeSeconds);
        console2.log("V2 treasury deployer", address(x.treasury));
        console2.log("V2 treasury code chunk A", x.treasury.chunkA());
        console2.log("V2 treasury code chunk B", x.treasury.chunkB());
        console2.log("upgrade controller", address(x.treasury.upgradeController()));
        console2.log("kind 1 buyback chunk A", a);
        console2.log("kind 1 buyback chunk B", b);
        console2.log("registered strategy kinds", x.treasury.kindCount());
        console2.log("token deployer", address(x.token));
        console2.log("curve deployer", address(x.curve));
        console2.log("curve code chunk", x.curve.curveChunk());
        console2.log("hook", address(x.hook));
        console2.log("V2 factory", address(x.factory));
        console2.log("V2 trade router", address(x.router));
        console2.log("V2 native router", address(x.nativeRouter));
        console2.log("lp fee", d.lpFee);
        // The sale share is the curve deployer's, fixed at construction; the opening window is each creator's.
        console2.log("fixed saleBps, for EXPECTED_SALE_BPS once reviewed", x.curve.DEFAULT_SALE_BPS());
        console2.log("creator snipeSeconds max", x.curve.MAX_SNIPE_SECONDS());
        console2.log("default snipeSeconds (no registration)", d.snipeSeconds);
        console2.log("public launch", x.factory.publicLaunch());
        console2.log("readback passed; no stock listed or launched");
    }

    /// @dev One owner transaction, rehearsed without signing: the factory owner appends the upgradeable buy-back
    ///      treasury as kind 1 from two chunks the deploying key created. The registry's own `makeChunks` is not
    ///      used: it is public, and its CREATE nonce can be advanced by anyone between a simulation and its
    ///      broadcast, which would move the addresses a recorded registration names. This proves the call
    ///      succeeds for the owner; it does not prove Safe signing or execution.
    function _rehearseKindRegistration(V2TreasuryDeployer registry, address firstOwner, address a, address b) internal {
        vm.prank(firstOwner);
        if (registry.registerKind(a, b) != 1 || registry.kindCount() != 2) revert ReadbackFailed("kind 1");
        (address storedA, address storedB) = registry.kinds(1);
        if (
            storedA != a || storedB != b
                || keccak256(bytes.concat(a.code, b.code))
                    != keccak256(type(HedgeFunV2UpgradeableBuybackTreasury).creationCode)
        ) revert ReadbackFailed("kind 1 code");
    }

    function _chunks(bytes memory code) private returns (address a, address b) {
        uint256 half = code.length / 2;
        bytes memory left = new bytes(half);
        bytes memory right = new bytes(code.length - half);
        assembly ("memory-safe") {
            mcopy(add(left, 32), add(code, 32), half)
            mcopy(add(right, 32), add(add(code, 32), half), mload(right))
        }
        a = address(new V2InitCodeChunk(left));
        b = address(new V2InitCodeChunk(right));
    }

    /// @dev The creator's registry: the fixed 7931 sale, which no registration can move, the 180-second window
    ///      cap, and a registration keyed by the factory's salt (symbol, creator, nonce).
    ///      The registration is simulated from a throwaway address and discarded with everything else.
    function _readBackCurveChoices(CurveDeployer curve, uint8 defaultSnipeSeconds) internal {
        if (curve.MIN_SALE_BPS() != 1000 || curve.MAX_SALE_BPS() != 9000 || curve.DEFAULT_SALE_BPS() != 7931
            || curve.MAX_SNIPE_SECONDS() != 180) revert ReadbackFailed("curve bounds");
        address creator = address(uint160(uint256(keccak256("rehearsal creator"))));
        bytes32 salt = keccak256(abi.encode("REHEARSE", creator, uint96(1)));
        (uint16 sale, uint8 window) = curve.curveConfig(salt, defaultSnipeSeconds);
        if (sale != 7931 || window != defaultSnipeSeconds) revert ReadbackFailed("curve default");
        uint16[6] memory other = [uint16(1000), 6000, 7930, 7932, 8000, 9000];
        for (uint256 i; i < other.length; ++i) {
            vm.prank(creator);
            try curve.setCurveConfig("REHEARSE", 1, other[i], 60) {
                revert ReadbackFailed("sale share was a choice");
            } catch (bytes memory reason) {
                if (bytes4(reason) != CurveDeployer.BadCurveConfig.selector) revert ReadbackFailed("sale share refusal");
            }
        }
        vm.prank(creator);
        curve.setCurveConfig("REHEARSE", 1, 7931, 60);
        (sale, window) = curve.curveConfig(salt, defaultSnipeSeconds);
        if (sale != 7931 || window != 60) revert ReadbackFailed("curve window");
    }
}
