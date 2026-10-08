// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2StrategyIncomeBase} from "./V2StrategyIncome.t.sol";

/// @dev Regression: an ordinary caller controls its call gas, but must not be able to
///      permanently redirect the stakers' configured share by exhausting an internal funding call.
contract V2IncomeGasRegressionTest is V2StrategyIncomeBase {
    function stockIsCurrency0() internal pure override returns (bool) { return true; }

    function test_gasLimitedBookPreservesDividendShare() public {
        _scanBookGas();
    }

    function test_gasLimitedBookPreservesDividendShareWithActiveStaker() public {
        token.transfer(ALICE, 1000 ether);
        vm.startPrank(ALICE);
        token.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();
        _scanBookGas();
    }

    function _scanBookGas() private {
        _graduate(10 ether);
        stock.mint(address(t), 4 ether);
        uint256 initial = vm.snapshotState();
        bool succeeded;
        for (uint256 stipend = 25_000; stipend <= 900_000; stipend += 500) {
            assertTrue(vm.revertToState(initial));
            // A caller may query the public getter before booking in the same transaction.
            // This warms the lot-count slot used after the caught funding call.
            t.lotCount();
            vm.prank(ALICE);
            (bool ok,) = address(t).call{gas: stipend}(abi.encodeWithSelector(t.book.selector));
            if (!ok) continue;
            succeeded = true;
            if (staking.totalFunded() != 1 ether) {
                emit log_named_uint("outer call gas limit", stipend);
                emit log_named_uint("stakers actually funded", staking.totalFunded());
                emit log_named_uint("buyback budget after successful booking", t.buybackStock());
                // The exact same assets, allowance and income succeed with ordinary gas afterwards.
                assertTrue(vm.revertToState(initial));
                vm.prank(ALICE);
                assertTrue(t.book());
                assertEq(staking.totalFunded(), 1 ether, "control: the reward token accepts funding");
                fail("limited-gas caller permanently diverted the staking share to buyback");
            }
        }
        assertTrue(succeeded, "the search must include fully successful bookings");
    }
}
