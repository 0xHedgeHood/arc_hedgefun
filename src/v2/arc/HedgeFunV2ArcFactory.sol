// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HedgeFunFactory} from "../../HedgeFunFactory.sol";
import {HedgeFunHook} from "../../hooks/HedgeFunHook.sol";
import {HedgeFunV2Hook} from "../../hooks/HedgeFunV2Hook.sol";
import {HedgeFunTreasuryBase} from "../../HedgeFunTreasuryBase.sol";
import {ArcCurveDeployer} from "./ArcCurveDeployer.sol";
import {V2TreasuryDeployer} from "../V2TreasuryDeployer.sol";
import {HedgeFunBondingCurve} from "../HedgeFunBondingCurve.sol";

/// @notice The V2 factory for Arc (5042): `HedgeFunV2Factory` line for line, except the scale of a listing's
///         opening price.
/// @dev `HedgeFunV2Factory` turns `Listing.openPriceE18` into the curve's virtual stock as
///      `openPriceE18 * supply / 1e18`, so one unit of the listed price is 1e9 raw stock units across a 1e9-token
///      supply. For an 18-decimal stock that is a fraction of a cent; for 8-decimal cirBTC it is 10 BTC, about $830,000
///      of opening FDV, and the ~$2,100 opening a launch needs rounds to zero. This factory divides by 1e36 instead:
///      here the field carries raw stock units per raw token unit, scaled by 1e36, and nothing else changes.
///      The 4663 factory is a separate contract, kept byte for byte so its release verification still holds.
contract HedgeFunV2ArcFactory is HedgeFunFactory {
    using SafeERC20 for IERC20;

    /// @notice A listing's `openPriceE18` is raw stock per raw token, times this.
    uint256 public constant OPEN_PRICE_SCALE = 1e36;

    /// @notice Fixes the sale share of every launch, and is the creator's registry of the opening window (`setCurveConfig`).
    ArcCurveDeployer public immutable curveDeployer;
    mapping(uint256 => address) public curves;
    mapping(address => uint256) private _curveIds;
    /// @notice Monotonic generation of accepted ownership handovers; binds treasury upgrade proposals.
    uint256 public ownershipEpoch;
    struct Frozen { PoolKey key; HedgeFunHook.Rates rates; }
    mapping(uint256 => Frozen) private _frozen;

    event CurveLaunched(uint256 indexed id, address indexed curve, uint16 saleBps, uint256 virtualStock);
    event Graduated(uint256 indexed id, uint160 sqrtPriceX96, uint128 liquidity, uint256 stockSeeded, uint256 tokenSeeded, uint256 tokenBurned);
    event GraduationCapitalSplit(uint256 indexed id, uint256 lpStock, uint256 treasuryStock, bool treasuryBooked);
    error Unseedable();
    error NotReady();
    error SeedOverspent();

    constructor(address owner_, address poolManager_, address v3Factory_, address usdg_, address protocol_,
        address treasuryDeployer_, address tokenDeployer_, address hook_, address curveDeployer_, Defaults memory d)
        HedgeFunFactory(owner_, poolManager_, v3Factory_, usdg_, protocol_, treasuryDeployer_, tokenDeployer_, hook_, d)
    {
        if (curveDeployer_.code.length == 0 || V2TreasuryDeployer(treasuryDeployer_).version() != 2
            || HedgeFunV2Hook(hook_).version() != 3) revert BadRequest();
        curveDeployer = ArcCurveDeployer(curveDeployer_);
        curveDeployer.bind();
    }

    /// @dev V1 keeps a zero LP fee; V2 has a fee-only vault and caps its static V4 fee at 0.30%.
    function _minLpFee() internal pure override returns (uint24) { return 1; }
    function _maxLpFee() internal pure override returns (uint24) { return 3000; }

    function _transferOwnership(address newOwner) internal override {
        super._transferOwnership(newOwner);
        ++ownershipEpoch;
    }

    function graduationConfig(uint256 id) external view returns (PoolKey memory, HedgeFunHook.Rates memory) {
        return (_frozen[id].key, _frozen[id].rates);
    }

    function predictCurve(Request memory q) external view returns (address) {
        address token = predictToken(q);
        address treasury = treasuryDeployer.predict(_salt(q), _treasuryArgs(q, token));
        return curveDeployer.predictConfigured(_salt(q), _curveInit(q, token, treasury, getDefaults()));
    }

    function _terms(Request memory q, address token, address treasury, Defaults memory d) internal view override returns (bytes32) {
        HedgeFunBondingCurve.Init memory p = _curveInit(q, token, treasury, d);
        uint16 lpBps = V2TreasuryDeployer(address(treasuryDeployer)).lpBps(q.stock);
        _preflight(p, d.tickSpacing, lpBps);
        // The predicted curve address pins every constructor input, including the creator's
        // opening-tax whitelist. The LP share is separate because it is read at graduation.
        return keccak256(abi.encode(super._terms(q, token, treasury, d),
            curveDeployer.predictConfigured(_salt(q), p), lpBps));
    }

    /// @dev The ONE place a curve's parameters are assembled; `predictCurve`, `_terms` (so `predict` and `_preflight`)
    ///      and `_openAndSeed` all call it. `saleBps` is the curve deployer's fixed share; `snipeSeconds` is the
    ///      creator's registration for this launch's salt, else the default (`ArcCurveDeployer.curveConfig`).
    function _curveInit(Request memory q, address token, address treasury, Defaults memory d)
        private view returns (HedgeFunBondingCurve.Init memory p)
    {
        (uint16 sale, uint8 window) = curveDeployer.curveConfig(_salt(q), d.snipeSeconds);
        p.factory = address(this);
        p.token = token;
        p.stock = q.stock;
        p.treasury = treasury;
        p.protocol = protocol;
        p.creator = q.creator;
        p.supply = d.supply;
        p.virtualStock = Math.mulDiv(listings[q.stock].openPriceE18, d.supply, OPEN_PRICE_SCALE, Math.Rounding.Ceil);
        p.saleBps = sale;
        p.taxBps = q.taxBps;
        p.protocolBps = d.protocolBps;
        p.creatorBps = q.creatorBps;
        p.snipeBps = d.snipeBps;
        p.snipeSeconds = window;
        p.openingTaxExemptions = new address[](0);
    }

    function _openAndSeed(Request memory q, address token, address treasury, uint256, Defaults memory d) internal override {
        HedgeFunBondingCurve.Init memory p = _curveInit(q, token, treasury, d);
        address curve = curveDeployer.deployConfigured(_salt(q), p);
        uint256 id = strategies.length;
        curves[id] = curve;
        _curveIds[curve] = id;
        PoolKey memory key = token < q.stock
            ? PoolKey(Currency.wrap(token), Currency.wrap(q.stock), d.lpFee, d.tickSpacing, hook)
            : PoolKey(Currency.wrap(q.stock), Currency.wrap(token), d.lpFee, d.tickSpacing, hook);
        HedgeFunHook.Rates memory rates = _rates(q, d);
        // The curve already provided price discovery; graduation is not another opening auction.
        rates.snipeBps = 0;
        rates.snipeSeconds = 0;
        // Both phases split the entire base fee; no settlement tip dilutes the frozen shares.
        rates.sweepTipBps = 0;
        // LP fees can fund permissionless buy-backs without any realised strategy profit.
        // They must not re-arm the sell spike for every new burst of trading volume.
        rates.spikeBps = 0;
        _frozen[id] = Frozen(key, rates);
        IERC20(token).safeTransfer(curve, d.supply);
        emit CurveLaunched(id, curve, p.saleBps, p.virtualStock);
    }

    /// @dev Fixed initial curve product makes the Ready endpoint independent of the trading path. The LP
    ///      share is the deployer's per-stock value at launch, frozen into the curve there.
    function _preflight(HedgeFunBondingCurve.Init memory p, int24 spacing, uint16 lpBps) private view {
        if (spacing < TickMath.MIN_TICK_SPACING || spacing > TickMath.MAX_TICK_SPACING
            || p.supply == 0 || p.supply > type(uint128).max || p.virtualStock == 0 || p.virtualStock > type(uint128).max) revert Unseedable();
        uint256 remaining = Math.mulDiv(p.supply, 10000 - p.saleBps, 10000);
        if (remaining == 0) revert Unseedable();
        uint256 effective = Math.mulDiv(p.supply, p.virtualStock, remaining, Math.Rounding.Ceil);
        if (effective > type(uint128).max) revert Unseedable();
        bool tokenIs0 = p.token < p.stock;
        curveDeployer.sqrtPrice(p.virtualStock, p.supply, tokenIs0);
        uint160 terminal = curveDeployer.sqrtPrice(effective, remaining, tokenIs0);
        uint256 lpStock = (effective - p.virtualStock) * lpBps / 10000;
        (uint256 a0, uint256 a1) = tokenIs0 ? (remaining, lpStock) : (lpStock, remaining);
        curveDeployer.graduationLiquidity(spacing, terminal, a0, a1, tokenIs0);
    }

    /// @notice Called by the final curve buy. Failure rolls back that buy and leaves the curve active.
    function graduateCurve() external nonReentrant {
        uint256 id = _curveIds[msg.sender];
        if (curves[id] != msg.sender) revert NotReady();
        _graduate(id);
    }

    /// @notice Permissionless fallback; successful final buys graduate atomically through graduateCurve.
    function graduate(uint256 id) external nonReentrant { _graduate(id); }

    function _graduate(uint256 id) private {
        if (id >= strategies.length) revert NotReady();
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(curves[id]);
        if (curve.status() != HedgeFunBondingCurve.Status.Ready) revert NotReady();
        Strategy memory s = strategies[id];
        uint160 price = curveDeployer.sqrtPrice(curve.virtualStock() + curve.realStockReserve(), curve.tokenReserve(), s.token < s.stock);
        (uint256 stockAmount, uint256 tokenAmount) = _release(curve, s);
        (bool seeded, bytes memory result) = address(curveDeployer).delegatecall(
            abi.encodeCall(ArcCurveDeployer.executeGraduation, (id, price, stockAmount, tokenAmount)));
        if (!seeded) assembly ("memory-safe") { revert(add(result, 0x20), mload(result)) }
        (uint128 liquidity, uint256 stockUsed, uint256 tokenUsed) = abi.decode(result, (uint128, uint256, uint256));
        // All unsold project tokens belong to the locked liquidity vault, including rounding residue.
        // Graduation does not buy back or burn project tokens. Keep the event ABI; tokenBurned is zero.
        bool booked;
        if (stockAmount != stockUsed) {
            _sendExact(s.stock, s.treasury, stockAmount - stockUsed);
            try HedgeFunTreasuryBase(s.treasury).book() returns (bool ok) { booked = ok; } catch {}
        }
        emit Graduated(id, price, liquidity, stockUsed, tokenUsed, 0);
        emit GraduationCapitalSplit(id, stockUsed, stockAmount - stockUsed, booked);
    }

    function _release(HedgeFunBondingCurve curve, Strategy memory s) private returns (uint256 stockAmount, uint256 tokenAmount) {
        uint256 stockBefore = IERC20(s.stock).balanceOf(address(this));
        uint256 tokenBefore = IERC20(s.token).balanceOf(address(this));
        (stockAmount, tokenAmount) = curve.release();
        if (IERC20(s.stock).balanceOf(address(this)) != stockBefore + stockAmount
            || IERC20(s.token).balanceOf(address(this)) != tokenBefore + tokenAmount) revert SeedOverspent();
    }

    /// @dev A fee charged to the sender must not consume this factory's pre-existing donations.
    function _sendExact(address asset, address to, uint256 amount) private {
        IERC20 erc20 = IERC20(asset);
        uint256 senderBefore = erc20.balanceOf(address(this));
        uint256 recipientBefore = erc20.balanceOf(to);
        erc20.safeTransfer(to, amount);
        if (erc20.balanceOf(address(this)) != senderBefore - amount
            || erc20.balanceOf(to) != recipientBefore + amount) revert SeedOverspent();
    }
}
