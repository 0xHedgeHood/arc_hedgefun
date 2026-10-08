// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunV2EngineTreasury, HedgeFunV2EngineTreasuryCore} from "../src/v2/HedgeFunV2EngineTreasury.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {EngineConfig, StrategyAction} from "../src/v2/strategy/IStrategyPolicy.sol";
import {EngineAccountingVenue} from "./V2StrategyEngineAccounting.t.sol";
import {V2AssetPercentEngineFixture} from "./V2AssetPercentEngine.t.sol";
import {MockFeed, MockToken} from "./mocks/Mocks.sol";
import {GraduationStock} from "./utils/V2FactoryFixture.sol";

/// @dev Both engine schemas have this ABI. The model uses external transfer deltas for swap inputs/outputs,
///      and keeps the cost model outside the production engine. It never derives expected cost from avgCost().
contract EngineCostHandler is Test {
    uint256 private constant SCALE = 1e30;
    uint256 private constant BPS = 10_000;
    uint256 private constant BOUNTY_BPS = 50;
    uint256 private constant PAYOUT_BPS = 5_000;

    HedgeFunV2EngineTreasury public immutable treasury;
    EngineAccountingVenue public immutable venue;
    GraduationStock public immutable stock;
    MockToken public immutable usdg;
    MockFeed public immutable stockFeed;
    MockFeed public immutable usdgFeed;

    uint256 public ghostCost;
    uint256 public ghostBooked;
    uint256 public ghostBuyback;
    uint256 public ghostReceived;
    bool public violation;
    uint256 public bookAttempts;
    uint256 public successfulBooks;
    uint256 public executeAttempts;
    uint256 public failedExecutions;
    uint256 public successfulBuys;
    uint256 public successfulSells;
    uint256 public profitableSells;
    uint256 public lossSells;
    uint256 public partialBuys;
    uint256 public partialSells;

    struct Before {
        uint256 price;
        uint256 pending;
        uint256 offered;
        uint256 treasuryStock;
        uint256 treasuryCash;
        uint256 venueStock;
        uint256 venueCash;
        uint256 keeperStock;
        uint256 keeperCash;
        bool due;
        StrategyAction intent;
    }

    constructor(
        address treasury_,
        EngineAccountingVenue venue_,
        GraduationStock stock_,
        MockToken usdg_,
        MockFeed stockFeed_,
        MockFeed usdgFeed_
    ) {
        treasury = HedgeFunV2EngineTreasury(treasury_);
        venue = venue_;
        stock = stock_;
        usdg = usdg_;
        stockFeed = stockFeed_;
        usdgFeed = usdgFeed_;
        ghostBooked = treasury.bookedStock();
        ghostBuyback = treasury.buybackStock();
        ghostReceived = treasury.totalStockReceived();
        // Graduation happens at the fixture's independently known 100 USDG oracle price.
        ghostCost = ghostBooked == 0 ? 0 : 100e18;
        _checkGhost();
    }

    function donateStock(uint96 rawAmount) external {
        stock.mint(address(treasury), bound(uint256(rawAmount), 1, 20e18));
        _checkGhost();
    }

    function donateUsdg(uint96 rawAmount) external {
        usdg.mint(address(treasury), bound(uint256(rawAmount), 1, 1_000e6));
        _checkGhost();
    }

    function setMarket(uint16 rawDollars, uint32 rawFraction) external {
        uint256 feedPrice = bound(uint256(rawDollars), 20, 240) * 1e8 + uint256(rawFraction) % 1e8;
        venue.setPrice(feedPrice * 1e10);
        stockFeed.set(int256(feedPrice));
        usdgFeed.set(1e8);
        _checkGhost();
    }

    function setOraclePaused(bool paused) external {
        stock.setOraclePaused(paused);
    }

    function advanceEpoch(uint16 rawOffset) external {
        vm.warp((block.timestamp / 1 days + 1) * 1 days + bound(uint256(rawOffset), 0, 1 hours));
        stockFeed.set(stockFeed.answer());
        usdgFeed.set(1e8);
    }

    function advanceCooldown(uint8 rawEdge) external {
        vm.warp(block.timestamp + 599 + uint256(rawEdge) % 3);
        stockFeed.set(stockFeed.answer());
        usdgFeed.set(1e8);
    }

    function makeOracleStale(uint16 rawExtra) external {
        vm.warp(block.timestamp + 26 hours + bound(uint256(rawExtra), 1, 1 hours));
    }

    function book() external {
        ++bookAttempts;
        _checkGhost();
        (, uint256 price) = treasury.health();
        uint256 pending = _pending();
        bytes32 beforeDigest = _stateDigest();
        (bool ok, bytes memory data) = address(treasury).call(abi.encodeCall(HedgeFunV2EngineTreasuryCore.book, ()));
        if (!ok || !abi.decode(data, (bool))) {
            if (_stateDigest() != beforeDigest) violation = true;
            return;
        }
        if (pending == 0 || price == 0) violation = true;
        _modelBook(pending, price);
        ++successfulBooks;
        _checkGhost();
    }

    function attemptExecute(uint16 rawFillBps) external {
        uint256 edge = uint256(rawFillBps) % 6;
        uint16 fill = edge == 0
            ? 1
            : edge == 1
                ? 499
                : edge == 2 ? 500 : edge == 3 ? 501 : edge == 4 ? 10_000 : uint16(bound(uint256(rawFillBps), 1, 10_000));
        venue.setFillBps(fill);
        ++executeAttempts;
        _checkGhost();
        Before memory before_ = _before();
        bytes32 beforeDigest = _stateDigest();
        (bool ok, bytes memory data) = address(treasury).call(abi.encodeCall(HedgeFunV2EngineTreasuryCore.execute, ()));
        if (!ok) {
            ++failedExecutions;
            if (_stateDigest() != beforeDigest) violation = true;
            return;
        }
        (HedgeFunV2Treasury.Action action,) = abi.decode(data, (HedgeFunV2Treasury.Action, uint256));
        if (!before_.due) violation = true;
        _modelBook(before_.pending, before_.price);
        if (action == HedgeFunV2Treasury.Action.RebalanceBuy) _modelBuy(before_);
        else if (action == HedgeFunV2Treasury.Action.RebalanceSell) _modelSell(before_);
        else violation = true;
        _checkGhost();
    }

    function _before() private view returns (Before memory b) {
        (, b.price) = treasury.health();
        b.pending = _pending();
        // Preview exposes the policy's offered input; all actual input/output and rewards below use balances.
        (b.due, b.intent, b.offered) = treasury.preview();
        b.treasuryStock = stock.balanceOf(address(treasury));
        b.treasuryCash = usdg.balanceOf(address(treasury));
        b.venueStock = stock.balanceOf(address(venue));
        b.venueCash = usdg.balanceOf(address(venue));
        b.keeperStock = stock.balanceOf(address(this));
        b.keeperCash = usdg.balanceOf(address(this));
    }

    function _modelBook(uint256 pending, uint256 price) private {
        if (pending == 0) return;
        ghostCost = _ceilMean(ghostBooked * ghostCost + pending * price, ghostBooked + pending);
        ghostBooked += pending;
        ghostReceived += pending;
    }

    function _modelBuy(Before memory b) private {
        ++successfulBuys;
        if (b.intent != StrategyAction.BuyStock) violation = true;
        uint256 actualSpend = usdg.balanceOf(address(venue)) - b.venueCash;
        uint256 grossStock = b.venueStock - stock.balanceOf(address(venue));
        uint256 keeperReward = stock.balanceOf(address(this)) - b.keeperStock;
        uint256 expectedReward = grossStock * BOUNTY_BPS / BPS;
        uint256 retainedStock = grossStock - expectedReward;
        if (actualSpend == 0 || retainedStock == 0 || actualSpend > b.offered) violation = true;
        if (actualSpend < b.offered) ++partialBuys;
        if (
            keeperReward != expectedReward || usdg.balanceOf(address(this)) != b.keeperCash
                || b.treasuryCash - usdg.balanceOf(address(treasury)) != actualSpend
                || stock.balanceOf(address(treasury)) - b.treasuryStock != retainedStock
        ) violation = true;
        ghostCost = _ceilMean(ghostBooked * ghostCost + actualSpend * SCALE, ghostBooked + retainedStock);
        ghostBooked += retainedStock;
    }

    function _modelSell(Before memory b) private {
        ++successfulSells;
        if (b.intent != StrategyAction.SellStock) violation = true;
        uint256 actualStockSold = stock.balanceOf(address(venue)) - b.venueStock;
        uint256 grossCash = b.venueCash - usdg.balanceOf(address(venue));
        uint256 keeperReward = usdg.balanceOf(address(this)) - b.keeperCash;
        uint256 expectedReward = grossCash * BOUNTY_BPS / BPS;
        uint256 gainStock;
        if (b.price > ghostCost) {
            gainStock = b.offered - Math.mulDiv(b.offered, ghostCost, b.price);
            ++profitableSells;
        } else {
            ++lossSells;
        }
        uint256 offeredBuyback = gainStock * PAYOUT_BPS / BPS;
        uint256 offeredSale = b.offered - offeredBuyback;
        if (actualStockSold == 0 || actualStockSold > offeredSale) violation = true;
        uint256 retainedGain = offeredBuyback;
        if (actualStockSold < offeredSale) {
            ++partialSells;
            retainedGain = Math.mulDiv(offeredBuyback, actualStockSold, offeredSale);
        }
        if (
            keeperReward != expectedReward || stock.balanceOf(address(this)) != b.keeperStock
                || b.treasuryStock - stock.balanceOf(address(treasury)) != actualStockSold
                || usdg.balanceOf(address(treasury)) - b.treasuryCash != grossCash - expectedReward
        ) violation = true;
        ghostBooked -= actualStockSold + retainedGain;
        ghostBuyback += retainedGain;
        // A sale removes inventory at the existing cost. It must not reprice the remaining inventory.
    }

    function _pending() private view returns (uint256) {
        uint256 balance = stock.balanceOf(address(treasury));
        uint256 accounted = ghostBooked + ghostBuyback;
        return balance > accounted ? balance - accounted : 0;
    }

    function _checkGhost() private {
        if (
            treasury.avgCost() != ghostCost || treasury.bookedStock() != ghostBooked
                || treasury.buybackStock() != ghostBuyback || treasury.totalStockReceived() != ghostReceived
                || stock.balanceOf(address(treasury)) < ghostBooked + ghostBuyback
        ) violation = true;
    }

    function _ceilMean(uint256 numerator, uint256 denominator) private pure returns (uint256) {
        return numerator == 0 ? 0 : 1 + (numerator - 1) / denominator;
    }

    function _stateDigest() private view returns (bytes32) {
        bytes32 inventory = keccak256(
            abi.encode(
                treasury.avgCost(),
                treasury.bookedStock(),
                treasury.buybackStock(),
                treasury.totalStockReceived(),
                treasury.lastGoodPrice(),
                treasury.lastGoodPriceAt()
            )
        );
        bytes32 strategy = keccak256(
            abi.encode(
                treasury.strategyNonce(),
                treasury.policyState(),
                treasury.lastStrategyAt(),
                treasury.turnoverEpoch(),
                treasury.turnoverInEpoch(),
                treasury.buybackAnchorSqrtP(),
                treasury.buybackAnchorAt()
            )
        );
        bytes32 balances = keccak256(
            abi.encode(
                stock.balanceOf(address(treasury)),
                usdg.balanceOf(address(treasury)),
                stock.balanceOf(address(venue)),
                usdg.balanceOf(address(venue)),
                stock.balanceOf(address(this)),
                usdg.balanceOf(address(this))
            )
        );
        return keccak256(abi.encode(inventory, strategy, balances));
    }
}

