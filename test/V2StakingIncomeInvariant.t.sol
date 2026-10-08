// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {V2StakingIncome} from "../src/v2/V2StakingIncome.sol";

/// A stock can reject transfers or deliver one raw unit less than requested. Both
/// modes must roll back the staking ledger, including updates accrued before I/O.
contract IncomeInvariantToken is ERC20 {
    uint8 private immutable decimalPlaces;
    uint8 public transferMode;
    error TransferBlocked();

    constructor(string memory symbol_, uint8 decimals_) ERC20(symbol_, symbol_) {
        decimalPlaces = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return decimalPlaces;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTransferMode(uint8 mode) external {
        transferMode = mode;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            if (transferMode == 1) revert TransferBlocked();
            if (transferMode == 2 && amount != 0) {
                super._update(from, address(0), 1);
                super._update(from, to, amount - 1);
                return;
            }
        }
        super._update(from, to, amount);
    }
}

/// The ghost model counts successful transfers, deposits, withdrawals and locks.
/// It deliberately does not reproduce reward-rate or reward-per-token formulas.
contract StakingIncomeHandler is Test {
    uint256 public constant INITIAL_STAKE = 1_000_000e18;
    uint256 public constant DURATION = 7 days;
    IncomeInvariantToken public immutable stakeToken;
    IncomeInvariantToken public immutable stock;
    V2StakingIncome public immutable pool;
    address[4] public actors = [address(0xA11CE), address(0xB0B), address(0xCA11), address(0xDAD)];
    address public constant RECIPIENT = address(0xFEE1);

    mapping(address => uint256) public ghostStaked;
    mapping(address => uint256) public ghostDeposited;
    mapping(address => uint256) public ghostPrincipalReceived;
    mapping(address => uint256) public ghostRewardsReceived;
    mapping(address => uint256) public ghostUnlock;
    uint256 public ghostTotalStaked;
    uint256 public ghostFunded;
    uint256 public ghostClaimed;
    uint256 public ghostSourceMinted;
    uint256 public ghostStockDonations;
    uint256 public ghostStakeDonations;
    uint256 public queuedFundings;
    uint256 public repeatedFundings;
    uint256 public lockedWithdrawals;
    uint256 public failedTransfers;
    uint256 public withdrawalsWithBlockedRewards;

    constructor() {
        stakeToken = new IncomeInvariantToken("FUN", 18);
        stock = new IncomeInvariantToken("STOCK", 6);
        pool = new V2StakingIncome(stakeToken, stock, address(this), DURATION, DURATION);
        stock.approve(address(pool), type(uint256).max);
        for (uint256 i; i < actors.length; ++i) {
            stakeToken.mint(actors[i], INITIAL_STAKE);
            vm.prank(actors[i]);
            stakeToken.approve(address(pool), type(uint256).max);
        }
    }

    function stake(uint8 who, uint96 rawAmount) external {
        address actor = actors[who % 4];
        uint256 available = stakeToken.balanceOf(actor);
        if (available == 0) return;
        uint256 amount = bound(uint256(rawAmount), 1, available);
        vm.prank(actor);
        pool.stake(amount);
        ghostStaked[actor] += amount;
        ghostDeposited[actor] += amount;
        ghostTotalStaked += amount;
        ghostUnlock[actor] = block.timestamp + DURATION;
    }

    function withdraw(uint8 who, uint96 rawAmount, bool toAnother) external {
        address actor = actors[who % 4];
        uint256 deposited = ghostStaked[actor];
        if (deposited == 0) return;
        uint256 amount = bound(uint256(rawAmount), 1, deposited);
        address recipient = toAnother ? RECIPIENT : actor;
        if (block.timestamp < ghostUnlock[actor]) {
            bytes32 beforeState = stateDigest();
            vm.prank(actor);
            vm.expectRevert(V2StakingIncome.StakeLocked.selector);
            pool.withdraw(amount, recipient);
            assertEq(stateDigest(), beforeState, "locked withdrawal mutated state");
            ++lockedWithdrawals;
            return;
        }
        _withdraw(actor, amount, recipient);
    }

    function fund(uint96 rawAmount) external {
        uint256 amount = bound(uint256(rawAmount), 1, 1_000_000e6);
        uint256[4] memory beforeEarned;
        for (uint256 i; i < actors.length; ++i) {
            beforeEarned[i] = pool.earned(actors[i]);
        }
        if (ghostTotalStaked == 0) ++queuedFundings;
        if (ghostFunded != 0) ++repeatedFundings;
        _mintSource(amount);
        pool.fund(amount);
        ghostFunded += amount;
        for (uint256 i; i < actors.length; ++i) {
            assertEq(pool.earned(actors[i]), beforeEarned[i], "funding reduced or advanced accrued income");
        }
    }

    function claim(uint8 who, bool toAnother) external {
        _claim(actors[who % 4], toAnother ? RECIPIENT : actors[who % 4]);
    }

    function advanceTime(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(uint256(seconds_), 0, 30 days));
    }

    function advanceToLockBoundary(uint8 who, uint8 edge) external {
        uint256 unlock = ghostUnlock[actors[who % 4]];
        if (unlock == 0) return;
        uint256 target = unlock - 1 + uint256(edge % 3);
        if (target > block.timestamp) vm.warp(target);
    }

    function donate(uint64 stockAmount, uint64 stakeAmount) external {
        uint256 stockDonation = bound(uint256(stockAmount), 0, 1_000e6);
        uint256 stakeDonation = bound(uint256(stakeAmount), 0, 1e18);
        stock.mint(address(pool), stockDonation);
        stakeToken.mint(address(pool), stakeDonation);
        ghostStockDonations += stockDonation;
        ghostStakeDonations += stakeDonation;
    }

    /// Modes 0/1 exercise reverting/taxed funding; 2/3 exercise the same claim
    /// failures. A nonzero claim must revert, and every public ledger must roll back.
    function rewardTransferFailure(uint8 who, uint96 rawAmount, uint8 scenario) external {
        address actor = actors[who % 4];
        uint8 selected = scenario % 4;
        uint8 mode = selected % 2 + 1;
        uint256 amount;
        if (selected < 2) {
            amount = bound(uint256(rawAmount), 1, 1_000_000e6);
            _mintSource(amount);
        } else if (pool.earned(actor) == 0) {
            return;
        }
        stock.setTransferMode(mode);
        bytes32 beforeState = stateDigest();
        vm.expectRevert(
            mode == 1 ? IncomeInvariantToken.TransferBlocked.selector : V2StakingIncome.InexactTransfer.selector
        );
        if (selected < 2) {
            pool.fund(amount);
        } else {
            vm.prank(actor);
            pool.claim(RECIPIENT);
        }
        assertEq(stateDigest(), beforeState, "failed reward transfer changed state");
        stock.setTransferMode(0);
        ++failedTransfers;
    }

    /// Failed incoming and outgoing FUN transfers must not update stake balances,
    /// locks, reward checkpoints, queued rewards or either asset's real balance.
    function principalTransferFailure(uint8 who, uint96 rawAmount, uint8 scenario) external {
        address actor = actors[who % 4];
        uint8 selected = scenario % 4;
        uint8 mode = selected % 2 + 1;
        uint256 available = selected < 2 ? stakeToken.balanceOf(actor) : ghostStaked[actor];
        if (available == 0) return;
        if (selected >= 2 && block.timestamp < ghostUnlock[actor]) vm.warp(ghostUnlock[actor]);
        uint256 amount = bound(uint256(rawAmount), 1, available);
        stakeToken.setTransferMode(mode);
        bytes32 beforeState = stateDigest();
        vm.prank(actor);
        vm.expectRevert(
            mode == 1 ? IncomeInvariantToken.TransferBlocked.selector : V2StakingIncome.InexactTransfer.selector
        );
        if (selected < 2) pool.stake(amount);
        else pool.withdraw(amount, RECIPIENT);
        assertEq(stateDigest(), beforeState, "failed principal transfer changed state");
        stakeToken.setTransferMode(0);
        ++failedTransfers;
    }

    function withdrawWithBlockedRewards(uint8 who, uint96 rawAmount) external {
        address actor = actors[who % 4];
        if (ghostStaked[actor] == 0) return;
        if (block.timestamp < ghostUnlock[actor]) vm.warp(ghostUnlock[actor]);
        uint256 amount = bound(uint256(rawAmount), 1, ghostStaked[actor]);
        uint256 claimBefore = ghostClaimed;
        stock.setTransferMode(1);
        _withdraw(actor, amount, actor);
        stock.setTransferMode(0);
        assertEq(ghostClaimed, claimBefore, "withdrawing principal unexpectedly paid rewards");
        ++withdrawalsWithBlockedRewards;
    }

    /// Only used by the terminal property, not selected as a random action.
    function finishAndExit() external {
        uint256 finish = pool.periodFinish();
        for (uint256 i; i < actors.length; ++i) {
            if (ghostUnlock[actors[i]] > finish) finish = ghostUnlock[actors[i]];
        }
        if (finish > block.timestamp) vm.warp(finish);
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            if (ghostStaked[actor] != 0) _withdraw(actor, ghostStaked[actor], actor);
            _claim(actor, actor);
            assertEq(pool.earned(actor), 0, "settled participant still has an unpaid claim");
        }
        assertEq(ghostTotalStaked, 0, "a sequence trapped principal");
    }

    function stateDigest() public view returns (bytes32 digest) {
        digest = keccak256(
            abi.encode(
                pool.totalStaked(),
                pool.totalFunded(),
                pool.totalClaimed(),
                pool.queuedRewardsScaled(),
                pool.rewardRateScaled(),
                pool.periodFinish(),
                pool.lastUpdate(),
                pool.rewardPerTokenStored(),
                pool.rewardPerTokenRemainder()
            )
        );
        digest = keccak256(
            abi.encode(
                digest,
                stakeToken.balanceOf(address(pool)),
                stock.balanceOf(address(pool)),
                stock.balanceOf(address(this)),
                stakeToken.totalSupply(),
                stock.totalSupply(),
                stakeToken.balanceOf(RECIPIENT),
                stock.balanceOf(RECIPIENT)
            )
        );
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            digest = keccak256(
                abi.encode(
                    digest,
                    pool.balanceOf(actor),
                    pool.unlockAt(actor),
                    pool.userRewardPerTokenPaid(actor),
                    pool.accruedRewards(actor),
                    pool.rewardRemainder(actor),
                    stakeToken.balanceOf(actor),
                    stock.balanceOf(actor)
                )
            );
        }
    }

    function _mintSource(uint256 amount) private {
        stock.mint(address(this), amount);
        ghostSourceMinted += amount;
    }

    function _withdraw(address actor, uint256 amount, address recipient) private {
        vm.prank(actor);
        pool.withdraw(amount, recipient);
        ghostStaked[actor] -= amount;
        ghostTotalStaked -= amount;
        ghostPrincipalReceived[recipient] += amount;
    }

    function _claim(address actor, address recipient) private {
        uint256 beforeBalance = stock.balanceOf(recipient);
        vm.prank(actor);
        uint256 claimed = pool.claim(recipient);
        assertEq(stock.balanceOf(recipient) - beforeBalance, claimed, "claim return differs from actual payment");
        ghostClaimed += claimed;
        ghostRewardsReceived[recipient] += claimed;
    }
}

