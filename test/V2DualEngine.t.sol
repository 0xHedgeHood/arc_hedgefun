// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunHook} from "../src/hooks/HedgeFunHook.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {V2LiquidityVault} from "../src/v2/V2LiquidityVault.sol";
import {CurveDeployer} from "../src/v2/CurveDeployer.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

contract V2DualEngineTest is V2FactoryFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public { _setUpV2(18); }

    function test_v2RejectsZeroAndExcessiveLpFees() public {
        HedgeFunFactory.Defaults memory d = _defaults();
        d.lpFee = 0;
        vm.prank(owner);
        vm.expectRevert(HedgeFunFactory.BadRequest.selector);
        factory.setDefaults(d);
        d.lpFee = 3001;
        vm.prank(owner);
        vm.expectRevert(HedgeFunFactory.BadRequest.selector);
        factory.setDefaults(d);
        assertEq(factory.getDefaults().lpFee, 3000);
    }

    function test_graduatedV2PoolNeverArmsSellSpikeFromFeeFundedBuyback() public {
        (uint256 id, HedgeFunBondingCurve curve, PoolKey memory key) = _launchV2(true);
        (, HedgeFunHook.Rates memory rates) = factory.graduationConfig(id);
        assertEq(rates.spikeBps, 0);
        _graduateV2(curve);
        vm.prank(curve.treasury());
        hook.noteEvent();
        assertEq(hook.sellRateBps(key.toId()), rates.taxBps);
    }

    function test_graduationExecutorRejectsDirectCalls() public {
        CurveDeployer deployer = factory.curveDeployer();
        vm.expectRevert(bytes4(keccak256("NotFactory()")));
        deployer.executeGraduation(0, uint160(1 << 96), 1, 1);
    }

    function test_predonatedVaultTokensNeverIncreaseLpBudgetOrCollectedFees() public {
        (uint256 id, HedgeFunBondingCurve curve, PoolKey memory key) = _launchV2(true);
        bytes memory args = abi.encode(address(factory), pm, key, curve.token(), address(stock), curve.treasury());
        bytes32 initHash = keccak256(abi.encodePacked(type(V2LiquidityVault).creationCode, args));
        address predicted = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), address(factory.curveDeployer()), bytes32(id), initHash)))));
        assertEq(predicted.code.length, 0);
        curve.buy(10e18, 1, address(this), block.timestamp);
        stock.transfer(predicted, 3e18);
        IERC20(curve.token()).transfer(predicted, 1e18);
        uint256 realReserve = curve.terminalStock() - curve.virtualStock();
        _graduateV2(curve);
        assertEq(hook.liquidityVaultOf(key.toId()), predicted);
        assertApproxEqAbs(stock.balanceOf(address(pm)), realReserve * 7000 / 10_000, 2);
        assertEq(stock.balanceOf(predicted), 3e18);
        assertEq(IERC20(curve.token()).balanceOf(predicted), 1e18 + V2LiquidityVault(predicted).lockedSeedTokens());
        (uint256 stockFee, uint256 funFee) = V2LiquidityVault(predicted).collectFees();
        assertEq(stockFee, 0);
        assertEq(funFee, 0);
        assertEq(stock.balanceOf(predicted), 3e18);
        assertEq(IERC20(curve.token()).balanceOf(predicted), 1e18 + V2LiquidityVault(predicted).lockedSeedTokens());
    }

    function test_stockSideLpFeeCreditsBuybackWithoutCreatingStrategyLot() public {
        (, HedgeFunBondingCurve curve, PoolKey memory key) = _launchV2(true);
        _graduateV2(curve);
        HedgeFunV2Treasury treasury = HedgeFunV2Treasury(curve.treasury());
        V2LiquidityVault vault = V2LiquidityVault(hook.liquidityVaultOf(key.toId()));
        assertEq(treasury.liquidityVault(), address(vault));
        assertGt(treasury.bookedStock(), 0);
        assertEq(treasury.buybackStock(), 0);
        uint256 principal = treasury.bookedStock();
        uint128 liquidityBefore = pm.getLiquidity(key.toId());

        PoolSwapTest router = new PoolSwapTest(pm);
        stock.approve(address(router), type(uint256).max);
        bool stockIs0 = address(stock) < address(curve.token());
        router.swap(key, SwapParams({zeroForOne: stockIs0, amountSpecified: -int256(5e18),
            sqrtPriceLimitX96: stockIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

        (uint256 stockFee, uint256 funBurned) = vault.collectFees();
        assertGt(stockFee, 0);
        assertEq(funBurned, 0);
        assertEq(treasury.buybackStock(), stockFee);
        assertEq(treasury.bookedStock(), principal, "LP income is not strategy cost basis");
        (uint128 baseAfter,,) = pm.getPositionInfo(key.toId(), address(vault),
            TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), bytes32(0));
        (uint128 surplusAfter,,) = pm.getPositionInfo(key.toId(), address(vault),
            vault.surplusTickLower(), vault.surplusTickUpper(), bytes32(uint256(1)));
        assertEq(baseAfter, liquidityBefore, "fee collection cannot remove base principal");
        assertEq(surplusAfter, vault.surplusLiquidity(), "fee collection cannot remove surplus principal");
        assertEq(stock.allowance(address(vault), address(treasury)), 0);
        assertEq(stock.balanceOf(address(vault)), 0);
        (uint256 repeatStock, uint256 repeatToken) = vault.collectFees();
        assertEq(repeatStock, 0);
        assertEq(repeatToken, 0);
    }

    function test_graduationDuringStaleOracleKeepsCapitalPendingUntilBook() public {
        (, HedgeFunBondingCurve curve,) = _launchV2(false);
        vm.warp(block.timestamp + 27 hours);
        _graduateV2(curve);
        HedgeFunV2Treasury treasury = HedgeFunV2Treasury(curve.treasury());
        assertEq(treasury.lotCount(), 0);
        uint256 pending = treasury.unbookedStock();
        assertGt(pending, 0);
        assertEq(stock.balanceOf(address(treasury)), pending);
        assertFalse(treasury.book());

        stockFeed.set(100e8);
        usdgFeed.set(1e8);
        (bool healthy, uint256 held) = treasury.stockEquivalentHeld();
        assertTrue(healthy);
        assertEq(held, pending, "pending strategy capital must be visible before booking");
        assertTrue(treasury.book());
        assertEq(treasury.lotCount(), 1);
        assertEq(treasury.bookedStock(), pending);
        assertEq(treasury.unbookedStock(), 0);
    }
}
