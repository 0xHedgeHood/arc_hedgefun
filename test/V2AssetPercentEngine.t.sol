// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunV2EngineTreasury} from "../src/v2/HedgeFunV2EngineTreasury.sol";
import {HedgeFunV2AssetPercentEngineTreasury} from "../src/v2/HedgeFunV2AssetPercentEngineTreasury.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {AssetPercentEngineConfig} from "../src/v2/strategy/AssetPercentEngineConfig.sol";
import {V2AssetPercentRebalancePolicy} from "../src/v2/strategy/V2AssetPercentRebalancePolicy.sol";
import {EngineConfig, StrategyAction} from "../src/v2/strategy/IStrategyPolicy.sol";
import {FundAssetMath} from "./utils/FundAssetMath.sol";
import {V2StrategyEngineAccountingFixture} from "./V2StrategyEngineAccounting.t.sol";

contract AssetPercentConfigHarness {
    function valid(bytes32[3] memory words, uint256 floor) external pure returns (bool) {
        return AssetPercentEngineConfig.valid(words, floor);
    }
}

abstract contract V2AssetPercentEngineFixture is V2StrategyEngineAccountingFixture {
    V2AssetPercentRebalancePolicy internal percentPolicy;
    bytes32 internal percentPolicyKey;
    uint8 internal percentKind;

    struct Risk {
        bool healthy;
        uint256 nav;
        uint256 trade;
        uint256 daily;
        uint256 remaining;
        uint64 epoch;
        uint256 used;
    }

    function setUp() public virtual override {
        super.setUp();
        percentPolicy = new V2AssetPercentRebalancePolicy();
        (address a, address b) = deployer.makeChunks(type(HedgeFunV2AssetPercentEngineTreasury).creationCode);
        vm.startPrank(owner);
        percentPolicyKey = deployer.registerPolicy(address(percentPolicy), 150_000, 160,
            keccak256("asset-percent-deps-v1"), keccak256("asset-percent-audit-v1"));
        percentKind = deployer.registerEngineKind(a, b, 1, 2, 3);
        // These suites' budgets and thresholds were written against an even split of the raise; they keep it.
        deployer.setLpBps(address(stock), 5000);
        vm.stopPrank();
    }

    function _percentConfig(uint256 trade, uint256 daily, uint256 payout) internal view returns (EngineConfig memory c) {
        c.schema = 2;
        c.engineVersion = 1;
        c.policyKey = percentPolicyKey;
        c.words[0] = bytes32(uint256(7000) | uint256(500) << 16 | uint256(600) << 32 | payout << 64);
        c.words[1] = bytes32(trade);
        c.words[2] = bytes32(daily);
    }

    function _launchPercent(uint96 nonce, uint256 trade, uint256 daily, uint256 payout)
        internal returns (HedgeFunV2AssetPercentEngineTreasury treasury)
    {
        HedgeFunFactory.Request memory q = _request();
        q.nonce = nonce;
        deployer.setEngineConfig(q.symbol, q.nonce, percentKind, _percentConfig(trade, daily, payout));
        (, address predicted, bytes32 terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        (, address t,,,) = factory.strategies(id);
        assertEq(t, predicted);
        treasury = HedgeFunV2AssetPercentEngineTreasury(t);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        stock.approve(address(curve), type(uint256).max);
        _graduateV2(curve);
    }

    function _risk(HedgeFunV2AssetPercentEngineTreasury t) internal view returns (Risk memory r) {
        (r.healthy, r.nav, r.trade, r.daily, r.remaining, r.epoch, r.used) = t.riskLimits();
    }

    function _price(uint256 p) internal {
        venue.setPrice(p);
        stockFeed.set(int256(p / 1e10));
        usdgFeed.set(1e8);
    }

    function _advance(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
        _price(venue.price());
    }

    function _assertWait(HedgeFunV2AssetPercentEngineTreasury t) internal {
        bytes32 before_ = keccak256(abi.encode(t.strategyNonce(), t.turnoverInEpoch(), t.turnoverEpoch(),
            t.lastStrategyAt(), t.bookedStock(), t.avgCost(), t.policyState()));
        (bool due, StrategyAction action, uint256 amount) = t.preview();
        assertFalse(due); assertEq(uint256(action), uint256(StrategyAction.Hold)); assertEq(amount, 0);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector); t.execute();
        assertEq(keccak256(abi.encode(t.strategyNonce(), t.turnoverInEpoch(), t.turnoverEpoch(),
            t.lastStrategyAt(), t.bookedStock(), t.avgCost(), t.policyState())), before_);
    }
}