contract V2EngineCostInvariantTest is V2AssetPercentEngineFixture {
    EngineCostHandler internal fixedHandler;
    EngineCostHandler internal percentHandler;

    function _config(uint256 maxTrade, uint256 maxDaily) internal view override returns (EngineConfig memory config) {
        config = super._config(maxTrade, maxDaily);
        config.words[0] |= bytes32(uint256(5_000) << 64);
    }

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        factory.setListingGates(address(stock), 50, 100, 100e6);
        fixedHandler = _handler(address(_launch(2_100, 100e6, 500e6)));
        percentHandler = _handler(address(_launchPercent(2_101, 1_000, 5_000, 5_000)));
        _target(fixedHandler);
        _target(percentHandler);
    }

    function _handler(address t) private returns (EngineCostHandler h) {
        assertGt(HedgeFunV2EngineTreasury(t).bookedStock(), 0);
        assertEq(HedgeFunV2EngineTreasury(t).avgCost(), PRICE);
        assertEq(HedgeFunV2EngineTreasury(t).payoutBps(), 5_000);
        assertEq(HedgeFunV2EngineTreasury(t).params().bountyBps, 50);
        h = new EngineCostHandler(t, venue, stock, usdg, stockFeed, usdgFeed);
    }

    function _target(EngineCostHandler h) private {
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = h.donateStock.selector;
        selectors[1] = h.donateUsdg.selector;
        selectors[2] = h.setMarket.selector;
        selectors[3] = h.setOraclePaused.selector;
        selectors[4] = h.advanceEpoch.selector;
        selectors[5] = h.advanceCooldown.selector;
        selectors[6] = h.makeOracleStale.selector;
        selectors[7] = h.book.selector;
        selectors[8] = h.attemptExecute.selector;
        targetSelector(FuzzSelector(address(h), selectors));
        targetContract(address(h));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_costAndBucketsMatchExternalAccountingModel() public view {
        _assertModel(fixedHandler);
        _assertModel(percentHandler);
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyExecuteAttemptIsClassified() public view {
        _assertCounters(fixedHandler);
        _assertCounters(percentHandler);
    }

    function _assertModel(EngineCostHandler h) private view {
        assertFalse(h.violation(), "external cost/transfer accounting mismatch");
        HedgeFunV2EngineTreasury t = h.treasury();
        assertEq(t.avgCost(), h.ghostCost());
        assertEq(t.bookedStock(), h.ghostBooked());
        assertEq(t.buybackStock(), h.ghostBuyback());
        assertEq(t.totalStockReceived(), h.ghostReceived());
        assertLe(t.bookedStock() + t.buybackStock(), stock.balanceOf(address(t)));
        assertEq(t.lotCount(), 0, "aggregate engines must stay lotless");
    }

    function _assertCounters(EngineCostHandler h) private view {
        assertEq(h.executeAttempts(), h.failedExecutions() + h.successfulBuys() + h.successfulSells());
        assertEq(h.successfulSells(), h.profitableSells() + h.lossSells());
        assertEq(h.treasury().strategyNonce(), h.successfulBuys() + h.successfulSells());
    }

    /// @dev Randomized multi-action witness guarantees successful book, buy, profitable sell, loss sell,
    ///      partial fills and rollback for BOTH schemas, independently of random invariant reachability.
    function testFuzz_costTransitionsExerciseBooksPartialBuysAndProfitLossSells(
        uint96 rawDonation,
        uint16 rawFill,
        uint32 rawFraction
    ) public {
        uint16 fill = uint16(bound(uint256(rawFill), 2_000, 9_995));
        // The handler's sixth choice takes this raw fraction literally, avoiding its min-lot edge cases.
        fill = uint16(uint256(fill) - uint256(fill) % 6 + 5);
        _witness(fixedHandler, rawDonation, fill, rawFraction);
        _witness(percentHandler, rawDonation, fill, rawFraction);
    }

    function _witness(EngineCostHandler h, uint96 donation, uint16 fill, uint32 fraction) private {
        h.setOraclePaused(false);
        h.setMarket(80, fraction);
        h.donateStock(uint96(bound(uint256(donation), 1e18, 20e18)));
        h.book();
        assertEq(h.successfulBooks(), 1);
        h.setMarket(180, fraction);
        h.attemptExecute(0); // A 1 bps fill is too small, including for the NAV-percent engine.
        assertEq(h.failedExecutions(), 1);
        h.attemptExecute(fill);
        assertEq(h.profitableSells(), 1);
        assertEq(h.partialSells(), 1);
        h.advanceEpoch(0);
        h.setMarket(20, fraction);
        h.attemptExecute(fill);
        assertEq(h.lossSells(), 1);
        assertEq(h.partialSells(), 2);
        h.advanceEpoch(0);
        // Add only fixture cash; the handler then validates the actual fill and actual retained stock.
        uint256 stockValue = Math.mulDiv(stock.balanceOf(address(h.treasury())), venue.price(), 1e30);
        usdg.mint(address(h.treasury()), stockValue * 4 + 500e6);
        h.attemptExecute(fill);
        assertEq(h.successfulBuys(), 1);
        assertEq(h.partialBuys(), 1);
        h.attemptExecute(10_000); // Same-block cooldown rejection must leave every accounting field unchanged.
        assertEq(h.failedExecutions(), 2);
        _assertModel(h);
        _assertCounters(h);
    }
}
