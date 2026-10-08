// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {BoundDeployer} from "../../HedgeFunDeployers.sol";
import {HedgeFunBondingCurve} from "../HedgeFunBondingCurve.sol";
import {V2LiquidityVault} from "../V2LiquidityVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {HedgeFunHook} from "../../hooks/HedgeFunHook.sol";
import {HedgeFunV2Treasury} from "../HedgeFunV2Treasury.sol";
import {V2InitCodeChunk} from "../V2TreasuryDeployer.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {V2SurplusLiquidity} from "../V2SurplusLiquidity.sol";

interface IV2LpShare { function lpBpsOfTreasury(address treasury) external view returns (uint16); }

interface IV2GraduationPrincipalTreasury {
    function wireWithGraduation(PoolKey calldata key, uint256 principal) external;
}

interface IArcGraduationView {
    function strategies(uint256 id) external view returns (address token, address treasury, address hook, address stock, address creator);
    function treasuryDeployer() external view returns (address);
    function graduationConfig(uint256 id) external view returns (PoolKey memory key, HedgeFunHook.Rates memory rates);
    function poolManager() external view returns (IPoolManager);
    function protocol() external view returns (address);
}

/// @notice `CurveDeployer` for Arc (5042), line for line except `sqrtPrice`, which also serves token/stock ratios at
///         and above 2^64. The 4663 deployer is kept byte for byte so its release verification still holds.
contract ArcCurveDeployer is BoundDeployer {
    using SafeERC20 for IERC20;
    address private immutable SELF = address(this);
    /// @notice The curve's creation code, byte for byte, held as the runtime code of an inert `V2InitCodeChunk` that
    ///         this deployer creates in its own constructor. Embedded here beside the vault's, it would put this
    ///         module over EIP-170. `deploy` and `predict` hash `code ++ args` exactly as before, so a curve's
    ///         address is derived as it always was; check it with `keccak256(curveChunk.code) == keccak256(type(HedgeFunBondingCurve).creationCode)`.
    address public immutable curveChunk;
    address public immutable vaultChunk;

    /// @notice The share of supply every launch through this deployer sells on its curve, fixed when the deployer is
    ///         created: 7931 on a release, 79.31%. No creator, owner or later transaction can choose another.
    /// @dev An immutable, so the value is part of this deployment and not of anyone's registration. The name is
    ///      kept from when it was only the default of a creator's choice, for the front ends that read it.
    uint16 public immutable DEFAULT_SALE_BPS;
    /// @notice The curve constructor's lower bound on `saleBps`, 10% of supply sold, and so this deployer's too.
    uint16 public constant MIN_SALE_BPS = 1000;
    /// @notice The curve constructor's upper bound on `saleBps`, 90% of supply sold.
    uint16 public constant MAX_SALE_BPS = 9000;
    /// @notice The longest opening window a creator may choose. 0 is "off": the flat tax from the first second.
    uint8 public constant MAX_SNIPE_SECONDS = 180;
    /// @notice Additional recipient wallets a creator may exempt from only the opening buy surcharge.
    uint8 public constant MAX_OPENING_TAX_EXEMPTIONS = 40;

    struct CurveChoice {
        uint16 saleBps;      // share of supply sold on the curve; 0 = nothing registered
        uint8 snipeSeconds;  // opening buy-tax window; 0 = none
    }
    /// @notice what a creator registered for a factory salt `keccak256(abi.encode(symbol, creator, nonce))`.
    ///         `saleBps` 0 means nothing was registered; `curveConfig` then gives the defaults.
    /// @dev Read only through external calls to this deployer, never inside `executeGraduation`'s delegatecall,
    ///      where this contract's storage slots would be the factory's.
    mapping(bytes32 => CurveChoice) public curveConfigOf;
    mapping(bytes32 => address[]) private _openingTaxExemptionsOf;

    /// @notice A creator registered or changed the curve choices for their own salt (symbol, creator, nonce).
    event CurveConfigSet(address indexed creator, string symbol, uint96 nonce, uint16 saleBps, uint8 snipeSeconds);
    event OpeningTaxExemptionsSet(address indexed creator, string symbol, uint96 nonce, address[] recipients);
    error CurveDeployFailed();
    error VaultDeployFailed();
    error Unseedable();
    error InexactTransfer();
    /// @notice `saleBps` other than `DEFAULT_SALE_BPS`, or `snipeSeconds` over MAX_SNIPE_SECONDS. At construction:
    ///         a sale share outside [MIN_SALE_BPS, MAX_SALE_BPS].
    error BadCurveConfig();
    error BadOpeningTaxExemptions();
    struct GraduationCtx {
        PoolKey key;
        HedgeFunHook.Rates rates;
        address token;
        address treasury;
        address hook;
        address stock;
        address creator;
        address vault;
        uint256 max0;
        uint256 max1;
    }
    constructor(uint16 saleBps_) {
        if (saleBps_ < MIN_SALE_BPS || saleBps_ > MAX_SALE_BPS) revert BadCurveConfig();
        DEFAULT_SALE_BPS = saleBps_;
        curveChunk = address(new V2InitCodeChunk(type(HedgeFunBondingCurve).creationCode));
        vaultChunk = address(new V2InitCodeChunk(type(V2LiquidityVault).creationCode));
    }

    /// @notice A creator chooses the opening window of their own upcoming launch. The salt is
    ///         (symbol, msg.sender, nonce), exactly as the factory derives it, so nobody can choose for anyone else.
    ///         `saleBps` is the share of supply sold on the curve and is not a choice: it must be this deployer's
    ///         `DEFAULT_SALE_BPS`. The graduation raise is `V * saleBps / (10000 - saleBps)` of the opening
    ///         valuation `V`, which the stock's listing sets. `snipeSeconds` is how long the opening buy tax takes
    ///         to decay to the flat tax; 0 is none. It is in the launch terms, so a change after `predict` makes
    ///         the launch revert `Restated`. A launch with no registration gets the factory's default window.
    /// @dev The argument stays so that a front end written for a chosen raise keeps its call. A raise larger than
    ///      the stock's V3 pool can deliver never graduates, and its buyers can only sell back to the curve;
    ///      `tools/v2_launch_check.py` shows that for a listing.
    function setCurveConfig(string calldata symbol, uint96 nonce, uint16 saleBps, uint8 snipeSeconds) external {
        if (saleBps != DEFAULT_SALE_BPS || snipeSeconds > MAX_SNIPE_SECONDS) revert BadCurveConfig();
        curveConfigOf[keccak256(abi.encode(symbol, msg.sender, nonce))] = CurveChoice(saleBps, snipeSeconds);
        emit CurveConfigSet(msg.sender, symbol, nonce, saleBps, snipeSeconds);
    }

    /// @notice Register the final token recipients exempt from the opening surcharge for a future launch.
    /// @dev Only the salt's creator may register. Replacing this list after a quote changes the launch terms and
    ///      predicted curve address. Once launched, the curve copies it into its own immutable launch policy.
    ///      The creator is exempt automatically and must not consume one of the 40 additional slots.
    function setOpeningTaxExemptions(string calldata symbol, uint96 nonce, address[] calldata recipients) external {
        if (recipients.length > MAX_OPENING_TAX_EXEMPTIONS) revert BadOpeningTaxExemptions();
        bytes32 salt = keccak256(abi.encode(symbol, msg.sender, nonce));
        delete _openingTaxExemptionsOf[salt];
        for (uint256 i; i < recipients.length; ++i) {
            address recipient = recipients[i];
            if (recipient == address(0) || recipient == msg.sender) revert BadOpeningTaxExemptions();
            for (uint256 j; j < i; ++j) {
                if (recipient == recipients[j]) revert BadOpeningTaxExemptions();
            }
            _openingTaxExemptionsOf[salt].push(recipient);
        }
        emit OpeningTaxExemptionsSet(msg.sender, symbol, nonce, recipients);
    }

    function openingTaxExemptions(bytes32 salt) external view returns (address[] memory) {
        return _openingTaxExemptionsOf[salt];
    }

    /// @notice The values a launch under `salt` is built with: the creator's registration, else `DEFAULT_SALE_BPS`
    ///         and `defaultSnipeSeconds`, which the factory passes as its current `Defaults.snipeSeconds`. The
    ///         factory's `predict`, `predictCurve`, terms, preflight and launch all read this one function.
    function curveConfig(bytes32 salt, uint8 defaultSnipeSeconds) external view returns (uint16 saleBps, uint8 snipeSeconds) {
        CurveChoice memory c = curveConfigOf[salt];
        return c.saleBps == 0 ? (DEFAULT_SALE_BPS, defaultSnipeSeconds) : (c.saleBps, c.snipeSeconds);
    }

    /// @dev Graduation quotes live here so the factory stays under EIP-170's runtime limit.
    ///      The one change from `CurveDeployer`: a raw ratio of 2^64 or more overflows its Q192 square. Against an
    ///      8-decimal stock it is routine: a 1e9-token supply over a ~2.6M-satoshi cirBTC reserve is ~3.9e20. There the
    ///      root is taken of the Q128 ratio and shifted up 32 bits, which can differ from the exact Q96 root only in
    ///      bits below 2^32 of a value above 2^128. Below 2^64 the result is `CurveDeployer`'s exactly.
    function sqrtPrice(uint256 effectiveStock, uint256 tokens, bool tokenIs0) external pure returns (uint160) {
        (uint256 num, uint256 den) = tokenIs0 ? (effectiveStock, tokens) : (tokens, effectiveStock);
        uint256 value = num / den < 1 << 64
            ? Math.sqrt(Math.mulDiv(num, 1 << 192, den))
            : Math.sqrt(Math.mulDiv(num, 1 << 128, den)) << 32;
        if (value <= TickMath.MIN_SQRT_PRICE || value >= TickMath.MAX_SQRT_PRICE) revert Unseedable();
        return uint160(value);
    }
    function liquidity(int24 spacing, uint160 price, uint256 amount0, uint256 amount1) external pure returns (uint128) {
        return _liquidity(spacing, price, amount0, amount1);
    }
    function graduationLiquidity(int24 spacing, uint160 price, uint256 amount0, uint256 amount1, bool tokenIs0)
        external pure returns (uint128)
    {
        return _graduationLiquidity(spacing, price, amount0, amount1, tokenIs0);
    }
    function _graduationLiquidity(int24 spacing, uint160 price, uint256 amount0, uint256 amount1, bool tokenIs0)
        private pure returns (uint128 l)
    {
        l = _liquidity(spacing, price, amount0, amount1);
        uint256 used = tokenIs0
            ? SqrtPriceMath.getAmount0Delta(price, TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(spacing)), l, true)
            : SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(spacing)), price, l, true);
        V2SurplusLiquidity.plan(price, spacing, tokenIs0, (tokenIs0 ? amount0 : amount1) - used, l);
    }
    function _liquidity(int24 spacing, uint160 price, uint256 amount0, uint256 amount1) private pure returns (uint128) {
        uint160 a = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(spacing));
        uint160 b = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(spacing));
        if (price <= a || price >= b || amount0 < 2 || amount1 < 2
            || amount0 > uint256(uint128(type(int128).max)) || amount1 > uint256(uint128(type(int128).max))) revert Unseedable();
        uint256 l0 = Math.mulDiv(amount0 - 1, Math.mulDiv(price, b, 1 << 96), b - price);
        uint256 l1 = Math.mulDiv(amount1 - 1, 1 << 96, price - a);
        uint256 l = Math.min(l0, l1);
        if (l == 0 || l > Pool.tickSpacingToMaxLiquidityPerTick(spacing) || l > uint256(uint128(type(int128).max))) revert Unseedable();
        return uint128(l);
    }

    /// @dev Called only through the bound factory's delegatecall. The factory is the caller of the
    ///      hook, treasury and deployVault; this module holds no launch funds or mutable authority.
    function executeGraduation(uint256 id, uint160 price, uint256 stockAmount, uint256 tokenAmount)
        external returns (uint128 liquidity_, uint256 stockUsed, uint256 tokenUsed)
    {
        if (address(this) != ArcCurveDeployer(SELF).factory()) revert NotFactory();
        IArcGraduationView v = IArcGraduationView(address(this));
        GraduationCtx memory g;
        (g.token, g.treasury, g.hook, g.stock, g.creator) = v.strategies(id);
        // the LP share was frozen into the treasury's record when the launch deployed it
        uint256 lpStock = stockAmount * IV2LpShare(v.treasuryDeployer()).lpBpsOfTreasury(g.treasury) / 10000;
        (g.key, g.rates) = v.graduationConfig(id);
        bool tokenIs0 = g.token < g.stock;
        (g.max0, g.max1) = tokenIs0 ? (tokenAmount, lpStock) : (lpStock, tokenAmount);
        liquidity_ = _graduationLiquidity(g.key.tickSpacing, price, g.max0, g.max1, tokenIs0);
        g.vault = ArcCurveDeployer(SELF).deployVault(bytes32(id),
            abi.encode(address(this), v.poolManager(), g.key, g.token, g.stock, g.treasury));
        _seedGraduation(v, g);
        (uint256 used0, uint256 used1) = V2LiquidityVault(g.vault).seed(price, liquidity_, g.max0, g.max1);
        (stockUsed, tokenUsed) = tokenIs0 ? (used1, used0) : (used0, used1);
        // Principal-aware kinds protect the exact transfer, independently of already-earned fees and book().
        // Legacy kinds keep their existing initializer. A principal-aware kind must reject legacy wire so
        // a failed exact initialization cannot silently fall back to an unprotected graduation.
        try IV2GraduationPrincipalTreasury(g.treasury).wireWithGraduation(g.key, stockAmount - stockUsed) {}
        catch { HedgeFunV2Treasury(g.treasury).wire(g.key); }
    }

    function _seedGraduation(IArcGraduationView v, GraduationCtx memory g) private {
        HedgeFunV2Treasury(g.treasury).setLiquidityVault(g.vault);
        HedgeFunHook(g.hook).registerGraduatedWithVault(g.key, g.token, g.stock, g.treasury, v.protocol(), g.creator, g.rates, g.vault);
        _sendExact(Currency.unwrap(g.key.currency0), g.vault, g.max0);
        _sendExact(Currency.unwrap(g.key.currency1), g.vault, g.max1);
    }

    function _sendExact(address asset, address to, uint256 amount) private {
        IERC20 erc20 = IERC20(asset);
        uint256 senderBefore = erc20.balanceOf(address(this));
        uint256 recipientBefore = erc20.balanceOf(to);
        erc20.safeTransfer(to, amount);
        if (erc20.balanceOf(address(this)) != senderBefore - amount
            || erc20.balanceOf(to) != recipientBefore + amount) revert InexactTransfer();
    }
    function deploy(bytes32 salt, bytes calldata args) external returns (address a) {
        _onlyFactory();
        return _deploy(salt, args);
    }
    /// @dev Attach the creator's registered list here to keep the factory below EIP-170.
    function deployConfigured(bytes32 salt, HedgeFunBondingCurve.Init calldata base) external returns (address) {
        _onlyFactory();
        HedgeFunBondingCurve.Init memory p = base;
        p.openingTaxExemptions = _openingTaxExemptionsOf[salt];
        return _deploy(salt, abi.encode(p));
    }
    function _deploy(bytes32 salt, bytes memory args) private returns (address a) {
        bytes memory code = _curveCode(args);
        assembly { a := create2(0, add(code, 0x20), mload(code), salt) }
        if (a == address(0)) revert CurveDeployFailed();
    }
    function predict(bytes32 salt, bytes calldata args) external view returns (address) {
        return _at(salt, keccak256(_curveCode(args)));
    }
    function predictConfigured(bytes32 salt, HedgeFunBondingCurve.Init calldata base) external view returns (address) {
        HedgeFunBondingCurve.Init memory p = base;
        p.openingTaxExemptions = _openingTaxExemptionsOf[salt];
        return _at(salt, keccak256(_curveCode(abi.encode(p))));
    }
    /// @dev `type(HedgeFunBondingCurve).creationCode ++ args`, the creation code copied from `curveChunk`.
    function _curveCode(bytes memory args) private view returns (bytes memory code) {
        return _chunkCode(curveChunk, args);
    }
    function _chunkCode(address chunk, bytes memory args) private view returns (bytes memory code) {
        uint256 len = chunk.code.length;
        code = new bytes(len + args.length);
        assembly ("memory-safe") {
            extcodecopy(chunk, add(code, 0x20), 0, len)
            mcopy(add(add(code, 0x20), len), add(args, 0x20), mload(args))
        }
    }
    function deployVault(bytes32 salt, bytes calldata args) external returns (address a) {
        _onlyFactory();
        bytes memory code = _chunkCode(vaultChunk, args);
        assembly ("memory-safe") { a := create2(0, add(code, 0x20), mload(code), salt) }
        if (a == address(0)) revert VaultDeployFailed();
    }
}
