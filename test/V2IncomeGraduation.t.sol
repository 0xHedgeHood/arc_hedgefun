// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2IncomeKindsFixture} from "./V2IncomeKinds.t.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2IncomeTreasury} from "../src/v2/HedgeFunV2IncomeTreasury.sol";
import {HedgeFunV2StrategyIncomeTreasury} from "../src/v2/HedgeFunV2StrategyIncomeTreasury.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {Vm} from "forge-std/Vm.sol";

/// Graduation capital stays independent of optional booking, fee timing and the kind's income split.
contract V2IncomeGraduationTest is V2IncomeKindsFixture {
    struct Scenario {
        uint8 choice;
        uint16 lpInput;
        uint96 grossInput;
        uint96 earlyGiftInput;
        uint96 lateGiftInput;
        bool preclaim;
        bool failBook;
    }
    function _checkOptionalBookFailure(uint8 kind) internal {
        Launch memory l = _launch(kind);
        // Same fault injection as V2BuybackKindTest: exercises the factory's documented
        // catch path, without claiming that a live caller can force this failure.
        vm.mockCallRevert(address(l.treasury), abi.encodeWithSelector(l.treasury.book.selector), bytes("book failed"));
        _graduateV2(l.curve);
        vm.clearMockedCalls();
        uint256 principal = stock.balanceOf(address(l.treasury));
        assertGt(principal, 0);
        vm.prank(alice);
        l.treasury.book();
        assertEq(l.staking.totalFunded(), 0, "graduation principal must not become staking income");
        assertEq(l.treasury.buybackStock(), 0, "graduation principal must not become buyback income");
    }

    function _checkPreclaimedFees(uint8 kind) internal {
        Launch memory l = _launch(kind);
        l.curve.buy(10 ** _incomeStockDecimals(), 1, address(this), block.timestamp);
        uint256 fees = l.curve.claimable(address(l.treasury));
        assertGt(fees, 0);
        l.curve.claimFees(address(l.treasury));
        assertFalse(l.treasury.book());
        _graduateV2(l.curve);
        uint256 expected = fees * l.treasury.stakingBps() / 10_000;
        assertEq(l.staking.totalFunded(), expected, "earned fees must not be reclassified as graduation principal");
    }

    function test_optionalBookFailureDividend() public { _checkOptionalBookFailure(dividendKind); }
    function test_optionalBookFailureSplit() public { _checkOptionalBookFailure(splitKind); }
    function test_optionalBookFailureStrategy25() public { _checkOptionalBookFailure(kinds.strategy25); }
    function test_optionalBookFailureStrategy50() public { _checkOptionalBookFailure(kinds.strategy50); }
    function test_preclaimedFeesDividend() public { _checkPreclaimedFees(dividendKind); }
    function test_preclaimedFeesSplit() public { _checkPreclaimedFees(splitKind); }
    function test_preclaimedFeesStrategy25() public { _checkPreclaimedFees(kinds.strategy25); }
    function test_preclaimedFeesStrategy50() public { _checkPreclaimedFees(kinds.strategy50); }

    function _kind(uint8 choice) internal view returns (uint8) {
        uint8[4] memory options = [dividendKind, splitKind, kinds.strategy25, kinds.strategy50];
        return options[choice % 4];
    }

    function _principal(Launch memory l, bool strategy) internal view returns (uint256) {
        return strategy ? HedgeFunV2StrategyIncomeTreasury(address(l.treasury)).principalStock()
            : l.treasury.protectedGraduationStock();
    }

    function testFuzz_principalInitializationRequiresFactoryAndCannotRepeat(uint8 choice) public {
        Launch memory l = _launch(_kind(choice));
        vm.prank(alice);
        vm.expectRevert(HedgeFunTreasuryBase.NotFactory.selector);
        l.treasury.wireWithGraduation(l.key, 1);
        _graduateV2(l.curve);
        uint256 principal = _principal(l, choice % 4 >= 2);
        vm.prank(address(factory));
        vm.expectRevert(HedgeFunTreasuryBase.AlreadyWired.selector);
        l.treasury.wireWithGraduation(l.key, 0);
        assertEq(_principal(l, choice % 4 >= 2), principal);
    }

    function testFuzz_failedInitializationCannotFallBackToLegacyWire(uint8 choice) public {
        Launch memory l = _launch(_kind(choice));
        vm.mockCallRevert(address(l.treasury), abi.encodeWithSelector(l.treasury.wireWithGraduation.selector), "failed init");
        vm.expectRevert(HedgeFunV2IncomeTreasury.GraduationPrincipalRequired.selector);
        l.curve.buy(type(uint256).max, 1, address(this), block.timestamp);
        vm.clearMockedCalls();
        assertEq(uint256(l.curve.status()), uint256(HedgeFunBondingCurve.Status.Active));
        assertEq(l.treasury.hook(), address(0));
        assertEq(l.treasury.liquidityVault(), address(0));
        assertEq(_principal(l, choice % 4 >= 2), 0);
    }

    function testFuzz_failedPrincipalTransferRollsBackInitialization(uint8 choice) public {
        Launch memory l = _launch(_kind(choice));
        stock.blockRecipient(address(l.treasury));
        vm.expectRevert(bytes("blocked recipient"));
        l.curve.buy(type(uint256).max, 1, address(this), block.timestamp);
        assertEq(uint256(l.curve.status()), uint256(HedgeFunBondingCurve.Status.Active));
        assertEq(l.treasury.hook(), address(0));
        assertEq(_principal(l, choice % 4 >= 2), 0);
        stock.blockRecipient(address(0));
        _graduateV2(l.curve);
        assertGt(_principal(l, choice % 4 >= 2), 0);
        assertEq(l.staking.totalFunded(), 0);
    }

    function testFuzz_claimTimingCannotRelabelPrincipal(Scenario memory x) public {
        uint256 unit = 10 ** _incomeStockDecimals();
        vm.prank(owner);
        deployer.setLpBps(address(stock), uint16(bound(x.lpInput, 1000, 10000)));
        Launch memory l = _launch(_kind(x.choice));
        l.curve.buy(bound(x.grossInput, unit / 100, 5 * unit), 1, address(this), block.timestamp);
        uint256 earlyFees = x.preclaim ? l.curve.claimable(address(l.treasury)) : 0;
        if (x.preclaim) l.curve.claimFees(address(l.treasury));
        uint256 earlyGift = bound(x.earlyGiftInput, 0, 3 * unit);
        stock.transfer(address(l.treasury), earlyGift);
        assertFalse(l.treasury.book());
        uint256 supply = l.token.totalSupply();
        if (x.failBook) vm.mockCallRevert(address(l.treasury), abi.encodeWithSelector(l.treasury.book.selector), "failed book");
        vm.recordLogs();
        _graduateV2(l.curve);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.clearMockedCalls();
        // Use the factory's measured LP/capital split as an independent oracle for the treasury ledger.
        uint256 principal;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0]
                == keccak256("GraduationCapitalSplit(uint256,uint256,uint256,bool)")) {
                (, principal,) = abi.decode(logs[i].data, (uint256, uint256, bool));
                found = true;
            }
        }
        assertTrue(found);
        bool strategy = x.choice % 4 >= 2;
        assertEq(_principal(l, strategy), principal);
        assertEq(l.token.totalSupply(), supply, "graduation cannot burn project tokens");
        vm.prank(alice);
        l.treasury.book();
        uint256 income = earlyFees + earlyGift;
        assertEq(l.staking.totalFunded() + l.treasury.buybackStock(), income);
        assertEq(stock.balanceOf(address(l.treasury)), principal + l.treasury.buybackStock());

        uint256 lateFees = l.curve.claimable(address(l.treasury));
        l.curve.claimFees(address(l.treasury));
        uint256 lateGift = bound(x.lateGiftInput, 0, 3 * unit);
        stock.transfer(address(l.treasury), lateGift);
        vm.prank(alice);
        l.treasury.book();
        income += lateFees + lateGift;
        assertEq(l.staking.totalFunded() + l.treasury.buybackStock(), income);
        assertEq(stock.balanceOf(address(l.treasury)), principal + l.treasury.buybackStock());
        assertEq(_principal(l, strategy), principal);
        uint256 funded = l.staking.totalFunded();
        assertApproxEqAbs(funded, income * l.treasury.stakingBps() / 10000, strategy ? 1 : 0);
        if (!strategy) assertEq(l.treasury.bookedStock(), principal);
        else assertEq(l.treasury.bookedStock() + l.treasury.unbookedStock(), principal);
        l.treasury.book();
        assertEq(l.staking.totalFunded(), funded, "repeated booking cannot duplicate income");
    }
}

contract V2IncomeGraduationSixDecimalsTest is V2IncomeGraduationTest {
    function _incomeStockDecimals() internal pure override returns (uint8) { return 6; }
}
