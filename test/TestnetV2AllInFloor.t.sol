// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TestnetV2AllInFloor} from "../script/testnet/TestnetV2AllInFloor.s.sol";
import {V2CreatorParams} from "../src/v2/strategy/V2CreatorParams.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";

contract AllInFloorRoleInvoker {
    function append(TestnetV2AllInFloor tool) external { tool.appendPlain(); }
    function launch(TestnetV2AllInFloor tool) external returns (uint256) { return tool.launchPlain(); }
    function graduate(TestnetV2AllInFloor tool) external { tool.graduatePlain(); }
}

contract TestnetV2AllInFloorTest is Test {
    TestnetV2AllInFloor private tool;
    function setUp() public { tool = new TestnetV2AllInFloor(); }

    function test_wrongChainBeforeScheduling() public {
        vm.chainId(1); vm.prank(tool.OPERATOR());
        vm.expectRevert(abi.encodeWithSelector(TestnetV2AllInFloor.WrongChain.selector, 1));
        tool.appendPlain();
    }
    function test_wrongSenderCannotAppend() public {
        vm.expectRevert(abi.encodeWithSelector(TestnetV2AllInFloor.WrongSender.selector, address(this)));
        tool.appendPlain();
    }
    function test_wrongCreatorCannotLaunch() public {
        vm.expectRevert(abi.encodeWithSelector(TestnetV2AllInFloor.WrongSender.selector, address(this)));
        tool.launchPlain();
    }
    function test_creatorRungsHaveOnlyStructuralValidation() public {
        tool.checkParameters(1,2,1,1);
        tool.checkParameters(1,0,1,0);
        vm.expectRevert(V2CreatorParams.BadConfig.selector);
        tool.checkParameters(0,2,1,1);
    }
    function test_forkAppendCreateGraduateOnUnchangedFeeCore() public {
        if (!vm.envOr("ALL_IN_FLOOR_FORK",false)) { vm.skip(true); return; }
        uint256 pin = vm.envUint("ALL_IN_FLOOR_FORK_BLOCK");
        vm.createSelectFork("https://rpc.testnet.chain.robinhood.com",pin);
        tool = new TestnetV2AllInFloor();
        emit log_named_uint("fork block",block.number);
        // The caller provides the reviewed revision; do not silently reuse a stale source pin.
        vm.envString("GIT_COMMIT");
        address owner = tool.OPERATOR(); address creator = tool.CREATOR();
        bytes memory roleCode = address(new AllInFloorRoleInvoker()).code;
        vm.etch(owner,roleCode); vm.etch(creator,roleCode);
        bytes32 factoryHash = tool.FACTORY().codehash;
        bytes32 registryHash = tool.REGISTRY().codehash;
        AllInFloorRoleInvoker(owner).append(tool);
        assertEq(V2TreasuryDeployer(tool.REGISTRY()).kindCount(),5);
        assertEq(AllInFloorRoleInvoker(creator).launch(tool),3);
        AllInFloorRoleInvoker(creator).graduate(tool);
        assertEq(HedgeFunV2Factory(tool.FACTORY()).strategyCount(),4);
        assertEq(tool.FACTORY().codehash,factoryHash);
        assertEq(tool.REGISTRY().codehash,registryHash);
    }
}
