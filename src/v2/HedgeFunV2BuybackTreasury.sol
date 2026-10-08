// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HedgeFunV2Treasury} from "./HedgeFunV2Treasury.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice Strategy kind 1: a pure buy-back treasury. Opt-in: production must register its exact code chunks.
///
/// Graduation principal is protected and cannot fund buybacks. Subsequent fees and voluntary contributions can
/// fund buybacks. It opens no stock lot, never sells stock, and has no stop, take-profit or
/// dip. The stock leaves only through the inherited `buyback()`: one `buybackChunkUsdg` per `buybackCooldown`,
/// bounded by the pool's own TWAP/anchor and `maxBuybackImpactBps`, burning what it buys. Graduated V2 pools
/// keep the flat sell tax after each buy-back. Nothing about pacing, price limits or bounties is new.
///
/// Because it is `HedgeFunV2Treasury` with `book()` and `execute()` replaced, it takes the same constructor
/// arguments and serves the same surface the factory, hook, vault and routers call. The creator's tp/stop/dip
/// parameters are accepted and ignored; `lotCount()` is always 0 and `bookedStock` holds only graduation principal.
///
/// What a keeper does: `claimFees` on the curve, `book()` here (or let graduation's own `book()` do it), then
/// `buyback()` whenever the cooldown allows. `execute()` reverts `UseBuyback`.
contract HedgeFunV2BuybackTreasury is HedgeFunV2Treasury {
    error UseBuyback();
    error GraduationPrincipalRequired();
    event BuybackBooked(uint256 amount, uint256 buybackStock);
    event GraduationPrincipalProtected(uint256 amount);
    uint256 public protectedGraduationStock;

    constructor(address usdg_, address stock_, address v3Pool_, address oracle_, address token_,
        address poolManager_, address factory_, Params memory p)
        HedgeFunV2Treasury(usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p) {}

    /// @dev The legacy initializer cannot distinguish graduation capital from already-earned fees.
    function wire(PoolKey calldata) public pure override { revert GraduationPrincipalRequired(); }

    /// @notice Protect exactly the capital the factory will transfer after seeding the locked LP.
    /// @dev Factory-only and once-only through super.wire. The transfer is in the same atomic graduation:
    ///      a failed transfer reverts these counters too. Protection does not depend on the optional book().
    function wireWithGraduation(PoolKey calldata key, uint256 principal) external {
        super.wire(key);
        protectedGraduationStock = principal;
        bookedStock = principal;
        totalStockReceived = principal;
        emit GraduationPrincipalProtected(principal);
    }

    /// @notice Graduation principal is segregated; later pending income becomes buy-back budget. Needs no oracle:
    ///         `buyback()`, which is priced off the token pool, not the stock. Parked until graduation wires the pool.
    /// @dev Also records `totalStockReceived`, the scorecard's denominator, which the inherited `_book` writes for a
    ///      lot and this kind never reaches: without it the published score is a division by zero for life.
    function book() public override nonReentrant returns (bool) {
        if (hook == address(0)) return false;
        uint256 pending = unbookedStock();
        if (pending == 0) return false;
        buybackStock += pending;
        totalStockReceived += pending;
        emit BuybackBooked(pending, buybackStock);
        return true;
    }

    /// @dev No lot is ever opened, so a lot can never be due.
    function _canAddLot() internal pure override returns (bool) { return false; }

    /// @notice This kind has no stock strategy to execute.
    function execute() external pure override returns (Action, uint256) { revert UseBuyback(); }
}
