// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {TradingCalendar} from "../src/TradingCalendar.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2EngineTreasury} from "../src/v2/HedgeFunV2EngineTreasury.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {EngineConfig, StrategyCapabilities} from "../src/v2/strategy/IStrategyPolicy.sol";
import {AccountingAlwaysSellPolicy, EngineAccountingVenue} from "./V2StrategyEngineAccounting.t.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

/// @notice The daily turnover cap follows the US market day (audit round 4, X-2 / L4-2): its bucket is the listing
///         oracle calendar's `tradingDate`, which rolls at 20:00 New York time with US daylight saving, not the UTC
///         calendar day. Every case runs a real `TradingCalendar` on real 2026 dates, with one action per bucket
///         (`maxDailyTurnoverUsdg == maxTradeUsdg`), so "same bucket" reads as `NotDue` and "new bucket" as a fill.
contract V2StrategyEngineTradingDayTest is V2FactoryFixture {
    uint256 private constant PRICE = 100e18;
    uint256 private constant COOLDOWN = 600;
    uint256 private constant CAP = 100e6;

    // session boundaries: 20:00 New York time, as UTC timestamps
    uint256 private constant WINTER_ROLL = 1_768_438_800; // Wed 2026-01-14 20:00 EST = Thu 01:00 UTC
    uint256 private constant SUMMER_ROLL = 1_784_160_000; // Wed 2026-07-15 20:00 EDT = Thu 00:00 UTC
    uint256 private constant THU_BEFORE_DST = 1_772_758_800; // Thu 2026-03-05 20:00 EST = Fri 01:00 UTC
    uint256 private constant MON_AFTER_DST = 1_773_100_800; // Mon 2026-03-09 20:00 EDT = Tue 00:00 UTC
    uint256 private constant THU_BEFORE_STD = 1_793_318_400; // Thu 2026-10-29 20:00 EDT = Fri 00:00 UTC
    uint256 private constant MON_AFTER_STD = 1_793_667_600; // Mon 2026-11-02 20:00 EST = Tue 01:00 UTC
    uint256 private constant NEW_YEAR_UTC = 1_798_761_600; // Fri 2027-01-01 00:00 UTC = Thu 2026-12-31 19:00 EST

    TradingCalendar internal calendar;
    PriceOracle internal usOracle;
    EngineAccountingVenue internal venue;
    V2TreasuryDeployer internal deployer;
    bytes32 internal policyKey;
    uint8 internal engineKind;
    uint96 internal nextNonce = 900;

    function setUp() public {
        _setUpV2(18);
        calendar = new TradingCalendar(owner);
        usOracle = new PriceOracle(address(stock), address(stockFeed), address(usdgFeed), address(calendar), 26 hours, 26 hours);
        venue = new EngineAccountingVenue(address(stock), address(usdg), 3000, 1e30, PRICE);
        stockPool = venue;
        v3f.set(address(stock), address(usdg), 3000, address(venue));
        vm.prank(owner);
        factory.list(address(stock), address(usOracle), address(venue), openPrice, true);
        usdg.mint(address(venue), 10_000_000e6);
        stock.mint(address(venue), 100_000e18);
        deployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        (address a, address b) = deployer.makeChunks(type(HedgeFunV2EngineTreasury).creationCode);
        vm.startPrank(owner);
        policyKey = deployer.registerPolicy(
            address(new AccountingAlwaysSellPolicy()), 100_000, 160, keccak256("day-deps"), keccak256("day-audit")
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

    /// launch and graduate at `at`, a moment the market is open
    function _launchAt(uint256 at) internal returns (HedgeFunV2EngineTreasury t) {
        _at(at);
        EngineConfig memory c;
        c.schema = StrategyCapabilities.CONFIG_SCHEMA_V1;
        c.engineVersion = StrategyCapabilities.SPOT_ENGINE_V1;
        c.policyKey = policyKey;
        c.words[0] = bytes32(uint256(5000) | uint256(500) << 16 | COOLDOWN << 32);
        c.words[1] = bytes32(CAP);
        c.words[2] = bytes32(CAP); // one action per trading date
        HedgeFunFactory.Request memory q = _request();
        q.nonce = nextNonce++;
        deployer.setEngineConfig(q.symbol, q.nonce, engineKind, c);
        (,, bytes32 terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        (, address a,,,) = factory.strategies(id);
        t = HedgeFunV2EngineTreasury(a);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        stock.approve(address(curve), type(uint256).max);
        _graduateV2(curve);
        assertEq(address(t.tradingCalendar()), address(calendar), "the listing oracle's own calendar");
    }

    function _at(uint256 ts) internal {
        vm.warp(ts);
        venue.setPrice(PRICE);
        stockFeed.set(100e8);
        usdgFeed.set(1e8);
    }

    /// an action at `ts` that must land in trading date `date`, in a fresh bucket
    function _fills(HedgeFunV2EngineTreasury t, uint256 ts, uint256 date) internal {
        _at(ts);
        (bool due,,) = t.preview();
        assertTrue(due, "preview agrees: a fresh bucket");
        t.execute();
        assertEq(t.turnoverEpoch(), date, "the bucket is the trading date");
        assertEq(t.turnoverEpoch(), calendar.tradingDate(ts));
        assertEq(t.turnoverInEpoch(), CAP, "a fresh bucket");
    }

    /// an attempt at `ts` (past the cooldown) that falls in the bucket already spent
    function _spent(HedgeFunV2EngineTreasury t, uint256 ts) internal {
        _at(ts);
        assertEq(calendar.tradingDate(ts), t.turnoverEpoch(), "same trading date");
        (bool due,,) = t.preview();
        assertFalse(due, "preview agrees: the bucket is spent");
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        t.execute();
    }

    /// the full cycle around one 20:00 New York roll: 15 minutes before it fills the bucket, 5 minutes before it is
    /// the same bucket, 5 minutes after it is the next one
    function _rollsAt(uint256 roll) internal {
        HedgeFunV2EngineTreasury t = _launchAt(roll - 6 hours);
        uint256 date = calendar.tradingDate(roll - 1);
        _fills(t, roll - 15 minutes, date);
        _spent(t, roll - 5 minutes);
        _fills(t, roll + 5 minutes, date + 1);
    }

    /// Winter: New York's 20:00 is 01:00 UTC. 23:55 and 00:05 UTC are one trading date -- the UTC day would have
    /// split them and allowed a second cap -- and 19:55 / 20:05 New York are two.
    function test_winterBucketRollsAt2000NewYorkNotAtMidnightUtc() public {
        HedgeFunV2EngineTreasury t = _launchAt(WINTER_ROLL - 10 hours);
        uint256 date = calendar.tradingDate(WINTER_ROLL - 1);
        assertEq(date, 20_467, "Wednesday 14 January 2026, as days since 1970-01-01");
        _fills(t, WINTER_ROLL - 65 minutes, date); // 23:55 UTC Wed = 18:55 EST
        _spent(t, WINTER_ROLL - 55 minutes); // 00:05 UTC Thu = 19:05 EST: a new UTC day, the same trading date
        _spent(t, WINTER_ROLL - 5 minutes); // 00:55 UTC = 19:55 EST
        _fills(t, WINTER_ROLL + 5 minutes, date + 1); // 01:05 UTC = 20:05 EST
    }

    /// Summer: New York's 20:00 is 00:00 UTC, and the roll moves with it.
    function test_summerBucketRollsAt2000NewYork() public {
        _rollsAt(SUMMER_ROLL);
    }

    /// Both sides of the March switch (Sunday 8 March): the Thursday before rolls at 01:00 UTC, the Monday after at
    /// 00:00 UTC. (Friday's 20:00 opens the weekend, when nothing trades.)
    function test_dstStartMovesTheRollAnHourEarlierInUtc() public {
        _rollsAt(THU_BEFORE_DST);
        _rollsAt(MON_AFTER_DST);
    }

    /// Both sides of the November switch (Sunday 1 November): the Thursday before rolls at 00:00 UTC, the Monday
    /// after at 01:00 UTC.
    function test_dstEndMovesTheRollAnHourLaterInUtc() public {
        _rollsAt(THU_BEFORE_STD);
        _rollsAt(MON_AFTER_STD);
    }

    /// The year turns in UTC at 19:00 New York time on New Year's Eve; the trading date does not.
    function test_theUtcYearBoundaryIsNotABucketBoundary() public {
        HedgeFunV2EngineTreasury t = _launchAt(NEW_YEAR_UTC - 8 hours);
        uint256 date = calendar.tradingDate(NEW_YEAR_UTC - 1);
        _fills(t, NEW_YEAR_UTC - 5 minutes, date); // 23:55 UTC Dec 31
        _spent(t, NEW_YEAR_UTC + 5 minutes); // 00:05 UTC Jan 1 2027, still the trading date of Dec 31
    }
}
