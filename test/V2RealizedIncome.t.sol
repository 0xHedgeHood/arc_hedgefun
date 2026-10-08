// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunV2TradablePercentEngineTreasuryCore as Treasury} from "../src/v2/HedgeFunV2TradablePercentEngineTreasury.sol";
import {V2TradablePercentEngineFixture} from "./V2TradablePercentEngine.t.sol";
import {StrategyAction} from "../src/v2/strategy/IStrategyPolicy.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";

contract V2RealizedIncomeTest is V2TradablePercentEngineFixture {
    function test_markedGainBelowFeesAndRewardDoesNotFundBuyback() public {
        Treasury t = _launchPercent(5300, 2500, 2500, 10_000, 10_000);
        _price(1002e17); // +0.2%, less than 0.3% venue fee plus 0.5% keeper reward
        uint256 held = t.bookedStock();
        t.execute();
        assertEq(t.buybackStock(), 0, "mark-to-oracle gain is not earned net income");
        uint256 principalCost = Math.mulDiv(held - t.bookedStock(), 100e18, 1e30, Math.Rounding.Ceil);
        assertEq(t.unrecoveredLossUsdg(), principalCost - t.reserveUsdg());
        assertGt(t.unrecoveredLossUsdg(), 0);
    }

    function test_lossesSurviveDateRolloverAndMustBeRecoveredBeforePayout() public {
        Treasury t = _launchPercent(5301, 2500, 2500, 10_000, 10_000);
        _price(50e18);
        t.execute();
        uint256 loss = t.unrecoveredLossUsdg();
        assertGt(loss, 0);
        assertEq(t.buybackStock(), 0);
        _advance(1 days);
        assertEq(t.unrecoveredLossUsdg(), loss, "daily quota rollover does not erase losses");
        _price(120e18);
        t.execute();
        assertGt(t.unrecoveredLossUsdg(), 0);
        assertLt(t.unrecoveredLossUsdg(), loss);
        assertEq(t.buybackStock(), 0, "later profit first repairs prior losses");
        _advance(1 days);
        _price(1000e18);
        t.execute();
        assertEq(t.unrecoveredLossUsdg(), 0);
        assertGt(t.buybackStock(), 0, "only net excess can fund FUN buyback");
    }

    function test_lpFeeIncomeRemainsEligibleWhileStrategyCarriesLoss() public {
        Treasury t = _launchPercent(5302, 2500, 2500, 10_000, 5000);
        _price(50e18);
        t.execute();
        uint256 loss = t.unrecoveredLossUsdg();
        stock.mint(t.liquidityVault(), 1e18);
        vm.startPrank(t.liquidityVault());
        stock.approve(address(t), 1e18);
        t.creditLiquidityFee(1e18);
        vm.stopPrank();
        assertEq(t.buybackStock(), 1e18, "earned LP fee is an independent income source");
        assertEq(t.unrecoveredLossUsdg(), loss);
    }

    /// A sale withholds its marked gain in stock and swaps the rest. With a loss still to recover, none of the
    /// withheld stock is reserved, so only the swapped part leaves inventory. That part can be under a lot while
    /// the whole offer is over one: the fill is complete, and it must not be refused as dust.
    function test_lossCarryDoesNotStallASaleThePreviewReportsDue() public {
        Treasury t = _launchPercent(5304, 2500, 1, 10_000, 10_000); // 0.01% of the stock per sale, all gain paid out
        _price(1000e18); // ten times cost: nine tenths of an offer is marked gain
        uint256 carry = 40e6;
        vm.store(address(t), _lossSlot(), bytes32(carry));
        assertEq(t.unrecoveredLossUsdg(), carry, "the test writes the loss carry where the treasury reads it");

        (bool due, StrategyAction action, uint256 offered) = t.preview();
        assertTrue(due);
        assertEq(uint256(action), uint256(StrategyAction.SellStock));
        uint256 lot = t.params().minLotUsdg;
        assertGe(Math.mulDiv(offered, 1000e18, 1e30), lot, "the offer is a full lot");
        assertLt(Math.mulDiv(offered, 100e18, 1e30), lot, "the part that is swapped is under a lot");

        uint256 held = t.bookedStock();
        t.execute();
        uint256 moved = held - t.bookedStock();
        assertGt(moved, 0);
        assertLt(moved, offered, "the withheld stock stays in inventory while the loss is recovered");
        assertEq(t.buybackStock(), 0, "nothing is reserved before the loss is recovered");
        assertLt(t.unrecoveredLossUsdg(), carry, "the sale's gain went to the loss");
        assertEq(t.bookedStock(), stock.balanceOf(address(t)));
    }

    /// The same offer filled a tenth: that is the dust fill the minimum is there for, loss carry or not.
    function test_dustFillIsStillRefusedWithALossCarry() public {
        Treasury t = _launchPercent(5305, 2500, 1, 10_000, 10_000);
        _price(1000e18);
        vm.store(address(t), _lossSlot(), bytes32(uint256(40e6)));
        venue.setFillBps(1000);
        (bool due,,) = t.preview();
        assertTrue(due);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        t.execute();
    }

    function _lossSlot() private pure returns (bytes32) {
        return bytes32(uint256(keccak256("hedgefun.v2.tradable-percent.directional-budget.v1")) + 4);
    }

    function testFuzz_reservedIncomeCannotExceedNetRealizedPayout(uint16 rawPayout, uint16 rawFill, uint256 rawPrice) public {
        uint256 payout = bound(rawPayout, 1, 10_000);
        Treasury t = _launchPercent(5303, 2500, 2500, 10_000, payout);
        uint256 price = bound(rawPrice, 101e18, 50_000e18); // $101..$50,000
        _price(price);
        venue.setFillBps(uint16(bound(rawFill, 1000, 10_000)));
        uint256 beforeHeld = t.bookedStock();
        t.execute();
        uint256 removed = beforeHeld - t.bookedStock();
        uint256 reserve = t.buybackStock();
        uint256 stockValue = Math.mulDiv(reserve, price, 1e30);
        uint256 cost = Math.mulDiv(removed, 100e18, 1e30, Math.Rounding.Ceil);
        uint256 netValue = t.reserveUsdg() + stockValue;
        if (netValue <= cost) assertEq(reserve, 0);
        else assertLe(stockValue, Math.mulDiv(netValue - cost, payout, 10_000) + 1);
        assertEq(t.bookedStock() + reserve, stock.balanceOf(address(t)));
    }
}
