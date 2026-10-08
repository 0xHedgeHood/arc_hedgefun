// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {V2StakingIncome} from "../src/v2/V2StakingIncome.sol";

contract RemainderBoundaryToken is ERC20 {
    uint8 private immutable precision;

    constructor(uint8 decimals_) ERC20("Remainder boundary asset", "TEST") {
        precision = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return precision;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Rewards are checked against whole, hand-computable streams. The tests do not
/// read or reproduce either remainder accumulator's implementation.
contract V2StakingRemainderBoundaryTest is Test {
    uint256 internal constant WEEK = 7 days;
    uint256 internal constant CIRCULATING_STAKE = 793_100_000e18;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);
    address internal constant OBSERVER = address(0x0B5E);

    struct Fixture {
        V2StakingIncome pool;
        RemainderBoundaryToken token;
        RemainderBoundaryToken reward;
    }

    function _fixture(uint8 rewardDecimals) internal returns (Fixture memory f) {
        f.token = new RemainderBoundaryToken(18);
        f.reward = new RemainderBoundaryToken(rewardDecimals);
        f.pool = new V2StakingIncome(f.token, f.reward, address(this), WEEK, WEEK);
        f.reward.approve(address(f.pool), type(uint256).max);
    }

    function _stake(Fixture memory f, address actor, uint256 amount) internal {
        f.token.mint(actor, amount);
        vm.startPrank(actor);
        f.token.approve(address(f.pool), type(uint256).max);
        f.pool.stake(amount);
        vm.stopPrank();
    }

    function _fund(Fixture memory f, uint256 amount) internal {
        f.reward.mint(address(this), amount);
        f.pool.fund(amount);
    }

    function _claim(Fixture memory f, address actor) internal returns (uint256 paid) {
        uint256 beforeBalance = f.reward.balanceOf(actor);
        vm.prank(actor);
        paid = f.pool.claim(actor);
        assertEq(f.reward.balanceOf(actor) - beforeBalance, paid);
    }

    function _withdrawAll(Fixture memory f, address actor) internal {
        uint256 amount = f.pool.balanceOf(actor);
        uint256 beforeBalance = f.token.balanceOf(actor);
        vm.prank(actor);
        f.pool.withdraw(amount, actor);
        assertEq(f.token.balanceOf(actor) - beforeBalance, amount);
    }

    function _assertConserved(Fixture memory f) internal view {
        assertEq(f.reward.balanceOf(address(f.pool)) + f.pool.totalClaimed(), f.pool.totalFunded());
        assertLe(f.pool.totalClaimed(), f.pool.totalFunded());
    }

    /// Clearing the global remainder on each stake would recreate checkpoint
    /// loss. Economically negligible one-wei entries must not reduce A's reward.
    function test_oneWeiStakeChangesCannotResetGlobalRemainder() public {
        Fixture memory quiet = _fixture(6);
        Fixture memory changing = _fixture(6);
        uint256 entries = WEEK / 300;
        _stake(quiet, ALICE, CIRCULATING_STAKE - entries);
        _stake(changing, ALICE, CIRCULATING_STAKE - entries);
        _stake(quiet, BOB, entries);
        _fund(quiet, 10_000);
        _fund(changing, 10_000);
        uint256 start = block.timestamp;
        for (uint256 i = 1; i <= entries; ++i) {
            vm.warp(start + i * 300);
            _stake(changing, BOB, 1);
        }
        uint256 quietPaid = _claim(quiet, ALICE);
        uint256 changedPaid = _claim(changing, ALICE);
        assertApproxEqAbs(quietPaid, 10_000, 1);
        assertApproxEqAbs(changedPaid, quietPaid, 1, "changing the denominator discarded rewards");
        assertEq(_claim(quiet, BOB), 0);
        assertEq(_claim(changing, BOB), 0);
        assertEq(changing.pool.totalStaked(), CIRCULATING_STAKE);
        _assertConserved(quiet);
        _assertConserved(changing);
    }

    /// Two old accounts each vest ~0.75 raw units. They retain those fractional
    /// claims after withdrawing; the next account earns only the unvested half.
    function test_oldPersonalFractionsSurviveEmptyPoolWithoutPayingANewAccount() public {
        Fixture memory f = _fixture(6);
        _stake(f, ALICE, 1e18);
        _stake(f, BOB, 1e18);
        vm.warp(block.timestamp + WEEK); // Existing seven-day locks expire first.
        _fund(f, 3);
        vm.warp(block.timestamp + WEEK / 2);
        assertEq(_claim(f, ALICE), 0);
        assertEq(_claim(f, BOB), 0);
        _withdrawAll(f, ALICE);
        _withdrawAll(f, BOB);
        assertEq(f.pool.totalStaked(), 0);
        assertEq(f.pool.totalClaimed(), 0);

        vm.warp(block.timestamp + 30 days);
        _stake(f, CAROL, 1e18);
        assertEq(_claim(f, CAROL), 0, "entry assigned old accounts' vested rewards");
        vm.warp(block.timestamp + WEEK);
        assertEq(_claim(f, CAROL), 1, "new holder should receive only ~1.5 unvested units");
        _withdrawAll(f, CAROL);

        // Another half raw unit of NEW income combines with A's retained ~0.75.
        // Forgetting A's personal remainder on claim/withdraw/re-entry pays zero.
        _fund(f, 1);
        _stake(f, ALICE, 1e18);
        vm.warp(block.timestamp + WEEK / 2);
        assertEq(_claim(f, ALICE), 1, "old account lost its fractional vested entitlement");
        assertEq(_claim(f, BOB), 0);
        assertEq(_claim(f, CAROL), 0, "departed account acquired later income");
        vm.warp(block.timestamp + WEEK / 2);
        assertEq(_claim(f, ALICE), 0);
        _withdrawAll(f, ALICE);
        assertEq(f.pool.totalFunded(), 4);
        assertEq(f.pool.totalClaimed(), 2);
        _assertConserved(f);
    }

    /// A completed stream's unclaimed fractional entitlement is not a new
    /// stream. Repeated empty-pool entries cannot replay it or pay old income.
    function test_completedEpochCannotBeReplayedByEmptyPoolReentries() public {
        Fixture memory f = _fixture(6);
        _stake(f, ALICE, CIRCULATING_STAKE);
        _fund(f, 10_000);
        vm.warp(block.timestamp + WEEK);
        uint256 paid = _claim(f, ALICE);
        assertApproxEqAbs(paid, 10_000, 1);
        _withdrawAll(f, ALICE);
        for (uint256 i; i < 8; ++i) {
            address newcomer = address(uint160(0x10000 + i));
            _stake(f, newcomer, 1);
            assertEq(_claim(f, newcomer), 0);
            vm.warp(block.timestamp + WEEK);
            assertEq(_claim(f, newcomer), 0, "empty pool replayed a completed reward");
            _withdrawAll(f, newcomer);
            assertEq(f.pool.totalClaimed(), paid);
            _assertConserved(f);
        }
    }

    /// Factory curves cap FUN supply at uint128. Effective index precision 1e45
    /// keeps the global unassigned residue below 3.5e-7 raw units even here.
    /// A sudden denominator change to one wei must not move A's historical whole
    /// units to the remaining participant or repeatedly consume the same carry.
    function test_uint128SupplyDroppingToOneWeiPreservesPastAndFutureAllocation() public {
        Fixture memory f = _fixture(6);
        _stake(f, ALICE, uint256(type(uint128).max) - 1);
        _stake(f, BOB, 1);
        vm.warp(block.timestamp + WEEK);
        _fund(f, 10_000);
        uint256 start = block.timestamp;
        vm.warp(start + WEEK / 2);
        uint256 oldPaid = _claim(f, ALICE);
        assertApproxEqAbs(oldPaid, 5_000, 1, "large supply failed to allocate the first half");
        _withdrawAll(f, ALICE);
        assertEq(f.pool.totalStaked(), 1);
        assertEq(_claim(f, BOB), 0, "smaller denominator transferred historical whole units");
        uint256 index = f.pool.rewardPerTokenStored();
        for (uint256 i; i < 32; ++i) {
            assertEq(_claim(f, BOB), 0);
            assertEq(_claim(f, OBSERVER), 0);
            assertEq(f.pool.rewardPerTokenStored(), index, "same-timestamp call replayed global carry");
        }
        vm.warp(start + WEEK);
        uint256 futurePaid = _claim(f, BOB);
        assertApproxEqAbs(futurePaid, 5_000, 1, "remaining holder did not receive the future half");
        assertLe(oldPaid + futurePaid, 10_000);
        _withdrawAll(f, BOB);
        _assertConserved(f);
    }

    /// A 1e45 index and one FUN wei permit cumulative raw rewards up to roughly
    /// 1.1579e32, NOT the old rate-scaling-only limit (~1.1579e59). This positive
    /// test approaches the stricter index limit without implying values beyond
    /// it are supported; even here both streams and principal must settle.
    function test_oneWeiStakeSettlesTwoStreamsNearTheIndexRepresentableLimit() public {
        Fixture memory f = _fixture(18);
        _stake(f, ALICE, 1);
        uint256 each = 5e31;
        _fund(f, each);
        vm.warp(block.timestamp + WEEK);
        uint256 first = _claim(f, ALICE);
        assertApproxEqAbs(first, each, 1);
        _fund(f, each);
        vm.warp(block.timestamp + WEEK);
        uint256 second = _claim(f, ALICE);
        assertApproxEqAbs(first + second, 2 * each, 1);
        _withdrawAll(f, ALICE);
        _assertConserved(f);
    }

    /// Reject the unsafe budget before moving assets. A bad second funding must
    /// leave the original valid stream and its principal withdrawable.
    function test_fundingAboveLifetimeLimitCannotPoisonAnExistingStream() public {
        Fixture memory f = _fixture(18);
        _stake(f, ALICE, 1);
        uint256 initial = 7e18;
        _fund(f, initial);
        uint256 limit = f.pool.MAX_TOTAL_FUNDED();
        assertEq(limit, type(uint256).max / 1e45);
        f.reward.mint(address(this), limit + 1);
        uint256 sourceBalance = f.reward.balanceOf(address(this));
        uint256 finish = f.pool.periodFinish();

        vm.expectRevert(V2StakingIncome.FundingLimitExceeded.selector);
        f.pool.fund(limit + 1);
        // This amount is individually within the cap but breaches the cumulative
        // limit because the initial seven STOCK has already been funded.
        vm.expectRevert(V2StakingIncome.FundingLimitExceeded.selector);
        f.pool.fund(limit);
        assertEq(f.pool.totalFunded(), initial);
        assertEq(f.pool.periodFinish(), finish);
        assertEq(f.reward.balanceOf(address(f.pool)), initial);
        assertEq(f.reward.balanceOf(address(this)), sourceBalance);

        vm.warp(finish);
        assertApproxEqAbs(_claim(f, ALICE), initial, 1);
        _withdrawAll(f, ALICE);
        assertEq(f.token.balanceOf(ALICE), 1);
        _assertConserved(f);
    }

    /// The advertised exact cap remains usable, including with the smallest
    /// possible denominator; rejection must not occur only after funds enter.
    function test_exactLifetimeLimitPaysAndPrincipalExitsAtOneWeiStake() public {
        Fixture memory f = _fixture(18);
        _stake(f, ALICE, 1);
        uint256 limit = f.pool.MAX_TOTAL_FUNDED();
        _fund(f, limit);
        vm.warp(block.timestamp + WEEK);
        assertApproxEqAbs(_claim(f, ALICE), limit, 1);
        assertEq(f.pool.totalFunded(), limit);

        f.reward.mint(address(this), 1);
        vm.expectRevert(V2StakingIncome.FundingLimitExceeded.selector);
        f.pool.fund(1);
        _withdrawAll(f, ALICE);
        assertEq(f.token.balanceOf(ALICE), 1);
        _assertConserved(f);
    }
}
