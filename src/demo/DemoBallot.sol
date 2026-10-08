// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice An independent, token-weighted demo poll on Robinhood Chain Testnet.
/// @dev Tokens stay locked until the deadline, so transferring a token cannot count it twice.
///      The final tallies remain after withdrawals. Candidates are poll options only: the result
///      grants no authority over a strategy, treasury, underlying stock or external voting system.
///      There is no owner, early unlock, third-party withdrawal or recovery of donated tokens.
///      The immutable token must support exact, non-rebasing ERC20 transfers in both directions.
contract DemoBallot is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant CHAIN_ID = 46630;
    uint256 public constant MIN_DURATION = 120;
    uint256 public constant MAX_DURATION = 30 days;

    IERC20 public immutable token;
    address public immutable candidateA;
    address public immutable candidateB;
    uint256 public immutable deadline;

    mapping(uint8 => uint256) public votes;
    mapping(address => uint256) public locked;
    mapping(address => uint8) public choiceOf;
    uint256 public totalVotes;

    event VoteCast(address indexed voter, uint8 indexed choice, uint256 amount);
    event Withdrawn(address indexed voter, uint256 amount);

    error WrongChain(uint256 actual);
    error InvalidToken();
    error InvalidCandidates();
    error InvalidDeadline();
    error PollClosed();
    error PollActive();
    error InvalidChoice();
    error ZeroAmount();
    error ChoiceLocked();
    error InexactTransfer();
    error NothingLocked();

    constructor(address token_, address candidateA_, address candidateB_, uint256 deadline_) {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        if (token_ == address(0) || token_.code.length == 0) revert InvalidToken();
        if (candidateA_ == address(0) || candidateB_ == address(0) || candidateA_ == candidateB_) {
            revert InvalidCandidates();
        }
        if (deadline_ < block.timestamp + MIN_DURATION || deadline_ > block.timestamp + MAX_DURATION) {
            revert InvalidDeadline();
        }
        token = IERC20(token_);
        candidateA = candidateA_;
        candidateB = candidateB_;
        deadline = deadline_;
    }

    /// @notice Lock additional tokens for one fixed choice: 0 selects A and 1 selects B.
    /// @dev An unvoted wallet's choiceOf getter defaults to 0; locked > 0 identifies a cast vote.
    function vote(uint8 choice, uint256 amount) external nonReentrant {
        if (block.timestamp >= deadline) revert PollClosed();
        if (choice > 1) revert InvalidChoice();
        if (amount == 0) revert ZeroAmount();
        if (locked[msg.sender] != 0 && choiceOf[msg.sender] != choice) revert ChoiceLocked();

        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = token.balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert InexactTransfer();

        choiceOf[msg.sender] = choice;
        locked[msg.sender] += amount;
        votes[choice] += amount;
        totalVotes += amount;
        emit VoteCast(msg.sender, choice, amount);
    }

    /// @notice After the poll closes, recover only the caller's own locked principal.
    /// @dev Transfer failures and inexact transfers revert the entire withdrawal, including locked = 0.
    ///      votes, totalVotes and choiceOf retain the final, non-binding poll result.
    function withdraw() external nonReentrant {
        if (block.timestamp < deadline) revert PollActive();
        uint256 amount = locked[msg.sender];
        if (amount == 0) revert NothingLocked();

        uint256 ballotBefore = token.balanceOf(address(this));
        uint256 voterBefore = token.balanceOf(msg.sender);
        locked[msg.sender] = 0;
        token.safeTransfer(msg.sender, amount);
        uint256 ballotAfter = token.balanceOf(address(this));
        uint256 voterAfter = token.balanceOf(msg.sender);
        if (
            ballotAfter > ballotBefore || ballotBefore - ballotAfter != amount || voterAfter < voterBefore
                || voterAfter - voterBefore != amount
        ) revert InexactTransfer();
        emit Withdrawn(msg.sender, amount);
    }
}
