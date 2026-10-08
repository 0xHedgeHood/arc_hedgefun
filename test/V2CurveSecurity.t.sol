// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockToken} from "./mocks/Mocks.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";

contract CallbackStockV2 is MockToken {
    address public target;
    bool public callbackEnabled;
    bool public reentrySucceeded;
    bytes4 public rejection;
    constructor() MockToken("STOCK", 18) {}
    function arm(address target_) external { target = target_; callbackEnabled = true; }
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (callbackEnabled && to == target) {
            (bool ok, bytes memory reason) = target.call(abi.encodeCall(HedgeFunBondingCurve.claimFees, (from)));
            reentrySucceeded = ok;
            if (reason.length >= 4) rejection = bytes4(reason);
        }
        return super.transferFrom(from, to, amount);
    }
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (callbackEnabled && msg.sender == target) {
            (bool ok, bytes memory reason) = target.call(abi.encodeCall(HedgeFunBondingCurve.claimFees, (to)));
            reentrySucceeded = ok;
            if (reason.length >= 4) rejection = bytes4(reason);
        }
        return super.transfer(to, amount);
    }
}

contract V2CurveSecurityTest is Test {
    CallbackStockV2 internal stock;
    HedgeFunToken internal token;
    HedgeFunBondingCurve internal curve;
    address internal user = address(0xA11CE);
    address internal role = address(0xBEEF);
    uint256 released;
    function graduateCurve() external {
        require(msg.sender == address(curve));
        (released,) = curve.release();
    }
    function setUp() public {
        stock = new CallbackStockV2();
        token = new HedgeFunToken("Curve", "CURVE", 1_000_000e18, address(this), address(this));
        curve = new HedgeFunBondingCurve(HedgeFunBondingCurve.Init({
            factory: address(this), token: address(token), stock: address(stock),
            treasury: role, protocol: role, creator: role, supply: 1_000_000e18, virtualStock: 100e18,
            saleBps: 8000, taxBps: 1000, protocolBps: 1000, creatorBps: 2000,
            snipeBps: 0, snipeSeconds: 0, openingTaxExemptions: new address[](0)
        }));
        token.transfer(address(curve), 1_000_000e18);
        stock.mint(user, 10_000e18);
        vm.startPrank(user);
        stock.approve(address(curve), type(uint256).max);
        token.approve(address(curve), type(uint256).max);
        vm.stopPrank();
    }
    function _buyAndSell() internal {
        vm.prank(user);
        (, uint256 got) = curve.buy(10e18, 1, user, block.timestamp);
        vm.prank(user);
        curve.sell(got / 2, 1, user, block.timestamp);
    }
    function test_sharedRecipientsPreserveAllFeeLiabilities() public {
        _buyAndSell();
        uint256 fee = curve.totalFees();
        assertGt(fee, 0);
        assertEq(curve.claimable(role), fee);
        uint256 reserve = curve.realStockReserve();
        curve.claimFees(role);
        assertEq(stock.balanceOf(role), fee);
        assertEq(curve.totalFees(), 0);
        assertEq(curve.realStockReserve(), reserve);
        assertEq(stock.balanceOf(address(curve)), reserve);
    }
    function test_stockCallbackCannotClaimDuringBuySellOrClaim() public {
        stock.arm(address(curve));
        _buyAndSell();
        assertFalse(stock.reentrySucceeded());
        assertEq(stock.rejection(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        uint256 owed = curve.claimable(role);
        curve.claimFees(role);
        assertFalse(stock.reentrySucceeded());
        assertEq(stock.balanceOf(role), owed);
        assertEq(curve.claimable(role), 0);
        assertEq(stock.balanceOf(address(curve)), curve.realStockReserve());
    }
    function test_releaseCallbackCannotConsumeRemainingFees() public {
        _buyAndSell();
        stock.arm(address(curve));
        vm.prank(user);
        curve.buy(type(uint256).max, 1, user, block.timestamp);
        uint256 owed = curve.claimable(role);
        assertGt(released, 0);
        assertFalse(stock.reentrySucceeded());
        assertEq(stock.rejection(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(stock.balanceOf(address(curve)), owed);
        curve.claimFees(role);
        assertEq(stock.balanceOf(role), owed);
        assertEq(stock.balanceOf(address(curve)), 0);
    }
}