contract V2StakingIncomeInvariantTest is Test {
    StakingIncomeHandler internal handler;
    V2StakingIncome internal pool;
    IncomeInvariantToken internal stakeToken;
    IncomeInvariantToken internal stock;

    function setUp() public {
        handler = new StakingIncomeHandler();
        pool = handler.pool();
        stakeToken = handler.stakeToken();
        stock = handler.stock();
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.stake.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.fund.selector;
        selectors[3] = handler.claim.selector;
        selectors[4] = handler.advanceTime.selector;
        selectors[5] = handler.advanceToLockBoundary.selector;
        selectors[6] = handler.donate.selector;
        selectors[7] = handler.rewardTransferFailure.selector;
        selectors[8] = handler.principalTransferFailure.selector;
        selectors[9] = handler.withdrawWithBlockedRewards.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 512
    /// forge-config: default.invariant.depth = 128
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_principalAndRewardsAreBackedByIndependentTransfers() public view {
        _assertLedger();
    }

    function afterInvariant() public {
        handler.finishAndExit();
        _assertLedger();
        assertEq(pool.totalStaked(), 0);
    }

    function _assertLedger() internal view {
        uint256 sumStaked;
        uint256 sumEarned;
        uint256 sumReceived;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(pool.balanceOf(actor), handler.ghostStaked(actor), "participant principal ledger");
            assertEq(pool.unlockAt(actor), handler.ghostUnlock(actor), "participant lock ledger");
            assertEq(
                stakeToken.balanceOf(actor),
                handler.INITIAL_STAKE() + handler.ghostPrincipalReceived(actor) - handler.ghostDeposited(actor),
                "participant FUN flow"
            );
            assertEq(stock.balanceOf(actor), handler.ghostRewardsReceived(actor), "participant stock flow");
            sumStaked += handler.ghostStaked(actor);
            sumEarned += pool.earned(actor);
            sumReceived += stock.balanceOf(actor);
        }
        address recipient = handler.RECIPIENT();
        assertEq(stakeToken.balanceOf(recipient), handler.ghostPrincipalReceived(recipient), "recipient FUN flow");
        assertEq(stock.balanceOf(recipient), handler.ghostRewardsReceived(recipient), "recipient stock flow");
        sumReceived += stock.balanceOf(recipient);
        assertEq(sumStaked, handler.ghostTotalStaked());
        assertEq(pool.totalStaked(), sumStaked);
        assertEq(stakeToken.balanceOf(address(pool)), sumStaked + handler.ghostStakeDonations(), "principal backing");
        assertEq(pool.totalFunded(), handler.ghostFunded(), "funding must be a successful transfer");
        assertEq(pool.totalClaimed(), handler.ghostClaimed(), "claim ledger");
        assertEq(sumReceived, handler.ghostClaimed(), "claims must reach recipients");
        assertLe(handler.ghostClaimed() + sumEarned, handler.ghostFunded(), "overallocated or donation-derived rewards");
        assertEq(
            stock.balanceOf(address(pool)) + handler.ghostClaimed(),
            handler.ghostFunded() + handler.ghostStockDonations(),
            "reward asset conservation"
        );
        assertEq(
            stock.balanceOf(address(handler)), handler.ghostSourceMinted() - handler.ghostFunded(), "source stock flow"
        );
        if (sumStaked == 0) assertEq(pool.rewardRateScaled(), 0, "an empty pool continues spending rewards");
    }

    function test_handlerExercisesEveryFailureAndLockBoundary() public {
        handler.fund(100e6); // Queue with no stakers.
        handler.advanceTime(30 days);
        handler.stake(0, 1e18);
        handler.stake(1, 2e18);
        handler.advanceTime(1 days);
        handler.fund(70e6); // Restart an active stream without clawing back earned income.
        for (uint8 scenario; scenario < 4; ++scenario) {
            handler.rewardTransferFailure(0, 11e6, scenario);
            handler.principalTransferFailure(0, 1e17, scenario);
        }
        // A fresh deposit relocks only this participant; -1, exact and +1 edges.
        handler.stake(0, 1e18);
        handler.advanceToLockBoundary(0, 0);
        handler.withdraw(0, 1e17, true);
        assertEq(handler.lockedWithdrawals(), 1);
        handler.advanceToLockBoundary(0, 1);
        handler.withdraw(0, 1e17, true);
        handler.advanceToLockBoundary(0, 2);
        handler.withdrawWithBlockedRewards(0, 1e17);
        handler.claim(1, true);
        handler.donate(123, 456);
        assertEq(handler.failedTransfers(), 8);
        assertEq(handler.withdrawalsWithBlockedRewards(), 1);
        assertEq(handler.queuedFundings(), 1);
        assertEq(handler.repeatedFundings(), 1);
        _assertLedger();
        handler.finishAndExit();
        _assertLedger();
    }

    function testFuzz_idleQueueAndRefillPreserveAccruedIncome(uint96 first, uint96 second, uint32 delay) public {
        first = uint96(bound(uint256(first), 1e6, 1_000_000e6));
        second = uint96(bound(uint256(second), 1e6, 1_000_000e6));
        handler.fund(first);
        uint256 queued = pool.queuedRewardsScaled();
        handler.advanceTime(delay);
        assertEq(pool.queuedRewardsScaled(), queued, "idle time spent queued rewards");
        handler.stake(0, 1e18);
        handler.advanceTime(3 days);
        uint256 accrued = pool.earned(handler.actors(0));
        assertGt(accrued, 0);
        handler.fund(second);
        assertEq(pool.earned(handler.actors(0)), accrued);
        handler.stake(1, 2e18);
        assertEq(pool.earned(handler.actors(1)), 0, "late stake received historical income");
        handler.finishAndExit();
        assertGt(stock.balanceOf(handler.actors(0)), 0);
        assertGt(stock.balanceOf(handler.actors(1)), 0);
        _assertLedger();
    }

    function testFuzz_rewardFailureNeverLocksPrincipal(uint96 stakeAmount, uint96 funding, uint8 mode) public {
        stakeAmount = uint96(bound(uint256(stakeAmount), 1e18, 100_000e18));
        funding = uint96(bound(uint256(funding), 1e6, 1_000_000e6));
        handler.stake(0, stakeAmount);
        handler.fund(funding);
        handler.advanceTime(7 days);
        handler.rewardTransferFailure(0, funding, 2 + mode % 2);
        uint256 owed = pool.earned(handler.actors(0));
        assertGt(owed, 0);
        handler.withdrawWithBlockedRewards(0, stakeAmount);
        assertEq(pool.balanceOf(handler.actors(0)), 0);
        assertEq(pool.earned(handler.actors(0)), owed, "exit destroyed the unpaid claim");
        handler.claim(0, false);
        assertEq(stock.balanceOf(handler.actors(0)), owed);
        _assertLedger();
    }
}
