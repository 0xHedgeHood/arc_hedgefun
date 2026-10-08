// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {V2StakingIncome} from "../src/v2/V2StakingIncome.sol";

contract AllocationRewardToken is ERC20 {
    uint8 private immutable precision;

    constructor(uint8 decimals_) ERC20("Allocation test asset", "TEST") {
        precision = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return precision;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Paired experiments use identical tokens, stake, reward funding and timestamps.
/// Only checkpoint frequency changes. The oracle is either the paired allocation
/// or a hand-computable amount/time split; it does not reproduce rewardPerToken.
contract V2StakingAllocationRegressionTest is Test {
    uint256 internal constant WEEK = 7 days;
    // DeployV2Testnet uses 1 billion FUN; 79.31% is initially sold by the curve.
    uint256 internal constant CIRCULATING_STAKE = 793_100_000e18;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant OBSERVER = address(0x0B5E);

    struct Fixture {
        V2StakingIncome pool;
        AllocationRewardToken token;
        AllocationRewardToken reward;
    }

    function _fixture(uint8 decimals_) internal returns (Fixture memory f) {
        f.token = new AllocationRewardToken(18);
        f.reward = new AllocationRewardToken(decimals_);
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

    function _claim(Fixture memory f, address actor) internal returns (uint256) {
        vm.prank(actor);
        return f.pool.claim(actor);
    }

    function _withdrawAll(Fixture memory f, address actor) internal {
        uint256 principal = f.pool.balanceOf(actor);
        vm.prank(actor);
        f.pool.withdraw(principal, actor);
        assertEq(f.token.balanceOf(actor), principal, "reward rounding changed principal");
    }

    function _pairedEmptyClaims(uint8 decimals_, uint256 interval)
        internal
        returns (uint256 quietPaid, uint256 noisyPaid, uint256 funded)
    {
        return _pairedObserverClaims(decimals_, interval, 0);
    }

    function _pairedObserverClaims(uint8 decimals_, uint256 interval, uint256 observerStake)
        internal
        returns (uint256 quietPaid, uint256 noisyPaid, uint256 funded)
    {
        Fixture memory quiet = _fixture(decimals_);
        Fixture memory noisy = _fixture(decimals_);
        _stake(quiet, ALICE, CIRCULATING_STAKE - observerStake);
        _stake(noisy, ALICE, CIRCULATING_STAKE - observerStake);
        if (observerStake != 0) {
            _stake(quiet, OBSERVER, observerStake);
            _stake(noisy, OBSERVER, observerStake);
        }
        funded = 10 ** uint256(decimals_) / 100; // The SAME 0.01 STOCK in both precision modes.
        _fund(quiet, funded);
        _fund(noisy, funded);
        uint256 start = block.timestamp;
        uint256 finish = start + WEEK;
        for (uint256 when = start + interval; when <= finish; when += interval) {
            vm.warp(when);
            assertEq(_claim(noisy, OBSERVER), 0);
        }
        vm.warp(finish);
        quietPaid = _claim(quiet, ALICE);
        noisyPaid = _claim(noisy, ALICE);
        assertEq(noisy.pool.balanceOf(OBSERVER), observerStake);
        assertEq(noisy.reward.balanceOf(OBSERVER), 0);
        assertEq(quiet.reward.balanceOf(address(quiet.pool)) + quietPaid, funded);
        assertEq(noisy.reward.balanceOf(address(noisy.pool)) + noisyPaid, funded);
        _withdrawAll(quiet, ALICE);
        _withdrawAll(noisy, ALICE);
        if (observerStake != 0) {
            _withdrawAll(quiet, OBSERVER);
            _withdrawAll(noisy, OBSERVER);
        }
        emit log_named_uint("reward decimals", decimals_);
        emit log_named_uint("checkpoint interval seconds", interval);
        emit log_named_uint("empty claim count", WEEK / interval);
        emit log_named_uint("funded raw units", funded);
        emit log_named_uint("quiet paid raw units", quietPaid);
        emit log_named_uint("frequent checkpoint paid raw units", noisyPaid);
        emit log_named_uint("additional unpaid raw units", quietPaid - noisyPaid);
    }

    /// An account without stake or accrued rewards has no allocation to settle.
    /// Its empty claims should not destroy other participants' streamed rewards.
    /// This failed before global division remainders were carried forward.
    function test_nonStakerClaimsPreserveSixDecimalAllocationEvery60Seconds() public {
        (uint256 quiet, uint256 noisy,) = _pairedEmptyClaims(6, 60);
        assertApproxEqAbs(noisy, quiet, 1, "non-staker claims materially reduced another user's reward");
    }

    function test_nonStakerClaimsPreserveSixDecimalAllocationEvery300Seconds() public {
        (uint256 quiet, uint256 noisy,) = _pairedEmptyClaims(6, 300);
        assertApproxEqAbs(noisy, quiet, 1, "non-staker claims materially reduced another user's reward");
    }

    /// An early-return for accounts with zero stake alone is insufficient: one
    /// FUN wei permits the same checkpoint sequence while earning zero stock.
    function test_oneWeiStakeClaimsCannotDiscardOtherParticipantsAllocation() public {
        (uint256 quiet, uint256 noisy,) = _pairedObserverClaims(6, 300, 1);
        assertApproxEqAbs(noisy, quiet, 1, "a one-wei stake still forces destructive checkpoints");
    }

    /// The same economic reward and checkpoint sequence with 18-decimal stocks.
    function test_eighteenDecimalEquivalentHasOnlyWeiScaleCheckpointError() public {
        (uint256 quiet, uint256 noisy, uint256 funded) = _pairedEmptyClaims(18, 60);
        assertApproxEqAbs(quiet, noisy, 1);
        assertLt(quiet - noisy, funded / 1e12, "18-decimal economic loss exceeds one trillionth");
        (quiet, noisy, funded) = _pairedEmptyClaims(18, 300);
        assertApproxEqAbs(quiet, noisy, 1);
        assertLt(quiet - noisy, funded / 1e12);
    }

    /// Same global checkpoints in both pools isolates the user-specific floor:
    /// a small participant claims every minute in only one of the two pools.
    function test_smallStakerFrequentClaimsPreservePersonalFractions() public {
        Fixture memory quiet = _fixture(6);
        Fixture memory noisy = _fixture(6);
        uint256 minorityStake = 1_000_000e18;
        _stake(quiet, ALICE, CIRCULATING_STAKE - minorityStake);
        _stake(noisy, ALICE, CIRCULATING_STAKE - minorityStake);
        _stake(quiet, BOB, minorityStake);
        _stake(noisy, BOB, minorityStake);
        _fund(quiet, 1e6);
        _fund(noisy, 1e6);
        uint256 start = block.timestamp;
        for (uint256 i = 1; i <= WEEK / 60; ++i) {
            vm.warp(start + i * 60);
            _claim(quiet, OBSERVER);
            _claim(noisy, OBSERVER);
            _claim(noisy, BOB);
        }
        uint256 once = _claim(quiet, BOB);
        _claim(noisy, BOB);
        uint256 frequent = noisy.reward.balanceOf(BOB);
        emit log_named_uint("minority once-only payment raw units", once);
        emit log_named_uint("minority minute-by-minute payment raw units", frequent);
        emit log_named_uint("minority unpaid raw units", once - frequent);
        assertGt(once, 1000, "meaningful counterfactual claim must exist");
        assertEq(frequent, once, "frequent claims discarded personal fractions");
        assertEq(_claim(quiet, ALICE), _claim(noisy, ALICE), "isolation: global checkpoints are identical");
    }

    /// Identical two funding events in the two pools. One holder is owed every
    /// unit eventually; adding funding may extend vesting but cannot add payees.
    function test_repeatedFundingHasBoundedRawUnitErrorAtBothPrecisions() public {
        _pairedRepeatedFunding(6);
        _pairedRepeatedFunding(18);
    }

    function _pairedRepeatedFunding(uint8 decimals_) internal {
        Fixture memory quiet = _fixture(decimals_);
        Fixture memory noisy = _fixture(decimals_);
        _stake(quiet, ALICE, CIRCULATING_STAKE);
        _stake(noisy, ALICE, CIRCULATING_STAKE);
        uint256 budget = 7 * 10 ** uint256(decimals_);
        _fund(quiet, budget);
        _fund(noisy, budget);
        uint256 start = block.timestamp;
        for (uint256 i = 1; i <= 10 days / 300; ++i) {
            vm.warp(start + i * 300);
            if (i * 300 == 3 days) {
                uint256 beforeQuiet = quiet.pool.earned(ALICE);
                uint256 beforeNoisy = noisy.pool.earned(ALICE);
                _fund(quiet, budget);
                _fund(noisy, budget);
                assertEq(quiet.pool.earned(ALICE), beforeQuiet);
                assertEq(noisy.pool.earned(ALICE), beforeNoisy);
            }
            _claim(noisy, OBSERVER);
        }
        uint256 quietPaid = _claim(quiet, ALICE);
        uint256 noisyPaid = _claim(noisy, ALICE);
        assertApproxEqAbs(quietPaid, 2 * budget, 2, "single holder should receive both complete streams");
        assertApproxEqAbs(quietPaid, noisyPaid, 1, "refill checkpoint frequency changed allocation");
        emit log_named_uint("refill reward decimals", decimals_);
        emit log_named_uint("refill additional unpaid raw units", quietPaid - noisyPaid);
    }

    /// A alone for two days, then A/B equally for five days: A earns 450, B 250.
    /// Both exit after their locks, in opposite orders. No running accumulator is
    /// used by the expected result, including when a third party checkpoints.
    function test_joinAndExitOrderingMatchesHandCalculatedAllocation() public {
        _pairedJoinAndExit(6);
        _pairedJoinAndExit(18);
    }

    function _pairedJoinAndExit(uint8 decimals_) internal {
        Fixture memory quiet = _fixture(decimals_);
        Fixture memory noisy = _fixture(decimals_);
        _stake(quiet, ALICE, CIRCULATING_STAKE / 2);
        _stake(noisy, ALICE, CIRCULATING_STAKE / 2);
        uint256 unit = 10 ** uint256(decimals_);
        _fund(quiet, 700 * unit);
        _fund(noisy, 700 * unit);
        uint256 start = block.timestamp;
        for (uint256 i = 1; i <= WEEK / 300; ++i) {
            vm.warp(start + i * 300);
            if (i * 300 == 2 days) {
                _stake(quiet, BOB, CIRCULATING_STAKE / 2);
                _stake(noisy, BOB, CIRCULATING_STAKE / 2);
                assertEq(quiet.pool.earned(BOB), 0, "late join received historical rewards");
                assertEq(noisy.pool.earned(BOB), 0);
            }
            _claim(noisy, OBSERVER);
        }
        vm.warp(start + 9 days);
        uint256 quietAlice = _claim(quiet, ALICE);
        _withdrawAll(quiet, ALICE);
        _withdrawAll(quiet, BOB);
        uint256 quietBob = _claim(quiet, BOB);
        uint256 noisyBob = _claim(noisy, BOB);
        _withdrawAll(noisy, BOB);
        _withdrawAll(noisy, ALICE);
        uint256 noisyAlice = _claim(noisy, ALICE);
        assertApproxEqAbs(quietAlice, 450 * unit, 2, "A's exact time-weighted share");
        assertApproxEqAbs(quietBob, 250 * unit, 2, "B's exact time-weighted share");
        assertApproxEqAbs(quietAlice, noisyAlice, 1);
        assertApproxEqAbs(quietBob, noisyBob, 1);
        assertEq(noisy.pool.totalStaked(), 0);
        assertEq(quiet.pool.totalStaked(), 0);
        emit log_named_uint("join/exit reward decimals", decimals_);
        emit log_named_uint("join/exit A additional unpaid raw units", quietAlice - noisyAlice);
        emit log_named_uint("join/exit B additional unpaid raw units", quietBob - noisyBob);
    }

    /// Frequency cannot accumulate a per-call error: the unallocated global
    /// fraction survives each checkpoint for both reward precisions.
    function testFuzz_checkpointFrequencyPreservesAllocation(
        uint32 rawFunded,
        uint16 rawCalls,
        uint96 rawStake,
        bool eighteenDecimals
    ) public {
        uint8 decimals_ = eighteenDecimals ? 18 : 6;
        Fixture memory quiet = _fixture(decimals_);
        Fixture memory noisy = _fixture(decimals_);
        uint256 staked = bound(uint256(rawStake), 1e18, CIRCULATING_STAKE);
        uint256 funded = bound(uint256(rawFunded), 1, 1_000_000_000);
        if (eighteenDecimals) funded *= 1e12;
        uint256 calls = bound(uint256(rawCalls), 1, 168);
        _stake(quiet, ALICE, staked);
        _stake(noisy, ALICE, staked);
        _fund(quiet, funded);
        _fund(noisy, funded);
        uint256 start = block.timestamp;
        for (uint256 i = 1; i <= calls; ++i) {
            vm.warp(start + WEEK * i / calls);
            _claim(noisy, OBSERVER);
        }
        uint256 quietPaid = _claim(quiet, ALICE);
        uint256 noisyPaid = _claim(noisy, ALICE);
        assertEq(noisyPaid, quietPaid);
        assertApproxEqAbs(quietPaid, funded, 2);
    }
}
