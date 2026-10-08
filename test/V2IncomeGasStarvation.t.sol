// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2StrategyIncomeBase} from "./V2StrategyIncome.t.sol";
import {HedgeFunV2StrategyIncomeTreasury} from "../src/v2/HedgeFunV2StrategyIncomeTreasury.sol";
import {MockToken} from "./mocks/Mocks.sol";

/// @dev A stock token whose transfer to one address is expensive, as an upgradeable issuer token's can become.
contract ExpensiveTransferStock is MockToken {
    address public expensiveTo;
    uint256 public burn;

    constructor() MockToken("STK", 18) {}

    function setExpensive(address to, uint256 burn_) external { (expensiveTo, burn) = (to, burn_); }

    function _update(address from, address to, uint256 value) internal override {
        if (to == expensiveTo) {
            uint256 start = gasleft();
            bytes32 h;
            while (start - gasleft() < burn) h = keccak256(abi.encode(h));   // runs out of gas when starved
        }
        super._update(from, to, value);
    }
}

/// With a cheap reward token no gas limit diverts the stakers' share even without a floor, but only because the
/// funding then costs less than 63 times what the treasury still has to do after it. A transfer some 250k dearer
/// breaks that: without `FUND_GAS_FLOOR` this test finds bookings that succeed and leave the share in the buyback.
contract V2IncomeGasStarvationTest is V2StrategyIncomeBase {
    function stockIsCurrency0() internal pure override returns (bool) { return true; }

    function test_aCallerCannotChooseGasThatLeavesTheStakersShareInTheBuyback() public {
        token.transfer(ALICE, 1000 ether);
        vm.startPrank(ALICE);
        token.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();
        _graduate(10 ether);
        // same storage, plus the two appended words: the pool's funding transfer now costs about 250k more
        vm.etch(address(stock), address(new ExpensiveTransferStock()).code);
        ExpensiveTransferStock(address(stock)).setExpensive(address(staking), 250_000);
        stock.mint(address(t), 4 ether);

        uint256 initial = vm.snapshotState();
        uint256 funded; uint256 starved;
        for (uint256 stipend = 100_000; stipend <= 1_200_000; stipend += 1_000) {
            assertTrue(vm.revertToState(initial));
            t.lotCount(); t.buybackStock(); t.bookedStock(); t.unbookedStock();
            vm.prank(ALICE);
            (bool ok, bytes memory out) = address(t).call{gas: stipend}(abi.encodeWithSelector(t.book.selector));
            if (ok) {
                assertEq(staking.totalFunded(), 1 ether, "a booking that succeeds has paid the stakers");
                ++funded;
            } else if (out.length >= 4 && bytes4(out) == HedgeFunV2StrategyIncomeTreasury.FundingStarved.selector) {
                assertTrue(vm.revertToState(initial));
                ++starved;
            }
        }
        assertGt(funded, 0, "the search includes fully successful bookings");
        assertGt(starved, 0, "and gas limits under the floor, refused before the funding is tried");
    }
}
