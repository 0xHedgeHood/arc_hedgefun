// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";
import {V2LiquidityVault} from "../src/v2/V2LiquidityVault.sol";
import {MockToken} from "./mocks/Mocks.sol";

contract V2LiquidityFeeSink {
    IERC20 public immutable stock;
    uint256 public credited;
    bool public rejectStock;
    constructor(IERC20 stock_) { stock = stock_; }
    function setRejectStock(bool reject) external { rejectStock = reject; }
    function creditLiquidityFee(uint256 amount) external {
        require(!rejectStock, "stock refused");
        stock.transferFrom(msg.sender, address(this), amount);
        credited += amount;
    }
}

contract V2VaultTestHook {
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }
}

contract ReenteringVaultStock is MockToken {
    V2LiquidityVault public target;
    address public sink;
    bool public armed;
    bool public attempted;
    bool public reentered;
    bytes4 public failureSelector;

    constructor() MockToken("STOCK", 18) {}

    function arm(V2LiquidityVault target_, address sink_) external {
        target = target_;
        sink = sink_;
        armed = true;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (armed && from == address(target) && to == sink && amount != 0) {
            armed = false;
            attempted = true;
            (bool ok, bytes memory reason) = address(target).call(abi.encodeCall(V2LiquidityVault.collectFees, ()));
            reentered = ok;
            if (!ok && reason.length >= 4) {
                bytes4 selector;
                assembly { selector := mload(add(reason, 0x20)) }
                failureSelector = selector;
            }
        }
    }
}

