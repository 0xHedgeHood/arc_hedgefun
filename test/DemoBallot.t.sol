// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DemoBallot} from "../src/demo/DemoBallot.sol";

contract BallotTestToken is ERC20 {
    bool public failDeposits;
    bool public failWithdrawals;
    bool public fee;
    bool public noOpWithdrawal;
    bool public reenterDeposits;
    bool public reenterWithdrawals;
    bool public reentrySucceeded;
    bytes4 public reentryError;
    DemoBallot public ballot;

    constructor() ERC20("Ballot test token", "BTT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailures(bool deposit_, bool withdrawal_) external {
        failDeposits = deposit_;
        failWithdrawals = withdrawal_;
    }

    function setFee(bool enabled) external {
        fee = enabled;
    }

    function setNoOpWithdrawal(bool enabled) external {
        noOpWithdrawal = enabled;
    }

    function setReentry(DemoBallot ballot_, bool deposit_, bool withdrawal_) external {
        ballot = ballot_;
        reenterDeposits = deposit_;
        reenterWithdrawals = withdrawal_;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (failDeposits) return false;
        if (reenterDeposits) _reenter(abi.encodeCall(DemoBallot.vote, (0, 1)));
        return super.transferFrom(from, to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failWithdrawals) return false;
        if (reenterWithdrawals) _reenter(abi.encodeCall(DemoBallot.withdraw, ()));
        if (noOpWithdrawal) return true;
        return super.transfer(to, amount);
    }

    function _reenter(bytes memory data) private {
        bytes memory result;
        (reentrySucceeded, result) = address(ballot).call(data);
        reentryError = bytes4(result);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (fee && from != address(0) && to != address(0) && amount != 0) {
            super._update(from, to, amount - 1);
            super._update(from, address(0), 1);
        } else {
            super._update(from, to, amount);
        }
    }
}

