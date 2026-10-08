// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IV3Factory, IV3Pool} from "../script/testnet/TestnetMarket.sol";
import {TestnetEthBridgeLiquidity} from "../script/testnet/TestnetEthBridgeLiquidity.sol";
import {MockToken} from "./mocks/Mocks.sol";

contract BridgeWrappedFixture is ERC20 {
    constructor() ERC20("Bridge fixture WETH", "WETH") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}(""); require(ok);
    }
}

contract BridgeSwapProbe {
    IV3Pool private immutable pool;
    IERC20 private immutable weth;
    constructor(IV3Pool pool_, IERC20 weth_) { pool = pool_; weth = weth_; }
    function buyUsdg(uint256 amount) external returns (uint256 received) {
        require(weth.transferFrom(msg.sender, address(this), amount));
        (int256 a0, int256 a1) = pool.swap(address(this), false, int256(amount), TickMath.MAX_SQRT_PRICE - 1, "");
        require(a0 < 0 && a1 > 0 && uint256(a1) == amount);
        received = uint256(-a0);
    }
    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        require(msg.sender == address(pool) && a0 < 0 && a1 > 0);
        require(weth.transfer(address(pool), uint256(a1)));
    }
}

contract TestnetV2EthBridgeLiquidityTest is Test {
    receive() external payable {}
    BridgeWrappedFixture private wrapped;
    MockToken private stable;
    IV3Factory private factory;
    IV3Pool private pool;
    TestnetEthBridgeLiquidity private bridge;
    uint128 private liquidity;

    function setUp() public {
        vm.deal(address(this), 0.01 ether);
        address weth = address(0x8888);
        address usdg = address(0x2222);
        vm.etch(weth, address(new BridgeWrappedFixture()).code);
        vm.etch(usdg, address(new MockToken("tUSDG", 6)).code);
        wrapped = BridgeWrappedFixture(weth);
        stable = MockToken(usdg);
        bytes memory code = vm.readFileBinary("lib/v4-core/test/bin/v3Factory.bytecode");
        address deployed;
        assembly ("memory-safe") { deployed := create(0, add(code, 32), mload(code)) }
        factory = IV3Factory(deployed);
        pool = IV3Pool(factory.createPool(weth, usdg, 3000));
        assertEq(factory.getPool(weth, usdg, 500), address(0), "fee-500 slot stays free for full ETH market");
        _buildPosition(weth, usdg, deployed);
    }

    function _buildPosition(address weth, address usdg, address deployed) private {
        uint160 sqrtP = uint160(Math.sqrt(Math.mulDiv(1e30, 1 << 192, 3000e18)));
        pool.initialize(sqrtP);
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 centre = tick / 60 * 60;
        if (tick < 0 && tick % 60 != 0) centre -= 60;
        int24 lo = centre - 6000;
        int24 hi = centre + 6000;
        liquidity = uint128(Math.mulDiv(0.005 ether, 1 << 96, uint256(sqrtP) - TickMath.getSqrtPriceAtTick(lo)));
        bridge = new TestnetEthBridgeLiquidity(address(this), deployed, weth, usdg, address(pool), lo, hi);
        wrapped.deposit{value: 0.0055 ether}();
        assertTrue(wrapped.transfer(address(bridge), 0.0055 ether));
        stable.mint(address(bridge), 20e6);
    }

    function test_realV3PositionAndUnusedPrefundingCanBeRecoveredOnlyByOwner() public {
        vm.expectRevert(TestnetEthBridgeLiquidity.BadCallback.selector);
        bridge.uniswapV3MintCallback(1, 1, "");
        (uint256 providedUsdg, uint256 providedWeth) = bridge.provide(liquidity, 20e6, 0.005 ether);
        assertGe(providedUsdg, 14e6);
        assertLe(providedUsdg, 16e6);
        assertApproxEqAbs(providedWeth, 0.005 ether, 5000);
        assertEq(pool.liquidity(), liquidity);
        assertEq(bridge.liquidityOwned(), liquidity);
        assertGe(wrapped.balanceOf(address(bridge)), 0.0005 ether);

        vm.prank(address(0xBAD)); vm.expectRevert(); bridge.decrease(liquidity);
        vm.prank(address(0xBAD)); vm.expectRevert(); bridge.collect();
        vm.prank(address(0xBAD)); vm.expectRevert(); bridge.withdrawUnused();
        bridge.decrease(liquidity);
        bridge.collect();
        bridge.withdrawUnused();
        assertEq(pool.liquidity(), 0);
        assertEq(bridge.liquidityOwned(), 0);
        assertEq(wrapped.balanceOf(address(bridge)), 0);
        assertEq(stable.balanceOf(address(bridge)), 0);
        assertApproxEqAbs(wrapped.balanceOf(address(this)), 0.0055 ether, 1000);
        assertApproxEqAbs(stable.balanceOf(address(this)), 20e6, 2);
        assertEq(address(wrapped).balance, wrapped.totalSupply());
    }

    function test_collectCrystallizesTradingFeesWhilePositionIsStillActive() public {
        bridge.provide(liquidity, 20e6, 0.005 ether);
        BridgeSwapProbe probe = new BridgeSwapProbe(pool, IERC20(address(wrapped)));
        wrapped.deposit{value: 0.00001 ether}();
        wrapped.approve(address(probe), 0.00001 ether);
        assertGt(probe.buyUsdg(0.00001 ether), 0);
        uint256 beforeFee = wrapped.balanceOf(address(this));
        (uint128 collectedUsdg, uint128 collectedWeth) = bridge.collect();
        assertEq(collectedUsdg, 0);
        assertGt(collectedWeth, 0);
        assertEq(wrapped.balanceOf(address(this)), beforeFee + collectedWeth);
        assertEq(bridge.liquidityOwned(), liquidity);
        bridge.decrease(liquidity);
        bridge.collect();
        bridge.withdrawUnused();
        assertEq(bridge.liquidityOwned(), 0);
        assertEq(wrapped.balanceOf(address(bridge)), 0);
        assertEq(stable.balanceOf(address(bridge)), 0);
    }
}
