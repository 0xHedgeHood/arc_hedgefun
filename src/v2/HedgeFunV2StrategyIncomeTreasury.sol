// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {HedgeFunV2AllInTreasury} from "./HedgeFunV2AllInTreasury.sol";
import {V2StakingIncome} from "./V2StakingIncome.sol";

/// @notice The ordinary stock strategy, with a staking dividend. The graduation principal runs the creator's
///         take-profit / dip / stop rungs exactly as kind 0 does. What changes is where earnings go:
///
///   - REALISED STRATEGY PROFIT, which kind 0 sends to the buy-back, is split: `stakingBps()` to stakers of the
///     launch token, the rest to the buy-back.
///   - THE TRADE-TAX SHARE, which kind 0 books as a new stock lot, is income here and is split the same way. It
///     never becomes strategy principal.
///   - Stock-side LP fees are unchanged: all of them fund the buy-back.
///
/// Only the graduation principal and the strategy's own dip buys open lots. `_canAddLot` refuses to book while
/// any arrived stock is still unclassified, so a keeper calls `book()` before `execute()` when tax has arrived;
/// until then a dip waits and nothing is mislabelled.
///
/// If the stock token refuses the transfer to the staking pool, that share stays in the buy-back budget rather
/// than blocking a take-profit.
abstract contract HedgeFunV2StrategyIncomeTreasury is HedgeFunV2AllInTreasury {
    using SafeERC20 for IERC20;

    error GraduationPrincipalRequired();
    error FundingStarved();
    /// @notice the gas a booking or take-profit must still hold when it funds the staking pool
    uint256 public constant FUND_GAS_FLOOR = 500_000;

    /// @notice This launch's staking pool: stake the launch token, earn the listed stock.
    V2StakingIncome public immutable staking;
    /// @notice Exact graduation transfer recorded before optional booking: strategy capital, never income.
    uint256 public principalStock;

    constructor(address usdg_, address stock_, address v3Pool_, address oracle_, address token_,
        address poolManager_, address factory_, Params memory p)
        HedgeFunV2AllInTreasury(usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p)
    {
        staking = new V2StakingIncome(IERC20(token_), IERC20(stock_), address(this), 7 days, 7 days);
        // The pool pulls only inside `fund`, which only this treasury can call.
        IERC20(stock_).forceApprove(address(staking), type(uint256).max);
    }

    /// @notice The share of profit and tax income paid to stakers, in bps. The remainder is buy-back budget.
    function stakingBps() public pure virtual returns (uint16);

    function wire(PoolKey calldata) public pure override { revert GraduationPrincipalRequired(); }

    /// @notice Separate graduation capital from earned fees, even when the optional book() fails.
    /// @dev Factory-only and once-only through super.wire; the transfer is part of the same atomic graduation.
    function wireWithGraduation(PoolKey calldata key, uint256 principal) external {
        super.wire(key);
        principalStock = principal;
    }

    /// @dev Unbooked stock that is strategy capital: the principal until its lot opens, and released lot dust.
    function _capitalUnbooked() private view returns (uint256) {
        return (totalStockReceived == 0 ? principalStock : 0) + _releasedDustStock;
    }

    function _canAddLot() internal view override returns (bool) {
        return super._canAddLot() && unbookedStock() == _capitalUnbooked();
    }

    /// @notice Classify arrived stock, then open the principal's lot when a live price allows it.
    /// @dev wireWithGraduation already identified principal; claim timing and caller cannot relabel income.
    function book() public override nonReentrant returns (bool booked) {
        if (hook == address(0)) return false;
        uint256 un = unbookedStock();
        uint256 capital = _capitalUnbooked();
        if (un > capital) {
            buybackStock += un - capital;
            _split(un - capital);
            booked = true;
        }
        if (_bookV2()) booked = true;
    }

    function _takeProfit(uint256 id) internal override {
        uint256 budget = buybackStock;
        super._takeProfit(id);
        if (buybackStock > budget) _split(buybackStock - budget);
    }

    /// @dev `amount` is already in `buybackStock`. Move the stakers' share out of it. The pool's own
    ///      `IncomeFunded` event and `totalFunded` are the record of what was paid.
    ///
    ///      A funding the stock token refuses leaves the share in the buy-back budget. One that fails only
    ///      because this call arrived with too little gas must not: the caller picks the gas, and would
    ///      otherwise pick where the stakers' share goes. So the funding is not attempted with less than
    ///      `FUND_GAS_FLOOR`, several times what it costs; a caller can then starve it only if the stock
    ///      token's transfer comes to cost more than the floor. What is left after a starved call cannot be
    ///      the test instead: each nested call keeps its own 1/64, so that remainder has no fixed bound.
    function _split(uint256 amount) private {
        uint256 share = amount * stakingBps() / 10000;
        if (share == 0) return;
        if (gasleft() < FUND_GAS_FLOOR) revert FundingStarved();
        try staking.fund(share) { buybackStock -= share; } catch {}
    }
}

/// @notice Stock strategy; 25% of profit and tax income to stakers, 75% to the buy-back.
contract HedgeFunV2StrategyDividend25Treasury is HedgeFunV2StrategyIncomeTreasury {
    constructor(address usdg_, address stock_, address v3Pool_, address oracle_, address token_,
        address poolManager_, address factory_, Params memory p)
        HedgeFunV2StrategyIncomeTreasury(usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p) {}

    function stakingBps() public pure override returns (uint16) { return 2500; }
}

/// @notice Stock strategy; 50% of profit and tax income to stakers, 50% to the buy-back.
contract HedgeFunV2StrategyDividend50Treasury is HedgeFunV2StrategyIncomeTreasury {
    constructor(address usdg_, address stock_, address v3Pool_, address oracle_, address token_,
        address poolManager_, address factory_, Params memory p)
        HedgeFunV2StrategyIncomeTreasury(usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p) {}

    function stakingBps() public pure override returns (uint16) { return 5000; }
}
