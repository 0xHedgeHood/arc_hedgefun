// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunV2AssetPercentEngineTreasury} from "../src/v2/HedgeFunV2AssetPercentEngineTreasury.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {EngineAccountingVenue} from "./V2StrategyEngineAccounting.t.sol";
import {MockFeed, MockToken} from "./mocks/Mocks.sol";
import {GraduationStock} from "./utils/V2FactoryFixture.sol";
import {FundAssetMath} from "./utils/FundAssetMath.sol";
import {V2AssetPercentEngineFixture} from "./V2AssetPercentEngine.t.sol";

contract AssetPercentEngineHandler is Test {
    uint256 private constant MIN_LOT = 5e6;
    uint256 private constant MAX_TRADE_BPS = 1000;
    uint256 private constant CHUNK = 50e6;
    uint256 private constant MAX_DAILY_BPS = 5000;
    uint256 private constant COOLDOWN = 600;

    HedgeFunV2AssetPercentEngineTreasury public immutable treasury;
    EngineAccountingVenue public immutable venue;
    GraduationStock public immutable stock;
    MockToken public immutable usdg;
    MockFeed public immutable stockFeed;
    MockFeed public immutable usdgFeed;

    bool public violation;
    uint256 public dailyAtLastSuccess;
    uint256 public tradeAtLastSuccess;
    uint256 public consumedAtLastSuccess;
    uint256 public usedAtLastSuccess;

    struct BeforeFill {
        uint256 tradeLimit;
        uint256 dailyLimit;
        uint256 price;
        uint256 stockBalance;
        uint256 cashBalance;
        uint256 buyback;
    }
    uint256 public executeAttempts;
    uint256 public failedExecutions;
    uint256 public successfulExecutions;
    uint256 public successfulBuys;
    uint256 public successfulSells;
    uint256 public subMinFillAttempts;
    uint256 public boundaryFillAttempts;
    uint256 public lastSuccessAt;
    uint64 public ghostTurnoverEpoch;
    uint256 public ghostTurnoverInEpoch;

    constructor(
        HedgeFunV2AssetPercentEngineTreasury treasury_,
        EngineAccountingVenue venue_,
        GraduationStock stock_,
        MockToken usdg_,
        MockFeed stockFeed_,
        MockFeed usdgFeed_
    ) {
        treasury = treasury_;
        venue = venue_;
        stock = stock_;
        usdg = usdg_;
        stockFeed = stockFeed_;
        usdgFeed = usdgFeed_;
    }

    function donateStock(uint96 rawAmount) external {
        stock.mint(address(treasury), bound(uint256(rawAmount), 1, 50e18));
    }

    function donateUsdg(uint96 rawAmount) external {
        usdg.mint(address(treasury), bound(uint256(rawAmount), 1, 500e6));
    }

    function setMarket(uint16 rawDollars) external {
        uint256 dollars = bound(uint256(rawDollars), 50, 200);
        venue.setPrice(dollars * 1e18);
        stockFeed.set(int256(dollars * 1e8));
        usdgFeed.set(1e8);
    }

    function shoveVenue(uint16 rawDollars) external {
        venue.setPrice(bound(uint256(rawDollars), 50, 200) * 1e18);
    }

    function setOraclePaused(bool paused) external {
        stock.setOraclePaused(paused);
    }

    function refreshFeeds() external {
        _refreshFeeds();
    }

    function advanceCooldownEdge(uint8 rawEdge) external {
        uint256 edge = uint256(rawEdge) % 3;
        vm.warp(block.timestamp + (edge == 0 ? 599 : edge == 1 ? 600 : 601));
        _refreshFeeds();
    }

    function advanceLive(uint16 rawSeconds) external {
        vm.warp(block.timestamp + bound(uint256(rawSeconds), 1, 1 hours));
        _refreshFeeds();
    }

    function advanceEpoch(uint16 rawOffset) external {
        uint256 nextEpoch = (block.timestamp / 1 days + 1) * 1 days;
        vm.warp(nextEpoch + bound(uint256(rawOffset), 0, 1 hours));
        _refreshFeeds();
    }

    function makeOracleStale(uint16 rawExtra) external {
        vm.warp(block.timestamp + 26 hours + bound(uint256(rawExtra), 1, 1 hours));
    }

    function book() external {
        treasury.book();
    }

    function attemptExecute(uint16 rawFillBps) external {
        uint16 fillBps;
        uint256 fillCase = uint256(rawFillBps) % 5;
        if (fillCase == 0) fillBps = 1;
        else if (fillCase == 1) fillBps = 499;
        else if (fillCase == 2) fillBps = 500;
        else if (fillCase == 3) fillBps = 501;
        else fillBps = uint16(bound(uint256(rawFillBps), 1, 10_000));
        venue.setFillBps(fillBps);
        ++executeAttempts;
        if (fillBps < 500) ++subMinFillAttempts;
        if (fillBps == 500) ++boundaryFillAttempts;

        BeforeFill memory before_;
        (, before_.price) = treasury.health(); // same certified price as the core, even if pool spot differs
        uint256 preNav = FundAssetMath.nav(treasury, stock, before_.price, 1e30);
        before_.tradeLimit = Math.min(Math.mulDiv(preNav, MAX_TRADE_BPS, 10000), CHUNK);
        before_.dailyLimit = Math.mulDiv(preNav, MAX_DAILY_BPS, 10000);
        before_.stockBalance = stock.balanceOf(address(treasury));
        before_.cashBalance = treasury.reserveUsdg();
        before_.buyback = treasury.buybackStock();
        uint64 nonceBefore = treasury.strategyNonce();
        uint64 epochBefore = treasury.turnoverEpoch();
        uint256 turnoverBefore = treasury.turnoverInEpoch();
        bytes32 digestBefore = _stateDigest();

        (bool ok, bytes memory data) =
            address(treasury).call(abi.encodeCall(HedgeFunV2AssetPercentEngineTreasury.execute, ()));
        if (!ok) {
            ++failedExecutions;
            if (_stateDigest() != digestBefore) violation = true;
            return;
        }

        (HedgeFunV2Treasury.Action action,) = abi.decode(data, (HedgeFunV2Treasury.Action, uint256));
        if (action == HedgeFunV2Treasury.Action.RebalanceBuy) ++successfulBuys;
        else if (action == HedgeFunV2Treasury.Action.RebalanceSell) ++successfulSells;
        else violation = true;

        if (treasury.strategyNonce() != nonceBefore + 1) violation = true;
        if (lastSuccessAt != 0 && block.timestamp - lastSuccessAt < COOLDOWN) violation = true;

        uint256 turnoverNow = treasury.turnoverInEpoch();
        uint256 consumed;
        if (treasury.turnoverEpoch() == epochBefore) {
            if (turnoverNow < turnoverBefore) violation = true;
            else consumed = turnoverNow - turnoverBefore;
        } else {
            consumed = turnoverNow;
        }
        uint256 actualTurnover = action == HedgeFunV2Treasury.Action.RebalanceBuy
            ? before_.cashBalance - treasury.reserveUsdg()
            : Math.mulDiv(
                before_.stockBalance - stock.balanceOf(address(treasury)) + treasury.buybackStock() - before_.buyback,
                before_.price,
                1e30
            );
        if (
            consumed != actualTurnover || consumed < MIN_LOT || consumed > before_.tradeLimit
                || turnoverNow > before_.dailyLimit
        ) {
            violation = true;
        }

        // the bucket is the listing calendar's trading date (the fixture's calendar keeps UTC days)
        uint64 expectedEpoch = uint64(treasury.tradingCalendar().tradingDate(block.timestamp));
        if (treasury.turnoverEpoch() != expectedEpoch) violation = true;
        if (ghostTurnoverEpoch != expectedEpoch) {
            ghostTurnoverEpoch = expectedEpoch;
            ghostTurnoverInEpoch = 0;
        }
        ghostTurnoverInEpoch += actualTurnover;
        if (ghostTurnoverInEpoch > before_.dailyLimit || turnoverNow != ghostTurnoverInEpoch) violation = true;
        dailyAtLastSuccess = before_.dailyLimit;
        tradeAtLastSuccess = before_.tradeLimit;
        consumedAtLastSuccess = consumed;
        usedAtLastSuccess = turnoverNow;

        ++successfulExecutions;
        lastSuccessAt = block.timestamp;
    }

    function _refreshFeeds() private {
        stockFeed.set(stockFeed.answer());
        usdgFeed.set(1e8);
    }

    function _stateDigest() private view returns (bytes32) {
        bytes32 strategyDigest = keccak256(
            abi.encode(
                treasury.strategyNonce(),
                treasury.turnoverEpoch(),
                treasury.turnoverInEpoch(),
                treasury.lastStrategyAt(),
                treasury.policyState(),
                treasury.bookedStock(),
                treasury.buybackStock(),
                treasury.avgCost()
            )
        );
        bytes32 accountingDigest = keccak256(
            abi.encode(
                treasury.totalStockReceived(),
                treasury.lastGoodPrice(),
                treasury.lastGoodPriceAt(),
                stock.balanceOf(address(treasury)),
                usdg.balanceOf(address(treasury)),
                stock.balanceOf(address(venue)),
                usdg.balanceOf(address(venue))
            )
        );
        bytes32 anchorDigest = keccak256(abi.encode(treasury.buybackAnchorSqrtP(), treasury.buybackAnchorAt()));
        return keccak256(abi.encode(strategyDigest, accountingDigest, anchorDigest));
    }
}

