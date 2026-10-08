// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {HedgeFunV2Treasury} from "./HedgeFunV2Treasury.sol";
import {V2StakingIncome} from "./V2StakingIncome.sol";

/// @notice Income kinds: a treasury that runs no stock strategy and pays its INCOME out, split between a staking
///         dividend and the token buy-back. Opt-in per launch, like kind 1: the owner registers the exact code
///         chunks, a creator names the kind for their own salt before `predict`/`launch`.
///
/// Income is stock other than the exact graduation capital: this treasury's share of the trade tax, the stock side of
/// the locked position's LP fees, and gifts. `stakingBps()` of it is transferred to this launch's own
/// `V2StakingIncome`, where it streams to whoever staked the launch token; the rest is the inherited buy-back
/// budget, spent by the inherited `buyback()` under the same pacing, price limits and bounty.
///
/// Graduation principal is NOT income. The factory records its exact transfer in `protectedGraduationStock`
/// before sending it, independently of optional income booking. It never funds a dividend or a buy-back.
///
/// The stakers' share never enters the buy-back budget, so `buyback()` cannot spend it:
///
///     stakers' share of income so far = totalIncomeStock * stakingBps / 10000   (cumulative, so rounding
///                                        never accumulates against either side)
///     of which transferred             = totalDividendStock
///     of which still held here         = pendingDividendStock
///
/// `book()` books arrived stock and transfers what is pending. The liquidity vault requires this treasury's
/// balance to rise by exactly the LP fee it credits, so `creditLiquidityFee` only records the split;
/// `distribute()`, or the next `book()`, moves it. Anyone may call either. If the staking transfer fails (a
/// paused or blocking stock token) the call reverts and nothing is relabelled.
///
/// It takes the same constructor arguments and serves the same surface as `HedgeFunV2Treasury`. The creator's
/// tp/stop/dip parameters are accepted and ignored; `lotCount()` is always 0.
abstract contract HedgeFunV2IncomeTreasury is HedgeFunV2Treasury {
    using SafeERC20 for IERC20;

    error UseBuyback();
    error GraduationPrincipalRequired();
    event GraduationPrincipalProtected(uint256 amount);
    event IncomeBooked(uint256 amount, uint256 stakersShare);
    event DividendFunded(uint256 amount, uint256 totalDividendStock);

    uint256 public constant STAKING_STREAM = 7 days;
    uint256 public constant STAKING_LOCK = 7 days;

    /// @notice This launch's staking pool: stake the launch token, earn the listed stock.
    V2StakingIncome public immutable staking;
    /// @notice Exact graduation capital. Booked, never spent: no lot, no dividend, no buy-back.
    uint256 public protectedGraduationStock;
    /// @notice Income received after graduation: tax share, LP stock fees, gifts.
    uint256 public totalIncomeStock;
    /// @notice The stakers' share already transferred to `staking`.
    uint256 public totalDividendStock;
    /// @notice The stakers' share still held here, outside the buy-back budget, until `distribute()`.
    uint256 public pendingDividendStock;

    constructor(address usdg_, address stock_, address v3Pool_, address oracle_, address token_,
        address poolManager_, address factory_, Params memory p)
        HedgeFunV2Treasury(usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p)
    {
        staking = new V2StakingIncome(IERC20(token_), IERC20(stock_), address(this), STAKING_STREAM, STAKING_LOCK);
    }

    /// @notice The share of income paid to stakers, in bps. The remainder is buy-back budget.
    function stakingBps() public pure virtual returns (uint16);

    /// @dev A legacy initializer cannot separate graduation capital from previously claimed fees.
    function wire(PoolKey calldata) public pure override { revert GraduationPrincipalRequired(); }

    /// @notice Record exactly the capital the factory transfers after seeding the LP.
    /// @dev Factory-only and once-only through super.wire. A failed transfer rolls back this initializer too.
    function wireWithGraduation(PoolKey calldata key, uint256 principal) external {
        super.wire(key);
        protectedGraduationStock = principal;
        bookedStock = principal;
        totalStockReceived = principal;
        emit GraduationPrincipalProtected(principal);
    }

    /// @notice Stock that has arrived and is in no ledger yet. The base's `unbookedStock()` does not know about
    ///         `pendingDividendStock` and reports it as unbooked until it is transferred.
    function unbookedIncome() public view returns (uint256) {
        uint256 balance = _stock.balanceOf(address(this));
        uint256 held = bookedStock + buybackStock + pendingDividendStock;
        return balance > held ? balance - held : 0;
    }

    /// @notice Book arrived stock as income and pay the stakers' share. Needs no oracle. Parked until
    ///         graduation wires the pool.
    /// @dev Principal is already segregated by wireWithGraduation; a failed optional book cannot expose it.
    ///      Also records `totalStockReceived`, which the inherited lot booking never reaches here.
    function book() public override nonReentrant returns (bool booked) {
        if (hook == address(0)) return false;
        uint256 pending = unbookedIncome();
        if (pending != 0) {
            booked = true;
            totalStockReceived += pending;
            _credit(pending);
        }
        _distribute();
    }

    /// @notice Stock-side LP fees are income like any other. The vault checks this balance after the call, so
    ///         the stakers' share is recorded here and transferred by `distribute()`.
    function creditLiquidityFee(uint256 amount) external override nonReentrant {
        if (msg.sender != liquidityVault || amount == 0) revert NotFactory();
        _stock.safeTransferFrom(msg.sender, address(this), amount);
        _credit(amount);
    }

    /// @notice Transfer the stakers' share that is waiting here to the staking pool.
    function distribute() external nonReentrant returns (uint256 paid) { return _distribute(); }

    function _credit(uint256 amount) private {
        totalIncomeStock += amount;
        uint256 share = totalIncomeStock * stakingBps() / 10000 - totalDividendStock - pendingDividendStock;
        pendingDividendStock += share;
        buybackStock += amount - share;
        emit IncomeBooked(amount, share);
    }

    function _distribute() private returns (uint256 paid) {
        paid = pendingDividendStock;
        if (paid == 0) return 0;
        pendingDividendStock = 0;
        totalDividendStock += paid;
        _stock.forceApprove(address(staking), paid);
        staking.fund(paid);
        emit DividendFunded(paid, totalDividendStock);
    }

    /// @dev No lot is ever opened, so a lot can never be due.
    function _canAddLot() internal pure override returns (bool) { return false; }

    /// @notice This kind has no stock strategy to execute.
    function execute() external pure override returns (Action, uint256) { revert UseBuyback(); }
}

/// @notice All income to stakers. The buy-back budget stays empty, so `buyback()` is never due.
contract HedgeFunV2DividendTreasury is HedgeFunV2IncomeTreasury {
    constructor(address usdg_, address stock_, address v3Pool_, address oracle_, address token_,
        address poolManager_, address factory_, Params memory p)
        HedgeFunV2IncomeTreasury(usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p) {}

    function stakingBps() public pure override returns (uint16) { return 10000; }
}

/// @notice Half of income to stakers, half to the token buy-back.
contract HedgeFunV2BuybackDividendTreasury is HedgeFunV2IncomeTreasury {
    constructor(address usdg_, address stock_, address v3Pool_, address oracle_, address token_,
        address poolManager_, address factory_, Params memory p)
        HedgeFunV2IncomeTreasury(usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p) {}

    function stakingBps() public pure override returns (uint16) { return 5000; }
}
