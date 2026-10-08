// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestnetV2KeeperReward} from "../script/testnet/TestnetV2KeeperReward.s.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunV2EngineTreasury} from "../src/v2/HedgeFunV2EngineTreasury.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";

// Give each fixed role a real call frame: Foundry cannot startBroadcast while a prank is active.
// Etching these invokers occurs only on this local fork, never in a production phase.
contract KeeperRewardRoleInvoker {
    function append(TestnetV2KeeperReward s) external { s.appendEngine(); }
    function launch(TestnetV2KeeperReward s, bool buy) external returns (uint256) {
        return buy ? s.launchBuy() : s.launchSell();
    }
    function graduate(TestnetV2KeeperReward s, bool buy) external {
        if (buy) s.graduateBuy(); else s.graduateSell();
    }
    function execute(TestnetV2KeeperReward s, bool buy) external {
        if (buy) s.executeBuy(); else s.executeSell();
    }
}

contract TestnetV2KeeperRewardTest is Test {
    TestnetV2KeeperReward internal tool;

    function setUp() public { tool = new TestnetV2KeeperReward(); }

    function test_wrongChainFailsBeforeSchedulingTransactions() public {
        vm.chainId(1);
        vm.prank(tool.OPERATOR());
        vm.expectRevert(abi.encodeWithSelector(TestnetV2KeeperReward.WrongChain.selector, 1));
        tool.appendEngine();
    }

    function test_wrongOwnerCannotAppend() public {
        vm.chainId(46630);
        vm.expectRevert(abi.encodeWithSelector(TestnetV2KeeperReward.WrongSender.selector, address(this)));
        tool.appendEngine();
    }

    function test_missingPinnedCoreFailsBeforeSchedulingTransactions() public {
        vm.chainId(46630);
        vm.prank(tool.OPERATOR());
        vm.expectRevert(TestnetV2KeeperReward.BadBinding.selector);
        tool.appendEngine();
    }

    function test_rewardRecipientsAreFixedByPhase() public {
        vm.expectRevert(abi.encodeWithSelector(TestnetV2KeeperReward.WrongSender.selector, address(this)));
        tool.executeSell();
        vm.expectRevert(abi.encodeWithSelector(TestnetV2KeeperReward.WrongSender.selector, address(this)));
        tool.executeBuy();
        vm.expectRevert(abi.encodeWithSelector(TestnetV2KeeperReward.WrongSender.selector, address(this)));
        tool.launchBuy();
    }

    function test_rewardFrictionBoundaryIsCheckedDespiteOldRegistry() public {
        tool.checkFriction(100, 30, 50); // actual listing: minimum 360; fixed band 500
        tool.checkFriction(170, 30, 50); // exactly 500
        vm.expectRevert(TestnetV2KeeperReward.BadFriction.selector);
        tool.checkFriction(171, 30, 50); // old registry's bounty-free floor is only 402
    }

    /// @dev Opt-in, public RPC, entirely local fork. Never reads a key or broadcasts to the network.
    function test_fork_allSevenPhasesPayTwoDifferentKeepersAndPreserveOldEngine() public {
        if (!vm.envOr("KEEPER_REWARD_FORK", false)) { vm.skip(true); return; }
        vm.createSelectFork("https://rpc.testnet.chain.robinhood.com", vm.envOr("KEEPER_REWARD_FORK_BLOCK", uint256(126884377)));
        tool = new TestnetV2KeeperReward();
        bytes memory invoker = address(new KeeperRewardRoleInvoker()).code;
        vm.etch(tool.OPERATOR(), invoker);
        vm.etch(tool.CREATOR(), invoker);
        vm.etch(tool.SECOND(), invoker);
        vm.setEnv("GIT_COMMIT", "1111111111111111111111111111111111111111"); // explicitly unverified fixture candidate
        V2TreasuryDeployer registry = V2TreasuryDeployer(tool.REGISTRY());
        (address oldA, address oldB) = registry.kinds(2);
        (, , bytes32 oldHash,) = registry.kindManifest(2);
        KeeperRewardRoleInvoker(tool.OPERATOR()).append(tool);
        assertEq(registry.kindCount(), 4);
        assertEq(KeeperRewardRoleInvoker(tool.CREATOR()).launch(tool, false), 1);
        KeeperRewardRoleInvoker(tool.CREATOR()).graduate(tool, false);
        HedgeFunV2Factory factory = HedgeFunV2Factory(tool.FACTORY());
        (, address sellTreasury,,,) = factory.strategies(1);
        IERC20 usdg = IERC20(factory.usdg());
        uint256 callerUsdg = usdg.balanceOf(tool.SECOND());
        KeeperRewardRoleInvoker(tool.SECOND()).execute(tool, false);
        assertGt(usdg.balanceOf(tool.SECOND()), callerUsdg);
        assertEq(HedgeFunV2EngineTreasury(sellTreasury).strategyNonce(), 1);
        assertEq(KeeperRewardRoleInvoker(tool.CREATOR()).launch(tool, true), 2);
        KeeperRewardRoleInvoker(tool.CREATOR()).graduate(tool, true);
        (, address buyTreasury,, address stock,) = factory.strategies(2);
        uint256 callerStock = IERC20(stock).balanceOf(tool.OPERATOR());
        KeeperRewardRoleInvoker(tool.OPERATOR()).execute(tool, true);
        assertGt(IERC20(stock).balanceOf(tool.OPERATOR()), callerStock);
        assertEq(HedgeFunV2EngineTreasury(buyTreasury).strategyNonce(), 1);
        (address a, address b) = registry.kinds(2);
        (, , bytes32 hash,) = registry.kindManifest(2);
        assertEq(a, oldA); assertEq(b, oldB); assertEq(hash, oldHash);
    }
}
