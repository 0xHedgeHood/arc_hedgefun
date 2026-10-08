// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2EngineTreasury, HedgeFunV2EngineTreasuryCore} from "../src/v2/HedgeFunV2EngineTreasury.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {EngineConfig, StrategyCapabilities} from "../src/v2/strategy/IStrategyPolicy.sol";
import {V2RebalancePolicy} from "../src/v2/strategy/V2RebalancePolicy.sol";
import {EngineAccountingVenue} from "./V2StrategyEngineAccounting.t.sol";
import {SwitchableCalendar} from "./mocks/Mocks.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

/// @notice Rebalance gains fund the burn (audit round 4, X-7 / M4-3). The engine's inventory carries one average
///         cost -- booked stock at the live oracle price, bought stock at its fill price, weighted by quantity, and
///         unchanged by a sale -- and a sale above it moves `payoutBps` of its gain into `buybackStock` instead of
///         selling it, for the inherited `buyback()` to burn. `payoutBps = 0` is the rebalance as it was.
contract V2StrategyEngineGainsTest is V2FactoryFixture {
    uint256 private constant PRICE = 100e18;
    uint256 private constant SCALE = 1e30;
    bytes32 private constant GAIN_TOPIC = keccak256("GainToBuyback(uint256,uint256,uint256,uint256)");

    V2TreasuryDeployer internal deployer;
    EngineAccountingVenue internal venue;
    bytes32 internal policyKey;
    uint8 internal engineKind;
    uint96 internal nextNonce = 700;

    struct Step {
        uint256 sold; // stock the pool took
        uint256 moved; // stock that left inventory
        uint256 toBuyback; // stock that moved to the buy-back
        uint256 gain; // from GainToBuyback, 0 when none was emitted
    }

    function setUp() public {
        _setUpV2(18);
        venue = new EngineAccountingVenue(address(stock), address(usdg), 3000, SCALE, PRICE);
        stockPool = venue;
        v3f.set(address(stock), address(usdg), 3000, address(venue));
        vm.prank(owner);
        factory.list(address(stock), address(oracle), address(venue), openPrice, true);
        usdg.mint(address(venue), 10_000_000e6);
        stock.mint(address(venue), 100_000e18);
        deployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        (address a, address b) = deployer.makeChunks(type(HedgeFunV2EngineTreasury).creationCode);
        vm.startPrank(owner);
        policyKey = deployer.registerPolicy(
            address(new V2RebalancePolicy()), 150_000, 160, keccak256("gains-deps"), keccak256("gains-audit")
        );
        engineKind = deployer.registerEngineKind(
            a,
            b,
            StrategyCapabilities.SPOT_ENGINE_V1,
            StrategyCapabilities.CONFIG_SCHEMA_V1,
            StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------ helpers

    function _launch(uint256 payout) internal returns (HedgeFunV2EngineTreasury t) {
        return _launch(payout, _request());
    }

    function _launch(uint256 payout, HedgeFunFactory.Request memory q) internal returns (HedgeFunV2EngineTreasury t) {
        EngineConfig memory c;
        c.schema = StrategyCapabilities.CONFIG_SCHEMA_V1;
        c.engineVersion = StrategyCapabilities.SPOT_ENGINE_V1;
        c.policyKey = policyKey;
        c.words[0] = bytes32(uint256(5000) | uint256(500) << 16 | uint256(600) << 32 | payout << 64);
        c.words[1] = bytes32(uint256(2_000e6));
        c.words[2] = bytes32(uint256(48_000e6));
        q.nonce = nextNonce++;
        deployer.setEngineConfig(q.symbol, q.nonce, engineKind, c);
        _registerCurve(q); // the 80% sale these gains were measured on, now the creator's choice
        (,, bytes32 terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        (, address a,,,) = factory.strategies(id);
        t = HedgeFunV2EngineTreasury(a);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        stock.approve(address(curve), type(uint256).max);
        _graduateV2(curve);
    }

    /// Chainlink and the venue move together, as a print followed by arbitrage does
    function _market(uint256 price) internal {
        venue.setPrice(price);
        stockFeed.set(int256(price / 1e10));
        usdgFeed.set(1e8);
    }

    /// one `execute()`, with the stock conservation it must keep: what left inventory went to the pool or to the
    /// buy-back and nowhere else, and the two buckets still cover the balance exactly
    function _step(HedgeFunV2EngineTreasury t) internal returns (Step memory s) {
        uint256 balance = stock.balanceOf(address(t));
        uint256 booked = t.bookedStock();
        uint256 buyback = t.buybackStock();
        vm.recordLogs();
        t.execute();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(t) && logs[i].topics[0] == GAIN_TOPIC) {
                (s.gain, s.toBuyback,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            }
        }
        if (t.bookedStock() < booked) {
            s.sold = balance - stock.balanceOf(address(t));
            s.moved = booked - t.bookedStock();
            assertEq(t.buybackStock() - buyback, s.moved - s.sold, "what left inventory unsold went to the buy-back");
            assertEq(t.buybackStock() - buyback, s.toBuyback, "the event reports the buy-back's share");
        } else {
            assertEq(t.buybackStock(), buyback, "a buy never touches the buy-back");
        }
        assertEq(t.bookedStock() + t.buybackStock(), stock.balanceOf(address(t)), "buckets cover the balance");
        vm.warp(block.timestamp + 600);
    }

    /// act until the policy is content at `price`, returning the stock moved to the buy-back on the way
    function _runToBand(HedgeFunV2EngineTreasury t, uint256 price) internal returns (uint256 toBuyback) {
        for (uint256 i; i < 64; ++i) {
            _market(price);
            (bool due,,) = t.preview();
            if (!due) return toBuyback;
            toBuyback += _step(t).toBuyback;
        }
        revert("did not reach the band");
    }

    // ------------------------------------------------------------------------------------------------ tests

    /// the econ lane's X-7 path -- sell down at 100, buy at 80, sell again at 100 -- now funds the burn
    function test_rebalanceGainsFundTheBurn() public {
        HedgeFunV2EngineTreasury t = _launch(5000);
        assertEq(t.payoutBps(), 5000);
        assertEq(t.avgCost(), PRICE, "graduation stock is booked at the live oracle price");
        assertEq(_runToBand(t, PRICE), 0, "selling at the average cost realises no gain");
        assertEq(t.buybackStock(), 0);
        _runToBand(t, 80e18);
        assertLt(t.avgCost(), PRICE, "buying at 80 lowers the average cost");
        assertGt(t.avgCost(), 80e18);
        uint256 paid = _runToBand(t, PRICE);
        assertGt(paid, 0, "a sale above the average cost moves part of its gain to the buy-back");
        assertEq(t.buybackStock(), paid);
        (uint256 spent, uint256 burned) = t.buyback();
        assertGt(spent, 0);
        assertGt(burned, 0, "and the buy-back burns");
        assertEq(t.totalBurned(), burned);
        assertEq(t.buybackStock(), paid - spent);
    }

    /// `payoutBps = 0` is the rebalance as it was before gains could fund the burn: the same path moves nothing to
    /// the buy-back, every sale takes out of inventory exactly what the pool took, and there is nothing to burn
    function test_zeroPayoutIsThePlainRebalance() public {
        HedgeFunV2EngineTreasury t = _launch(0);
        assertEq(t.payoutBps(), 0);
        _runToBand(t, PRICE);
        _runToBand(t, 80e18);
        for (uint256 i; i < 64; ++i) {
            _market(PRICE);
            (bool due,,) = t.preview();
            if (!due) break;
            Step memory s = _step(t);
            assertGt(s.gain, 0, "the gain is still measured and reported");
            assertEq(s.toBuyback, 0);
            assertEq(s.moved, s.sold, "a sale takes out exactly what the pool took");
        }
        assertEq(t.buybackStock(), 0);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        t.buyback();
    }

    /// a sale at or below the average cost has no gain: nothing moves to the buy-back and nothing is reported
    function test_aSaleAtOrBelowAverageCostMovesNothing() public {
        HedgeFunV2EngineTreasury t = _launch(10_000);
        uint256 cost = t.avgCost();
        _market(90e18); // still all stock after graduation, so overweight: a sale below cost
        Step memory below = _step(t);
        assertGt(below.sold, 0);
        assertEq(below.gain, 0);
        assertEq(below.moved, below.sold);
        _market(PRICE); // exactly at cost
        Step memory at = _step(t);
        assertGt(at.sold, 0);
        assertEq(at.gain, 0);
        assertEq(t.buybackStock(), 0);
        assertEq(t.avgCost(), cost, "a sale leaves the average cost where it was");
    }

    /// at `payoutBps = 10,000` the whole gain stays in stock and only the principal, `q * cost / p`, is sold
    function test_fullPayoutSellsOnlyThePrincipal() public {
        HedgeFunV2EngineTreasury t = _launch(10_000);
        _runToBand(t, PRICE);
        _runToBand(t, 80e18);
        uint256 cost = t.avgCost();
        _market(PRICE);
        vm.warp((block.timestamp / 1 days + 1) * 1 days); // a fresh turnover epoch
        _market(PRICE);
        Step memory s = _step(t);
        assertGt(s.gain, 0);
        assertEq(s.toBuyback, s.gain, "all of the gain");
        assertEq(t.turnoverInEpoch(), Math.mulDiv(s.moved, PRICE, SCALE), "turnover is what left inventory");
        assertEq(s.sold, s.moved - s.gain);
        assertApproxEqAbs(s.sold, Math.mulDiv(s.moved, cost, PRICE), 1, "the principal at the average cost");
        assertEq(t.avgCost(), cost);
    }

    /// the average cost is exact: booking at the live price, buying at the fill price, both weighted by quantity
    function test_averageCostFollowsBookingsAndBuysAndIgnoresSales() public {
        HedgeFunV2EngineTreasury t = _launch(5000);
        uint256 held = t.bookedStock();
        assertEq(t.avgCost(), PRICE);

        _market(90e18);
        uint256 donation = 50e18;
        stock.transfer(address(t), donation);
        assertTrue(t.book());
        uint256 afterBooking = Math.ceilDiv(held * PRICE + donation * 90e18, held + donation);
        assertEq(t.avgCost(), afterBooking, "booked at 90");

        _runToBand(t, 90e18); // sales only
        uint256 afterSales = t.avgCost();
        assertEq(afterSales, afterBooking, "sales leave it unchanged");

        _market(70e18);
        uint256 booked = t.bookedStock();
        uint256 usdgBefore = usdg.balanceOf(address(t));
        _step(t); // underweight after the drop: a buy
        uint256 spent = usdgBefore - usdg.balanceOf(address(t));
        uint256 bought = t.bookedStock() - booked;
        assertGt(bought, 0);
        assertEq(
            t.avgCost(), Math.ceilDiv(booked * afterSales + spent * SCALE, booked + bought), "bought at the fill price"
        );
    }

    /// book() prices incoming stock at a LIVE oracle print, as kind 0 books a lot; with none it waits
    function test_bookWaitsForALivePrice() public {
        HedgeFunV2EngineTreasury t = _launch(5000);
        uint256 cost = t.avgCost();
        uint256 booked = t.bookedStock();
        stock.transfer(address(t), 10e18);
        vm.warp(block.timestamp + 27 hours); // the feed is past its maximum age: not live
        assertFalse(t.book());
        assertEq(t.bookedStock(), booked);
        assertEq(t.unbookedStock(), 10e18);
        assertEq(t.avgCost(), cost);
        _market(120e18);
        assertTrue(t.book());
        assertEq(t.bookedStock(), booked + 10e18);
        assertEq(t.avgCost(), Math.ceilDiv(booked * cost + 10e18 * 120e18, booked + 10e18));
    }

    /// the live-price requirement is book()'s own: a launch with a band (`bandBpsPerHour > 0`) in a scheduled closure
    /// has health() ok off the frozen feed, which kind 0's band may act on, and book() must still wait
    function test_bookWaitsForALivePriceEvenWhenTheBandServesOne() public {
        SwitchableCalendar calendar = new SwitchableCalendar();
        PriceOracle closable = new PriceOracle(
            address(stock), address(stockFeed), address(usdgFeed), address(calendar), 26 hours, 26 hours
        );
        vm.startPrank(owner);
        factory.list(address(stock), address(closable), address(venue), openPrice, true);
        factory.setBandCeiling(address(stock), 200);
        vm.stopPrank();
        HedgeFunFactory.Request memory q = _request();
        q.bandBpsPerHour = 200;
        HedgeFunV2EngineTreasury t = _launch(5000, q);
        uint256 cost = t.avgCost();
        uint256 booked = t.bookedStock();
        stock.transfer(address(t), 10e18);
        calendar.setClosed(true);
        (bool ok,) = t.health();
        assertTrue(ok, "control: the band serves the frozen feed through a scheduled closure");
        assertFalse(t.book(), "no live print, no booking");
        assertEq(t.bookedStock(), booked);
        assertEq(t.avgCost(), cost);
        calendar.setClosed(false);
        assertTrue(t.book());
        assertEq(t.bookedStock(), booked + 10e18);
    }

    /// a short fill takes out of inventory only the share of the gain and of the payout that the sold amount
    /// stands for, so a dust fill cannot move a whole payout
    function testFuzz_shortFillMovesOnlyItsShare(uint16 fillBps) public {
        fillBps = uint16(bound(fillBps, 1, 10_000));
        HedgeFunV2EngineTreasury t = _launch(5000);
        _runToBand(t, PRICE);
        _runToBand(t, 80e18);
        uint256 cost = t.avgCost();
        _market(PRICE);
        (bool due,, uint256 planned) = t.preview();
        assertTrue(due);
        venue.setFillBps(fillBps);
        uint256 plannedGain = planned - Math.mulDiv(planned, cost, PRICE);
        uint256 plannedPayout = plannedGain * 5000 / 10_000;
        uint256 sale = planned - plannedPayout;
        uint256 booked = t.bookedStock();
        uint256 balance = stock.balanceOf(address(t));
        (bool ok,) = address(t).call(abi.encodeCall(HedgeFunV2EngineTreasuryCore.execute, ()));
        if (!ok) {
            // a fill under the minimum lot reverts atomically
            assertEq(t.bookedStock(), booked);
            assertEq(t.buybackStock(), 0);
            return;
        }
        uint256 sold = balance - stock.balanceOf(address(t));
        uint256 paid = t.buybackStock();
        assertEq(paid, Math.mulDiv(plannedPayout, sold, sale), "the payout scales with the fill");
        assertEq(booked - t.bookedStock(), sold + paid);
        assertEq(t.bookedStock() + t.buybackStock(), stock.balanceOf(address(t)));
        assertLe(Math.mulDiv(sold + paid, PRICE, SCALE), 2_000e6, "one action moves at most maxTradeUsdg");
    }
}
