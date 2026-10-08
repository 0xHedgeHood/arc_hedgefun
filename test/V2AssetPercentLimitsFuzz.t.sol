// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunV2AssetPercentEngineTreasury} from "../src/v2/HedgeFunV2AssetPercentEngineTreasury.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {V2AssetPercentEngineFixture} from "./V2AssetPercentEngine.t.sol";
import {FundAssetMath} from "./utils/FundAssetMath.sol";

/// @dev Randomized normal keeper actions on a genuine graduated fund. Feeds and the external V3 fill are mocked.
///      Expected NAV comes from actual vault position/balances, and turnover comes from actual asset movement.
contract V2AssetPercentLimitsFuzzTest is V2AssetPercentEngineFixture {
    uint256 private constant SCALE = 1e30;
    uint256 private constant MIN_LOT = 5e6;
    uint256 private constant COOLDOWN = 600;
    uint256 private tradeBps;
    uint256 private dailyBps;
    uint256 private chunk;
    uint64 private ghostDate;
    uint256 private ghostUsed;
    uint256 private attempts;
    uint256 private successes;
    uint256 private failures;
    uint256 private buys;
    uint256 private sells;
    uint256 private partialSuccesses;
    uint256 private rollovers;

    struct Snapshot {
        uint256 price;
        uint256 nav;
        uint256 stock;
        uint256 cash;
        uint256 buyback;
        uint64 nonce;
        uint64 date;
        uint256 used;
        uint256 at;
        bytes32 digest;
    }

    event Schema2Coverage(
        uint256 attempts,
        uint256 successfulBuys,
        uint256 successfulSells,
        uint256 revertedAttempts,
        uint256 successfulPartialFills,
        uint256 tradingDateRollovers
    );

    function testFuzz_schema2MixedFillsRespectPreActionNavAndTradingDate(
        uint256 seed,
        uint16 rawTradeBps,
        uint16 rawDailyBps,
        bool payout
    ) public {
        _runMixed(seed, rawTradeBps, rawDailyBps, payout);
    }

    function test_schema2NonVacuousCoverageWitness() public {
        _runMixed(0xA551, 1000, 2000, true);
        emit Schema2Coverage(attempts, buys, sells, failures, partialSuccesses, rollovers);
    }

    function _runMixed(uint256 seed, uint16 rawTradeBps, uint16 rawDailyBps, bool payout) private {
        tradeBps = bound(rawTradeBps, 500, 2000);
        dailyBps = bound(rawDailyBps, tradeBps, Math.min(10_000, tradeBps * 4));
        chunk = 50e6;
        vm.prank(owner);
        factory.setListingGates(address(stock), 50, 100, uint64(chunk));
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(1500, tradeBps, dailyBps, payout ? 10_000 : 0);

        // Every run exercises both directions and a rollover, rather than relying on random handlers to become due.
        // Donations are ordinary balance transfers; they create allocation drift without choosing a keeper's action.
        for (uint256 i; i < 8; ++i) {
            uint256 random = uint256(keccak256(abi.encode(seed, i)));
            if (i == 4) {
                vm.warp((block.timestamp / 1 days + 1) * 1 days + random % 3600);
            } else if (i != 0) {
                vm.warp(block.timestamp + COOLDOWN + random % 600);
            }
            _price((50 + random % 151) * 1e18);
            _fundDirection(t, i % 2 == 0);
            _assertRiskSnapshot(t);

            venue.setFillBps(1);
            _attempt(t, false); // a due allocation with an actual sub-minimum fill must roll back entirely
            uint16 fill = i % 3 == 0 ? 10_000 : uint16(1001 + random % 8999);
            venue.setFillBps(fill);
            _attempt(t, true);
            _assertRiskSnapshot(t);

            // An immediate repeated call cannot renew cooldown, consume budget or advance the nonce.
            venue.setFillBps(10_000);
            _attempt(t, false);
        }
        assertEq(attempts, 24);
        assertEq(successes, 8);
        assertEq(buys, 4);
        assertEq(sells, 4);
        assertEq(failures, 16);
        assertEq(partialSuccesses, 5);
        assertEq(rollovers, 1);
        assertEq(t.strategyNonce(), successes);
    }

    function testFuzz_schema2NavShrinkCannotEraseSpendAndGrowthReopensOnlyDifference(
        uint16 rawTradeBps,
        uint96 extraCash
    ) public {
        tradeBps = bound(rawTradeBps, 500, 1500);
        dailyBps = tradeBps;
        chunk = type(uint64).max;
        vm.prank(owner);
        factory.setListingGates(address(stock), 50, 100, uint64(chunk));
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(1501, tradeBps, dailyBps, 0);
        uint256 initialNav = _nav(t);
        venue.setFillBps(10_000);
        _attempt(t, true);
        uint256 historicalSpend = ghostUsed;
        uint64 historicalDate = ghostDate;
        assertGt(historicalSpend, 0);

        vm.warp(block.timestamp + COOLDOWN);
        _price(1e18);
        _assertRiskSnapshot(t);
        Risk memory shrunk = _risk(t);
        assertLt(shrunk.nav, initialNav);
        assertLt(shrunk.daily, historicalSpend);
        assertEq(shrunk.remaining, 0);
        _attempt(t, false);
        assertEq(t.turnoverInEpoch(), historicalSpend);
        assertEq(t.turnoverEpoch(), historicalDate);

        _price(PRICE);
        usdg.mint(address(t), initialNav * 3 + bound(extraCash, 0, 1000e6));
        _assertRiskSnapshot(t);
        Risk memory grown = _risk(t);
        assertEq(grown.used, historicalSpend);
        assertEq(grown.epoch, historicalDate);
        assertEq(grown.remaining, grown.daily - historicalSpend);
        assertGe(grown.remaining, MIN_LOT);
        _attempt(t, true);

        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1);
        _price(PRICE);
        _fundDirection(t, true);
        _assertRiskSnapshot(t);
        assertEq(_risk(t).used, 0);
        _attempt(t, true);
        assertEq(rollovers, 1);
        assertEq(successes, 3);
        assertEq(failures, 1);
    }

    function testFuzz_schema2MinimumPercentageCapWaitsWithoutInflatingBudget(uint8 rawDailyBps, uint96 extraCash)
        public
    {
        tradeBps = 1;
        dailyBps = bound(rawDailyBps, 1, 24);
        chunk = 50e6;
        vm.prank(owner);
        factory.setListingGates(address(stock), 50, 100, uint64(chunk));
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(1502, tradeBps, dailyBps, 0);
        _assertRiskSnapshot(t);
        assertLt(_risk(t).trade, MIN_LOT);
        venue.setFillBps(10_000);
        _attempt(t, false);
        assertEq(t.strategyNonce(), 0);
        assertEq(t.turnoverInEpoch(), 0);

        usdg.mint(address(t), 200_000e6 + bound(extraCash, 0, 1_000_000e6));
        _assertRiskSnapshot(t);
        assertGe(_risk(t).trade, MIN_LOT);
        _attempt(t, true);
        assertEq(successes, 1);
        assertEq(failures, 1);
    }

    function _fundDirection(HedgeFunV2AssetPercentEngineTreasury t, bool buy) private {
        if (buy) {
            usdg.mint(address(t), Math.mulDiv(stock.balanceOf(address(t)), venue.price(), SCALE) * 3 + 1000e6);
        } else {
            stock.mint(address(t), Math.mulDiv(t.reserveUsdg() * 4 + 1000e6, SCALE, venue.price()));
        }
    }

    function _nav(HedgeFunV2AssetPercentEngineTreasury t) private view returns (uint256) {
        (, uint256 price) = t.health();
        return FundAssetMath.nav(t, stock, price, SCALE);
    }

    function _assertRiskSnapshot(HedgeFunV2AssetPercentEngineTreasury t) private view {
        Risk memory actual = _risk(t);
        uint256 expectedNav = _nav(t);
        uint64 date = uint64(t.tradingCalendar().tradingDate(block.timestamp));
        uint256 used = date == ghostDate ? ghostUsed : 0;
        uint256 cap = Math.mulDiv(expectedNav, dailyBps, 10_000);
        assertTrue(actual.healthy);
        assertEq(actual.nav, expectedNav);
        assertEq(actual.trade, Math.min(Math.mulDiv(expectedNav, tradeBps, 10_000), chunk));
        assertEq(actual.daily, cap);
        assertEq(actual.epoch, date);
        assertEq(actual.used, used);
        assertEq(actual.remaining, cap > used ? cap - used : 0);
    }

    function _attempt(HedgeFunV2AssetPercentEngineTreasury t, bool expectSuccess) private {
        Snapshot memory before_;
        (, before_.price) = t.health();
        before_.nav = FundAssetMath.nav(t, stock, before_.price, SCALE);
        before_.stock = stock.balanceOf(address(t));
        before_.cash = t.reserveUsdg();
        before_.buyback = t.buybackStock();
        before_.nonce = t.strategyNonce();
        before_.date = uint64(t.tradingCalendar().tradingDate(block.timestamp));
        before_.used = before_.date == ghostDate ? ghostUsed : 0;
        before_.at = t.lastStrategyAt();
        before_.digest = _stateDigest(t);
        ++attempts;

        (bool ok, bytes memory data) = address(t).call(abi.encodeCall(HedgeFunV2AssetPercentEngineTreasury.execute, ()));
        assertEq(ok, expectSuccess, "expected successful fill or atomic rejection");
        if (!ok) {
            ++failures;
            assertEq(_stateDigest(t), before_.digest, "failed attempt changed strategy, balances or keeper reward");
            return;
        }
        (HedgeFunV2Treasury.Action action, uint256 nonce) = abi.decode(data, (HedgeFunV2Treasury.Action, uint256));
        uint256 moved;
        if (action == HedgeFunV2Treasury.Action.RebalanceBuy) {
            ++buys;
            moved = before_.cash - t.reserveUsdg();
        } else {
            assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.RebalanceSell));
            ++sells;
            moved = Math.mulDiv(
                before_.stock - stock.balanceOf(address(t)) + t.buybackStock() - before_.buyback, before_.price, SCALE
            );
        }
        assertGe(moved, MIN_LOT);
        assertLe(moved, Math.min(Math.mulDiv(before_.nav, tradeBps, 10_000), chunk));
        assertLe(before_.used + moved, Math.mulDiv(before_.nav, dailyBps, 10_000));
        assertEq(t.turnoverEpoch(), before_.date);
        assertEq(t.turnoverInEpoch(), before_.used + moved);
        assertEq(t.strategyNonce(), before_.nonce + 1);
        assertEq(nonce, t.strategyNonce());
        assertEq(t.lastStrategyAt(), block.timestamp);
        if (before_.at != 0) assertGe(block.timestamp - before_.at, COOLDOWN);
        if (ghostDate != 0 && ghostDate != before_.date) ++rollovers;
        ghostDate = before_.date;
        ghostUsed = before_.used + moved;
        ++successes;
        if (venue.fillBps() != 10_000) ++partialSuccesses;
        assertLe(t.bookedStock() + t.buybackStock(), stock.balanceOf(address(t)));
    }

    function _stateDigest(HedgeFunV2AssetPercentEngineTreasury t) private view returns (bytes32) {
        bytes32 strategy = keccak256(
            abi.encode(
                t.strategyNonce(),
                t.turnoverEpoch(),
                t.turnoverInEpoch(),
                t.lastStrategyAt(),
                t.policyState(),
                t.bookedStock(),
                t.buybackStock(),
                t.avgCost()
            )
        );
        bytes32 balances = keccak256(
            abi.encode(
                stock.balanceOf(address(t)),
                usdg.balanceOf(address(t)),
                stock.balanceOf(address(venue)),
                usdg.balanceOf(address(venue)),
                stock.balanceOf(address(this)),
                usdg.balanceOf(address(this))
            )
        );
        bytes32 accounting = keccak256(
            abi.encode(
                t.totalStockReceived(),
                t.lastGoodPrice(),
                t.lastGoodPriceAt(),
                t.buybackAnchorSqrtP(),
                t.buybackAnchorAt()
            )
        );
        return keccak256(abi.encode(strategy, balances, accounting));
    }
}
