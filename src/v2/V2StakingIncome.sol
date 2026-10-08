// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Stake a launch token, earn the stock its treasury actually transfers in. One instance per treasury.
/// @dev Deployed by an income-kind treasury in its own constructor, which is the immutable `incomeSource`.
///      Only that source may fund rewards, with a real transfer of a different asset than the staked one.
///      This contract enforces funding and time-weighted allocation; what counts as income is the source's rule.
///      Rewards stream over `duration`; stakes cannot enter and exit in a single funding transaction.
///      A funding that arrives while a stream is running does not restart it: see `_schedule`.
///      No administrator can withdraw principal, rewards or donations. Fractions carry across checkpoints.
///      Rewards funded while nothing is staked are queued and start streaming with the first stake.
contract V2StakingIncome is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // A launch's supply is bounded by uint128 in the factory. At this precision, an unallocated
    // global fraction is below 3.5e-7 raw reward units even at that maximum supply.
    uint256 private constant SCALE = 1e45;
    uint256 public constant RATE_SCALE = 1e18;
    /// @notice Lifetime funding ceiling in raw reward units, keeping the index safe even with one wei staked.
    uint256 public constant MAX_TOTAL_FUNDED = type(uint256).max / SCALE;
    IERC20 public immutable stakeToken;
    IERC20 public immutable rewardToken;
    address public immutable incomeSource;
    uint256 public immutable duration;
    uint256 public immutable minimumStakeTime;

    uint256 public totalStaked;
    uint256 public totalFunded;
    uint256 public totalClaimed;
    /// @notice Sub-raw-unit scheduling remainder, in raw reward units times RATE_SCALE.
    uint256 public queuedRewardsScaled;
    /// @notice Raw reward units times RATE_SCALE emitted per second.
    uint256 public rewardRateScaled;
    uint256 public periodFinish;
    uint256 public lastUpdate;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public unlockAt;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public accruedRewards;
    /// @notice Undivided global numerator, in raw reward units times SCALE. It is not anyone's accrued reward.
    /// @dev Carry it across changes in totalStaked; the next active stake set receives this unallocated dust once.
    uint256 public rewardPerTokenRemainder;
    /// @notice This account's accrued fraction of one raw reward unit, scaled by SCALE; retained after exit/claim.
    mapping(address => uint256) public rewardRemainder;

    error InvalidConfig();
    error InvalidAmount();
    error InvalidRecipient();
    error NotIncomeSource();
    error StakeLocked();
    error InexactTransfer();
    error FundingLimitExceeded();

    event Staked(address indexed account, uint256 amount, uint256 unlockAt);
    event Withdrawn(address indexed account, address indexed recipient, uint256 amount);
    event IncomeFunded(uint256 amount, uint256 queued, uint256 rate, uint256 finish);
    event RewardPaid(address indexed account, address indexed recipient, uint256 amount);

    constructor(IERC20 stake_, IERC20 reward_, address source_, uint256 duration_, uint256 lock_) {
        if (address(stake_).code.length == 0 || address(reward_).code.length == 0
            || address(stake_) == address(reward_) || source_ == address(0)
            || duration_ < 1 hours || duration_ > 30 days || lock_ < 1 hours || lock_ > 30 days) {
            revert InvalidConfig();
        }
        stakeToken = stake_;
        rewardToken = reward_;
        incomeSource = source_;
        duration = duration_;
        minimumStakeTime = lock_;
        lastUpdate = block.timestamp;
        periodFinish = block.timestamp;
    }

    function rewardPerToken() public view returns (uint256) {
        (uint256 index,) = _rewardIndex();
        return index;
    }

    function _rewardIndex() private view returns (uint256 index, uint256 remainder) {
        index = rewardPerTokenStored;
        remainder = rewardPerTokenRemainder;
        uint256 through = Math.min(block.timestamp, periodFinish);
        uint256 supply = totalStaked;
        if (supply == 0 || through <= lastUpdate) return (index, remainder);
        uint256 emitted = (through - lastUpdate) * rewardRateScaled;
        index += Math.mulDiv(emitted, SCALE / RATE_SCALE, supply) + remainder / supply;
        uint256 carry = remainder % supply;
        remainder = mulmod(emitted, SCALE / RATE_SCALE, supply);
        // Add the two remainders without overflowing when totalStaked is large.
        if (remainder >= supply - carry) {
            ++index;
            remainder -= supply - carry;
        } else {
            remainder += carry;
        }
    }

    function earned(address account) public view returns (uint256) {
        (uint256 amount,) = _accountAccrual(account, rewardPerToken());
        return accruedRewards[account] + amount;
    }

    function _accountAccrual(address account, uint256 index) private view returns (uint256 amount, uint256 remainder) {
        uint256 delta = index - userRewardPerTokenPaid[account];
        uint256 stake_ = balanceOf[account];
        amount = Math.mulDiv(stake_, delta, SCALE);
        remainder = mulmod(stake_, delta, SCALE) + rewardRemainder[account];
        amount += remainder / SCALE;
        remainder %= SCALE;
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        _update(msg.sender);
        _pullExact(stakeToken, msg.sender, amount);
        balanceOf[msg.sender] += amount;
        totalStaked += amount;
        // Only the depositor can extend its own lock; no stakeFor/griefing entry point.
        unlockAt[msg.sender] = block.timestamp + minimumStakeTime;
        if (rewardRateScaled == 0 && queuedRewardsScaled != 0) _schedule(queuedRewardsScaled);
        emit Staked(msg.sender, amount, unlockAt[msg.sender]);
    }

    /// @notice Principal withdrawal does not attempt a reward payment; a blocked reward token cannot trap FUN.
    function withdraw(uint256 amount, address to) external nonReentrant {
        if (amount == 0 || amount > balanceOf[msg.sender]) revert InvalidAmount();
        _recipient(to);
        if (block.timestamp < unlockAt[msg.sender]) revert StakeLocked();
        _update(msg.sender);
        balanceOf[msg.sender] -= amount;
        totalStaked -= amount;
        if (totalStaked == 0) {
            queuedRewardsScaled += _remaining();
            rewardRateScaled = 0;
            periodFinish = block.timestamp;
            lastUpdate = block.timestamp;
        }
        _pushExact(stakeToken, to, amount);
        emit Withdrawn(msg.sender, to, amount);
    }

    /// @notice Newly funded rewards join the running stream; see `_schedule` for how long the two then take.
    /// @dev The source controls funding timing, and anyone can make the source fund a wei. Funding never claws
    ///      back accrued rewards, and a small one cannot hold back a large one that is already streaming.
    function fund(uint256 amount) external nonReentrant {
        if (msg.sender != incomeSource) revert NotIncomeSource();
        if (amount == 0) revert InvalidAmount();
        if (amount > MAX_TOTAL_FUNDED - totalFunded) revert FundingLimitExceeded();
        _update(address(0));
        _pullExact(rewardToken, msg.sender, amount);
        totalFunded += amount;
        _schedule(amount * RATE_SCALE + queuedRewardsScaled);
        emit IncomeFunded(amount, queuedRewardsScaled, rewardRateScaled, periodFinish);
    }

    function claim(address to) external nonReentrant returns (uint256 amount) {
        _recipient(to);
        _update(msg.sender);
        amount = accruedRewards[msg.sender];
        if (amount == 0) return 0;
        accruedRewards[msg.sender] = 0;
        totalClaimed += amount;
        _pushExact(rewardToken, to, amount);
        emit RewardPaid(msg.sender, to, amount);
    }

    function _remaining() private view returns (uint256) {
        return block.timestamp < periodFinish ? (periodFinish - block.timestamp) * rewardRateScaled : 0;
    }

    /// @dev `fresh` is what has no schedule yet; it, the rate and the queue are raw reward units times RATE_SCALE.
    ///
    ///      What is already streaming keeps the time it had left and what is new gets a full `duration`; the
    ///      stream then runs for the mean of the two, weighted by amount. Restarting a full `duration` over
    ///      everything on each funding would let a one-wei funding, which anyone can cause, push the whole
    ///      remainder out again: repeated, the stream never ends and pays out on an exponential, not a line.
    ///      Here a funding moves the end only by its own share of the total. The mean rounds down, so the end is
    ///      never earlier than it was, never later than a full `duration`, and dust does not move it at all.
    function _schedule(uint256 fresh) private {
        uint256 left = _remaining();
        uint256 budget = fresh + left;
        lastUpdate = block.timestamp;
        if (totalStaked == 0 || budget < duration) {
            queuedRewardsScaled = budget;
            rewardRateScaled = 0;
            periodFinish = block.timestamp;
            return;
        }
        uint256 span = left == 0 ? duration : (left * (periodFinish - block.timestamp) + fresh * duration) / budget;
        rewardRateScaled = budget / span;
        queuedRewardsScaled = budget % span;
        periodFinish = block.timestamp + span;
    }

    function _update(address account) private {
        (rewardPerTokenStored, rewardPerTokenRemainder) = _rewardIndex();
        uint256 through = Math.min(block.timestamp, periodFinish);
        if (through > lastUpdate) lastUpdate = through;
        if (account != address(0)) {
            (uint256 amount, uint256 remainder) = _accountAccrual(account, rewardPerTokenStored);
            accruedRewards[account] += amount;
            rewardRemainder[account] = remainder;
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    function _recipient(address to) private view {
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
    }

    function _pullExact(IERC20 asset, address from, uint256 amount) private {
        uint256 beforeHere = asset.balanceOf(address(this));
        uint256 beforeThere = asset.balanceOf(from);
        asset.safeTransferFrom(from, address(this), amount);
        if (asset.balanceOf(address(this)) != beforeHere + amount
            || asset.balanceOf(from) != beforeThere - amount) revert InexactTransfer();
    }

    function _pushExact(IERC20 asset, address to, uint256 amount) private {
        uint256 beforeHere = asset.balanceOf(address(this));
        uint256 beforeThere = asset.balanceOf(to);
        asset.safeTransfer(to, amount);
        if (asset.balanceOf(address(this)) != beforeHere - amount
            || asset.balanceOf(to) != beforeThere + amount) revert InexactTransfer();
    }
}
