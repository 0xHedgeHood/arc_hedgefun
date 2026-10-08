// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {
    HedgeFunV2TradablePercentEngineTreasuryCore,
    HedgeFunV2TradablePercentEngineTreasury,
    HedgeFunV2TradablePercentEngineTreasuryLogic
} from "../src/v2/HedgeFunV2TradablePercentEngineTreasury.sol";
import {V2TreasuryUpgradeController} from "../src/v2/V2TreasuryUpgradeController.sol";
import {EngineAccountingVenue} from "./V2StrategyEngineAccounting.t.sol";
import {MockFeed, MockToken} from "./mocks/Mocks.sol";
import {GraduationStock} from "./utils/V2FactoryFixture.sol";
import {V2TradablePercentEngineFixture} from "./V2TradablePercentEngine.t.sol";

/// @dev Expected caps derive from independent balance snapshots, never from riskLimits or policy output.
contract TradablePercentAuditHandler is Test {
    uint256 private constant SCALE = 1e30;
    HedgeFunV2TradablePercentEngineTreasuryCore public immutable treasury;
    HedgeFunV2TradablePercentEngineTreasury public immutable proxy;
    EngineAccountingVenue public immutable venue;
    GraduationStock public immutable stock;
    MockToken public immutable usdg;
    MockFeed private immutable stockFeed;
    MockFeed private immutable usdgFeed;
    V2TreasuryUpgradeController public immutable controller;
    address private immutable owner;
    address private immutable first;
    address private immutable second;

    bool public violation;
    uint256 public failureMask;
    uint256 public executeAttempts;
    uint256 public failures;
    uint256 public successes;
    uint256 public buys;
    uint256 public sells;
    uint256 public upgrades;
    uint256 public lastSuccessAt;
    uint64 public ghostEpoch;
    uint256 public ghostUsed;
    uint256 public ghostBought;
    uint256 public ghostSold;
    uint256 public ghostDailyBasis;
    uint256 public dailyAtLastSuccess;
    uint256 public directionalCapAtLastSuccess;
    uint256 public directionalInputAtLastSuccess;

    struct Snapshot {
        uint256 stockBalance;
        uint256 inventory;
        uint256 cash;
        uint256 buyback;
        uint256 price;
        uint256 cost;
        uint256 capital;
        uint256 keeperStock;
        uint256 keeperCash;
        uint256 poolStock;
        uint256 poolCash;
        bytes32 digest;
    }

    constructor(
        HedgeFunV2TradablePercentEngineTreasuryCore t,
        EngineAccountingVenue v,
        GraduationStock s,
        MockToken u,
        MockFeed sf,
        MockFeed uf,
        V2TreasuryUpgradeController control,
        address owner_,
        address replacement
    ) {
        treasury = t;
        proxy = HedgeFunV2TradablePercentEngineTreasury(payable(address(t)));
        venue = v;
        stock = s;
        usdg = u;
        stockFeed = sf;
        usdgFeed = uf;
        controller = control;
        owner = owner_;
        first = proxy.initialImplementation();
        second = replacement;
    }

    function donateStock(uint96 raw) external {
        stock.mint(address(treasury), bound(raw, 1, 100e18));
    }

    function donateCash(uint96 raw) external {
        usdg.mint(address(treasury), bound(raw, 1, 10_000e6));
    }

    function creditLpIncome(uint96 raw) external {
        uint256 amount = bound(raw, 1, 100e18);
        stock.mint(treasury.liquidityVault(), amount);
        vm.prank(treasury.liquidityVault());
        stock.approve(address(treasury), amount);
        vm.prank(treasury.liquidityVault());
        treasury.creditLiquidityFee(amount);
    }

    function changeMarket(uint16 raw) external {
        uint256 price = bound(raw, 1, 300) * 1e18;
        venue.setPrice(price);
        stockFeed.set(int256(price / 1e10));
        usdgFeed.set(1e8);
    }

    function shoveVenue(uint16 raw) external {
        venue.setPrice(bound(raw, 1, 300) * 1e18);
    }

    function pauseOracle(bool value) external {
        stock.setOraclePaused(value);
    }

    function refreshFeeds() external {
        _refresh();
    }

    function advanceCooldown(uint8 raw) external {
        vm.warp(block.timestamp + 599 + uint256(raw) % 3);
        _refresh();
    }

    function nextEpoch(uint16 raw) external {
        vm.warp((block.timestamp / 1 days + 1) * 1 days + uint256(raw) % 3600);
        _refresh();
    }

    function staleOracle(uint16 raw) external {
        vm.warp(block.timestamp + 26 hours + uint256(raw) % 3600);
    }

    function book() external {
        treasury.book();
    }

    function scheduleUpgrade() external {
        address next = proxy.implementation() == first ? second : first;
        vm.prank(owner);
        controller.schedule(address(proxy), next, "");
    }

    function cancelUpgrade() external {
        vm.prank(owner);
        controller.cancel(address(proxy));
    }

    function finishUpgrade(bool mature) external {
        (address next,,,, uint256 readyAt) = controller.proposals(address(proxy));
        if (readyAt == 0) return;
        if (block.timestamp < readyAt) {
            if (!mature) return;
            vm.warp(readyAt);
            _refresh();
        }
        bytes32 before_ = _digest();
        controller.execute(address(proxy), "");
        if (_digest() != before_ || proxy.implementation() != next) _fail(1);
        ++upgrades;
    }

    function attemptExecute(uint16 raw) external {
        uint16 fill = raw % 4 == 0 ? 1 : raw % 4 == 1 ? 10_000 : uint16(bound(raw, 1, 9999));
        venue.setFillBps(fill);
        ++executeAttempts;
        Snapshot memory s;
        s.stockBalance = stock.balanceOf(address(treasury));
        s.buyback = treasury.buybackStock();
        s.inventory = s.stockBalance - s.buyback;
        s.cash = treasury.reserveUsdg();
        (, s.price) = treasury.health();
        s.cost = treasury.avgCost();
        s.capital = Math.mulDiv(s.inventory, s.price, SCALE) + s.cash;
        s.keeperStock = stock.balanceOf(address(this));
        s.keeperCash = usdg.balanceOf(address(this));
        s.poolStock = stock.balanceOf(address(venue));
        s.poolCash = usdg.balanceOf(address(venue));
        s.digest = _digest();
        (bool ok, bytes memory data) =
            address(treasury).call(abi.encodeCall(HedgeFunV2TradablePercentEngineTreasuryCore.execute, ()));
        if (!ok) {
            ++failures;
            if (_digest() != s.digest) _fail(2);
            return;
        }
        (HedgeFunV2Treasury.Action action, uint256 nonce) = abi.decode(data, (HedgeFunV2Treasury.Action, uint256));
        uint256 consumed;
        if (action == HedgeFunV2Treasury.Action.RebalanceBuy) {
            ++buys;
            consumed = s.cash - treasury.reserveUsdg();
            directionalInputAtLastSuccess = consumed;
            directionalCapAtLastSuccess = Math.mulDiv(s.cash, 2000, 10_000);
            uint256 gross = s.poolStock - stock.balanceOf(address(venue));
            uint256 reward = stock.balanceOf(address(this)) - s.keeperStock;
            if (reward != Math.mulDiv(gross, 50, 10_000)) _fail(4);
            if (treasury.bookedStock() != s.inventory + gross - reward) _fail(8);
        } else if (action == HedgeFunV2Treasury.Action.RebalanceSell) {
            ++sells;
            uint256 moved = s.stockBalance - stock.balanceOf(address(treasury)) + treasury.buybackStock() - s.buyback;
            consumed = Math.mulDiv(moved, s.price, SCALE);
            directionalInputAtLastSuccess = moved;
            directionalCapAtLastSuccess = Math.mulDiv(s.inventory, 2500, 10_000);
            uint256 gross = s.poolCash - usdg.balanceOf(address(venue));
            if (usdg.balanceOf(address(this)) - s.keeperCash != Math.mulDiv(gross, 50, 10_000)) _fail(16);
            if (treasury.bookedStock() != s.inventory - moved) _fail(32);
        } else {
            _fail(64);
        }
        uint64 epoch = uint64(treasury.tradingCalendar().tradingDate(block.timestamp));
        if (ghostEpoch != epoch) {
            ghostEpoch = epoch;
            ghostUsed = 0;
            ghostBought = 0;
            ghostSold = 0;
            ghostDailyBasis = s.capital;
        }
        ghostUsed += consumed;
        if (action == HedgeFunV2Treasury.Action.RebalanceBuy) ghostBought += consumed;
        else ghostSold += consumed;
        dailyAtLastSuccess = Math.mulDiv(ghostDailyBasis, 5000, 10_000);
        // What has to be a lot is the FILL. For a buy that is the cash spent. For a sale it is the stock swapped
        // plus the marked gain withheld beside it, and what leaves inventory can be less than that: loss recovery
        // and costs keep withheld stock in inventory. The swapped part alone is never under a lot less the largest
        // share a sale withholds, `payoutBps` of the gain over average cost.
        uint256 lot = 5e6;
        if (action == HedgeFunV2Treasury.Action.RebalanceSell && s.price > s.cost) {
            lot -= Math.mulDiv(Math.mulDiv(lot, s.price - s.cost, s.price), treasury.payoutBps(), 10_000) + 4;
        }
        if (consumed < lot) _fail(128);
        if (directionalInputAtLastSuccess > directionalCapAtLastSuccess) _fail(256);
        if (ghostBought > dailyAtLastSuccess || ghostSold > dailyAtLastSuccess) _fail(512);
        if (treasury.turnoverInEpoch() != ghostUsed) _fail(1024);
        if (treasury.turnoverEpoch() != epoch) _fail(2048);
        if (nonce != successes + 1 || treasury.strategyNonce() != nonce) _fail(4096);
        if (lastSuccessAt != 0 && block.timestamp - lastSuccessAt < 600) _fail(8192);
        ++successes;
        lastSuccessAt = block.timestamp;
    }

    function _fail(uint256 mask) private {
        violation = true;
        failureMask |= mask;
    }

    function _refresh() private {
        stockFeed.set(stockFeed.answer());
        usdgFeed.set(1e8);
    }

    function _digest() private view returns (bytes32) {
        (bool readOk, bytes memory daily) = address(treasury).staticcall(abi.encodeWithSignature("dailyRiskLimits()"));
        require(readOk, "daily read");
        bytes32 execution = keccak256(
            abi.encode(
                daily,
                treasury.strategyNonce(),
                treasury.lastStrategyAt(),
                treasury.turnoverEpoch(),
                treasury.turnoverInEpoch(),
                treasury.policyState(),
                treasury.avgCost(),
                treasury.unrecoveredLossUsdg(),
                treasury.bookedStock(),
                treasury.buybackStock()
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
        return keccak256(
            abi.encode(
                execution,
                balances,
                treasury.engineConfig(),
                treasury.configHash(),
                treasury.totalStockReceived(),
                treasury.lastGoodPrice(),
                treasury.lastGoodPriceAt(),
                treasury.buybackAnchorSqrtP(),
                treasury.buybackAnchorAt()
            )
        );
    }
}

contract V2TradablePercentInvariantTest is V2TradablePercentEngineFixture {
    HedgeFunV2TradablePercentEngineTreasuryCore private treasury;
    TradablePercentAuditHandler private handler;

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        factory.setListingGates(address(stock), 50, 100, 5e6);
        treasury = _launchPercent(3200, 2000, 2500, 5000, 5000);
        HedgeFunV2TradablePercentEngineTreasuryLogic next = new HedgeFunV2TradablePercentEngineTreasuryLogic(
            address(usdg),
            address(stock),
            address(venue),
            address(oracle),
            address(treasury.token()),
            address(pm),
            address(factory),
            treasury.params(),
            _binding(treasury)
        );
        handler = new TradablePercentAuditHandler(
            treasury, venue, stock, usdg, stockFeed, usdgFeed, controller, owner, address(next)
        );
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = handler.donateStock.selector;
        selectors[1] = handler.donateCash.selector;
        selectors[2] = handler.creditLpIncome.selector;
        selectors[3] = handler.changeMarket.selector;
        selectors[4] = handler.shoveVenue.selector;
        selectors[5] = handler.pauseOracle.selector;
        selectors[6] = handler.refreshFeeds.selector;
        selectors[7] = handler.advanceCooldown.selector;
        selectors[8] = handler.nextEpoch.selector;
        selectors[9] = handler.staleOracle.selector;
        selectors[10] = handler.book.selector;
        selectors[11] = handler.scheduleUpgrade.selector;
        selectors[12] = handler.cancelUpgrade.selector;
        selectors[13] = handler.finishUpgrade.selector;
        selectors[14] = handler.attemptExecute.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_inventoryAndNonceMatchActualSuccessfulFillsAcrossUpgrades() public view {
        assertEq(handler.failureMask(), 0);
        assertLe(treasury.bookedStock() + treasury.buybackStock(), stock.balanceOf(address(treasury)));
        assertEq(treasury.strategyNonce(), handler.successes());
        assertEq(treasury.lastStrategyAt(), handler.lastSuccessAt());
        assertEq(treasury.policyState(), bytes32(0));
        assertEq(handler.executeAttempts(), handler.successes() + handler.failures());
        assertEq(handler.successes(), handler.buys() + handler.sells());
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_dynamicCapsUseInputAssetsAndNeverRewriteHistoricalSpend() public view {
        assertEq(handler.failureMask(), 0);
        assertLe(handler.directionalInputAtLastSuccess(), handler.directionalCapAtLastSuccess());
        assertLe(handler.ghostBought(), handler.dailyAtLastSuccess());
        assertLe(handler.ghostSold(), handler.dailyAtLastSuccess());
        assertEq(handler.ghostUsed(), handler.ghostBought() + handler.ghostSold());
        assertEq(treasury.turnoverInEpoch(), handler.ghostUsed());
        assertEq(treasury.turnoverEpoch(), handler.ghostEpoch());
    }

    function test_handlerWitnessBuysSellsRejectsAndPreservesHistoryThroughUpgrade() public {
        handler.attemptExecute(1);
        assertEq(handler.sells(), 1);
        handler.attemptExecute(1);
        assertEq(handler.failures(), 1);
        handler.donateCash(10_000e6);
        handler.advanceCooldown(1);
        handler.attemptExecute(1);
        assertEq(handler.buys(), 1);
        handler.scheduleUpgrade();
        handler.finishUpgrade(true);
        assertEq(handler.upgrades(), 1);
        stock.mint(address(treasury), 1000e18);
        handler.attemptExecute(1);
        assertEq(handler.sells(), 2);
        invariant_inventoryAndNonceMatchActualSuccessfulFillsAcrossUpgrades();
        invariant_dynamicCapsUseInputAssetsAndNeverRewriteHistoricalSpend();
    }
}