contract V2LiquidityVaultTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager private pm;
    PoolSwapTest private swapRouter;
    HedgeFunToken private fun;
    ReenteringVaultStock private stock;
    V2LiquidityFeeSink private sink;
    V2LiquidityVault private vault;
    PoolKey private key;

    function setUp() public {
        pm = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(pm);
        fun = new HedgeFunToken("FUN", "FUN", 1_000_000e18, address(this), address(this));
        stock = new ReenteringVaultStock();
        stock.mint(address(this), 1_000_000e18);
        sink = new V2LiquidityFeeSink(IERC20(address(stock)));
        // Valid hook address with only the mandatory before-initialize callback; no swap/tax effects in this unit test.
        address noOpHook = address(0x102000);
        vm.etch(noOpHook, address(new V2VaultTestHook()).code);
        address c0 = address(fun) < address(stock) ? address(fun) : address(stock);
        address c1 = address(fun) < address(stock) ? address(stock) : address(fun);
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(noOpHook));
        vault = new V2LiquidityVault(address(this), pm, key, address(fun), address(stock), address(sink));
        fun.transfer(address(vault), 1000e18);
        stock.transfer(address(vault), 1000e18);
        fun.approve(address(swapRouter), type(uint256).max);
        stock.approve(address(swapRouter), type(uint256).max);
    }

    function test_seedLocksPositionAndReturnsUnusedBudget() public {
        uint256 stockBefore = stock.balanceOf(address(this));
        uint256 funBefore = fun.balanceOf(address(this));
        (uint256 used0, uint256 used1) = vault.seed(uint160(1 << 96), 500e18, 1000e18, 1000e18);
        assertTrue(vault.seeded());
        assertGt(used0, 0);
        assertGt(used1, 0);
        assertEq(stock.balanceOf(address(this)), stockBefore + 1000e18 - (address(stock) < address(fun) ? used0 : used1));
        assertEq(fun.balanceOf(address(this)), funBefore, "unused project tokens are never returned to the factory");
        assertEq(stock.balanceOf(address(vault)), 0);
        assertEq(fun.balanceOf(address(vault)), vault.lockedSeedTokens());
        assertEq(fun.balanceOf(address(pm)) + vault.lockedSeedTokens(), 1000e18);
        assertEq(fun.totalSupply(), 1_000_000e18, "seeding does not burn supply");
        assertGt(vault.surplusLiquidity(), 0);
        PoolId id = key.toId();
        assertGt(pm.getLiquidity(id), 0);
        vm.expectRevert(V2LiquidityVault.AlreadySeeded.selector);
        vault.seed(uint160(1 << 96), 1, 1, 1);
    }

    function test_collectsOnlyEarnedFeesAndKeepsPrincipalLocked() public {
        vault.seed(uint160(1 << 96), 500e18, 1000e18, 1000e18);
        PoolId id = key.toId();
        uint128 lpBefore = pm.getLiquidity(id);
        bool stockIs0 = address(stock) < address(fun);
        swapRouter.swap(key, SwapParams({zeroForOne: stockIs0, amountSpecified: -int256(10e18),
            sqrtPriceLimitX96: stockIs0 ? uint160(1 << 95) : uint160(1 << 97)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        swapRouter.swap(key, SwapParams({zeroForOne: !stockIs0, amountSpecified: -int256(10e18),
            sqrtPriceLimitX96: stockIs0 ? uint160(1 << 97) : uint160(1 << 95)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        uint256 supplyBefore = fun.totalSupply();
        uint256 treasuryBefore = stock.balanceOf(address(sink));
        (uint256 stockFee, uint256 burned) = vault.collectFees();
        assertGt(stockFee, 0);
        assertGt(burned, 0);
        assertEq(stock.balanceOf(address(sink)) - treasuryBefore, stockFee);
        assertEq(sink.credited(), stockFee);
        assertEq(supplyBefore - fun.totalSupply(), burned);
        _assertLockedPositions(lpBefore);
        assertEq(stock.balanceOf(address(vault)), 0);
        assertEq(fun.balanceOf(address(vault)), vault.lockedSeedTokens());
        (uint256 secondStock, uint256 secondToken) = vault.collectFees();
        assertEq(secondStock, 0);
        assertEq(secondToken, 0);
        _assertLockedPositions(lpBefore);
    }

    function test_stockCreditFailureParksFeeButStillBurnsTokenFee() public {
        vault.seed(uint160(1 << 96), 500e18, 1000e18, 1000e18);
        uint128 lpBefore = pm.getLiquidity(key.toId());
        bool stockIs0 = address(stock) < address(fun);
        swapRouter.swap(key, SwapParams({zeroForOne: stockIs0, amountSpecified: -int256(10e18),
            sqrtPriceLimitX96: stockIs0 ? uint160(1 << 95) : uint160(1 << 97)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        swapRouter.swap(key, SwapParams({zeroForOne: !stockIs0, amountSpecified: -int256(10e18),
            sqrtPriceLimitX96: stockIs0 ? uint160(1 << 97) : uint160(1 << 95)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

        sink.setRejectStock(true);
        uint256 supplyBefore = fun.totalSupply();
        (uint256 delivered, uint256 burned) = vault.collectFees();
        assertEq(delivered, 0);
        assertGt(burned, 0);
        assertGt(stock.balanceOf(address(vault)), 0);
        assertEq(sink.credited(), 0);
        assertEq(stock.allowance(address(vault), address(sink)), 0);
        assertEq(fun.totalSupply(), supplyBefore - burned);
        _assertLockedPositions(lpBefore);

        sink.setRejectStock(false);
        (delivered, burned) = vault.collectFees();
        assertGt(delivered, 0);
        assertEq(burned, 0);
        assertEq(sink.credited(), delivered);
        assertEq(stock.balanceOf(address(vault)), 0);
        assertEq(stock.allowance(address(vault), address(sink)), 0);
        _assertLockedPositions(lpBefore);
    }

    function test_callbackCannotBeCalledByOutsider() public {
        vm.expectRevert(V2LiquidityVault.NotPoolManager.selector);
        vault.unlockCallback("");
        vm.expectRevert(V2LiquidityVault.Busy.selector);
        vault.creditPendingStock();
        vm.expectRevert(V2LiquidityVault.NotSeeded.selector);
        vault.collectFees();
    }

    function test_tokenSideFeeBurnsWithoutTreasuryCredit() public {
        vault.seed(uint160(1 << 96), 500e18, 1000e18, 1000e18);
        uint128 lpBefore = pm.getLiquidity(key.toId());
        bool funIs0 = address(fun) < address(stock);
        swapRouter.swap(key, SwapParams({zeroForOne: funIs0, amountSpecified: -int256(10e18),
            sqrtPriceLimitX96: funIs0 ? uint160(1 << 95) : uint160(1 << 97)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        uint256 supplyBefore = fun.totalSupply();
        (uint256 stockFee, uint256 burned) = vault.collectFees();
        assertEq(stockFee, 0);
        assertGt(burned, 0);
        assertEq(sink.credited(), 0);
        assertEq(fun.totalSupply(), supplyBefore - burned);
        _assertLockedPositions(lpBefore);
    }

    function test_stockCallbackCannotReenterFeeCollection() public {
        vault.seed(uint160(1 << 96), 500e18, 1000e18, 1000e18);
        uint128 lpBefore = pm.getLiquidity(key.toId());
        bool stockIs0 = address(stock) < address(fun);
        swapRouter.swap(key, SwapParams({zeroForOne: stockIs0, amountSpecified: -int256(10e18),
            sqrtPriceLimitX96: stockIs0 ? uint160(1 << 95) : uint160(1 << 97)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        stock.arm(vault, address(sink));
        (uint256 stockFee, uint256 burned) = vault.collectFees();
        assertGt(stockFee, 0);
        assertEq(burned, 0);
        assertTrue(stock.attempted());
        assertFalse(stock.reentered());
        assertEq(stock.failureSelector(), V2LiquidityVault.Busy.selector);
        assertEq(stock.balanceOf(address(sink)), stockFee);
        assertEq(sink.credited(), stockFee);
        assertEq(stock.allowance(address(vault), address(sink)), 0);
        _assertLockedPositions(lpBefore);
    }

    function _assertLockedPositions(uint128 baseLiquidity) private view {
        (uint128 base,,) = pm.getPositionInfo(key.toId(), address(vault),
            TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), bytes32(0));
        (uint128 extra,,) = pm.getPositionInfo(key.toId(), address(vault),
            vault.surplusTickLower(), vault.surplusTickUpper(), bytes32(uint256(1)));
        assertEq(base, baseLiquidity, "fee collection preserves base position principal");
        assertEq(extra, vault.surplusLiquidity(), "fee collection preserves surplus position principal");
    }
}
