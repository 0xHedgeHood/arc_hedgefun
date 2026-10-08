// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {CurveDeployer} from "../../src/v2/CurveDeployer.sol";
import {HedgeFunV2ArcFactory} from "../../src/v2/arc/HedgeFunV2ArcFactory.sol";
import {ArcCurveDeployer} from "../../src/v2/arc/ArcCurveDeployer.sol";

/// @dev Script-only release identity. The factory template, the curve and vault creation code and their immutable
/// offsets are from the reviewed #25 build: 9be8cf48a723f1ab65412505e231f98b8fac450e, solc 0.8.26, Cancun,
/// optimizer runs 1, no metadata hash. The curve deployer template is NOT that build: it is the one whose sale
/// share is fixed at construction, compiled with the same settings, and the #25 review does not cover it. A core
/// deployed from the #25 curve deployer is therefore refused here, as any other executable code is.
/// Supports different deployment addresses, but deliberately refuses different executable code or compiler output.
/// An operator-supplied hash or a selector appearing somewhere in bytecode is not evidence of compatibility.
///
/// On Arc (5042) the factory and the curve deployer are `HedgeFunV2ArcFactory` and `ArcCurveDeployer`, so the two
/// runtime templates and their immutable offsets are those builds', with the same compiler settings; the curve and
/// vault creation code is unchanged. The Arc templates are this source's build and no review covers them yet.
abstract contract IncomeKindCompatibility is Script {
    error IncompatibleIncomeDeployment(string component);

    bytes32 internal constant FACTORY_TEMPLATE =
        0x89c15b5927042e7ad12d61494556be1e3ad27e2f277ea6a2928d853dd15e850d;
    bytes32 internal constant CURVE_DEPLOYER_TEMPLATE =
        0xd39e4b9e8ad667584dbdd2d4a414bd012dd30b47c4c21ada6cdd1bb3ad061935;
    bytes32 internal constant CURVE_CREATION =
        0xf9300a4b32d609e484af5bb208cc46000f4e83f6b57bc7f19f0b5c22f2a43f3c;
    bytes32 internal constant VAULT_CREATION =
        0xe0b01f54fd3d486753adada93bee53dc2602c494ed2faba0144215b58a2d73f0;
    uint256 internal constant ARC_CHAIN_ID = 5042;
    bytes32 internal constant ARC_FACTORY_TEMPLATE =
        0x2c033b637921f88d2f1e0ec391169c0ccf1958bf9fff823271646b410a910ede;
    bytes32 internal constant ARC_CURVE_DEPLOYER_TEMPLATE =
        0x3b9b6b273abff5196702dd6d277c961ddc4fb14a040225dffbe778b484a73a85;

    function _checkIncomeCompatibility(HedgeFunV2Factory factory) internal view {
        if (address(factory).code.length == 0) revert IncompatibleIncomeDeployment("factory missing");
        if (keccak256(_factoryRuntime(factory)) != address(factory).codehash)
            revert IncompatibleIncomeDeployment("factory runtime");
        CurveDeployer curve = factory.curveDeployer();
        if (address(curve).code.length == 0) revert IncompatibleIncomeDeployment("graduation module missing");
        if (curve.factory() != address(factory)) revert IncompatibleIncomeDeployment("graduation module binding");
        if (keccak256(_curveRuntime(curve)) != address(curve).codehash)
            revert IncompatibleIncomeDeployment("graduation module runtime");
        if (curve.curveChunk().codehash != CURVE_CREATION)
            revert IncompatibleIncomeDeployment("curve creation code");
        if (curve.vaultChunk().codehash != VAULT_CREATION)
            revert IncompatibleIncomeDeployment("vault creation code");
    }

    function _factoryRuntime(HedgeFunV2Factory factory) internal view returns (bytes memory code) {
        if (block.chainid == ARC_CHAIN_ID) return _arcFactoryRuntime(factory);
        code = vm.getDeployedCode("HedgeFunV2Factory.sol:HedgeFunV2Factory");
        if (keccak256(code) != FACTORY_TEMPLATE) revert IncompatibleIncomeDeployment("factory build template");
        // Every compiler immutableReference is bound, including repeated internal-call sites, not just getters.
        _bind(code, hex"06ea0dcc0e830f720fe5107719f4", address(factory.poolManager()));
        _bind(code, hex"047515c0", address(factory.v3Factory()));
        _bind(code, hex"078e15ef19c437e1", factory.usdg());
        _bind(code, hex"05361cc6370f382e", factory.protocol());
        _bind(code, hex"027e07f409511dab22d9", address(factory.treasuryDeployer()));
        _bind(code, hex"02b10a0d2234", address(factory.tokenDeployer()));
        _bind(code, hex"04a823e9256739963a11", address(factory.hook()));
        _bind(code, hex"05a908941bfb1e57282029ec340a34b935b83865", address(factory.curveDeployer()));
    }

    function _arcFactoryRuntime(HedgeFunV2Factory factory) private view returns (bytes memory code) {
        code = vm.getDeployedCode("HedgeFunV2ArcFactory.sol:HedgeFunV2ArcFactory");
        if (keccak256(code) != ARC_FACTORY_TEMPLATE) revert IncompatibleIncomeDeployment("factory build template");
        _bind(code, hex"071a0dfc0eb30fa2101510a71a24", address(factory.poolManager()));
        _bind(code, hex"04a515f0", address(factory.v3Factory()));
        _bind(code, hex"07be161f19f43817", factory.usdg());
        _bind(code, hex"05661cf637453864", factory.protocol());
        _bind(code, hex"02ae082409811de1230f", address(factory.treasuryDeployer()));
        _bind(code, hex"02e10a3d226a", address(factory.tokenDeployer()));
        _bind(code, hex"04d8241f259d39cc3a47", address(factory.hook()));
        _bind(code, hex"05d908c41c2b1e8d28562a22344034ef35ee389b", address(factory.curveDeployer()));
    }

    function _curveRuntime(CurveDeployer curve) internal view returns (bytes memory code) {
        if (block.chainid == ARC_CHAIN_ID) return _arcCurveRuntime(curve);
        code = vm.getDeployedCode("CurveDeployer.sol:CurveDeployer");
        if (keccak256(code) != CURVE_DEPLOYER_TEMPLATE)
            revert IncompatibleIncomeDeployment("graduation module build template");
        // SELF is private and must be this exact deployment, independently of what its public getters return.
        _bind(code, hex"09830d36", address(curve));
        _bind(code, hex"014d11c4", curve.curveChunk());
        _bind(code, hex"01e208e8", curve.vaultChunk());
        // The fixed sale share is an immutable too: whatever this deployment was constructed with, bound exactly.
        _bindWord(code, hex"01bb04b6118f", bytes32(uint256(curve.DEFAULT_SALE_BPS())));
    }

    function _arcCurveRuntime(CurveDeployer curve) private view returns (bytes memory code) {
        code = vm.getDeployedCode("ArcCurveDeployer.sol:ArcCurveDeployer");
        if (keccak256(code) != ARC_CURVE_DEPLOYER_TEMPLATE)
            revert IncompatibleIncomeDeployment("graduation module build template");
        _bind(code, hex"09b60d69", address(curve));
        _bind(code, hex"014d11ff", curve.curveChunk());
        _bind(code, hex"01e2091b", curve.vaultChunk());
        _bindWord(code, hex"01bb04b611ca", bytes32(uint256(curve.DEFAULT_SALE_BPS())));
    }

    /// @dev Packed big-endian uint16 offsets into the zero-immutable runtime template. Refuse stale or duplicate
    /// offsets rather than overwriting executable bytes. The pinned template hash fixes the entire instruction body.
    function _bind(bytes memory code, bytes memory offsets, address value) private pure {
        _bindWord(code, offsets, bytes32(uint256(uint160(value))));
    }

    function _bindWord(bytes memory code, bytes memory offsets, bytes32 word) private pure {
        for (uint256 i; i < offsets.length; i += 2) {
            uint256 offset = (uint256(uint8(offsets[i])) << 8) | uint256(uint8(offsets[i + 1]));
            if (offset == 0 || offset + 32 > code.length || code[offset - 1] != bytes1(0x7f))
                revert IncompatibleIncomeDeployment("immutable offsets");
            bytes32 blank;
            assembly ("memory-safe") { blank := mload(add(add(code, 32), offset)) }
            if (blank != bytes32(0)) revert IncompatibleIncomeDeployment("immutable template value");
            assembly ("memory-safe") { mstore(add(add(code, 32), offset), word) }
        }
    }
}
