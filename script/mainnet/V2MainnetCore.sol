// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HedgeFunFactory, TokenDeployer} from "../../src/HedgeFunFactory.sol";
import {HedgeFunV2Hook} from "../../src/hooks/HedgeFunV2Hook.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {V2TreasuryDeployer} from "../../src/v2/V2TreasuryDeployer.sol";
import {CurveDeployer} from "../../src/v2/CurveDeployer.sol";
import {HedgeFunBondingCurve} from "../../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter} from "../../src/v2/HedgeFunV2TradeRouter.sol";
import {HedgeFunV2NativeRouter, IWrappedNative} from "../../src/v2/HedgeFunV2NativeRouter.sol";
import {V2MainnetDefaults} from "./V2MainnetDefaults.sol";

/// @notice The V2 core for Robinhood Chain (4663): what is deployed, with what bindings, and what is checked first.
/// @dev Shared by `DeployV2MainnetCore`, which broadcasts it on chain 4663, and `RehearseV2Launchpad`, which runs
///      the same code on a local fork and broadcasts nothing. Neither imports anything from `script/testnet/`:
///      there are no test tokens, feeds, markets or operator constants here.
///
///      The core is seven contracts and no owner action. The factory is born with public launch closed and
///      nothing listed, and its registry holds kind 0 only. Everything after that is the factory owner's:
///      registering further strategy kinds and policies, listing stocks, whitelisting a launch router, opening
///      public launch.
///
///      Who that first owner is, is the caller's explicit choice:
///
///       * the owner Safe, from the constructor. The deploying key never holds a role, and every later step is a
///         Safe transaction;
///       * the deploying key (`deployerSetsUp`), which then runs the registration and listing scripts, all of
///         which broadcast as the factory owner, and hands the factory to the Safe with `HandOverV2Mainnet`
///         before public launch is opened. Until the Safe accepts, that one key can do anything an owner can,
///         including schedule a treasury upgrade; nothing is launched in that window because launch is closed.
abstract contract V2MainnetCore is Script {
    uint256 public constant CHAIN_ID = 4663;
    address public constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address public constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address public constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint160 public constant HOOK_FLAGS = 0x28CC;

    error MissingCode(address target);
    error UnsafeRole(address who);
    error BadWrappedNative(address weth);
    error ProtocolRefusesNative(address protocol);
    error BadHook(address expected, address actual);
    error NoHookSalt();
    error ReadbackFailed(string what);

    /// @param owner the Safe that owns the factory, and through it the registry and the upgrade controller,
    ///        once deployment and any hand-over are complete
    /// @param protocol the Safe that receives the protocol's share of tax and the launch fee
    /// @param weth the chain's wrapped native token, for the native-currency router
    struct Roles {
        address owner;
        address protocol;
        address weth;
    }

    /// @dev the factory's owner at construction: the Safe, or the deploying key when it is to run the setup
    function _firstOwner(address deployer, Roles memory r, bool deployerSetsUp) internal pure returns (address) {
        return deployerSetsUp ? deployer : r.owner;
    }

    struct Deployed {
        V2TreasuryDeployer treasury;
        TokenDeployer token;
        CurveDeployer curve;
        HedgeFunV2Hook hook;
        HedgeFunV2Factory factory;
        HedgeFunV2TradeRouter router;
        HedgeFunV2NativeRouter nativeRouter;
        bytes32 hookSalt;
    }

    function _defaults() internal pure returns (HedgeFunFactory.Defaults memory) {
        return V2MainnetDefaults.release();
    }

    /// @dev Everything that can be refused before a transaction is sent. Nothing here is broadcast: the two probes
    ///      move one wei inside a state snapshot that is reverted.
    function _preflight(address deployer, Roles memory r, HedgeFunFactory.Defaults memory d) internal {
        if (PM.code.length == 0) revert MissingCode(PM);
        if (V3_FACTORY.code.length == 0) revert MissingCode(V3_FACTORY);
        if (USDG.code.length == 0) revert MissingCode(USDG);
        if (CREATE2_FACTORY.code.length == 0) revert MissingCode(CREATE2_FACTORY);
        _requireSafe(r.owner);
        _requireSafe(r.protocol);
        // A key that deploys must hold no role afterwards.
        if (deployer == r.owner || deployer == r.protocol) revert UnsafeRole(deployer);
        _requireWrappedNative(r.weth);
        // `HedgeFunFactory._chargeLaunchFee` forwards a native fee to `protocol`, which is immutable, and reverts
        // the launch if the transfer fails. A recipient that cannot take it would refuse every launch.
        if (d.launchFeeCurrency == HedgeFunFactory.FeeCurrency.Native) _requireAcceptsNative(r.protocol);
    }

    /// @dev Seven CREATEs from the broadcaster; the caller opens and closes the broadcast.
    function _deployCore(
        address firstOwner,
        Roles memory r,
        HedgeFunFactory.Defaults memory d,
        bytes32 salt,
        address mined
    ) internal returns (Deployed memory x) {
        x.hookSalt = salt;
        x.treasury = new V2TreasuryDeployer();
        x.token = new TokenDeployer();
        x.curve = new CurveDeployer(V2MainnetDefaults.SALE_BPS);
        x.hook = new HedgeFunV2Hook{salt: salt}(IPoolManager(PM));
        if (address(x.hook) != mined || uint160(address(x.hook)) & 0x3FFF != HOOK_FLAGS) {
            revert BadHook(mined, address(x.hook));
        }
        x.factory = new HedgeFunV2Factory(
            firstOwner, PM, V3_FACTORY, USDG, r.protocol, address(x.treasury), address(x.token), address(x.hook),
            address(x.curve), d
        );
        x.router = new HedgeFunV2TradeRouter(x.factory);
        x.nativeRouter = new HedgeFunV2NativeRouter(x.router, IWrappedNative(r.weth));
    }

    /// @dev The simulation's state. After a broadcast, run `VerifyV2MainnetCore` against the confirmed chain.
    function _readBackCore(Deployed memory x, address firstOwner, Roles memory r, HedgeFunFactory.Defaults memory d)
        internal
        view
    {
        HedgeFunV2Factory f = x.factory;
        if (f.owner() != firstOwner || f.pendingOwner() != address(0) || f.protocol() != r.protocol) {
            revert ReadbackFailed("roles");
        }
        if (f.publicLaunch() || f.strategyCount() != 0) revert ReadbackFailed("born closed and empty");
        if (
            address(f.poolManager()) != PM || address(f.v3Factory()) != V3_FACTORY || f.usdg() != USDG
                || address(f.treasuryDeployer()) != address(x.treasury) || address(f.curveDeployer()) != address(x.curve)
                || address(f.hook()) != address(x.hook)
        ) revert ReadbackFailed("factory bindings");
        if (
            x.treasury.factory() != address(f) || x.token.factory() != address(f) || x.curve.factory() != address(f)
                || x.hook.factory() != address(f) || address(x.router.factory()) != address(f)
                || address(x.nativeRouter.router()) != address(x.router)
                || address(x.nativeRouter.wrappedNative()) != r.weth
        ) revert ReadbackFailed("component bindings");
        if (x.treasury.version() != 2 || x.hook.version() != 3 || x.treasury.kindCount() != 1) {
            revert ReadbackFailed("versions and kinds");
        }
        if (x.treasury.upgradeController().owner() != firstOwner) revert ReadbackFailed("upgrade controller owner");
        if (keccak256(abi.encode(f.getDefaults())) != keccak256(abi.encode(d))) revert ReadbackFailed("defaults");
        // Permanent: the sale share is the curve deployer's immutable, and nothing can correct it but a redeployment.
        if (x.curve.DEFAULT_SALE_BPS() != V2MainnetDefaults.SALE_BPS) revert ReadbackFailed("sale share");
        if (x.treasury.DEFAULT_LP_BPS() != V2MainnetDefaults.LP_BPS) revert ReadbackFailed("default LP share");
        // The curve deployer creates its curve-code chunk in its own constructor; every curve address hashes it.
        if (keccak256(x.curve.curveChunk().code) != keccak256(type(HedgeFunBondingCurve).creationCode)) {
            revert ReadbackFailed("curve code");
        }
    }

    function _mineHook(uint256 start) internal view returns (bytes32 salt, address hook) {
        if (start > type(uint256).max - 2_000_000) revert NoHookSalt();
        bytes32 initHash = keccak256(abi.encodePacked(type(HedgeFunV2Hook).creationCode, abi.encode(PM)));
        for (uint256 i = start; i < start + 2_000_000; ++i) {
            hook = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, bytes32(i), initHash))))
            );
            if (uint160(hook) & 0x3FFF == HOOK_FLAGS && hook.code.length == 0) return (bytes32(i), hook);
        }
        revert NoHookSalt();
    }

    /// @dev Answers as a Safe that needs at least two signatures. It does not prove who the signers are.
    function _requireSafe(address who) internal view {
        if (who.code.length == 0 || who.code.length == 23 && who.code[0] == 0xef) revert UnsafeRole(who);
        (bool ok, bytes memory result) = who.staticcall(abi.encodeWithSignature("getThreshold()"));
        if (!ok || result.length != 32) revert UnsafeRole(who);
        uint256 threshold = abi.decode(result, (uint256));
        (ok, result) = who.staticcall(abi.encodeWithSignature("getOwners()"));
        if (!ok || result.length < 64) revert UnsafeRole(who);
        uint256 owners = abi.decode(result, (address[])).length;
        if (threshold < 2 || threshold > owners) revert UnsafeRole(who);
    }

    /// @dev The router is fixed to this address for good. An address that merely has code is not enough: wrap one
    ///      wei and unwrap it, inside a snapshot.
    function _requireWrappedNative(address weth) internal {
        if (weth.code.length == 0 || weth == USDG) revert BadWrappedNative(weth);
        uint256 snapshot = vm.snapshotState();
        V2NativeProbe probe = new V2NativeProbe();
        vm.deal(address(probe), 1);
        bool ok = probe.wrapsOneWei(weth);
        vm.revertToState(snapshot);
        if (!ok) revert BadWrappedNative(weth);
    }

    function _requireAcceptsNative(address protocol) internal {
        uint256 snapshot = vm.snapshotState();
        V2NativeProbe probe = new V2NativeProbe();
        vm.deal(address(probe), 1);
        bool ok = probe.paysOneWei(protocol);
        vm.revertToState(snapshot);
        if (!ok) revert ProtocolRefusesNative(protocol);
    }
}

/// @notice Moves one wei for the two preflight probes. It exists only inside a reverted snapshot: a script may
///         not use its own address, and nothing here is ever broadcast.
contract V2NativeProbe {
    receive() external payable {}

    function wrapsOneWei(address weth) external returns (bool) {
        try IERC20Metadata(weth).decimals() returns (uint8 decimals) {
            if (decimals != 18) return false;
        } catch { return false; }
        uint256 held = IWrappedNative(weth).balanceOf(address(this));
        try IWrappedNative(weth).deposit{value: 1}() {} catch { return false; }
        if (IWrappedNative(weth).balanceOf(address(this)) != held + 1 || address(this).balance != 0) return false;
        try IWrappedNative(weth).withdraw(1) {} catch { return false; }
        return IWrappedNative(weth).balanceOf(address(this)) == held && address(this).balance == 1;
    }

    function paysOneWei(address to) external returns (bool ok) {
        (ok,) = to.call{value: 1}("");
    }
}
