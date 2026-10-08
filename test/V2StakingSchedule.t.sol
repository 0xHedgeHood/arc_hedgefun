// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2IncomeKindsFixture} from "./V2IncomeKinds.t.sol";

/// How a funding joins a stream that is already running: it moves the end by its own share of the total.
/// The treasury is the pool's only source, so every funding here is a real `book()` of arrived stock.
contract V2StakingScheduleTest is V2IncomeKindsFixture {
    Launch internal l;

    function _start(uint256 funded) internal {
        l = _graduated(dividendKind);
        l.token.transfer(alice, 1_000e18);
        vm.startPrank(alice);
        l.token.approve(address(l.staking), type(uint256).max);
        l.staking.stake(1_000e18);
        vm.stopPrank();
        _fund(funded);
    }

    function _fund(uint256 amount) internal {
        stock.transfer(address(l.treasury), amount);
        l.treasury.book();
    }

    /// Anyone can make the treasury fund one wei. It must not push out what is already streaming.
    function test_dustFundingDoesNotMoveTheEndOfARunningStream() public {
        _start(7e18);
        uint256 finish = l.staking.periodFinish();
        assertEq(finish, block.timestamp + 7 days);
        uint256 start = block.timestamp;
        for (uint256 h = 1; h < 7 * 24; ++h) {
            vm.warp(start + h * 1 hours);
            _fund(1);
            assertEq(l.staking.periodFinish(), finish, "a wei does not move the end");
        }
        vm.warp(finish);
        assertApproxEqAbs(l.staking.earned(alice), 7e18, 1e6, "the first funding is fully paid after one duration");
    }

    function test_equalFundingHalfwayEndsAtTheMeanOfWhatWasLeftAndAFullDuration() public {
        _start(8e18);
        vm.warp(block.timestamp + 3.5 days);          // 4e18 left, with 3.5 days to run
        _fund(4e18);                                   // as much again, due a full 7 days
        assertApproxEqAbs(l.staking.periodFinish(), block.timestamp + 5.25 days, 1, "(3.5 + 7) / 2");
        vm.warp(l.staking.periodFinish());
        assertApproxEqAbs(l.staking.earned(alice), 12e18, 1e6, "all of both by the new end");
    }

    function test_largeFundingNearTheEndStillStreamsOverAlmostAFullDuration() public {
        _start(1e18);
        vm.warp(block.timestamp + 7 days - 60);       // one minute of a small stream left
        uint256 before = l.staking.earned(alice);
        _fund(1_000e18);
        assertGt(l.staking.periodFinish(), block.timestamp + 7 days - 60, "the new money is not released in a minute");
        vm.warp(block.timestamp + 60);
        assertLt(l.staking.earned(alice) - before, 1e18, "a minute later about a minute's worth has streamed");
    }

    function testFuzz_aFundingNeverEndsTheStreamEarlierNorLaterThanAFullDuration(
        uint96 first, uint96 second, uint32 elapsed
    ) public {
        _start(bound(first, 1e6, 1e20));
        uint256 finish = l.staking.periodFinish();
        vm.warp(block.timestamp + bound(elapsed, 1, 7 days - 1));
        _fund(bound(second, 1, 1e20));
        assertGe(l.staking.periodFinish(), finish, "never earlier");
        assertLe(l.staking.periodFinish(), block.timestamp + 7 days, "never later than a full duration");
        vm.warp(l.staking.periodFinish());
        vm.prank(alice);
        uint256 paid = l.staking.claim(alice);
        assertLe(paid, l.staking.totalFunded(), "never more than was funded");
        assertApproxEqAbs(paid, l.staking.totalFunded(), 1e6, "and all of it by the end, to the only staker");
    }
}
