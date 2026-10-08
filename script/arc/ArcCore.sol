// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HedgeFunFactory, TokenDeployer} from "../../src/HedgeFunFactory.sol";
import {HedgeFunV2Hook} from "../../src/hooks/HedgeFunV2Hook.sol";
import {HedgeFunV2ArcFactory} from "../../src/v2/arc/HedgeFunV2ArcFactory.sol";
import {V2TreasuryDeployer} from "../../src/v2/V2TreasuryDeployer.sol";
import {ArcCurveDeployer} from "../../src/v2/arc/ArcCurveDeployer.sol";
import {HedgeFunBondingCurve} from "../../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter} from "../../src/v2/HedgeFunV2TradeRouter.sol";
import {ArcDefaults} from "./ArcDefaults.sol";

/// @notice The V2 core for Arc (5042): what is deployed, with what bindings, and what is checked first.
/// @dev The 4663 core (`V2MainnetCore`) with three differences:
///
///       * the factory is `HedgeFunV2ArcFactory`, whose listed opening price is scaled by 1e36 so an 8-decimal
///         stock such as cirBTC can be listed;
///       * there is no native router. Arc's native currency IS USDC: its ERC-20 view at `USDG` and the native
///         balance are one balance, and there is no wrapped form to `deposit` into. A payer approves USDC to the
///         trade router like any ERC-20;
///       * the bindings are Arc's: Uniswap's V4 PoolManager (the same address as on 4663), the chain's only
///         Uniswap V3 factory (its runtime is the 4663 V3 factory's byte for byte, but for the 20-byte address
///         immutable), and USDC as the quote.
///
///      Six contracts and no owner action. The factory is born with public launch closed, nothing listed, and kind
///      0 only, exactly as on 4663, and the same setup scripts run after it.
abstract contract ArcCore is Script {
    uint256 public constant CHAIN_ID = 5042;
    address public constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address public constant V3_FACTORY = 0xf0db7b58379503491d857dB50AC9ece64c653918;
    address public constant USDC = 0x3600000000000000000000000000000000000000;
    uint160 public constant HOOK_FLAGS = 0x28CC;

    error MissingCode(address target);
    error UnsafeRole(address who);
    error ProtocolRefusesNative(address protocol);
    error BadHook(address expected, address actual);
    error NoHookSalt();
    error ReadbackFailed(string what);

    /// @param owner the Safe that owns the factory, and through it the registry and the upgrade controller
    /// @param protocol the Safe that receives the protocol's share of tax and the launch fee
    struct Roles {
        address owner;
        address protocol;
    }

    struct Deployed {
        V2TreasuryDeployer treasury;
        TokenDeployer token;
        ArcCurveDeployer curve;
        HedgeFunV2Hook hook;
        HedgeFunV2ArcFactory factory;
        HedgeFunV2TradeRouter router;
        bytes32 hookSalt;
    }

    function _firstOwner(address deployer, Roles memory r, bool deployerSetsUp) internal pure returns (address) {
        return deployerSetsUp ? deployer : r.owner;
    }

    function _defaults() internal pure returns (HedgeFunFactory.Defaults memory) {
        return ArcDefaults.release();
    }

    /// @dev Everything that can be refused before a transaction is sent. The native probe moves one wei of USDC
    ///      inside a state snapshot that is reverted.
    function _preflight(address deployer, Roles memory r, HedgeFunFactory.Defaults memory d) internal {
        if (PM.code.length == 0) revert MissingCode(PM);
        if (V3_FACTORY.code.length == 0) revert MissingCode(V3_FACTORY);
        if (USDC.code.length == 0) revert MissingCode(USDC);
        if (CREATE2_FACTORY.code.length == 0) revert MissingCode(CREATE2_FACTORY);
        _requireSafe(r.owner);
        _requireSafe(r.protocol);
        if (deployer == r.owner || deployer == r.protocol) revert UnsafeRole(deployer);
        // `_chargeLaunchFee` forwards a native fee to the immutable `protocol` and reverts the launch if that fails.
        // On Arc a native transfer also reverts when either side is on USDC's blocklist.
        if (d.launchFeeCurrency == HedgeFunFactory.FeeCurrency.Native) _requireAcceptsNative(r.protocol);
    }

    /// @dev Six CREATEs from the broadcaster; the caller opens and closes the broadcast.
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
        x.curve = new ArcCurveDeployer(ArcDefaults.SALE_BPS);
        x.hook = new HedgeFunV2Hook{salt: salt}(IPoolManager(PM));
        if (address(x.hook) != mined || uint160(address(x.hook)) & 0x3FFF != HOOK_FLAGS) {
            revert BadHook(mined, address(x.hook));
        }
        x.factory = new HedgeFunV2ArcFactory(
            firstOwner, PM, V3_FACTORY, USDC, r.protocol, address(x.treasury), address(x.token), address(x.hook),
            address(x.curve), d
        );
        x.router = new HedgeFunV2TradeRouter(x.factory);
    }

    /// @dev The simulation's state. After a broadcast, run `VerifyArcCore` against the confirmed chain.
    function _readBackCore(Deployed memory x, address firstOwner, Roles memory r, HedgeFunFactory.Defaults memory d)
        internal
        view
    {
        HedgeFunV2ArcFactory f = x.factory;
        if (f.owner() != firstOwner || f.pendingOwner() != address(0) || f.protocol() != r.protocol) {
            revert ReadbackFailed("roles");
        }
        if (f.publicLaunch() || f.strategyCount() != 0) revert ReadbackFailed("born closed and empty");
        if (
            address(f.poolManager()) != PM || address(f.v3Factory()) != V3_FACTORY || f.usdg() != USDC
                || address(f.treasuryDeployer()) != address(x.treasury) || address(f.curveDeployer()) != address(x.curve)
                || address(f.hook()) != address(x.hook) || f.OPEN_PRICE_SCALE() != 1e36
        ) revert ReadbackFailed("factory bindings");
        if (
            x.treasury.factory() != address(f) || x.token.factory() != address(f) || x.curve.factory() != address(f)
                || x.hook.factory() != address(f) || address(x.router.factory()) != address(f)
        ) revert ReadbackFailed("component bindings");
        if (x.treasury.version() != 2 || x.hook.version() != 3 || x.treasury.kindCount() != 1) {
            revert ReadbackFailed("versions and kinds");
        }
        if (x.treasury.upgradeController().owner() != firstOwner) revert ReadbackFailed("upgrade controller owner");
        if (keccak256(abi.encode(f.getDefaults())) != keccak256(abi.encode(d))) revert ReadbackFailed("defaults");
        if (x.curve.DEFAULT_SALE_BPS() != ArcDefaults.SALE_BPS) revert ReadbackFailed("sale share");
        if (x.treasury.DEFAULT_LP_BPS() != ArcDefaults.LP_BPS) revert ReadbackFailed("default LP share");
        if (keccak256(x.curve.curveChunk().code) != keccak256(type(HedgeFunBondingCurve).creationCode)) {
            revert ReadbackFailed("curve code");
        }
    }

    /// @dev The same init code and the same PoolManager as on 4663, so the same salt mines the same address; the
    ///      search only skips a candidate that already has code here.
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

    function _requireAcceptsNative(address protocol) internal {
        uint256 snapshot = vm.snapshotState();
        ArcNativeProbe probe = new ArcNativeProbe();
        vm.deal(address(probe), 1);
        bool ok = probe.paysOneWei(protocol);
        vm.revertToState(snapshot);
        if (!ok) revert ProtocolRefusesNative(protocol);
    }
}

/// @notice Moves one wei for the preflight probe. It exists only inside a reverted snapshot.
contract ArcNativeProbe {
    receive() external payable {}

    function paysOneWei(address to) external returns (bool ok) {
        (ok,) = to.call{value: 1}("");
    }
}
