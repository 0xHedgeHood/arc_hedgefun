// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BoundDeployer} from "../HedgeFunDeployers.sol";
import {HedgeFunTreasuryBase} from "../HedgeFunTreasuryBase.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3.sol";
import {HedgeFunV2UpgradeableTreasury} from "./HedgeFunV2UpgradeableTreasury.sol";
import {V2TreasuryUpgradeController} from "./V2TreasuryUpgradeController.sol";
import {EngineConfig, IStrategyPolicy, PolicyManifest, StrategyCapabilities} from "./strategy/IStrategyPolicy.sol";
import {SpotEngineConfig} from "./strategy/SpotEngineConfig.sol";
import {V2CreatorParams} from "./strategy/V2CreatorParams.sol";

interface IFactoryOwner {
    function owner() external view returns (address);
}

interface IStrategyEngineIntrospection {
    function engineVersion() external view returns (uint32);
    function strategyId() external view returns (bytes32);
    function configHash() external view returns (bytes32);
}

contract V2InitCodeChunk {
    constructor(bytes memory data) {
        assembly ("memory-safe") { return(add(data, 0x20), mload(data)) }
    }
}

/// @notice Deploys one V2 treasury per launch. New kind 0 is a delayed-upgrade proxy over the ordinary all-in strategy.
///
/// The factory has no bytes to spare under EIP-170 and its `Request` is the deployed V1 ABI, so the per-launch strategy choice
/// lives here instead: a creator names the kind for their own (symbol, nonce) salt before `predict`/`launch`, and the
/// factory's unchanged `deploy(salt, args)` picks that kind's code. Nothing about the factory moves; a second strategy
/// is one `registerKind` by the factory owner, never a new factory or hook.
///
/// Every kind must accept the same constructor arguments as `HedgeFunV2Treasury` and honour the treasury surface the
/// factory, hook, vault and routers call (`wire`, `setLiquidityVault`, `creditLiquidityFee`, `book`, `poolKey`,
/// `health`). Kind registration is write-once. The new default proxy can change implementations through its public
/// upgrade controller; other registered kinds remain immutable unless their registered code explicitly supports upgrades.
contract V2TreasuryDeployer is BoundDeployer {
    error TreasuryDeployFailed();
    error StopInsideExecutionFriction(uint256 stopBps, uint256 minimumExclusiveBps);
    error BadKind();
    error NotOwner();
    error BadLpBps();
    error BadPolicy();
    error BadEngineConfig();
    error InitCodeTooLarge();

    struct Kind {
        address chunkA;
        address chunkB;
        uint32 engineVersion;
        uint32 engineConfigSchema;
        bytes32 creationCodeHash;
        uint256 capabilities;
    }
    /// registered strategy code, by kind. Index 0 is the ordinary lot strategy with creator-selected rungs.
    Kind[] private _kinds;
    /// @notice Exact default proxy creation code allowed creator-selected TP/dip/stop rungs, also if re-registered.
    /// @dev Getter name is retained for clients of earlier registries; this code imposes no economic trigger floor.
    bytes32 public immutable allInTriggerCodeHash;
    V2TreasuryUpgradeController public immutable upgradeController;
    /// @notice the kind a creator chose for a salt; unset = kind 0
    mapping(bytes32 => uint8) public strategyKindOf;
    mapping(bytes32 => EngineConfig) private _engineConfigOf;
    mapping(bytes32 => PolicyManifest) private _policies;
    mapping(bytes32 => bytes32) public policyDependencyManifestHash;
    mapping(bytes32 => bytes32) public policyAuditManifestHash;

    uint256 public constant MAX_RUNTIME_CODE_SIZE = 24_576;
    uint256 public constant MAX_INITCODE_SIZE = 49_152;
    uint32 public constant MAX_POLICY_GAS = 500_000;
    uint16 public constant POLICY_RETURN_BYTES = 160;

    event KindRegistered(uint8 indexed kind, address chunkA, address chunkB);
    event EngineKindRegistered(
        uint8 indexed kind,
        uint32 indexed engineVersion,
        uint32 indexed configSchema,
        bytes32 creationCodeHash,
        uint256 capabilities
    );
    event StrategyKindSet(address indexed creator, string symbol, uint96 nonce, uint8 kind);
    event EngineConfigSet(
        address indexed creator,
        string symbol,
        uint96 nonce,
        uint8 indexed kind,
        bytes32 indexed policyKey,
        bytes32 rawConfigHash
    );
    event PolicyRegistered(
        bytes32 indexed policyKey,
        address indexed implementation,
        bytes32 runtimeCodeHash,
        uint32 engineVersion,
        uint32 configSchema,
        uint256 capabilities,
        uint32 maxGas,
        uint16 maxReturnBytes,
        bytes32 dependencyManifestHash,
        bytes32 auditManifestHash
    );
    event PolicyDisabled(bytes32 indexed policyKey);
    event TreasuryCodeBound(
        address indexed treasury, uint8 indexed kind, bytes32 initCodeHash, bytes32 runtimeCodeHash, bytes32 configHash
    );
    event LpBpsSet(address indexed stock, uint16 lpBps);

    /// @notice the share of a graduating curve's REAL stock reserve that seeds the V4 pool; the rest is this
    ///         treasury's strategy capital. Per stock, set by the factory owner for FUTURE launches, in the
    ///         launch terms, and frozen per treasury when the launch deploys it. Neither factory nor curve
    ///         deployer has the bytes for it.
    uint16 public constant DEFAULT_LP_BPS = 7000;
    uint16 public constant MIN_LP_BPS = 1000;
    mapping(address => uint16) private _lpBps;
    /// @notice the LP share a launched treasury's curve graduates with
    mapping(address => uint16) public lpBpsOfTreasury;

    function lpBps(address stock) public view returns (uint16) {
        uint16 value = _lpBps[stock];
        return value == 0 ? DEFAULT_LP_BPS : value;
    }

    /// @notice Changes future launches only; a pending quote for `stock` becomes stale (`Restated`).
    function setLpBps(address stock, uint16 value) external {
        _onlyOwner();
        if (value < MIN_LP_BPS || value > 10000) revert BadLpBps();
        _lpBps[stock] = value;
        emit LpBpsSet(stock, value);
    }

    function _onlyOwner() private view {
        if (factory == address(0) || msg.sender != IFactoryOwner(factory).owner()) revert NotOwner();
    }

    constructor() {
        upgradeController = new V2TreasuryUpgradeController();
        bytes memory code = type(HedgeFunV2UpgradeableTreasury).creationCode;
        bytes32 codeHash = keccak256(code);
        allInTriggerCodeHash = codeHash;
        (address a, address b) = makeChunks(code);
        _appendKind(Kind(a, b, 0, 0, codeHash, 0));
    }

    /// @notice Split creation code into two immutable code blobs: a treasury's initcode alone exceeds what one
    ///         contract may hold. Anyone may call; the blobs are inert until `registerKind` names them.
    function makeChunks(bytes memory code) public returns (address a, address b) {
        uint256 half = code.length / 2;
        a = address(new V2InitCodeChunk(_slice(code, 0, half)));
        b = address(new V2InitCodeChunk(_slice(code, half, code.length - half)));
    }

    function _slice(bytes memory src, uint256 offset, uint256 len) private pure returns (bytes memory part) {
        part = new bytes(len);
        assembly ("memory-safe") {
            mcopy(add(part, 0x20), add(add(src, 0x20), offset), len)
        }
    }

    function version() external pure returns (uint256) {
        return 2;
    }

    function kindCount() external view returns (uint256) {
        return _kinds.length;
    }

    function kinds(uint8 kind) external view returns (address chunkA_, address chunkB_) {
        if (kind >= _kinds.length) revert BadKind();
        Kind storage k = _kinds[kind];
        return (k.chunkA, k.chunkB);
    }

    function chunkA() external view returns (address) {
        return _kinds[0].chunkA;
    }

    function chunkB() external view returns (address) {
        return _kinds[0].chunkB;
    }

    function kindManifest(uint8 kind)
        external
        view
        returns (uint32 engineVersion, uint32 configSchema, bytes32 creationCodeHash, uint256 capabilities)
    {
        if (kind >= _kinds.length) revert BadKind();
        Kind storage k = _kinds[kind];
        return (k.engineVersion, k.engineConfigSchema, k.creationCodeHash, k.capabilities);
    }

    /// @notice The bound factory's owner adds a strategy kind for FUTURE launches. Existing kinds never change.
    function registerKind(address a, address b) external returns (uint8 kind) {
        _onlyOwner();
        if (a.code.length == 0 || b.code.length == 0 || _kinds.length == type(uint8).max) revert BadKind();
        kind = _appendKind(Kind(a, b, 0, 0, _creationCodeHash(a, b), 0));
    }

    /// @notice Register an execution core separately from its policies. All future configurations for this kind
    ///         must use the declared schema, and every policy capability must be a subset of this core's surface.
    function registerEngineKind(address a, address b, uint32 engineVersion, uint32 configSchema, uint256 capabilities)
        external
        returns (uint8 kind)
    {
        _onlyOwner();
        if (
            a.code.length == 0 || b.code.length == 0 || engineVersion == 0 || configSchema == 0 || capabilities == 0
                || _kinds.length == type(uint8).max
        ) revert BadKind();
        bytes32 codeHash = _creationCodeHash(a, b);
        kind = _appendKind(Kind(a, b, engineVersion, configSchema, codeHash, capabilities));
        emit EngineKindRegistered(kind, engineVersion, configSchema, codeHash, capabilities);
    }

    /// @dev Callers enforce capacity and kind-specific validation; share the immutable registration write.
    function _appendKind(Kind memory k) private returns (uint8 kind) {
        kind = uint8(_kinds.length);
        _kinds.push(k);
        emit KindRegistered(kind, k.chunkA, k.chunkB);
    }

    /// @notice Register one audited policy identity. A policy is advisory: the selected engine remains the sole
    ///         custody and risk boundary. Registrations are immutable; disabling only blocks future launches.
    function registerPolicy(
        address implementation,
        uint32 maxGas,
        uint16 maxReturnBytes,
        bytes32 dependencyManifestHash,
        bytes32 auditManifestHash
    ) external returns (bytes32 policyKey) {
        _onlyOwner();
        if (
            implementation.code.length == 0 || maxGas == 0 || maxGas > MAX_POLICY_GAS
                || maxReturnBytes != POLICY_RETURN_BYTES || dependencyManifestHash == bytes32(0)
                || auditManifestHash == bytes32(0)
        ) revert BadPolicy();

        uint32 engineVersion;
        uint32 configSchema;
        uint256 capabilities;
        try IStrategyPolicy(implementation).policyMetadata() returns (
            uint32 engineVersion_, uint32 configSchema_, uint256 capabilities_
        ) {
            engineVersion = engineVersion_;
            configSchema = configSchema_;
            capabilities = capabilities_;
        } catch {
            revert BadPolicy();
        }
        if (engineVersion == 0 || configSchema == 0 || capabilities == 0) revert BadPolicy();

        bytes32 runtimeCodeHash = implementation.codehash;
        policyKey = keccak256(
            abi.encode(
                implementation,
                runtimeCodeHash,
                engineVersion,
                configSchema,
                capabilities,
                maxGas,
                maxReturnBytes,
                dependencyManifestHash,
                auditManifestHash
            )
        );
        if (_policies[policyKey].implementation != address(0)) revert BadPolicy();
        _policies[policyKey] = PolicyManifest({
            implementation: implementation,
            runtimeCodeHash: runtimeCodeHash,
            engineVersion: engineVersion,
            configSchema: configSchema,
            maxGas: maxGas,
            maxReturnBytes: maxReturnBytes,
            capabilities: capabilities,
            enabledForNewLaunches: true
        });
        policyDependencyManifestHash[policyKey] = dependencyManifestHash;
        policyAuditManifestHash[policyKey] = auditManifestHash;
        emit PolicyRegistered(
            policyKey,
            implementation,
            runtimeCodeHash,
            engineVersion,
            configSchema,
            capabilities,
            maxGas,
            maxReturnBytes,
            dependencyManifestHash,
            auditManifestHash
        );
    }

    function disablePolicy(bytes32 policyKey) external {
        _onlyOwner();
        PolicyManifest storage manifest = _policies[policyKey];
        if (manifest.implementation == address(0) || !manifest.enabledForNewLaunches) revert BadPolicy();
        manifest.enabledForNewLaunches = false;
        emit PolicyDisabled(policyKey);
    }

    function policy(bytes32 policyKey) external view returns (PolicyManifest memory) {
        return _policies[policyKey];
    }

    /// @notice A creator picks the strategy for their own upcoming launch: the salt is (symbol, msg.sender, nonce),
    ///         exactly as the factory derives it, so nobody can choose for anyone else. Changing it after `predict`
    ///         moves the treasury address and the launch reverts `Restated` -- re-quote. Kind 0 needs no call.
    function setStrategyKind(string calldata symbol, uint96 nonce, uint8 kind) external {
        if (kind >= _kinds.length) revert BadKind();
        if (_kinds[kind].engineConfigSchema != 0) revert BadKind();
        strategyKindOf[keccak256(abi.encode(symbol, msg.sender, nonce))] = kind;
        emit StrategyKindSet(msg.sender, symbol, nonce, kind);
    }

    /// @notice Select an engine and bind its fixed-width config to the creator's exact factory salt.
    /// @dev Refuses, as `BadEngineConfig`, every floor on the words that needs no listing data. The floors that do
    ///      (`minLotUsdg`, `sellChunkUsdg`, the deadband's friction) are refused by `predict` and `deploy`, which see
    ///      the factory's args. All three run the engine constructor's own `SpotEngineConfig.valid`, so a config this
    ///      deployer has quoted cannot fail inside CREATE2 as an opaque `TreasuryDeployFailed`.
    function setEngineConfig(string calldata symbol, uint96 nonce, uint8 kind, EngineConfig calldata config) external {
        if (kind >= _kinds.length) revert BadKind();
        Kind storage k = _kinds[kind];
        _checkPolicy(k, config);
        if (
            _isSpotV1(config.engineVersion, config.schema)
                && !SpotEngineConfig.valid(config.words, 1, type(uint256).max, 1)
        ) revert BadEngineConfig();
        bytes32 salt = keccak256(abi.encode(symbol, msg.sender, nonce));
        strategyKindOf[salt] = kind;
        _engineConfigOf[salt] = config;
        emit StrategyKindSet(msg.sender, symbol, nonce, kind);
        emit EngineConfigSet(msg.sender, symbol, nonce, kind, config.policyKey, keccak256(abi.encode(config)));
    }

    function engineConfigOf(bytes32 salt) external view returns (EngineConfig memory) {
        return _engineConfigOf[salt];
    }

    function _code(bytes32 salt, bytes calldata args) private view returns (bytes memory code) {
        Kind storage k = _kinds[strategyKindOf[salt]];
        address a = k.chunkA;
        address b = k.chunkB;
        uint256 alen = a.code.length;
        uint256 blen = b.code.length;
        uint256 configLen = k.engineConfigSchema == 0 ? 0 : 192;
        code = new bytes(alen + blen + args.length + configLen);
        assembly ("memory-safe") {
            let dst := add(code, 0x20)
            extcodecopy(a, dst, 0, alen)
            extcodecopy(b, add(dst, alen), 0, blen)
            calldatacopy(add(add(dst, alen), blen), args.offset, args.length)
        }
        if (configLen != 0) {
            EngineConfig memory config = _engineConfigOf[salt];
            _checkPolicy(k, config);
            bytes memory encoded = abi.encode(config);
            assembly ("memory-safe") {
                mcopy(add(add(add(add(code, 0x20), alen), blen), args.length), add(encoded, 0x20), 192)
            }
        }
        if (code.length > MAX_INITCODE_SIZE) revert InitCodeTooLarge();
    }

    function _checkPolicy(Kind storage k, EngineConfig memory config) private view {
        PolicyManifest storage manifest = _policies[config.policyKey];
        if (k.engineConfigSchema == 0 || config.engineVersion != k.engineVersion
            || config.schema != k.engineConfigSchema || config.policyKey == bytes32(0)
            || manifest.implementation == address(0) || !manifest.enabledForNewLaunches
            || manifest.implementation.codehash != manifest.runtimeCodeHash
            || manifest.engineVersion != config.engineVersion || manifest.configSchema != config.schema
            || manifest.capabilities & ~k.capabilities != 0) revert BadPolicy();
    }

    /// @dev Everything a treasury constructor would refuse, refused here by name: `predict` and `deploy` both run
    ///      it, so a quote is never given for a launch that CREATE2 then fails opaquely.
    function _validate(bytes32 salt, bytes calldata args) private view {
        (,, address v3Pool,,,,, HedgeFunTreasuryBase.Params memory p) = abi.decode(
            args, (address, address, address, address, address, address, address, HedgeFunTreasuryBase.Params)
        );
        uint256 poolFeeBps = uint256(IUniswapV3Pool(v3Pool).fee()) / 100;
        Kind storage k = _kinds[strategyKindOf[salt]];
        if (k.creationCodeHash == allInTriggerCodeHash) {
            V2CreatorParams.validate(p.tp1Bps, p.tp2Bps, p.dipBps, p.stopBps);
        } else {
            uint256 friction = p.maxSlippageBps + poolFeeBps + p.bountyBps;
            if (p.stopBps != 0 && p.stopBps <= friction) revert StopInsideExecutionFriction(p.stopBps, friction);
        }
        // Spot engine floors remain listing-dependent, exactly as its constructor sees them.
        if (
            _isSpotV1(k.engineVersion, k.engineConfigSchema)
                && !SpotEngineConfig.valid(
                    _engineConfigOf[salt].words,
                    p.minLotUsdg,
                    p.sellChunkUsdg,
                    SpotEngineConfig.minDeadbandBps(p.maxSlippageBps, poolFeeBps, p.bountyBps)
                )
        ) revert BadEngineConfig();
    }

    /// @dev `SpotEngineConfig` is the word layout of exactly one engine: another engine version may reuse schema 1
    ///      with its own meaning for the words, and must not be refused by the spot engine's bounds.
    function _isSpotV1(uint32 engineVersion, uint32 schema) private pure returns (bool) {
        return engineVersion == StrategyCapabilities.SPOT_ENGINE_V1 && schema == StrategyCapabilities.CONFIG_SCHEMA_V1;
    }

    function deploy(bytes32 salt, bytes calldata args) external returns (address a) {
        _onlyFactory();
        _validate(salt, args);
        bytes memory code = _code(salt, args);
        bytes32 initCodeHash = keccak256(code);
        assembly ("memory-safe") { a := create2(0, add(code, 0x20), mload(code), salt) }
        if (a == address(0) || a.code.length == 0 || a.code.length > MAX_RUNTIME_CODE_SIZE) {
            revert TreasuryDeployFailed();
        }
        uint8 kind = strategyKindOf[salt];
        bytes32 boundConfigHash;
        Kind storage k = _kinds[kind];
        if (k.engineConfigSchema != 0) {
            EngineConfig storage config = _engineConfigOf[salt];
            IStrategyEngineIntrospection engine = IStrategyEngineIntrospection(a);
            boundConfigHash = engine.configHash();
            if (
                engine.engineVersion() != config.engineVersion || engine.strategyId() != config.policyKey
                    || boundConfigHash == bytes32(0)
            ) revert TreasuryDeployFailed();
        }
        // `args` starts (usdg, stock, ...): the stock is its second word
        lpBpsOfTreasury[a] = lpBps(address(uint160(uint256(bytes32(args[32:64])))));
        emit TreasuryCodeBound(a, kind, initCodeHash, a.codehash, boundConfigHash);
    }

    function predict(bytes32 salt, bytes calldata args) external view returns (address) {
        _validate(salt, args);
        return _at(salt, keccak256(_code(salt, args)));
    }

    function _creationCodeHash(address a, address b) private view returns (bytes32) {
        return keccak256(bytes.concat(a.code, b.code));
    }
}
