// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";
import {HedgeFunHook} from "../src/hooks/HedgeFunHook.sol";
import {HedgeFunV2Hook} from "../src/hooks/HedgeFunV2Hook.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

/// Production factory, curve, hook and PoolManager, in both currency orderings. Every V4 fee is a stock claim
/// from the moment it is taken; these tests distinguish the claim from paid stock throughout.
abstract contract V2TwoSidedFeesBase is V2FactoryFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolSwapTest internal swapRouter;
    HedgeFunBondingCurve internal curve;
    HedgeFunToken internal token;
    PoolKey internal key;
    PoolId internal pid;
    uint96 internal nextNonce;

    function tokenIsCurrency0() internal pure virtual returns (bool);

    function _request() internal view override returns (HedgeFunFactory.Request memory q) {
        q = super._request();
        q.taxBps = 300;
        q.nonce = nextNonce;
    }

    function setUp() public {
        _setUpV2(18);
        (, curve, key) = _launchV2(tokenIsCurrency0());
        _graduateV2(curve);
        token = HedgeFunToken(curve.token());
        pid = key.toId();
        swapRouter = new PoolSwapTest(pm);
        stock.approve(address(swapRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
    }

    function _swap(bool selling, int256 amount) internal returns (BalanceDelta delta) {
        bool zeroForOne = selling == tokenIsCurrency0();
        delta = swapRouter.swap(key, SwapParams({zeroForOne: zeroForOne, amountSpecified: amount,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
    }

    function _stockOf(BalanceDelta delta) internal pure returns (int256) {
        return tokenIsCurrency0() ? delta.amount1() : delta.amount0();
    }

    function _tokenOf(BalanceDelta delta) internal pure returns (int256) {
        return tokenIsCurrency0() ? delta.amount0() : delta.amount1();
    }

    function _tokenClaim() internal view returns (uint256) {
        return pm.balanceOf(address(hook), uint256(uint160(address(token))));
    }

    function _stockClaim() internal view returns (uint256) {
        return pm.balanceOf(address(hook), uint256(uint160(address(stock))));
    }

    function _assertSplit(uint256 grossStock, uint256 protocolBefore, uint256 creatorBefore, uint256 treasuryBefore)
        internal view
    {
        uint256 protocolCut = grossStock * 2000 / 10_000;
        uint256 creatorCut = grossStock * 1000 / 10_000;
        assertEq(stock.balanceOf(protocol) - protocolBefore, protocolCut);
        assertEq(stock.balanceOf(address(this)) - creatorBefore, creatorCut);
        assertEq(stock.balanceOf(curve.treasury()) - treasuryBefore, grossStock - protocolCut - creatorCut);
        assertEq(hook.rates(pid).sweepTipBps, 0);
    }

    function testCurveBuyAccruesAndPaysStockToAllThreeRoles() public {
        uint256 gross = curve.terminalStock() - curve.virtualStock();
        uint256 stockFee = curve.totalFees();
        assertGt(stockFee, 0);
        assertEq(curve.claimable(protocol), stockFee * 2000 / 10_000);
        assertEq(curve.claimable(address(this)), stockFee * 1000 / 10_000);
        assertEq(curve.claimable(curve.treasury()), stockFee - stockFee * 2000 / 10_000 - stockFee * 1000 / 10_000);
        assertEq(curve.realStockReserve(), 0, "graduation released principal, not fees");
        assertApproxEqAbs(stockFee * 9700, gross * 300, 10_000);
        uint256 p = stock.balanceOf(protocol);
        uint256 c = stock.balanceOf(address(this));
        uint256 t = stock.balanceOf(curve.treasury());
        curve.claimFees(protocol);
        curve.claimFees(address(this));
        curve.claimFees(curve.treasury());
        _assertSplit(stockFee, p, c, t);
        assertEq(curve.totalFees(), 0);
    }

    function testV4ExactInputBuyIsTaxedInStockBeforeTheSwap() public {
        uint256 supply = token.totalSupply();
        uint256 payerBefore = stock.balanceOf(address(this));
        BalanceDelta delta = _swap(false, -int256(1e18));
        assertEq(payerBefore - stock.balanceOf(address(this)), 1e18, "the buyer pays what they specified");
        assertEq(_stockOf(delta), -int256(1e18));
        assertGt(_tokenOf(delta), 0);
        (uint256 accruedToken, uint256 accruedStock) = hook.accrued(pid);
        assertEq(accruedToken, 0, "no fee is ever held in the token");
        assertEq(accruedStock, 0.03e18, "3% of the payment");
        assertEq(_tokenClaim(), 0);
        assertEq(_stockClaim(), accruedStock);
        assertEq(token.totalSupply(), supply, "the basic buy fee burns nothing");
    }

    function testV4BuyFeeIsPaidByAnyonesSweepWithNoOwnerStep() public {
        _swap(false, -int256(1e18));
        (, uint256 stockFee) = hook.accrued(pid);
        uint256 p = stock.balanceOf(protocol);
        uint256 c = stock.balanceOf(address(this));
        uint256 t = stock.balanceOf(curve.treasury());
        vm.prank(address(0xBEEF));
        hook.sweep(pid);
        _assertSplit(stockFee, p, c, t);
        assertEq(_stockClaim(), 0);
        (uint256 at, uint256 ast) = hook.accrued(pid);
        assertEq(at + ast, 0);
        assertEq(hook.owedProtocol(pid) + hook.owedCreator(pid) + hook.owedTreasury(pid), 0);
    }

    /// Only the payment net of the fee meets the pool, exactly as on an exact-output buy of the same tokens.
    function testExactInputAndExactOutputBuysCostTheSame() public {
        uint256 snapshot = vm.snapshotState();
        BalanceDelta exactIn = _swap(false, -int256(1e18));
        uint256 tokensOut = uint256(_tokenOf(exactIn));
        (, uint256 feeIn) = hook.accrued(pid);
        vm.revertToState(snapshot);
        BalanceDelta exactOut = _swap(false, int256(tokensOut));
        (, uint256 feeOut) = hook.accrued(pid);
        assertEq(uint256(_tokenOf(exactOut)), tokensOut);
        assertApproxEqAbs(uint256(-_stockOf(exactOut)), 1e18, 1e6, "the same total payment");
        assertApproxEqAbs(feeOut, feeIn, 1e6, "the same fee");
    }

    function testFuzz_exactInputBuyFeeIsExactlyTheRateOfThePayment(uint256 paid) public {
        paid = bound(paid, 1, 20e18);
        uint256 supply = token.totalSupply();
        BalanceDelta delta = _swap(false, -int256(paid));
        assertEq(_stockOf(delta), -int256(paid));
        (uint256 accruedToken, uint256 accruedStock) = hook.accrued(pid);
        assertEq(accruedToken, 0);
        assertEq(accruedStock, paid * 300 / 10_000);
        assertEq(_tokenClaim(), 0);
        assertEq(_stockClaim(), accruedStock);
        assertEq(token.totalSupply(), supply);
    }

    /// A buy that would stop at its price limit has already paid the fee on stock it never traded: refused.
    function testBuyThatStopsAtItsPriceLimitIsRefused() public {
        (uint160 spot,,,) = pm.getSlot0(pid);
        bool zeroForOne = !tokenIsCurrency0();
        uint160 limit = zeroForOne ? spot - spot / 10_000 : spot + spot / 10_000;
        SwapParams memory params = SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(40e18), sqrtPriceLimitX96: limit});
        vm.expectRevert(abi.encodeWithSelector(CustomRevert.WrappedError.selector, address(hook), IHooks.afterSwap.selector,
            abi.encodeWithSelector(HedgeFunV2Hook.PartialFillRefused.selector), abi.encodeWithSelector(Hooks.HookCallFailed.selector)));
        swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        (uint256 at, uint256 ast) = hook.accrued(pid);
        assertEq(at + ast, 0);
        assertEq(_stockClaim(), 0);
        // the same limit is no obstacle to a buy that fills before reaching it
        params.amountSpecified = -int256(1e12);
        swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        (, ast) = hook.accrued(pid);
        assertEq(ast, 1e12 * 300 / 10_000);
    }

    /// A sell is taxed after the swap on the stock that actually moved, so it may still stop early.
    function testSellThatStopsAtItsPriceLimitIsTaxedOnWhatMoved() public {
        (uint160 spot,,,) = pm.getSlot0(pid);
        bool zeroForOne = tokenIsCurrency0();
        uint160 limit = zeroForOne ? spot - spot / 10_000 : spot + spot / 10_000;
        uint256 offered = token.balanceOf(address(this));
        BalanceDelta delta = swapRouter.swap(key, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(offered),
            sqrtPriceLimitX96: limit}), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        assertLt(uint256(-_tokenOf(delta)), offered, "stopped early");
        (uint256 at, uint256 stockFee) = hook.accrued(pid);
        assertEq(at, 0);
        assertEq(stockFee, (uint256(_stockOf(delta)) + stockFee) * 300 / 10_000);
    }

    function testV4SellPaysExactTwentyTenSeventy() public {
        _swap(true, -int256(100e18));
        (uint256 at, uint256 stockFee) = hook.accrued(pid);
        assertEq(at, 0);
        assertGt(stockFee, 0);
        uint256 p = stock.balanceOf(protocol);
        uint256 c = stock.balanceOf(address(this));
        uint256 t = stock.balanceOf(curve.treasury());
        hook.sweep(pid);
        _assertSplit(stockFee, p, c, t);
        assertEq(_stockClaim(), 0);
    }

    function testExactOutputBuyStillPaysInStock() public {
        _swap(false, int256(100e18));
        (uint256 at, uint256 stockFee) = hook.accrued(pid);
        assertEq(at, 0);
        assertGt(stockFee, 0);
        uint256 p = stock.balanceOf(protocol);
        uint256 c = stock.balanceOf(address(this));
        uint256 t = stock.balanceOf(curve.treasury());
        hook.sweep(pid);
        _assertSplit(stockFee, p, c, t);
    }

    function testBuysAndSellsAccrueOneStockLedgerAndNoTokenLedger() public {
        _swap(false, -int256(2e18));
        (, uint256 afterBuy) = hook.accrued(pid);
        _swap(true, -int256(100e18));
        _swap(false, int256(50e18));
        (uint256 at, uint256 stockFees) = hook.accrued(pid);
        assertEq(at, 0);
        assertGt(stockFees, afterBuy);
        assertEq(_stockClaim(), stockFees);
        assertEq(_tokenClaim(), 0);
        uint256 p = stock.balanceOf(protocol);
        uint256 c = stock.balanceOf(address(this));
        uint256 t = stock.balanceOf(curve.treasury());
        hook.sweep(pid);
        _assertSplit(stockFees, p, c, t);
    }

    function testOnlyThePoolManagerCallsBeforeSwap() public {
        SwapParams memory params = SwapParams({zeroForOne: !tokenIsCurrency0(), amountSpecified: -int256(1e18),
            sqrtPriceLimitX96: 0});
        vm.expectRevert(HedgeFunHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        PoolKey memory wrong = key;
        wrong.fee += 1;
        vm.prank(address(pm));
        vm.expectRevert(HedgeFunHook.WrongPool.selector);
        hook.beforeSwap(address(this), wrong, params, "");
        (uint256 at, uint256 ast) = hook.accrued(pid);
        assertEq(at + ast, 0);
    }

    function testRejectedStockPayoutPreservesRoleCreditAndRetryDoesNotDoubleSplit() public {
        _swap(false, -int256(1e18));
        (, uint256 stockFee) = hook.accrued(pid);
        stock.blockRecipient(protocol);
        uint256 c = stock.balanceOf(address(this));
        uint256 t = stock.balanceOf(curve.treasury());
        hook.sweep(pid);
        uint256 cut = stockFee * 2000 / 10_000;
        assertEq(hook.owedProtocol(pid), cut);
        assertEq(stock.balanceOf(protocol), 0);
        assertEq(stock.balanceOf(address(this)) - c, stockFee * 1000 / 10_000);
        assertEq(stock.balanceOf(curve.treasury()) - t, stockFee - cut - stockFee * 1000 / 10_000);
        hook.sweep(pid);
        assertEq(hook.owedProtocol(pid), cut);
        assertEq(stock.balanceOf(address(this)) - c, stockFee * 1000 / 10_000);
        stock.blockRecipient(address(0));
        hook.sweep(pid);
        assertEq(stock.balanceOf(protocol), cut);
        assertEq(hook.owedProtocol(pid), 0);
    }

    function testTwoPoolsOnSameStockKeepTheirFeesSeparate() public {
        _swap(false, -int256(1e18));
        (, uint256 firstFee) = hook.accrued(pid);
        nextNonce = lastNonce + 1;
        (, HedgeFunBondingCurve secondCurve, PoolKey memory secondKey) = _launchV2(tokenIsCurrency0());
        _graduateV2(secondCurve);
        PoolId secondId = secondKey.toId();
        swapRouter.swap(secondKey, SwapParams({zeroForOne: !tokenIsCurrency0(), amountSpecified: -int256(2e18),
            sqrtPriceLimitX96: tokenIsCurrency0() ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        (, uint256 secondFee) = hook.accrued(secondId);
        assertEq(firstFee, 0.03e18);
        assertEq(secondFee, 0.06e18);
        assertEq(_stockClaim(), firstFee + secondFee, "one currency, two pools' claims");
        uint256 firstTreasury = stock.balanceOf(curve.treasury());
        hook.sweep(secondId);
        assertEq(_stockClaim(), firstFee, "pool 2 redeems its own claims and no more");
        assertEq(stock.balanceOf(curve.treasury()), firstTreasury);
        (, uint256 stillFirst) = hook.accrued(pid);
        assertEq(stillFirst, firstFee);
        uint256 p = stock.balanceOf(protocol);
        uint256 c = stock.balanceOf(address(this));
        hook.sweep(pid);
        _assertSplit(firstFee, p, c, firstTreasury);
        assertEq(_stockClaim(), 0);
    }

    function testStockRedemptionFailureKeepsTheBuyFeeForALaterSweep() public {
        _swap(false, -int256(1e18));
        _swap(true, -int256(100e18));
        (uint256 at, uint256 stockFees) = hook.accrued(pid);
        assertEq(at, 0);
        stock.blockRecipient(address(hook));
        hook.sweep(pid);
        (, uint256 stillAccrued) = hook.accrued(pid);
        assertEq(stillAccrued, stockFees);
        assertEq(_stockClaim(), stockFees);
        stock.blockRecipient(address(0));
        uint256 p = stock.balanceOf(protocol);
        uint256 c = stock.balanceOf(address(this));
        uint256 t = stock.balanceOf(curve.treasury());
        hook.sweep(pid);
        _assertSplit(stockFees, p, c, t);
        assertEq(_stockClaim(), 0);
    }
}

contract V2TwoSidedFeesToken0Test is V2TwoSidedFeesBase {
    function tokenIsCurrency0() internal pure override returns (bool) { return true; }
}

contract V2TwoSidedFeesToken1Test is V2TwoSidedFeesBase {
    function tokenIsCurrency0() internal pure override returns (bool) { return false; }
}