contract DemoBallotTest is Test {
    BallotTestToken internal token;
    DemoBallot internal ballot;
    address internal alice;
    address internal bob;
    address internal candidateA;
    address internal candidateB;
    uint256 internal end;

    event VoteCast(address indexed voter, uint8 indexed choice, uint256 amount);
    event Withdrawn(address indexed voter, uint256 amount);

    function setUp() public {
        vm.chainId(46630);
        vm.warp(1_700_000_000);
        alice = makeAddr("ballot alice");
        bob = makeAddr("ballot bob");
        candidateA = makeAddr("candidate A");
        candidateB = makeAddr("candidate B");
        token = new BallotTestToken();
        end = block.timestamp + 15 minutes;
        ballot = new DemoBallot(address(token), candidateA, candidateB, end);
        token.mint(alice, 100e18);
        token.mint(bob, 100e18);
        vm.prank(alice);
        token.approve(address(ballot), type(uint256).max);
        vm.prank(bob);
        token.approve(address(ballot), type(uint256).max);
    }

    function _vote(address voter, uint8 choice, uint256 amount) internal {
        vm.prank(voter);
        ballot.vote(choice, amount);
    }

    function _assertNoVote(address voter) internal view {
        assertEq(ballot.locked(voter), 0);
        assertEq(ballot.votes(0), 0);
        assertEq(ballot.votes(1), 0);
        assertEq(ballot.totalVotes(), 0);
        assertEq(token.balanceOf(address(ballot)), 0);
    }

    function testConstructorBindsImmutablePoll() public view {
        assertEq(address(ballot.token()), address(token));
        assertEq(ballot.candidateA(), candidateA);
        assertEq(ballot.candidateB(), candidateB);
        assertEq(ballot.deadline(), end);
    }

    function testWrongChainRefused() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DemoBallot.WrongChain.selector, 1));
        new DemoBallot(address(token), candidateA, candidateB, end);
    }

    function testZeroTokenRefused() public {
        vm.expectRevert(DemoBallot.InvalidToken.selector);
        new DemoBallot(address(0), candidateA, candidateB, end);
    }

    function testTokenWithoutCodeRefused() public {
        vm.expectRevert(DemoBallot.InvalidToken.selector);
        new DemoBallot(alice, candidateA, candidateB, end);
    }

    function testCandidateAddressesMustBeNonzeroAndDistinct() public {
        vm.expectRevert(DemoBallot.InvalidCandidates.selector);
        new DemoBallot(address(token), address(0), candidateB, end);
        vm.expectRevert(DemoBallot.InvalidCandidates.selector);
        new DemoBallot(address(token), candidateA, address(0), end);
        vm.expectRevert(DemoBallot.InvalidCandidates.selector);
        new DemoBallot(address(token), candidateA, candidateA, end);
    }

    function testDeadlineBounds() public {
        uint256 now_ = block.timestamp;
        vm.expectRevert(DemoBallot.InvalidDeadline.selector);
        new DemoBallot(address(token), candidateA, candidateB, now_ + 119);
        vm.expectRevert(DemoBallot.InvalidDeadline.selector);
        new DemoBallot(address(token), candidateA, candidateB, now_ + 30 days + 1);
        new DemoBallot(address(token), candidateA, candidateB, now_ + 120);
        new DemoBallot(address(token), candidateA, candidateB, now_ + 30 days);
    }

    function testVoteLocksExactAmountAndEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(ballot));
        emit VoteCast(alice, 1, 30e18);
        _vote(alice, 1, 30e18);
        assertEq(token.balanceOf(alice), 70e18);
        assertEq(token.balanceOf(address(ballot)), 30e18);
        assertEq(ballot.locked(alice), 30e18);
        assertEq(ballot.choiceOf(alice), 1);
        assertEq(ballot.votes(0), 0);
        assertEq(ballot.votes(1), 30e18);
        assertEq(ballot.totalVotes(), 30e18);
    }

    function testSameChoiceAdditionalDepositCountsOnlyNewTokens() public {
        _vote(alice, 0, 30e18);
        _vote(alice, 0, 70e18);
        assertEq(ballot.locked(alice), 100e18);
        assertEq(ballot.votes(0), 100e18);
        assertEq(ballot.totalVotes(), 100e18);
        assertEq(token.balanceOf(address(ballot)), 100e18);
    }

    function testChoiceChangeRefusedWithoutMovingFunds() public {
        _vote(alice, 0, 30e18);
        vm.expectRevert(DemoBallot.ChoiceLocked.selector);
        _vote(alice, 1, 10e18);
        assertEq(ballot.choiceOf(alice), 0);
        assertEq(ballot.locked(alice), 30e18);
        assertEq(ballot.votes(0), 30e18);
        assertEq(ballot.votes(1), 0);
        assertEq(token.balanceOf(alice), 70e18);
    }

    function testZeroAmountRefused() public {
        vm.expectRevert(DemoBallot.ZeroAmount.selector);
        _vote(alice, 0, 0);
        _assertNoVote(alice);
    }

    function testInvalidChoiceRefused() public {
        vm.expectRevert(DemoBallot.InvalidChoice.selector);
        _vote(alice, 2, 1e18);
        _assertNoVote(alice);
    }

    function testTransferredTokensCannotBeCountedTwice() public {
        _vote(alice, 0, 60e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 40e18, 60e18));
        _vote(alice, 0, 60e18);
        vm.prank(alice);
        token.transfer(bob, 40e18);
        _vote(bob, 1, 140e18);
        assertEq(ballot.votes(0), 60e18);
        assertEq(ballot.votes(1), 140e18);
        assertEq(ballot.totalVotes(), token.totalSupply());
        assertEq(token.balanceOf(address(ballot)), 200e18);
    }

    function testDepositFailureGivesNoCredit() public {
        token.setFailures(true, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        _vote(alice, 0, 10e18);
        _assertNoVote(alice);
        assertEq(token.balanceOf(alice), 100e18);
    }

    function testFeeOnDepositRefusedAndAllEffectsRolledBack() public {
        token.setFee(true);
        vm.expectRevert(DemoBallot.InexactTransfer.selector);
        _vote(alice, 1, 10e18);
        _assertNoVote(alice);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.totalSupply(), 200e18);
    }

    function testCannotWithdrawBeforeDeadline() public {
        _vote(alice, 0, 10e18);
        vm.warp(end - 1);
        vm.expectRevert(DemoBallot.PollActive.selector);
        vm.prank(alice);
        ballot.withdraw();
        assertEq(ballot.locked(alice), 10e18);
    }

    function testVoteBeforeDeadlineAndRefusedAtDeadline() public {
        vm.warp(end - 1);
        _vote(alice, 0, 10e18);
        vm.warp(end);
        vm.expectRevert(DemoBallot.PollClosed.selector);
        _vote(alice, 0, 1e18);
        assertEq(ballot.totalVotes(), 10e18);
    }

    function testWithdrawAtDeadlineReturnsOnlyOwnPrincipalAndKeepsResult() public {
        _vote(alice, 0, 30e18);
        _vote(bob, 1, 40e18);
        vm.warp(end);
        vm.expectEmit(true, false, false, true, address(ballot));
        emit Withdrawn(alice, 30e18);
        vm.prank(alice);
        ballot.withdraw();
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(bob), 60e18);
        assertEq(token.balanceOf(address(ballot)), 40e18);
        assertEq(ballot.locked(alice), 0);
        assertEq(ballot.locked(bob), 40e18);
        assertEq(ballot.votes(0), 30e18);
        assertEq(ballot.votes(1), 40e18);
        assertEq(ballot.totalVotes(), 70e18);
        assertEq(ballot.choiceOf(alice), 0);
    }

    function testNonVoterCannotWithdrawSomebodyElsesTokens() public {
        _vote(alice, 0, 30e18);
        vm.warp(end);
        vm.expectRevert(DemoBallot.NothingLocked.selector);
        vm.prank(bob);
        ballot.withdraw();
        assertEq(ballot.locked(alice), 30e18);
        assertEq(token.balanceOf(address(ballot)), 30e18);
    }

    function testNoRepeatedWithdrawalOrRevoteOfWithdrawnCapital() public {
        _vote(alice, 1, 30e18);
        vm.warp(end);
        vm.prank(alice);
        ballot.withdraw();
        vm.expectRevert(DemoBallot.NothingLocked.selector);
        vm.prank(alice);
        ballot.withdraw();
        vm.expectRevert(DemoBallot.PollClosed.selector);
        _vote(alice, 1, 30e18);
        assertEq(ballot.totalVotes(), 30e18);
    }

    function testWithdrawalFailureRetainsAllPrincipalAndVotes() public {
        _vote(alice, 1, 30e18);
        vm.warp(end);
        token.setFailures(false, true);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(alice);
        ballot.withdraw();
        assertEq(ballot.locked(alice), 30e18);
        assertEq(token.balanceOf(address(ballot)), 30e18);
        assertEq(ballot.totalVotes(), 30e18);
        token.setFailures(false, false);
        vm.prank(alice);
        ballot.withdraw();
        assertEq(token.balanceOf(alice), 100e18);
    }

    function testFeeActivatedAfterVotingCannotReduceWithdrawalPrincipal() public {
        _vote(alice, 1, 30e18);
        vm.warp(end);
        token.setFee(true);
        vm.expectRevert(DemoBallot.InexactTransfer.selector);
        vm.prank(alice);
        ballot.withdraw();
        assertEq(ballot.locked(alice), 30e18);
        assertEq(token.balanceOf(alice), 70e18);
        assertEq(token.balanceOf(address(ballot)), 30e18);
        assertEq(token.totalSupply(), 200e18);
    }

    function testNoOpTransferCannotEraseLockedPrincipal() public {
        _vote(alice, 1, 30e18);
        vm.warp(end);
        token.setNoOpWithdrawal(true);
        vm.expectRevert(DemoBallot.InexactTransfer.selector);
        vm.prank(alice);
        ballot.withdraw();
        assertEq(ballot.locked(alice), 30e18);
        assertEq(token.balanceOf(address(ballot)), 30e18);
    }

    function testDepositReentryCannotCreateExtraVotes() public {
        token.setReentry(ballot, true, false);
        _vote(alice, 1, 30e18);
        assertFalse(token.reentrySucceeded());
        assertEq(token.reentryError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(ballot.locked(address(token)), 0);
        assertEq(ballot.totalVotes(), 30e18);
    }

    function testWithdrawalReentryCannotWithdrawTwice() public {
        _vote(alice, 1, 30e18);
        vm.warp(end);
        token.setReentry(ballot, false, true);
        vm.prank(alice);
        ballot.withdraw();
        assertFalse(token.reentrySucceeded());
        assertEq(token.reentryError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(ballot.locked(alice), 0);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(ballot.totalVotes(), 30e18);
    }

    function testFuzzVotesRemainBackedUntilWithdrawal(uint256 aliceAmount, uint256 bobAmount) public {
        aliceAmount = bound(aliceAmount, 1, 100e18);
        bobAmount = bound(bobAmount, 1, 100e18);
        _vote(alice, 0, aliceAmount);
        _vote(bob, 1, bobAmount);
        assertEq(ballot.votes(0), aliceAmount);
        assertEq(ballot.votes(1), bobAmount);
        assertEq(ballot.totalVotes(), aliceAmount + bobAmount);
        assertEq(token.balanceOf(address(ballot)), ballot.locked(alice) + ballot.locked(bob));
        vm.warp(end);
        vm.prank(alice);
        ballot.withdraw();
        vm.prank(bob);
        ballot.withdraw();
        assertEq(token.balanceOf(address(ballot)), 0);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(bob), 100e18);
        assertEq(ballot.totalVotes(), aliceAmount + bobAmount);
    }
}
