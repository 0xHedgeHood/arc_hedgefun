// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {V2LaunchFeeDefaults} from "../script/testnet/V2LaunchFeeDefaults.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

contract V2LaunchFeesTest is V2FactoryFixture {
    uint256 constant FEE = 0.0005 ether;

    function setUp() public {
        _setUpV2(18);
        vm.deal(address(this), 1 ether);
    }

    function _configure() private {
        HedgeFunFactory.Defaults memory before_ = factory.getDefaults();
        HedgeFunFactory.Defaults memory next = V2LaunchFeeDefaults.applyTo(factory.getDefaults());
        vm.prank(owner);
        factory.setDefaults(next);
        HedgeFunFactory.Defaults memory after_ = factory.getDefaults();
        assertEq(after_.lpFee, 2000);
        assertEq(after_.protocolBps, 3000);
        assertEq(after_.buybackCooldown, 10);
        assertEq(after_.maxCreatorBps, 5000);
        assertEq(uint8(after_.launchFeeCurrency), uint8(HedgeFunFactory.FeeCurrency.Native));
        assertEq(after_.launchFeeAmount, FEE);
        after_.lpFee = before_.lpFee;
        after_.protocolBps = before_.protocolBps;
        after_.buybackCooldown = before_.buybackCooldown;
        after_.maxCreatorBps = before_.maxCreatorBps;
        after_.launchFeeCurrency = before_.launchFeeCurrency;
        after_.launchFeeAmount = before_.launchFeeAmount;
        assertEq(keccak256(abi.encode(after_)), keccak256(abi.encode(before_)), "all other defaults preserved");
    }

    function _paidLaunch(uint16 creatorBps) private {
        HedgeFunFactory.Request memory q = _request();
        q.taxBps = 100;
        q.creatorBps = creatorBps;
        q.maxFee = FEE;
        (,, bytes32 terms) = factory.predict(q);
        uint256 recipientBefore = protocol.balance;
        uint256 usdgBefore = usdg.balanceOf(address(this));
        uint256 id = factory.launch{value: FEE}(q, terms);
        assertEq(protocol.balance - recipientBefore, FEE);
        assertEq(address(factory).balance, 0);
        assertEq(usdg.balanceOf(address(this)), usdgBefore);
        assertEq(usdg.allowance(address(this), address(factory)), 0, "no ERC20 fee approval needed");
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        assertEq(curve.creatorBps(), creatorBps);
        assertEq(curve.taxBps(), 100);
        assertEq(curve.protocolBps(), 3000);
    }

    function test_zeroCreatorSharePaysNativeFee() public { _configure(); _paidLaunch(0); }
    function test_tenPercentCreatorSharePaysNativeFee() public { _configure(); _paidLaunch(1000); }

    function testFuzz_creatorShareAboveHalfRejected(uint16 bps) public {
        _configure();
        HedgeFunFactory.Request memory q = _request();
        q.creatorBps = uint16(bound(bps, 5001, 10000));
        vm.expectRevert(HedgeFunFactory.BadRequest.selector);
        factory.launch{value: FEE}(q, bytes32(0));
    }

    function test_wrongNativeValueAndFeeCeilingRejected() public {
        _configure();
        HedgeFunFactory.Request memory q = _request();
        (,, bytes32 terms) = factory.predict(q);
        vm.expectRevert(HedgeFunFactory.BadRequest.selector);
        factory.launch(q, terms);
        vm.expectRevert(HedgeFunFactory.BadRequest.selector);
        factory.launch{value: FEE - 1}(q, terms);
        vm.expectRevert(HedgeFunFactory.BadRequest.selector);
        factory.launch{value: FEE + 1}(q, terms);
        q.maxFee = FEE - 1;
        vm.expectRevert(HedgeFunFactory.Restated.selector);
        factory.launch{value: FEE}(q, terms);
    }

    function test_oldLaunchKeepsThirtyPercentAndOldQuoteCannotBeUsed() public {
        HedgeFunFactory.Request memory q = _request();
        q.creatorBps = 3000;
        (,, bytes32 terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        bytes32 frozen = _frozenHash(id);
        q.creatorBps = 1000;
        q.nonce = 1;
        (,, bytes32 oldQuote) = factory.predict(q);
        _configure();
        assertEq(curve.creatorBps(), 3000);
        assertEq(_frozenHash(id), frozen);
        vm.expectRevert(HedgeFunFactory.Restated.selector);
        factory.launch{value: FEE}(q, oldQuote);
    }

    function _frozenHash(uint256 id) private view returns (bytes32) {
        (bool ok, bytes memory data) = address(factory).staticcall(abi.encodeWithSignature("graduationConfig(uint256)", id));
        require(ok);
        return keccak256(data);
    }

    function test_onlyOwnerCanChangeFees() public {
        HedgeFunFactory.Defaults memory next = V2LaunchFeeDefaults.applyTo(factory.getDefaults());
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(this)));
        factory.setDefaults(next);
    }
}
