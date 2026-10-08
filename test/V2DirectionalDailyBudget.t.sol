// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {StrategyAction} from "../src/v2/strategy/IStrategyPolicy.sol";
import {HedgeFunV2TradablePercentEngineTreasuryCore as Treasury} from "../src/v2/HedgeFunV2TradablePercentEngineTreasury.sol";
import {HedgeFunV2TradablePercentEngineTreasury as Proxy} from "../src/v2/HedgeFunV2TradablePercentEngineTreasury.sol";
import {V2TradablePercentEngineFixture} from "./V2TradablePercentEngine.t.sol";

contract V2DirectionalDailyBudgetTest is V2TradablePercentEngineFixture {
    using stdStorage for StdStorage;
    struct Day { uint64 epoch; uint256 basis; uint256 buyCap; uint256 sellCap; uint256 bought; uint256 sold; }

    function _day(Treasury t) private view returns (Day memory d) {
        (d.epoch, d.basis, d.buyCap, d.sellCap, d.bought, d.sold) = t.dailyRiskLimits();
    }

    function _launchDaily(uint96 nonce) private returns (Treasury) {
        return _launchPercent(nonce, 2500, 2500, uint256(5000) | uint256(2000) << 16, 0);
    }

    function test_sellExhaustionDoesNotConsumeSameDayDipBudget() public {
        Treasury t = _launchDaily(4100);
        Day memory before_ = _day(t);
        uint256 initialValue = Math.mulDiv(t.bookedStock(), 100e18, 1e30);
        assertEq(before_.basis, initialValue);
        assertEq(before_.buyCap, initialValue / 2);
        assertEq(before_.sellCap, initialValue / 5);
        t.execute();
        _advance(600);
        (bool due,,) = t.preview();
        assertFalse(due, "sell budget exhausted while stock allocation is still high");
        _price(40e18);
        uint256 cash = t.reserveUsdg();
        StrategyAction action;
        uint256 offered;
        (due, action, offered) = t.preview();
        assertTrue(due, "the independent buy budget remains available after the sell");
        assertEq(uint256(action), uint256(StrategyAction.BuyStock));
        t.execute();
        Day memory after_ = _day(t);
        assertEq(after_.basis, initialValue, "a price fall cannot shrink today's basis");
        assertEq(after_.bought, cash - t.reserveUsdg());
        assertEq(after_.bought, offered, "preview matches a full fill");
        assertLe(after_.sold, before_.sellCap);
        assertLe(after_.bought, before_.buyCap);
        assertEq(t.turnoverInEpoch(), after_.sold + after_.bought);
    }

    function test_buyExhaustionDoesNotConsumeIndependentSellBudget() public {
        Treasury t = _launchPercent(4106, 2500, 2500, uint256(2000) | uint256(5000) << 16, 0);
        usdg.mint(address(t), 100_000e6);
        t.execute();
        Day memory bought = _day(t);
        assertEq(bought.bought, bought.buyCap);
        assertEq(bought.sold, 0);
        _advance(600);
        _price(2000e18);
        (bool due, StrategyAction action,) = t.preview();
        assertTrue(due);
        assertEq(uint256(action), uint256(StrategyAction.SellStock));
        t.execute();
        Day memory sold = _day(t);
        assertEq(sold.bought, bought.buyCap);
        assertGt(sold.sold, 0);
        assertLe(sold.sold, sold.sellCap);
        assertEq(sold.basis, bought.basis);
    }

    function test_controllerUpgradePreservesPinnedBasisDirectionsAndLossLedger() public {
        Treasury t = _launchDaily(4107);
        address next = address(_replacement(t));
        vm.prank(owner); controller.schedule(address(t), next, "");
        _advance(controller.UPGRADE_DELAY());
        _price(50e18);
        t.execute();
        _advance(600);
        _price(20e18);
        t.execute();
        Day memory before_ = _day(t);
        uint256 loss = t.unrecoveredLossUsdg();
        assertGt(before_.bought, 0);
        assertGt(before_.sold, 0);
        assertGt(loss, 0);
        controller.execute(address(t), "");
        assertEq(Proxy(payable(address(t))).implementation(), next);
        assertEq(keccak256(abi.encode(_day(t))), keccak256(abi.encode(before_)));
        assertEq(t.unrecoveredLossUsdg(), loss);
    }

    function testFuzz_priceMovesAndDonationsCannotReopenDailyCapacity(uint96 rawStock, uint96 rawCash) public {
        Treasury t = _launchDaily(4101);
        Day memory initial = _day(t);
        t.execute();
        Day memory used = _day(t);
        stock.mint(address(t), bound(rawStock, 0, 1000e18));
        usdg.mint(address(t), bound(rawCash, 0, 100_000e6));
        _price(250e18);
        Day memory changed = _day(t);
        assertEq(changed.basis, initial.basis);
        assertEq(changed.buyCap, initial.buyCap);
        assertEq(changed.sellCap, initial.sellCap);
        assertEq(changed.bought, used.bought);
        assertEq(changed.sold, used.sold);
        assertEq(t.turnoverInEpoch(), used.sold);
    }

    function test_nextTradingDateGetsFreshBasisAndIndependentCounters() public {
        Treasury t = _launchDaily(4102);
        t.execute();
        Day memory used = _day(t);
        usdg.mint(address(t), 1000e6);
        _advance(1 days);
        Day memory next = _day(t);
        assertGt(next.epoch, used.epoch);
        assertEq(next.bought, 0);
        assertEq(next.sold, 0);
        assertEq(next.basis, Math.mulDiv(t.bookedStock(), 100e18, 1e30) + t.reserveUsdg());
        assertEq(t.turnoverInEpoch(), used.sold, "view never resets stored accounting");
    }

    function test_sameDateLegacyUsageIsChargedToBothDirections() public {
        Treasury t = _launchDaily(4103);
        Day memory before_ = _day(t);
        uint256 legacy = before_.sellCap / 2;
        // Pre-upgrade storage: an aggregate total exists but the new namespace does not.
        stdstore.target(address(t)).sig("turnoverEpoch()").checked_write(before_.epoch);
        stdstore.target(address(t)).sig("turnoverInEpoch()").checked_write(legacy);
        Day memory pending = _day(t);
        assertEq(pending.bought, legacy);
        assertEq(pending.sold, legacy);
        t.execute();
        Day memory after_ = _day(t);
        assertEq(after_.bought, legacy, "unknown old buys are not reset");
        assertEq(after_.sold, t.turnoverInEpoch());
        assertLe(after_.sold, before_.sellCap);
    }

    function test_failedDustFillDoesNotFreezeBasisOrSpendEitherDirection() public {
        Treasury t = _launchDaily(4104);
        Day memory before_ = _day(t);
        venue.setFillBps(1);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        t.execute();
        assertEq(keccak256(abi.encode(_day(t))), keccak256(abi.encode(before_)));
        usdg.mint(address(t), 1000e6);
        assertEq(_day(t).basis, before_.basis + 1000e6, "unsuccessful action did not pin the basis");
    }

    function test_partialFillChargesOnlyActualInputAndKeepsBuyCapacity() public {
        Treasury t = _launchDaily(4105);
        venue.setFillBps(2500);
        uint256 held = t.bookedStock();
        t.execute();
        Day memory d = _day(t);
        assertEq(d.sold, Math.mulDiv(held - t.bookedStock(), 100e18, 1e30));
        assertLt(d.sold, d.sellCap);
        assertEq(d.bought, 0);
    }
}