contract V2AssetPercentEngineTest is V2AssetPercentEngineFixture {
    address private constant KEEPER = address(0xB07);

    function test_schemaAndGenericRegistryAppendPreserveExistingKindAndWords() public {
        (uint32 oldVersion, uint32 oldSchema, bytes32 oldCode, uint256 oldCaps) = deployer.kindManifest(engineKind);
        assertEq(oldVersion, 1); assertEq(oldSchema, 1); assertEq(oldCaps, 3);
        assertEq(oldCode, keccak256(type(HedgeFunV2EngineTreasury).creationCode));
        // A fresh registry commits to the code compiled in this checkout. Already deployed
        // registries retain their original chunks and hash when the source later changes.
        HedgeFunV2EngineTreasury old = _launch(920, 100e6, 500e6);
        assertEq(uint256(old.engineConfig().words[1]), 100e6);
        usdg.mint(address(old), 50_000e6);
        (bool due, StrategyAction action, uint256 amount) = old.preview();
        assertTrue(due); assertEq(uint256(action), uint256(StrategyAction.BuyStock)); assertEq(amount, 100e6);

        (uint32 version, uint32 schema, bytes32 creationHash, uint256 caps) = deployer.kindManifest(percentKind);
        assertEq(version, 1); assertEq(schema, 2); assertEq(caps, 3);
        assertEq(creationHash, keccak256(type(HedgeFunV2AssetPercentEngineTreasury).creationCode));
        assertTrue(creationHash != oldCode);
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(921, 1000, 5000, 0);
        assertEq(t.engineVersion(), 1); assertEq(t.engineConfig().schema, 2);
        assertEq(uint256(t.engineConfig().words[1]), 1000);
        assertEq(uint256(t.engineConfig().words[2]), 5000);
        assertEq(t.strategyId(), percentPolicyKey);
        assertEq(t.policyGasLimit(), 150_000); assertEq(t.policyReturnLimit(), 160);
    }

    function test_liveNavGrowthAndShrinkResizeBothLimitsWithoutRoundingUp() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(922, 1000, 5000, 0);
        Risk memory initial = _risk(t);
        assertTrue(initial.healthy);
        (uint256 held, uint256 parked, uint256 principal, uint256 fees,) = t.assetReader().assetBalances();
        assertGt(principal, 0);
        assertEq(initial.nav, Math.mulDiv(held + parked + principal + fees, PRICE, 1e30));
        assertEq(initial.trade, initial.nav / 10); assertEq(initial.daily, initial.nav / 2);
        usdg.mint(address(t), initial.nav + 1);
        Risk memory grown = _risk(t);
        assertEq(grown.nav, initial.nav * 2 + 1);
        assertEq(grown.trade, Math.mulDiv(grown.nav, 1000, 10_000));
        assertEq(grown.daily, Math.mulDiv(grown.nav, 5000, 10_000));
        _price(50e18);
        Risk memory shrunk = _risk(t);
        assertEq(shrunk.nav, Math.mulDiv(held + parked + principal + fees, 50e18, 1e30) + t.reserveUsdg());
        assertLt(shrunk.nav, grown.nav); assertLt(shrunk.trade, grown.trade); assertLt(shrunk.daily, grown.daily);
    }

    function test_sellPreviewAndExecuteUsePercentageAndAbsoluteListingChunk() public {
        vm.prank(owner); factory.setListingGates(address(stock), 50, 100, 25e6);
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(923, 1000, 5000, 0);
        Risk memory r = _risk(t); assertEq(r.trade, 25e6);
        (bool due, StrategyAction action, uint256 offered) = t.preview();
        assertTrue(due); assertEq(uint256(action), uint256(StrategyAction.SellStock));
        uint256 held = t.bookedStock();
        vm.prank(KEEPER); t.execute();
        assertEq(held - t.bookedStock(), offered);
        assertEq(t.turnoverInEpoch(), Math.mulDiv(offered, PRICE, 1e30));
        assertLe(t.turnoverInEpoch(), r.trade);
        assertGt(usdg.balanceOf(KEEPER), 0);
    }

    function test_buyPreviewAndExecuteUsePercentageAndAbsoluteListingChunk() public {
        vm.prank(owner); factory.setListingGates(address(stock), 50, 100, 25e6);
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(924, 1000, 5000, 0);
        usdg.mint(address(t), _risk(t).nav * 3);
        (bool due, StrategyAction action, uint256 offered) = t.preview();
        assertTrue(due); assertEq(uint256(action), uint256(StrategyAction.BuyStock)); assertEq(offered, 25e6);
        uint256 cash = t.reserveUsdg(); uint256 held = t.bookedStock();
        uint256 poolStock = stock.balanceOf(address(venue));
        vm.prank(KEEPER); t.execute();
        uint256 gross = poolStock - stock.balanceOf(address(venue));
        uint256 reward = Math.mulDiv(gross, 50, 10_000);
        assertEq(cash - t.reserveUsdg(), offered); assertEq(t.turnoverInEpoch(), offered);
        assertEq(t.bookedStock() - held, gross - reward); assertEq(stock.balanceOf(KEEPER), reward);
    }

    function test_tinyNavWaitsUntilPercentCapMeetsMinLot() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(925, 1, 24, 0);
        Risk memory r = _risk(t); assertLt(r.trade, 5e6);
        _assertWait(t);
        usdg.mint(address(t), 100_000e6);
        assertGe(_risk(t).trade, 5e6);
        (bool due, StrategyAction action, uint256 amount) = t.preview();
        assertTrue(due); assertEq(uint256(action), uint256(StrategyAction.BuyStock));
        assertEq(amount, _risk(t).trade);
        t.execute(); assertGe(t.turnoverInEpoch(), 5e6);
    }

    function test_dailyDepletionAndDonationReopenOnlyTheCurrentNavDifference() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(926, 1000, 1000, 0);
        Risk memory before_ = _risk(t); t.execute(); _advance(600);
        uint256 used = t.turnoverInEpoch(); uint64 epoch = t.turnoverEpoch();
        Risk memory depleted = _risk(t);
        assertLe(depleted.daily, used); assertEq(depleted.remaining, 0);
        _assertWait(t);
        usdg.mint(address(t), before_.nav * 2);
        Risk memory grown = _risk(t);
        assertEq(t.turnoverEpoch(), epoch); assertEq(grown.used, used);
        assertEq(grown.remaining, grown.daily - used);
        (bool due,, uint256 amount) = t.preview(); assertTrue(due); assertLe(amount, grown.remaining);
        t.execute(); assertGt(t.turnoverInEpoch(), used); assertLe(t.turnoverInEpoch(), grown.daily);
    }

    function test_dailyBudgetShrinksBelowUsedThenRecoversInSameEpoch() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(927, 1000, 2000, 0);
        t.execute(); _advance(600);
        uint256 used = t.turnoverInEpoch(); uint64 epoch = t.turnoverEpoch();
        _price(10e18);
        assertLt(_risk(t).daily, used); assertEq(_risk(t).remaining, 0);
        _assertWait(t); assertEq(t.turnoverInEpoch(), used);
        _price(PRICE);
        Risk memory recovered = _risk(t);
        assertEq(recovered.epoch, epoch); assertEq(recovered.used, used); assertGt(recovered.remaining, 0);
        t.execute(); assertLe(t.turnoverInEpoch(), recovered.daily);
    }

    function test_subMinRemainingDailyWaitDoesNotConsumeOrResetBudget() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(928, 1000, 1000, 0);
        t.execute(); _advance(600);
        uint256 used = t.turnoverInEpoch();
        uint256 targetNav = (used + 4e6) * 10;
        usdg.mint(address(t), targetNav - _risk(t).nav);
        assertEq(_risk(t).remaining, 4e6);
        assertGe(_risk(t).trade, 5e6);
        _assertWait(t); assertEq(t.turnoverInEpoch(), used);
    }

    function test_stockDonationsAndBuybackAreIncludedWhileInventoryStaysIsolated() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(929, 1000, 5000, 0);
        Risk memory initial = _risk(t);
        uint256 lpStock = 20e18;
        stock.mint(t.liquidityVault(), lpStock);
        vm.prank(t.liquidityVault()); stock.approve(address(t), lpStock);
        vm.prank(t.liquidityVault()); t.creditLiquidityFee(lpStock);
        assertEq(t.buybackStock(), lpStock); assertEq(_risk(t).nav, initial.nav + 2000e6);
        assertGt(stock.balanceOf(address(pm)), 0, "LP assets remain outside the trading treasury");
        stock.mint(address(t), 10e18);
        Risk memory donated = _risk(t); assertEq(donated.nav, initial.nav + 3000e6);
        (bool due,, uint256 offered) = t.preview(); assertTrue(due);
        uint256 held = t.bookedStock(); uint256 pending = t.unbookedStock();
        t.execute(); assertEq(t.bookedStock(), held + pending - offered);
        assertEq(t.unbookedStock(), 0); assertEq(t.buybackStock(), lpStock);
    }

    function test_gainPayoutRetainsBuybackInFullNavAndCountsAllActuallyMovedInventory() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(930, 1000, 5000, 10_000);
        _price(200e18); Risk memory r = _risk(t);
        (bool due,, uint256 offered) = t.preview(); assertTrue(due);
        uint256 held = t.bookedStock(); uint256 poolStock = stock.balanceOf(address(venue));
        uint256 poolCash = usdg.balanceOf(address(venue));
        vm.prank(KEEPER); t.execute();
        uint256 sold = stock.balanceOf(address(venue)) - poolStock;
        uint256 bb = t.buybackStock();
        assertGt(bb, 0); assertEq(held - t.bookedStock(), sold + bb); assertEq(sold + bb, offered);
        uint256 gross = poolCash - usdg.balanceOf(address(venue));
        assertEq(usdg.balanceOf(KEEPER), Math.mulDiv(gross, 50, 10_000));
        assertEq(t.turnoverInEpoch(), Math.mulDiv(sold + bb, 200e18, 1e30));
        assertLe(t.turnoverInEpoch(), r.trade);
        Risk memory after_ = _risk(t);
        assertEq(after_.nav, FundAssetMath.nav(t, stock, 200e18, 1e30));
        assertLt(after_.nav, r.nav); assertEq(after_.trade, after_.nav / 10);
    }

    function testFuzz_partialFillRewardsAndActualTurnover(uint16 fill, bool buy, bool payout) public {
        fill = uint16(bound(fill, 1000, 10_000)); venue.setFillBps(fill);
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(931, 1000, 5000, payout ? 10_000 : 0);
        if (buy) usdg.mint(address(t), _risk(t).nav * 3);
        else if (payout) _price(200e18);
        Risk memory r = _risk(t); uint256 held = t.bookedStock(); uint256 cost = t.avgCost();
        uint256 cash = t.reserveUsdg(); uint256 poolStock = stock.balanceOf(address(venue));
        uint256 poolCash = usdg.balanceOf(address(venue));
        vm.prank(KEEPER); t.execute();
        if (buy) {
            uint256 spent = cash - t.reserveUsdg(); uint256 gross = poolStock - stock.balanceOf(address(venue));
            uint256 reward = Math.mulDiv(gross, 50, 10_000); uint256 retained = gross - reward;
            assertEq(t.bookedStock(), held + retained); assertEq(stock.balanceOf(KEEPER), reward);
            assertEq(t.avgCost(), Math.ceilDiv(held * cost + spent * 1e30, held + retained));
            assertEq(t.turnoverInEpoch(), spent);
        } else {
            uint256 sold = stock.balanceOf(address(venue)) - poolStock;
            uint256 gross = poolCash - usdg.balanceOf(address(venue));
            assertEq(usdg.balanceOf(KEEPER), Math.mulDiv(gross, 50, 10_000));
            assertEq(t.turnoverInEpoch(), Math.mulDiv(sold + t.buybackStock(), venue.price(), 1e30));
            assertEq(held - t.bookedStock(), sold + t.buybackStock());
        }
        assertLe(t.turnoverInEpoch(), r.trade); assertLe(t.turnoverInEpoch(), r.remaining);
        assertEq(t.bookedStock() + t.buybackStock(), stock.balanceOf(address(t)));
    }

    function test_dustFillRollsBackCashBucketsNonceCooldownAndReward() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(932, 1000, 5000, 0);
        venue.setFillBps(1); uint256 held = t.bookedStock(); uint256 cash = t.reserveUsdg();
        uint256 poolCash = usdg.balanceOf(address(venue)); uint256 poolStock = stock.balanceOf(address(venue));
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector); vm.prank(KEEPER); t.execute();
        assertEq(t.bookedStock(), held); assertEq(t.reserveUsdg(), cash);
        assertEq(usdg.balanceOf(address(venue)), poolCash); assertEq(stock.balanceOf(address(venue)), poolStock);
        assertEq(t.strategyNonce(), 0); assertEq(t.lastStrategyAt(), 0); assertEq(t.turnoverInEpoch(), 0);
        assertEq(usdg.balanceOf(KEEPER), 0);
    }

    function test_rewardTransferFailureRollsBackPercentageBudgetAndSwap() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(933, 1000, 5000, 0);
        usdg.mint(address(t), _risk(t).nav * 3); stock.blockRecipient(KEEPER);
        uint256 held = t.bookedStock(); uint256 cash = t.reserveUsdg(); uint256 cost = t.avgCost();
        vm.expectRevert(); vm.prank(KEEPER); t.execute();
        assertEq(t.bookedStock(), held); assertEq(t.reserveUsdg(), cash); assertEq(t.avgCost(), cost);
        assertEq(t.strategyNonce(), 0); assertEq(t.turnoverInEpoch(), 0);
    }

    function test_newTradingDateResetsBudgetAndCooldownPreviewMatchesCore() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(934, 1000, 1000, 0);
        t.execute(); (bool due,,) = t.preview(); assertFalse(due);
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1); _price(PRICE);
        assertEq(_risk(t).used, 0); assertEq(_risk(t).remaining, _risk(t).daily);
        uint256 preTradeDaily = _risk(t).daily;
        (due,,) = t.preview(); assertTrue(due); t.execute();
        assertEq(t.turnoverEpoch(), uint64(t.tradingCalendar().tradingDate(block.timestamp)));
        assertLe(t.turnoverInEpoch(), preTradeDaily);
    }

    function test_staleOrUnhealthySnapshotHasNoReportedCapacity() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(935, 1000, 5000, 0);
        stock.setOraclePaused(true);
        Risk memory r = _risk(t); assertFalse(r.healthy); assertEq(r.nav, 0); assertEq(r.remaining, 0);
        (bool due,,) = t.preview(); assertFalse(due);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector); t.execute();
    }
}
