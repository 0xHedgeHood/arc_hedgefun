// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolTrader} from "../src/PoolTrader.sol";
import {HedgeFunV2AssetPercentEngineTreasury} from "../src/v2/HedgeFunV2AssetPercentEngineTreasury.sol";
import {StrategyAction} from "../src/v2/strategy/IStrategyPolicy.sol";
import {ISwapCallback, MockLpPool} from "./mocks/Mocks.sol";
import {V2AssetPercentEngineFixture} from "./V2AssetPercentEngine.t.sol";

contract PercentOrderedVenue is MockLpPool {
    bool private immutable stockFirst;
    uint16 private fill = 10_000;
    constructor(address stock_, address usdg_, bool stockFirst_)
        MockLpPool(stockFirst_ ? stock_ : usdg_, stockFirst_ ? usdg_ : stock_, 3000)
    {
        stockFirst = stockFirst_;
        sqrtPriceX96 = uint160(Math.sqrt(stockFirst_ ? Math.mulDiv(100e18, 1 << 192, 1e30)
            : Math.mulDiv(1e30, 1 << 192, 100e18)));
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }
    function zeroFill() external { fill = 0; }
    function swap(address recipient, bool zeroForOne, int256 specified, uint160 limit, bytes calldata data)
        external returns (int256 a0, int256 a1)
    {
        require(specified > 0 && (zeroForOne ? limit < sqrtPriceX96 : limit > sqrtPriceX96));
        uint256 input = Math.mulDiv(uint256(specified), fill, 10_000);
        uint256 net = Math.mulDiv(input, 997_000, 1_000_000);
        bool buy = zeroForOne != stockFirst;
        uint256 output = buy ? Math.mulDiv(net, 1e30, 100e18) : Math.mulDiv(net, 100e18, 1e30);
        IERC20(zeroForOne ? token1 : token0).transfer(recipient, output);
        (a0, a1) = zeroForOne ? (int256(input), -int256(output)) : (-int256(output), int256(input));
        ISwapCallback(msg.sender).uniswapV3SwapCallback(a0, a1, data);
    }
}

contract V2AssetPercentOrderingTest is V2AssetPercentEngineFixture {
    function _ordered(bool first, uint96 nonce) private returns (HedgeFunV2AssetPercentEngineTreasury t, PercentOrderedVenue pool) {
        pool = new PercentOrderedVenue(address(stock), address(usdg), first);
        v3f.set(address(stock), address(usdg), 3000, address(pool));
        vm.prank(owner); factory.list(address(stock), address(oracle), address(pool), openPrice, true);
        usdg.mint(address(pool), 10_000_000e6); stock.mint(address(pool), 100_000e18);
        t = _launchPercent(nonce, 1000, 5000, 0);
        assertEq(t.stockIsToken0(), first);
    }

    function testFuzz_bothTokenOrderingsAndDirectionsUseExactSamePercentUnits(bool first, bool buy) public {
        (HedgeFunV2AssetPercentEngineTreasury t,) = _ordered(first, 1400);
        if (buy) usdg.mint(address(t), _risk(t).nav * 3);
        Risk memory r = _risk(t);
        (bool due, StrategyAction action, uint256 amount) = t.preview(); assertTrue(due);
        assertEq(uint256(action), uint256(buy ? StrategyAction.BuyStock : StrategyAction.SellStock));
        uint256 cash = t.reserveUsdg(); uint256 held = t.bookedStock();
        t.execute();
        uint256 spent = buy ? cash - t.reserveUsdg() : Math.mulDiv(held - t.bookedStock(), PRICE, 1e30);
        assertEq(t.turnoverInEpoch(), spent); assertLe(spent, r.trade); assertLe(spent, r.daily);
        if (buy) assertEq(spent, amount); else assertEq(held - t.bookedStock(), amount);
        assertEq(t.bookedStock() + t.buybackStock(), stock.balanceOf(address(t)));
    }

    function testFuzz_zeroFillCannotCommitActionOrBudget(bool first, bool buy) public {
        (HedgeFunV2AssetPercentEngineTreasury t, PercentOrderedVenue pool) = _ordered(first, 1401);
        if (buy) usdg.mint(address(t), _risk(t).nav * 3);
        uint256 cash = t.reserveUsdg(); uint256 held = t.bookedStock(); pool.zeroFill();
        vm.expectRevert(PoolTrader.Slippage.selector); t.execute();
        assertEq(t.reserveUsdg(), cash); assertEq(t.bookedStock(), held);
        assertEq(t.strategyNonce(), 0); assertEq(t.lastStrategyAt(), 0); assertEq(t.turnoverInEpoch(), 0);
    }
}
