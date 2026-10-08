// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";
import {HedgeFunHook} from "../src/hooks/HedgeFunHook.sol";
import {HedgeFunV2Hook} from "../src/hooks/HedgeFunV2Hook.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {V2LiquidityVault} from "../src/v2/V2LiquidityVault.sol";
import {Vm} from "forge-std/Vm.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";
import {MockToken} from "./mocks/Mocks.sol";

interface IProtocolFeesLike {
    function setProtocolFeeController(address) external;
    function setProtocolFee(PoolKey memory key, uint24 newProtocolFee) external;
}

/// Stands in for a V1 factory that bound a version-3 hook: it registers a pool WITHOUT a vault and seeds it.
contract VaultlessPoolBinder is PoolModifyLiquidityTest {
    constructor(IPoolManager m) PoolModifyLiquidityTest(m) {}
    function owner() external view returns (address) { return address(this); }
    function bindAndRegister(HedgeFunV2Hook h, PoolKey memory key, address token, address stock, address treasury, HedgeFunHook.Rates memory r, uint160 sqrtP) external {
        h.bind();
        h.register(key, token, stock, treasury, address(0xAAA1), address(0xAAA2), address(0), r);
        manager.initialize(key, sqrtP);
    }
}

/// The version-3 hook's stock-side buy fee against the real PoolManager, in both currency orderings and with a
/// 6-decimal stock: what an independent audit of the change exercised beyond `V2TwoSidedFees.t.sol`.
abstract contract V2StockBuyFeeBase is V2FactoryFixture {
    event Taxed(PoolId indexed id, bool indexed selling, bool inToken, uint256 moved, uint256 tax, uint256 rateBps);

    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolSwapTest internal swapRouter;
    HedgeFunBondingCurve internal curve;
    HedgeFunToken internal token;
    PoolKey internal key;
    PoolId internal pid;

    function tokenIsCurrency0() internal pure virtual returns (bool);
    function stockDecimals() internal pure virtual returns (uint8) { return 18; }

    function _request() internal view override returns (HedgeFunFactory.Request memory q) {
        q = super._request();
        q.taxBps = 300;
    }

    function setUp() public {
        _setUpV2(stockDecimals());
        (, curve, key) = _launchV2(tokenIsCurrency0());
        _graduateV2(curve);
        token = HedgeFunToken(curve.token());
        pid = key.toId();
        swapRouter = new PoolSwapTest(pm);
        stock.approve(address(swapRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
    }

    PoolSwapTest.TestSettings internal plain = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }
    function _stockOf(BalanceDelta d) internal pure returns (int256) { return tokenIsCurrency0() ? d.amount1() : d.amount0(); }
    function _tokenOf(BalanceDelta d) internal pure returns (int256) { return tokenIsCurrency0() ? d.amount0() : d.amount1(); }
    function _stockClaim() internal view returns (uint256) { return pm.balanceOf(address(hook), uint256(uint160(address(stock)))); }
    function _tokenClaim() internal view returns (uint256) { return pm.balanceOf(address(hook), uint256(uint160(address(token)))); }

    function test_aBuyStoppedByItsLimitRevertsPartialFillRefused() public {
        (uint160 spot,,,) = pm.getSlot0(pid);
        bool zeroForOne = !tokenIsCurrency0();
        uint160 limit = zeroForOne ? spot - spot / 10_000 : spot + spot / 10_000;
        SwapParams memory params = SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(40 * 10 ** uint256(stockDecimals())), sqrtPriceLimitX96: limit});
        vm.expectRevert(abi.encodeWithSelector(CustomRevert.WrappedError.selector, address(hook), IHooks.afterSwap.selector,
            abi.encodeWithSelector(HedgeFunV2Hook.PartialFillRefused.selector), abi.encodeWithSelector(bytes4(keccak256("HookCallFailed()")))));
        swapRouter.swap(key, params, plain, "");
    }

    /// The buyer pays exactly `paid`, claims equal the ledger, the manager holds the claim, and one sweep pays
    /// everything out leaving nothing behind.
    function testFuzz_buyThenSweepLeavesNothingBehind(uint256 paid, bool thenSell) public {
        paid = bound(paid, 1, 5_000 * 10 ** uint256(stockDecimals()));
        uint256 before = stock.balanceOf(address(this));
        uint256 pmBefore = stock.balanceOf(address(pm));
        BalanceDelta d = swapRouter.swap(key, SwapParams({zeroForOne: !tokenIsCurrency0(), amountSpecified: -int256(paid),
            sqrtPriceLimitX96: _limit(!tokenIsCurrency0())}), plain, "");
        assertEq(before - stock.balanceOf(address(this)), paid);
        assertEq(stock.balanceOf(address(pm)) - pmBefore, paid);
        assertEq(_stockOf(d), -int256(paid));
        (uint256 at, uint256 ast) = hook.accrued(pid);
        assertEq(at, 0);
        assertEq(ast, paid * 300 / 10_000);
        assertEq(_stockClaim(), ast);
        assertEq(_tokenClaim(), 0);
        if (thenSell && _tokenOf(d) > 0) {
            swapRouter.swap(key, SwapParams({zeroForOne: tokenIsCurrency0(), amountSpecified: -_tokenOf(d),
                sqrtPriceLimitX96: _limit(tokenIsCurrency0())}), plain, "");
            (at, ast) = hook.accrued(pid);
            assertEq(at, 0);
            assertEq(_stockClaim(), ast);
        }
        uint256 hookBal = stock.balanceOf(address(hook));
        hook.sweep(pid);
        (at, ast) = hook.accrued(pid);
        assertEq(at + ast, 0);
        assertEq(_stockClaim(), 0);
        assertEq(stock.balanceOf(address(hook)), hookBal, "nothing sticks in the hook");
        assertEq(hook.totalOwed(address(stock)), 0);
    }

    /// No false refusal at the small end, where fee and price steps round hardest.
    function testFuzz_smallBuysAlwaysFill(uint256 paid) public {
        paid = bound(paid, 1, 1e7);
        BalanceDelta d = swapRouter.swap(key, SwapParams({zeroForOne: !tokenIsCurrency0(), amountSpecified: -int256(paid),
            sqrtPriceLimitX96: _limit(!tokenIsCurrency0())}), plain, "");
        assertEq(_stockOf(d), -int256(paid));
        (, uint256 ast) = hook.accrued(pid);
        assertEq(ast, paid * 300 / 10_000);
        assertEq(_stockClaim(), ast);
    }

    /// ... nor when Uniswap governance switches a protocol fee on for the pool.
    function testFuzz_aProtocolFeeDoesNotBreakTheFullFillCheck(uint256 paid) public {
        paid = bound(paid, 1, 10 ** uint256(stockDecimals()) * 1000);
        vm.prank(address(this));
        IProtocolFeesLike(address(pm)).setProtocolFeeController(address(this));
        IProtocolFeesLike(address(pm)).setProtocolFee(key, uint24(1000) | (uint24(1000) << 12));
        BalanceDelta d = swapRouter.swap(key, SwapParams({zeroForOne: !tokenIsCurrency0(), amountSpecified: -int256(paid),
            sqrtPriceLimitX96: _limit(!tokenIsCurrency0())}), plain, "");
        assertEq(_stockOf(d), -int256(paid));
        (, uint256 ast) = hook.accrued(pid);
        assertEq(ast, paid * 300 / 10_000);
        assertEq(_stockClaim(), ast);
    }

    /// One meaning for both stock-taxed buys: `moved` is the stock that met the pool, and the buyer paid
    /// `moved + tax`. An exact-input buy's tax is the rate of the payment; an exact-output buy's is grossed up.
    function test_taxedEventMeansTheSameForBothBuyTypes() public {
        uint256 paid = 10 ** uint256(stockDecimals());
        uint256 tax = paid * 300 / 10_000;
        vm.expectEmit(true, true, false, true, address(hook));
        emit Taxed(pid, false, false, paid - tax, tax, 300);
        BalanceDelta d = swapRouter.swap(key, SwapParams({zeroForOne: !tokenIsCurrency0(), amountSpecified: -int256(paid),
            sqrtPriceLimitX96: _limit(!tokenIsCurrency0())}), plain, "");
        assertEq(_stockOf(d), -int256(paid));

        (, uint256 before) = hook.accrued(pid);
        vm.recordLogs();
        d = swapRouter.swap(key, SwapParams({zeroForOne: !tokenIsCurrency0(), amountSpecified: _tokenOf(d),
            sqrtPriceLimitX96: _limit(!tokenIsCurrency0())}), plain, "");
        (, uint256 afterOutput) = hook.accrued(pid);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != Taxed.selector) continue;
            (bool inToken, uint256 moved, uint256 outputTax,) = abi.decode(logs[i].data, (bool, uint256, uint256, uint256));
            assertFalse(inToken);
            assertEq(outputTax, afterOutput - before);
            assertEq(moved + outputTax, uint256(-_stockOf(d)), "moved + tax is the payment");
            seen = true;
        }
        assertTrue(seen);
    }

    /// The treasury is exempt in `beforeSwap` too: untaxed, and it may stop at its limit.
    function test_theTreasuryIsUntaxedAndMayFillShort() public {
        address treasury = curve.treasury();
        vm.etch(treasury, address(swapRouter).code);                 // the hook only knows the treasury by address
        stock.approve(treasury, type(uint256).max);
        (uint160 spot,,,) = pm.getSlot0(pid);
        bool zeroForOne = !tokenIsCurrency0();
        uint160 limit = zeroForOne ? spot - spot / 10_000 : spot + spot / 10_000;
        BalanceDelta d = PoolSwapTest(treasury).swap(key, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(40 * 10 ** uint256(stockDecimals())),
            sqrtPriceLimitX96: limit}), plain, "");
        assertLt(uint256(-_stockOf(d)), 40 * 10 ** uint256(stockDecimals()), "stopped at its limit");
        assertGt(uint256(-_stockOf(d)), 0);
        (uint256 at, uint256 ast) = hook.accrued(pid);
        assertEq(at + ast, 0, "untaxed");
        assertEq(_stockClaim(), 0);
    }

    /// Dust: a buy whose fee floors to zero is neither taxed nor held to a full fill.
    function test_aDustBuyIsUntaxed() public {
        BalanceDelta d = swapRouter.swap(key, SwapParams({zeroForOne: !tokenIsCurrency0(), amountSpecified: -int256(33),
            sqrtPriceLimitX96: _limit(!tokenIsCurrency0())}), plain, "");
        (uint256 at, uint256 ast) = hook.accrued(pid);
        assertEq(at + ast, 0);
        assertEq(_stockOf(d), -33);
        assertEq(_stockClaim(), 0);
    }

    function test_anExactOutputSellIsStillRefused() public {
        vm.expectRevert(abi.encodeWithSelector(CustomRevert.WrappedError.selector, address(hook), IHooks.afterSwap.selector,
            abi.encodeWithSelector(HedgeFunHook.ExactOutputRefused.selector), abi.encodeWithSelector(bytes4(keccak256("HookCallFailed()")))));
        swapRouter.swap(key, SwapParams({zeroForOne: tokenIsCurrency0(), amountSpecified: int256(1e15),
            sqrtPriceLimitX96: _limit(tokenIsCurrency0())}), plain, "");
    }

    function test_amountsNoTradeCouldBeRevertAndLeaveNothing() public {
        bool z = !tokenIsCurrency0();
        vm.expectRevert();
        swapRouter.swap(key, SwapParams({zeroForOne: z, amountSpecified: type(int256).min, sqrtPriceLimitX96: _limit(z)}), plain, "");
        vm.expectRevert();
        swapRouter.swap(key, SwapParams({zeroForOne: z, amountSpecified: -int256(1 << 200), sqrtPriceLimitX96: _limit(z)}), plain, "");
        vm.expectRevert();
        swapRouter.swap(key, SwapParams({zeroForOne: z, amountSpecified: -int256(uint256(uint128(type(int128).max))), sqrtPriceLimitX96: _limit(z)}), plain, "");
        (uint256 at, uint256 ast) = hook.accrued(pid);
        assertEq(at + ast, 0);
        assertEq(_stockClaim(), 0);
    }

    /// The pool's LP fee is charged on the payment NET of the tax, so the vault's stock-side fee (the treasury's
    /// buy-back budget) on an exact-input buy is `1 - taxBps` of 0.30% of the payment.
    function test_theLpFeeIsChargedOnThePaymentNetOfTheTax() public {
        if (stockDecimals() != 18) return;                                       // amounts below are 18-decimal
        V2LiquidityVault vault = V2LiquidityVault(hook.liquidityVaultOf(pid));
        vault.collectFees();
        swapRouter.swap(key, SwapParams({zeroForOne: !tokenIsCurrency0(), amountSpecified: -int256(100e18),
            sqrtPriceLimitX96: _limit(!tokenIsCurrency0())}), plain, "");
        (uint256 stockFee,) = vault.collectFees();
        assertApproxEqAbs(stockFee, 97e18 * 3000 / 1e6, 1e6);
    }

    /// A pool registered WITHOUT a vault on a version-3 hook keeps the base rules, and `beforeSwap` is inert.
    function test_aVaultlessPoolKeepsTheBaseHooksRules() public {
        if (stockDecimals() != 18) return;                                       // amounts below are 18-decimal
        HedgeFunV2Hook h = _deployV2Hook(pm);
        VaultlessPoolBinder binder = new VaultlessPoolBinder(pm);
        MockToken tkn = new MockToken("LEG", 18);
        while ((address(tkn) < address(stock)) != tokenIsCurrency0()) tkn = new MockToken("LEG", 18);
        PoolKey memory k = address(tkn) < address(stock)
            ? PoolKey(Currency.wrap(address(tkn)), Currency.wrap(address(stock)), 3000, 60, h)
            : PoolKey(Currency.wrap(address(stock)), Currency.wrap(address(tkn)), 3000, 60, h);
        HedgeFunHook.Rates memory r;
        r.taxBps = 300; r.protocolBps = 2000; r.creatorBps = 1000;
        binder.bindAndRegister(h, k, address(tkn), address(stock), address(0x7EA5), r, uint160(1 << 96));
        tkn.mint(address(this), 1_000e18);
        tkn.approve(address(binder), type(uint256).max); stock.approve(address(binder), type(uint256).max);
        tkn.approve(address(swapRouter), type(uint256).max);
        binder.modifyLiquidity(k, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1_000e18, salt: 0}), "");
        PoolId lid = k.toId();
        assertEq(h.liquidityVaultOf(lid), address(0));
        bool z = address(tkn) > address(stock);                                  // stock in
        // exact-input buy: taxed in the TOKEN, after the swap, as the base hook does
        BalanceDelta d = swapRouter.swap(k, SwapParams({zeroForOne: z, amountSpecified: -int256(1e18), sqrtPriceLimitX96: _limit(z)}), plain, "");
        (uint256 at, uint256 ast) = h.accrued(lid);
        assertGt(at, 0); assertEq(ast, 0);
        assertEq(pm.balanceOf(address(h), uint256(uint160(address(tkn)))), at);
        assertEq(z ? d.amount0() : d.amount1(), -int256(1e18));
        // and it may stop at its limit
        (uint160 spot,,,) = pm.getSlot0(lid);
        uint160 limit = z ? spot - spot / 100_000 : spot + spot / 100_000;
        d = swapRouter.swap(k, SwapParams({zeroForOne: z, amountSpecified: -int256(100e18), sqrtPriceLimitX96: limit}), plain, "");
        assertLt(uint256(-int256(z ? d.amount0() : d.amount1())), 100e18);
        (uint256 at2,) = h.accrued(lid);
        assertGt(at2, at);
    }
}

contract V2StockBuyFeeToken0Test is V2StockBuyFeeBase {
    function tokenIsCurrency0() internal pure override returns (bool) { return true; }
}

contract V2StockBuyFeeToken1Test is V2StockBuyFeeBase {
    function tokenIsCurrency0() internal pure override returns (bool) { return false; }
}

contract V2StockBuyFeeSixDecimalsTest is V2StockBuyFeeBase {
    function tokenIsCurrency0() internal pure override returns (bool) { return true; }
    function stockDecimals() internal pure override returns (uint8) { return 6; }
}