contract V2AssetPercentInvariantTest is V2AssetPercentEngineFixture {
    HedgeFunV2AssetPercentEngineTreasury internal treasury;
    AssetPercentEngineHandler internal handler;

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        factory.setListingGates(address(stock), 50, 100, 50e6);
        treasury = _launchPercent(1100, 1000, 5000, 5000);
        handler = new AssetPercentEngineHandler(treasury, venue, stock, usdg, stockFeed, usdgFeed);
        targetContract(address(handler));
        // Select mutations explicitly: public counter getters must not inflate the reported handler-call count.
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.donateStock.selector;
        selectors[1] = handler.donateUsdg.selector;
        selectors[2] = handler.setMarket.selector;
        selectors[3] = handler.shoveVenue.selector;
        selectors[4] = handler.setOraclePaused.selector;
        selectors[5] = handler.refreshFeeds.selector;
        selectors[6] = handler.advanceCooldownEdge.selector;
        selectors[7] = handler.advanceLive.selector;
        selectors[8] = handler.advanceEpoch.selector;
        selectors[9] = handler.makeOracleStale.selector;
        selectors[10] = handler.book.selector;
        selectors[11] = handler.attemptExecute.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_bucketsCoveredAndOnlySuccessfulActionsAdvanceState() public view {
        assertLe(treasury.bookedStock() + treasury.buybackStock(), stock.balanceOf(address(treasury)));
        assertEq(treasury.strategyNonce(), handler.successfulExecutions());
        assertEq(treasury.lastStrategyAt(), handler.lastSuccessAt());
        assertEq(treasury.policyState(), bytes32(0));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyFillFitsItsOwnPreTradeNavLimitsAndCumulativeEpochLedger() public view {
        // Post-trade or post-donation NAV may shrink below historical spend. The authoritative bound is the
        // snapshot before each successful action; subsequent shrinking cannot rewrite the consumed history.
        assertLe(handler.consumedAtLastSuccess(), handler.tradeAtLastSuccess());
        assertLe(handler.usedAtLastSuccess(), handler.dailyAtLastSuccess());
        assertFalse(handler.violation());
        assertEq(handler.executeAttempts(), handler.failedExecutions() + handler.successfulExecutions());
        assertEq(handler.successfulExecutions(), handler.successfulBuys() + handler.successfulSells());
        assertEq(treasury.turnoverInEpoch(), handler.ghostTurnoverInEpoch());
    }
}
