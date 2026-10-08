// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {ConfigureV2LaunchFees} from "../script/testnet/ConfigureV2LaunchFees.s.sol";
import {TestnetMarket} from "../script/testnet/TestnetMarket.sol";
import {TestnetForkVenue} from "./utils/TestnetForkVenue.sol";

contract LaunchFeeOperatorInvoker {
    function run(ConfigureV2LaunchFees script) external { script.run(); }
}

/// Opt-in, pinned public-testnet fork. No signing or broadcast to the public chain.
contract TestnetV2LaunchFeesForkTest is Test {
    HedgeFunV2Factory constant FACTORY = HedgeFunV2Factory(0x6847318D28aB2f9343DDd2067871DC4f48609383);
    uint256 constant FEE = 0.0005 ether;

    function test_forkConfigurePreservesDefaultsAndAcceptsNativeLaunch() public {
        vm.skip(!vm.envOr("LAUNCH_FEES_FORK", false), "set LAUNCH_FEES_FORK=true");
        uint256 forkBlock = vm.envUint("LAUNCH_FEES_FORK_BLOCK");
        vm.createSelectFork(
            vm.envOr("LAUNCH_FEES_FORK_RPC", string("https://rpc.testnet.chain.robinhood.com")),
            forkBlock
        );
        assertEq(block.chainid, 46630);
        emit log_named_uint("requested fork block", forkBlock);
        HedgeFunFactory.Defaults memory before_ = FACTORY.getDefaults();
        (bool ok, bytes memory frozenBefore) = address(FACTORY).staticcall(abi.encodeWithSignature("graduationConfig(uint256)", 0));
        assertTrue(ok);
        address operator = FACTORY.owner();
        vm.setEnv("V2_FACTORY", vm.toString(address(FACTORY)));
        vm.setEnv("OPERATOR", vm.toString(operator));
        vm.setEnv("EXPECTED_DEFAULTS_HASH", vm.toString(keccak256(abi.encode(before_))));
        vm.etch(operator, type(LaunchFeeOperatorInvoker).runtimeCode);
        LaunchFeeOperatorInvoker(operator).run(new ConfigureV2LaunchFees());
        HedgeFunFactory.Defaults memory after_ = FACTORY.getDefaults();
        assertEq(after_.lpFee, 2000);
        assertEq(after_.protocolBps, 3000);
        assertEq(after_.buybackCooldown, 10);
        assertEq(after_.maxCreatorBps, 5000);
        assertEq(uint8(after_.launchFeeCurrency), 1);
        assertEq(after_.launchFeeAmount, FEE);
        after_.lpFee = before_.lpFee;
        after_.protocolBps = before_.protocolBps;
        after_.buybackCooldown = before_.buybackCooldown;
        after_.maxCreatorBps = before_.maxCreatorBps;
        after_.launchFeeCurrency = before_.launchFeeCurrency;
        after_.launchFeeAmount = before_.launchFeeAmount;
        assertEq(keccak256(abi.encode(after_)), keccak256(abi.encode(before_)));
        _assertFrozen(frozenBefore);
        _launch(0);
        _launch(1000);
    }

    function _assertFrozen(bytes memory expected) private view {
        (bool ok, bytes memory data) = address(FACTORY).staticcall(abi.encodeWithSignature("graduationConfig(uint256)", 0));
        require(ok && keccak256(data) == keccak256(expected), "existing launch changed");
    }

    function _launch(uint16 share) private {
        address creator = makeAddr("native fee fork creator");
        HedgeFunFactory.Request memory q;
        q.name = "Native Fee Fork Test";
        q.symbol = "NATIVEFEE";
        q.stock = TestnetForkVenue.listedStock(FACTORY, TestnetMarket(vm.envOr("TESTNET_MARKET", address(0xc1AF2f52980F8A7AA4E90A8E30D5c3FaF0375f21))));
        q.creator = creator;
        q.taxBps = 100;
        q.creatorBps = share;
        q.tp1Bps = 500;
        q.tp2Bps = 1000;
        q.dipBps = 500;
        q.lotBps = 2000;
        q.nonce = uint96(FACTORY.strategyCount() + 1000000);
        q.maxFee = FEE;
        (,, q.expectedOpenPriceE18,) = FACTORY.listings(q.stock);
        (,, bytes32 terms) = FACTORY.predict(q);
        uint256 protocolBefore = FACTORY.protocol().balance;
        vm.deal(creator, FEE + 1);
        vm.startPrank(creator);
        vm.expectRevert(HedgeFunFactory.BadRequest.selector);
        FACTORY.launch(q, terms);
        vm.expectRevert(HedgeFunFactory.BadRequest.selector);
        FACTORY.launch{value: FEE + 1}(q, terms);
        q.creatorBps = 5001;
        vm.expectRevert(HedgeFunFactory.BadRequest.selector);
        FACTORY.launch{value: FEE}(q, terms);
        q.creatorBps = share;
        uint256 id = FACTORY.launch{value: FEE}(q, terms);
        vm.stopPrank();
        assertEq(FACTORY.protocol().balance - protocolBefore, FEE);
        assertEq(creator.balance, 1);
        assertEq(IERC20(FACTORY.usdg()).allowance(creator, address(FACTORY)), 0);
        assertEq(HedgeFunBondingCurve(FACTORY.curves(id)).creatorBps(), share);
        assertEq(HedgeFunBondingCurve(FACTORY.curves(id)).taxBps(), 100);
    }
}
