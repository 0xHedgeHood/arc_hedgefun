// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";
import {V2RouterPool, V2RouterRegistry, V2RouterTreasury, V2RouterGraduated, V2RouterAsset} from "./V2TradeRouter.t.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter as Router} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {HedgeFunV2NativeRouter as NativeRouter, IWrappedNative} from "../src/v2/HedgeFunV2NativeRouter.sol";

contract V2WrappedNative is ERC20 {
    constructor() ERC20("Wrapped native", "WNATIVE") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }
}
contract NativeRejector {}

contract V2NativeRouterTest is V2FactoryFixture {
    Router internal trade;
    NativeRouter internal nativeRouter;
    V2WrappedNative internal wrapped;
    V2RouterPool internal venue;
    HedgeFunBondingCurve internal curve;
    IERC20 internal token;
    uint256 internal id;
    address internal alice = address(0xB0B);

    function setUp() public {
        _setUpV2(18);
        (id, curve,) = _launchV2(true);
        token = IERC20(curve.token());
        trade = new Router(factory);
        wrapped = new V2WrappedNative();
        nativeRouter = new NativeRouter(trade, IWrappedNative(address(wrapped)));
        venue = new V2RouterPool(address(wrapped), address(stock));
        v3f.set(address(wrapped), address(stock), venue.fee(), address(venue));
        vm.deal(address(this), 20_000 ether);
        wrapped.deposit{value: 10_000 ether}();
        wrapped.transfer(address(venue), 9_000 ether);
        stock.mint(address(venue), 10_000 ether);
        vm.deal(alice, 1_000 ether);
        vm.prank(alice);
        token.approve(address(nativeRouter), type(uint256).max);
    }

    function _params(uint256 amount, uint8 stage) internal view returns (Router.TradeParams memory) {
        return Router.TradeParams(id, address(wrapped), amount, 0, 1, block.timestamp, stage, true);
    }
    function _path(bool buy) internal view returns (Router.Hop[] memory path) {
        path = new Router.Hop[](1);
        path[0] = Router.Hop(address(venue), buy ? address(stock) : address(wrapped));
    }
    function _assertClean() internal view {
        assertEq(address(nativeRouter).balance, 0);
        assertEq(wrapped.balanceOf(address(nativeRouter)), 0);
        assertEq(stock.balanceOf(address(nativeRouter)), 0);
        assertEq(token.balanceOf(address(nativeRouter)), 0);
        assertEq(wrapped.allowance(address(nativeRouter), address(trade)), 0);
        assertEq(token.allowance(address(nativeRouter), address(trade)), 0);
    }

    function testNativeBuyAndSellThroughRealCurve() public {
        vm.prank(alice);
        (uint256 got,) = nativeRouter.buy{value: 10 ether}(_params(10 ether, 0), _path(true));
        assertEq(token.balanceOf(alice), got);
        assertEq(alice.balance, 990 ether);
        vm.prank(alice);
        (uint256 received, uint256 refund) = nativeRouter.sell(_params(got, 0), _path(false));
        assertGt(received, 0);
        assertEq(alice.balance, 990 ether + received);
        assertEq(refund, 0);
        assertEq(token.balanceOf(alice), 0);
        _assertClean();
    }

    function testNativeBuyUsesCallerAsOpeningTaxRecipient() public {
        HedgeFunFactory.Request memory q = _request();
        q.nonce = lastNonce + 1;
        factory.curveDeployer().setCurveConfig(q.symbol, q.nonce, 8000, 60);
        address[] memory list = new address[](1);
        list[0] = alice;
        factory.curveDeployer().setOpeningTaxExemptions(q.symbol, q.nonce, list);
        (,, bytes32 terms) = factory.predict(q);
        id = factory.launch(q, terms);
        curve = HedgeFunBondingCurve(factory.curves(id));
        token = IERC20(curve.token());
        uint256 stockGot = 10 ether * 997 / 1000;
        (, uint256 exemptOut,) = curve.quoteBuyFor(stockGot, alice);
        (, uint256 normalOut,) = curve.quoteBuyFor(stockGot, address(nativeRouter));
        assertGt(exemptOut, normalOut);
        Router.TradeParams memory p = _params(10 ether, 0);
        p.minFinalOut = exemptOut;
        vm.prank(alice);
        (uint256 got,) = nativeRouter.buy{value: 10 ether}(p, _path(true));
        assertEq(got, exemptOut);
        assertEq(token.balanceOf(alice), exemptOut);
        _assertClean();
    }

    function testNativeStockSlippageFloorRollsBackWrappingAndGraduation() public {
        Router.TradeParams memory p = _params(500 ether, 0);
        // The final curve output is capped at 400 stock; the upstream floor protects the refund too.
        p.minStockReceived = 499 ether;
        vm.prank(alice); vm.expectPartialRevert(Router.TooLittleStock.selector);
        nativeRouter.buy{value: 500 ether}(p, _path(true));
        assertEq(alice.balance, 1_000 ether);
        assertEq(uint256(curve.status()), 0);
        assertEq(curve.realStockReserve(), 0);
        _assertClean();
    }

    function testNativeFinalBuyRequiresRefundConsentThenTradesRealV4() public {
        Router.TradeParams memory p = _params(500 ether, 0);
        p.allowPartialFill = false;
        vm.prank(alice); vm.expectPartialRevert(Router.PartialFill.selector);
        nativeRouter.buy{value: 500 ether}(p, _path(true));
        assertEq(alice.balance, 1_000 ether);
        assertEq(uint256(curve.status()), 0);
        p.allowPartialFill = true;
        vm.prank(alice);
        (uint256 got, uint256 refund) = nativeRouter.buy{value: 500 ether}(p, _path(true));
        assertEq(uint256(curve.status()), 2);
        assertGt(refund, 0);
        assertEq(stock.balanceOf(alice), refund);
        vm.prank(alice);
        (uint256 proceeds,) = nativeRouter.sell(_params(got / 100, 2), _path(false));
        assertGt(proceeds, 0);
        vm.prank(alice);
        nativeRouter.buy{value: 1 ether}(_params(1 ether, 2), _path(true));
        _assertClean();
    }

    function testForcedNativeAndTokenDonationsAreNeverPaidToTraders() public {
        vm.deal(address(nativeRouter), 7 ether);
        wrapped.transfer(address(nativeRouter), 11 ether);
        stock.mint(address(nativeRouter), 13 ether);
        vm.prank(alice);
        (uint256 got,) = nativeRouter.buy{value: 10 ether}(_params(10 ether, 0), _path(true));
        vm.prank(alice); token.transfer(address(nativeRouter), got / 10);
        vm.prank(alice);
        nativeRouter.sell(_params(got - got / 10, 0), _path(false));
        assertEq(address(nativeRouter).balance, 7 ether);
        assertEq(wrapped.balanceOf(address(nativeRouter)), 11 ether);
        assertEq(stock.balanceOf(address(nativeRouter)), 13 ether);
        assertEq(token.balanceOf(address(nativeRouter)), got / 10);
    }

    function testRejectedNativePayoutRollsBackSell() public {
        address rejector = address(new NativeRejector());
        vm.prank(alice);
        (uint256 got,) = nativeRouter.buy{value: 10 ether}(_params(10 ether, 0), _path(true));
        vm.prank(alice); token.transfer(rejector, got);
        vm.prank(rejector); token.approve(address(nativeRouter), got);
        uint256 reserve = curve.realStockReserve();
        vm.prank(rejector); vm.expectRevert(NativeRouter.NativeTransferFailed.selector);
        nativeRouter.sell(_params(got, 0), _path(false));
        assertEq(token.balanceOf(rejector), got);
        assertEq(curve.realStockReserve(), reserve);
        _assertClean();
    }

    function testPaymentAssetAmountAndUnsolicitedNativeChecks() public {
        Router.TradeParams memory p = _params(10 ether, 0);
        vm.prank(alice); vm.expectRevert(NativeRouter.BadPayment.selector);
        nativeRouter.buy{value: 1 ether}(p, _path(true));
        p.asset = address(stock);
        vm.prank(alice); vm.expectRevert(NativeRouter.BadPayment.selector);
        nativeRouter.buy{value: 10 ether}(p, _path(true));
        vm.prank(alice);
        (bool ok,) = address(nativeRouter).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(alice.balance, 1_000 ether);
        _assertClean();
    }

    function testWrappedNativeQuoteRefundIsUnwrappedOnce() public {
        V2RouterRegistry registry = new V2RouterRegistry(pm, v3f);
        HedgeFunToken t = new HedgeFunToken("Wrapped quote", "WQ", 1_000_000e18, address(this), address(this));
        HedgeFunBondingCurve c = new HedgeFunBondingCurve(HedgeFunBondingCurve.Init(
            address(registry), address(t), address(wrapped), address(0x71), address(0x72), address(0x73),
            1_000_000e18, 100 ether, 8000, 1000, 2000, 1000, 0, 0, new address[](0)));
        t.transfer(address(c), 1_000_000e18);
        registry.set(address(t), address(wrapped), address(0), address(c));
        trade = new Router(HedgeFunFactory(address(registry)));
        nativeRouter = new NativeRouter(trade, IWrappedNative(address(wrapped)));
        wrapped.transfer(address(nativeRouter), 11 ether);
        vm.deal(address(nativeRouter), 7 ether);
        Router.Hop[] memory empty = new Router.Hop[](0);
        (uint256 expectedSpent, uint256 expectedTokens, uint256 burned) = c.quoteBuyFor(500 ether, alice);
        assertEq(burned, 0, "this curve has no opening surcharge");
        assertApproxEqAbs(expectedSpent * 9000, 400 ether * 10_000, 10_000,
            "a 400-stock principal cap requires the gross 10%-fee payment");
        vm.prank(alice);
        (uint256 got, uint256 refund) = nativeRouter.buy{value: 500 ether}(_params(500 ether, 0), empty);
        assertEq(refund, 500 ether - expectedSpent);
        assertEq(alice.balance, 500 ether + refund);
        assertEq(got, expectedTokens);
        assertEq(t.balanceOf(alice), got);
        assertEq(wrapped.balanceOf(address(nativeRouter)), 11 ether);
        assertEq(address(nativeRouter).balance, 7 ether);
        assertEq(wrapped.allowance(address(nativeRouter), address(trade)), 0);
    }

    function _thinNativeMarket() private {
        V2RouterRegistry registry = new V2RouterRegistry(pm, v3f);
        V2RouterAsset t = new V2RouterAsset("THIN");
        token = IERC20(address(t));
        PoolKey memory key = address(t) < address(wrapped)
            ? PoolKey(Currency.wrap(address(t)), Currency.wrap(address(wrapped)), 3000, 60, IHooks(address(0)))
            : PoolKey(Currency.wrap(address(wrapped)), Currency.wrap(address(t)), 3000, 60, IHooks(address(0)));
        pm.initialize(key, uint160(1 << 96));
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        t.mint(address(this), 1_000 ether);
        t.approve(address(lp), type(uint256).max);
        wrapped.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-60, 60, 1e21, bytes32(0)), "");
        registry.set(address(t), address(wrapped), address(new V2RouterTreasury(key)), address(new V2RouterGraduated()));
        trade = new Router(HedgeFunFactory(address(registry)));
        nativeRouter = new NativeRouter(trade, IWrappedNative(address(wrapped)));
        t.mint(alice, 100 ether);
        t.mint(address(nativeRouter), 23 ether);
        vm.prank(alice); t.approve(address(nativeRouter), type(uint256).max);
    }

    function testNativePartialSaleReturnsUnsoldTokensOnce() public {
        _thinNativeMarket();
        Router.TradeParams memory p = _params(100 ether, 2);
        Router.Hop[] memory empty = new Router.Hop[](0);
        p.allowPartialFill = false;
        vm.prank(alice); vm.expectPartialRevert(Router.PartialFill.selector);
        nativeRouter.sell(p, empty);
        assertEq(token.balanceOf(alice), 100 ether);
        p.allowPartialFill = true;
        vm.prank(alice);
        (uint256 got, uint256 refund) = nativeRouter.sell(p, empty);
        assertGt(got, 0); assertGt(refund, 0); assertLt(refund, 100 ether);
        assertEq(alice.balance, 1_000 ether + got);
        assertEq(token.balanceOf(alice), refund);
        assertEq(token.balanceOf(address(nativeRouter)), 23 ether);
        assertEq(token.allowance(address(nativeRouter), address(trade)), 0);
        assertEq(wrapped.balanceOf(address(nativeRouter)), 0);
        assertEq(address(nativeRouter).balance, 0);
    }
}
