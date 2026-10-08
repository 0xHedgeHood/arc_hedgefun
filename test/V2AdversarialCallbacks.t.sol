// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";
import {HedgeFunBondingCurve as Curve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter as Router} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {HedgeFunV2NativeRouter as NativeRouter, IWrappedNative} from "../src/v2/HedgeFunV2NativeRouter.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";
import {V2RouterPool, V2RouterRegistry} from "./V2TradeRouter.t.sol";
import {V2WrappedNative} from "./V2NativeRouter.t.sol";
import {CallbackStockV2} from "./V2CurveSecurity.t.sol";

/// A local payout recipient that either rejects payment or attempts the same nested sell once.
contract V2CallbackRecipient {
    NativeRouter internal immutable adapter;
    bool public tryNested;
    bool public rejectPayment;
    bytes internal nestedCall;
    uint256 public payments;
    uint256 public paid;
    bool public nestedSucceeded;
    bytes4 public rejection;

    constructor(NativeRouter adapter_, IERC20 token) {
        adapter = adapter_;
        token.approve(address(adapter_), type(uint256).max);
    }
    function configure(bool nested, bool reject, bytes calldata data) external {
        tryNested = nested;
        rejectPayment = reject;
        nestedCall = data;
    }
    function sell(Router.TradeParams calldata p, Router.Hop[] calldata path) external returns (uint256 out) {
        (out,) = adapter.sell(p, path);
    }
    receive() external payable {
        require(msg.sender == address(adapter), "unexpected payer");
        require(!rejectPayment, "payment rejected");
        payments++;
        paid += msg.value;
        if (tryNested) {
            bytes memory reason;
            (nestedSucceeded, reason) = address(adapter).call(nestedCall);
            if (reason.length >= 4) rejection = bytes4(reason);
        }
    }
}

/// Local ERC20 callback model. The nested call is bounded to the router currently receiving a payment.
contract V2CallbackPayment is ERC20 {
    address public router;
    address public payer;
    bool public enabled;
    bytes internal nestedCall;
    uint256 public attempts;
    bool public nestedSucceeded;
    bytes4 public rejection;

    constructor() ERC20("Callback payment", "CBPAY") {}
    function mint(address who, uint256 amount) external { _mint(who, amount); }
    function configure(address router_, address payer_, bool enabled_, bytes calldata call_) external {
        router = router_; payer = payer_; enabled = enabled_; nestedCall = call_;
    }
    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (enabled && from == payer && to == router) {
            attempts++;
            bytes memory reason;
            (nestedSucceeded, reason) = router.call(nestedCall);
            if (reason.length >= 4) rejection = bytes4(reason);
        }
    }
}

/// Defensive callback regression tests. All contracts and assets are created locally, with no RPC or fork.
contract V2AdversarialCallbacksTest is V2FactoryFixture {
    Router internal trade;
    NativeRouter internal adapter;
    V2WrappedNative internal wrapped;
    V2RouterPool internal venue;
    Curve internal curve;
    IERC20 internal token;
    V2CallbackRecipient internal recipient;
    uint256 internal strategyId;
    address internal alice = address(0xB0B);
    address internal bob = address(0xCA11);

    function setUp() public {
        _setUpV2(18);
        (strategyId, curve,) = _launchV2(true);
        token = IERC20(curve.token());
        trade = new Router(factory);
        wrapped = new V2WrappedNative();
        adapter = new NativeRouter(trade, IWrappedNative(address(wrapped)));
        venue = new V2RouterPool(address(wrapped), address(stock));
        v3f.set(address(wrapped), address(stock), venue.fee(), address(venue));
        vm.deal(address(this), 20_000 ether);
        wrapped.deposit{value: 10_000 ether}();
        wrapped.transfer(address(venue), 9_000 ether);
        stock.mint(address(venue), 10_000 ether);
        recipient = new V2CallbackRecipient(adapter, token);
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.prank(alice); token.approve(address(adapter), type(uint256).max);
        vm.prank(bob); token.approve(address(adapter), type(uint256).max);
    }

    function _params(uint256 amount, uint8 stage) internal view returns (Router.TradeParams memory) {
        return Router.TradeParams(strategyId, address(wrapped), amount, 0, 1, block.timestamp, stage, true);
    }
    function _path(bool buying) internal view returns (Router.Hop[] memory path) {
        path = new Router.Hop[](1);
        path[0] = Router.Hop(address(venue), buying ? address(stock) : address(wrapped));
    }
    function _buy(address who, uint256 amount, uint8 stage) internal returns (uint256 bought) {
        vm.prank(who);
        (bought,) = adapter.buy{value: amount}(_params(amount, stage), _path(true));
    }
    function _walletHash(address who) internal view returns (bytes32) {
        return keccak256(abi.encode(who.balance, token.balanceOf(who), stock.balanceOf(who),
            wrapped.balanceOf(who), token.allowance(who, address(adapter)), wrapped.allowance(who, address(trade))));
    }
    function _custodyHash(address who) internal view returns (bytes32) {
        return keccak256(abi.encode(_walletHash(who), stock.allowance(who, address(curve)),
            token.allowance(who, address(curve)), token.allowance(who, address(trade))));
    }
    function _stateHash() internal view returns (bytes32) {
        bytes32 traders = keccak256(abi.encode(_walletHash(alice), _walletHash(bob), _walletHash(address(recipient))));
        bytes32 custodians = keccak256(abi.encode(_custodyHash(address(trade)), _custodyHash(address(adapter)),
            _walletHash(address(venue)), _walletHash(address(factory)), _walletHash(address(pm))));
        bytes32 curveState = keccak256(abi.encode(curve.status(), curve.realStockReserve(), curve.tokenReserve(),
            curve.totalFees(), curve.claimable(protocol), curve.claimable(address(this)), curve.claimable(curve.treasury()),
            token.totalSupply(), _walletHash(address(curve))));
        return keccak256(abi.encode(traders, custodians, curveState));
    }
    function _assertTemporaryApprovalsClear() internal view {
        assertEq(wrapped.allowance(address(adapter), address(trade)), 0);
        assertEq(token.allowance(address(adapter), address(trade)), 0);
        assertEq(stock.allowance(address(trade), address(curve)), 0);
        assertEq(token.allowance(address(trade), address(curve)), 0);
    }

    function testUnauthorizedAndIdleTrustedCallbacksPreserveAllBalances() public {
        _buy(alice, 10 ether, 0);
        bytes32 beforeState = _stateHash();
        vm.prank(bob); vm.expectRevert(Router.NotThePool.selector);
        trade.uniswapV3SwapCallback(1, -1, "");
        assertEq(_stateHash(), beforeState);
        vm.prank(address(venue)); vm.expectRevert(Router.NotThePool.selector);
        trade.uniswapV3SwapCallback(1, -1, abi.encode(alice));
        assertEq(_stateHash(), beforeState);
        vm.prank(bob); vm.expectRevert(Router.NotPoolManager.selector);
        trade.unlockCallback("");
        assertEq(_stateHash(), beforeState);
        vm.prank(address(pm)); vm.expectRevert(Router.NotPoolManager.selector);
        trade.unlockCallback(abi.encode(alice));
        assertEq(_stateHash(), beforeState);
        assertGt(_buy(bob, 5 ether, 0), 0);
        _assertTemporaryApprovalsClear();
    }

    function testInvalidCanonicalCallbacksRollbackAlongsideNormalUsers() public {
        uint256 got = _buy(alice, 10 ether, 0);
        vm.prank(alice); token.transfer(address(trade), got / 100);
        wrapped.transfer(address(trade), 11 ether);
        stock.transfer(address(trade), 13 ether);
        V2RouterPool.Mode[6] memory modes = [V2RouterPool.Mode.Overcharge, V2RouterPool.Mode.BothPositive,
            V2RouterPool.Mode.WrongDirection, V2RouterPool.Mode.Twice, V2RouterPool.Mode.NoPay, V2RouterPool.Mode.ShortOutput];
        for (uint256 i; i < modes.length; i++) {
            venue.setMode(modes[i]);
            bytes32 beforeState = _stateHash();
            vm.prank(bob); vm.expectRevert();
            adapter.buy{value: 5 ether}(_params(5 ether, 0), _path(true));
            assertEq(_stateHash(), beforeState, "failed callback changed user/reserve/donation accounting");
            _assertTemporaryApprovalsClear();
        }
        venue.setMode(V2RouterPool.Mode.Normal);
        assertGt(_buy(bob, 5 ether, 0), 0);
        assertEq(token.balanceOf(alice), got - got / 100);
        assertEq(token.balanceOf(address(trade)), got / 100);
        assertEq(wrapped.balanceOf(address(trade)), 11 ether);
        assertEq(stock.balanceOf(address(trade)), 13 ether);
    }

    function testNativePayoutCallbackCannotRepeatPaymentAndMatchesControl() public {
        uint256 bought = _buy(alice, 10 ether, 0);
        vm.prank(alice); token.transfer(address(recipient), bought);
        Router.TradeParams memory p = _params(bought / 2, 0);
        Router.Hop[] memory path = _path(false);
        uint256 checkpoint = vm.snapshotState();
        uint256 controlOut = recipient.sell(p, path);
        bytes32 controlState = _stateHash();
        vm.revertToState(checkpoint);
        recipient.configure(true, false, abi.encodeCall(NativeRouter.sell, (p, path)));
        uint256 out = recipient.sell(p, path);
        assertEq(out, controlOut);
        assertEq(_stateHash(), controlState, "nested payout call changed the successful trade");
        assertEq(recipient.payments(), 1);
        assertEq(recipient.paid(), out);
        assertFalse(recipient.nestedSucceeded());
        assertEq(recipient.rejection(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(address(recipient).balance, out);
        assertEq(token.balanceOf(address(recipient)), bought - bought / 2);
        _assertTemporaryApprovalsClear();
        assertGt(_buy(bob, 5 ether, 0), 0);
    }

    function testRejectedNativePayoutRollsBackFeesReservesAndTemporaryApproval() public {
        uint256 bought = _buy(alice, 10 ether, 0);
        vm.prank(alice); token.transfer(address(recipient), bought);
        recipient.configure(false, true, "");
        bytes32 beforeState = _stateHash();
        vm.expectRevert(NativeRouter.NativeTransferFailed.selector);
        recipient.sell(_params(bought / 2, 0), _path(false));
        assertEq(_stateHash(), beforeState);
        assertEq(recipient.payments(), 0);
        _assertTemporaryApprovalsClear();
        recipient.configure(false, false, "");
        assertGt(recipient.sell(_params(bought / 2, 0), _path(false)), 0);
        _assertTemporaryApprovalsClear();
    }

    function testUnexpectedNativeReceiveCannotCreditOrChangeOtherTrades() public {
        _buy(alice, 10 ether, 0);
        bytes32 beforeState = _stateHash();
        vm.prank(bob);
        (bool ok, bytes memory reason) = address(adapter).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(bytes4(reason), NativeRouter.BadPayment.selector);
        assertEq(_stateHash(), beforeState);
        assertGt(_buy(bob, 5 ether, 0), 0);
        _assertTemporaryApprovalsClear();
    }

    function testStaleStageAfterAnotherUserGraduatesRollsBackWrapping() public {
        _buy(alice, 500 ether, 0);
        assertEq(uint256(curve.status()), uint256(Curve.Status.Graduated));
        bytes32 beforeState = _stateHash();
        vm.prank(bob); vm.expectRevert(abi.encodeWithSelector(Router.StageChanged.selector, uint8(2)));
        adapter.buy{value: 5 ether}(_params(5 ether, 0), _path(true));
        assertEq(_stateHash(), beforeState);
        assertGt(_buy(bob, 5 ether, 2), 0);
        _assertTemporaryApprovalsClear();
    }

    function testPaymentTokenReentryIsRejectedWithoutChangingControlResult() public {
        V2CallbackPayment payment = new V2CallbackPayment();
        V2RouterPool paymentVenue = new V2RouterPool(address(payment), address(stock));
        v3f.set(address(payment), address(stock), paymentVenue.fee(), address(paymentVenue));
        payment.mint(address(paymentVenue), 1_000 ether);
        stock.mint(address(paymentVenue), 1_000 ether);
        payment.mint(alice, 20 ether);
        vm.prank(alice); payment.approve(address(trade), 20 ether);
        Router.TradeParams memory p = _params(5 ether, 0);
        p.asset = address(payment);
        Router.Hop[] memory path = new Router.Hop[](1);
        path[0] = Router.Hop(address(paymentVenue), address(stock));
        uint256 checkpoint = vm.snapshotState();
        vm.prank(alice); (uint256 controlOut,) = trade.buy(p, path);
        bytes32 controlState = _stateHash();
        vm.revertToState(checkpoint);
        payment.configure(address(trade), alice, true, abi.encodeCall(Router.buy, (p, path)));
        vm.prank(alice); (uint256 out,) = trade.buy(p, path);
        assertEq(out, controlOut);
        assertEq(_stateHash(), controlState);
        assertEq(payment.attempts(), 1);
        assertFalse(payment.nestedSucceeded());
        assertEq(payment.rejection(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(payment.balanceOf(alice), 15 ether);
        assertEq(payment.balanceOf(address(trade)), 0);
        assertEq(payment.allowance(address(trade), address(paymentVenue)), 0);
        _assertTemporaryApprovalsClear();
    }

    function testCurveCallbackClaimsCannotChangeAnotherUsersFeeRights() public {
        CallbackStockV2 callbackStock = new CallbackStockV2();
        V2RouterRegistry registry = new V2RouterRegistry(pm, v3f);
        HedgeFunToken t = new HedgeFunToken("Callback strategy", "CB", 1_000_000 ether, address(this), address(this));
        Curve c = new Curve(Curve.Init(address(registry), address(t), address(callbackStock), bob, protocol,
            alice, 1_000_000 ether, 100 ether, 8000, 1000, 2000, 1000, 0, 0, new address[](0)));
        registry.set(address(t), address(callbackStock), address(0), address(c));
        t.transfer(address(c), 1_000_000 ether);
        callbackStock.mint(alice, 1_000 ether);
        vm.prank(alice); callbackStock.approve(address(c), type(uint256).max);
        vm.prank(alice); t.approve(address(c), type(uint256).max);
        vm.prank(alice); (, uint256 bought) = c.buy(10 ether, 1, alice, block.timestamp);
        vm.prank(alice); c.sell(bought / 4, 1, alice, block.timestamp);
        uint256 checkpoint = vm.snapshotState();
        vm.prank(alice); uint256 normalOut = c.sell(bought / 4, 1, alice, block.timestamp);
        uint256 normalFees = c.totalFees();
        uint256 normalBobClaim = c.claimable(bob);
        uint256 normalReserve = c.realStockReserve();
        vm.revertToState(checkpoint);
        callbackStock.arm(address(c));
        vm.prank(alice); uint256 callbackOut = c.sell(bought / 4, 1, alice, block.timestamp);
        assertEq(callbackOut, normalOut);
        assertEq(c.totalFees(), normalFees);
        assertEq(c.claimable(bob), normalBobClaim);
        assertEq(c.realStockReserve(), normalReserve);
        assertFalse(callbackStock.reentrySucceeded());
        assertEq(callbackStock.rejection(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(callbackStock.balanceOf(bob), 0);
        c.claimFees(bob);
        assertEq(callbackStock.balanceOf(bob), normalBobClaim);
        assertEq(c.claimable(bob), 0);
        assertEq(callbackStock.balanceOf(address(c)), c.realStockReserve() + c.totalFees());
    }
}
