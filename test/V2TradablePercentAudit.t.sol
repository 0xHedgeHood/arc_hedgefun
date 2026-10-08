// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {
    HedgeFunV2TradablePercentEngineTreasuryCore,
    HedgeFunV2TradablePercentEngineTreasury,
    HedgeFunV2TradablePercentEngineTreasuryLogic
} from "../src/v2/HedgeFunV2TradablePercentEngineTreasury.sol";
import {
    StrategyAction,
    StrategyContext,
    StrategyIntent,
    EngineConfig,
    IStrategyPolicy
} from "../src/v2/strategy/IStrategyPolicy.sol";
import {V2TradablePercentEngineFixture} from "./V2TradablePercentEngine.t.sol";

/// @dev An approved policy is still untrusted: this one deliberately asks for the entire uint256 range.
contract AuditUnboundedTradablePolicy is IStrategyPolicy {
    uint8 private immutable fault;

    constructor(uint8 value) {
        fault = value;
    }

    function policyMetadata() external pure returns (uint32, uint32, uint256) {
        return (1, 3, 3);
    }

    function decide(StrategyContext calldata context, EngineConfig calldata, bytes32 state)
        external
        view
        returns (StrategyIntent memory intent)
    {
        intent = StrategyIntent(
            context.configHash,
            context.nonce,
            context.usdgInventory > context.stockValueUsdg ? StrategyAction.BuyStock : StrategyAction.SellStock,
            type(uint256).max,
            state
        );
        if (fault == 1) intent.configHash = keccak256("wrong-domain");
        else if (fault == 2) intent.nonce += 1;
        else if (fault == 3) intent.action = StrategyAction.BuybackBurn;
        else if (fault == 4) intent.action = StrategyAction.BuyStock;
    }
}

/// @dev Independent accounting assertions use actual balances and input-asset denominators, not policy helpers.
contract V2TradablePercentAuditTest is V2TradablePercentEngineFixture {
    address private constant KEEPER = address(0xA0D17);
    uint256 private constant SCALE = 1e30;

    struct AuditRisk {
        bool healthy;
        uint256 capital;
        uint256 buy;
        uint256 sell;
        uint256 daily;
        uint256 remaining;
        uint64 epoch;
        uint256 used;
    }

    struct FillSnapshot {
        uint256 held;
        uint256 cash;
        uint256 cost;
        uint256 buyback;
        uint256 venueStock;
        uint256 venueCash;
        uint256 offered;
        uint256 buyCap;
        uint256 sellCap;
        uint256 daily;
    }

    function _auditRisk(HedgeFunV2TradablePercentEngineTreasuryCore t) private view returns (AuditRisk memory r) {
        (r.healthy, r.capital, r.buy, r.sell, r.daily, r.remaining, r.epoch, r.used) = t.riskLimits();
    }

    function _auditDigest(HedgeFunV2TradablePercentEngineTreasuryCore t) private view returns (bytes32) {
        bytes32 trading = keccak256(
            abi.encode(
                t.strategyNonce(),
                t.lastStrategyAt(),
                t.turnoverEpoch(),
                t.turnoverInEpoch(),
                t.policyState(),
                t.bookedStock(),
                t.buybackStock(),
                t.avgCost()
            )
        );
        bytes32 custody = keccak256(
            abi.encode(
                stock.balanceOf(address(t)),
                usdg.balanceOf(address(t)),
                stock.balanceOf(address(venue)),
                usdg.balanceOf(address(venue)),
                stock.balanceOf(KEEPER),
                usdg.balanceOf(KEEPER)
            )
        );
        return keccak256(
            abi.encode(
                trading,
                custody,
                _budgetDigest(t),
                t.totalStockReceived(),
                t.lastGoodPrice(),
                t.lastGoodPriceAt(),
                t.buybackAnchorSqrtP(),
                t.buybackAnchorAt(),
                t.configHash(),
                t.engineConfig()
            )
        );
    }

    /// @dev The directional budget and the loss carry live in their own storage namespace.
    function _budgetDigest(HedgeFunV2TradablePercentEngineTreasuryCore t) private view returns (bytes32) {
        (uint64 epoch, uint256 basis, uint256 buyCap, uint256 sellCap, uint256 bought, uint256 sold) = t.dailyRiskLimits();
        return keccak256(abi.encode(epoch, basis, buyCap, sellCap, bought, sold, t.unrecoveredLossUsdg()));
    }

    /// @dev `riskLimits` adds the two directions together. This is the traded direction's own daily cap: a policy
    ///      that could spend both budgets one way would pass against the sum.
    function _directionCap(HedgeFunV2TradablePercentEngineTreasuryCore t, bool buy, uint256 dailyBps)
        private
        view
        returns (uint256 cap)
    {
        (, uint256 basis, uint256 buyCap, uint256 sellCap,,) = t.dailyRiskLimits();
        cap = buy ? buyCap : sellCap;
        assertEq(cap, Math.mulDiv(basis, dailyBps, 10_000));
        (,,,, uint256 daily,,,) = t.riskLimits();
        assertEq(daily, buyCap + sellCap);
    }

    function testFuzz_partialFillUsesIndependentDirectionalCapsAndActualReward(
        uint16 rawBuy,
        uint16 rawSell,
        uint16 rawFill,
        bool buy,
        bool payout
    ) public {
        uint256 buyBps = bound(rawBuy, 1000, 2500);
        uint256 sellBps = bound(rawSell, 1000, 2500);
        uint16 fill = uint16(bound(rawFill, 1000, 9999));
        // A deliberately tiny legacy cap must not silently clip the new percentage action.
        vm.prank(owner);
        factory.setListingGates(address(stock), 50, 100, 5e6);
        HedgeFunV2TradablePercentEngineTreasuryCore t =
            _launchPercent(3101, buyBps, sellBps, 10_000, payout ? 10_000 : 0);
        if (buy) usdg.mint(address(t), Math.mulDiv(t.bookedStock(), 100e18, SCALE) * 4);
        else if (payout) _price(200e18);
        venue.setFillBps(fill);
        FillSnapshot memory s;
        s.held = t.bookedStock();
        s.cash = t.reserveUsdg();
        s.cost = t.avgCost();
        s.buyback = t.buybackStock();
        s.venueStock = stock.balanceOf(address(venue));
        s.venueCash = usdg.balanceOf(address(venue));
        s.buyCap = Math.mulDiv(s.cash, buyBps, 10_000);
        s.sellCap = Math.mulDiv(s.held, sellBps, 10_000);
        s.daily = Math.mulDiv(s.held, venue.price(), SCALE) + s.cash;
        (bool due, StrategyAction action, uint256 offered) = t.preview();
        assertTrue(due);
        assertEq(uint256(action), uint256(buy ? StrategyAction.BuyStock : StrategyAction.SellStock));
        s.offered = offered;
        if (buy) assertLe(offered, s.buyCap);
        else assertLe(offered, s.sellCap);
        vm.prank(KEEPER);
        t.execute();
        if (buy) {
            uint256 spent = s.cash - t.reserveUsdg();
            uint256 gross = s.venueStock - stock.balanceOf(address(venue));
            uint256 reward = Math.mulDiv(gross, 50, 10_000);
            assertEq(spent, Math.mulDiv(s.offered, fill, 10_000));
            assertLe(spent, s.buyCap);
            assertEq(stock.balanceOf(KEEPER), reward);
            assertEq(t.bookedStock(), s.held + gross - reward);
            assertEq(t.avgCost(), Math.ceilDiv(s.held * s.cost + spent * SCALE, s.held + gross - reward));
            assertEq(t.turnoverInEpoch(), spent);
        } else {
            uint256 sold = stock.balanceOf(address(venue)) - s.venueStock;
            uint256 parked = t.buybackStock() - s.buyback;
            uint256 gross = s.venueCash - usdg.balanceOf(address(venue));
            assertEq(s.held - t.bookedStock(), sold + parked);
            assertLe(sold + parked, s.sellCap);
            assertLt(sold + parked, s.offered, "partial fill cannot charge the offered budget");
            assertEq(usdg.balanceOf(KEEPER), Math.mulDiv(gross, 50, 10_000));
            assertEq(t.turnoverInEpoch(), Math.mulDiv(sold + parked, venue.price(), SCALE));
        }
        assertGe(t.turnoverInEpoch(), 5e6);
        assertLe(t.turnoverInEpoch(), s.daily);
        assertEq(t.bookedStock() + t.buybackStock(), stock.balanceOf(address(t)));
    }

    function test_lpDonationsAndCreditedBuybackCannotInflateAnyTradingCap() public {
        HedgeFunV2TradablePercentEngineTreasuryCore t = _launchPercent(3102, 2300, 1700, 5000, 0);
        AuditRisk memory before_ = _auditRisk(t);
        stock.mint(t.liquidityVault(), 1_000_000e18);
        usdg.mint(t.liquidityVault(), 1_000_000e6);
        assertEq(keccak256(abi.encode(_auditRisk(t))), keccak256(abi.encode(before_)));
        vm.prank(t.liquidityVault());
        stock.approve(address(t), 900_000e18);
        vm.prank(t.liquidityVault());
        t.creditLiquidityFee(900_000e18);
        assertEq(t.buybackStock(), 900_000e18);
        assertEq(keccak256(abi.encode(_auditRisk(t))), keccak256(abi.encode(before_)));
        uint256 sellCap = _directionCap(t, false, 5000);
        t.execute();
        assertEq(t.buybackStock(), 900_000e18, "strategy must not spend reserved LP income");
        assertLe(t.turnoverInEpoch(), sellCap, "a sale is held to the sell direction's own cap");
    }

    function test_unbookedDonationIsCountedOnceAndOnlyForItsInputAsset() public {
        HedgeFunV2TradablePercentEngineTreasuryCore t = _launchPercent(3103, 2000, 2500, 5000, 0);
        AuditRisk memory before_ = _auditRisk(t);
        stock.mint(address(t), 17e18 + 11);
        AuditRisk memory donated = _auditRisk(t);
        assertEq(donated.buy, before_.buy);
        assertEq(donated.sell, Math.mulDiv(t.bookedStock() + 17e18 + 11, 2500, 10_000));
        assertEq(donated.capital, Math.mulDiv(t.bookedStock() + 17e18 + 11, 100e18, SCALE));
        assertTrue(t.book());
        assertFalse(t.book());
        assertEq(keccak256(abi.encode(_auditRisk(t))), keccak256(abi.encode(donated)));
        usdg.mint(address(t), 101e6 + 3);
        AuditRisk memory cashDonation = _auditRisk(t);
        assertEq(cashDonation.sell, donated.sell);
        assertEq(cashDonation.buy, Math.mulDiv(101e6 + 3, 2000, 10_000));
        assertEq(cashDonation.capital, donated.capital + 101e6 + 3);
    }

    function testFuzz_sameDateCapitalShrinkAndDonationNeverEraseConsumedTurnover(uint96 rawCash) public {
        HedgeFunV2TradablePercentEngineTreasuryCore t = _launchPercent(3104, 2000, 1000, 1000, 0);
        AuditRisk memory initial = _auditRisk(t);
        t.execute();
        _advance(600);
        uint256 used = t.turnoverInEpoch();
        uint64 epoch = t.turnoverEpoch();
        assertGt(used, 0);
        _price(1e18);
        AuditRisk memory reduced = _auditRisk(t);
        assertEq(reduced.daily, initial.daily, "falling NAV cannot shrink the pinned daily budgets");
        assertEq(reduced.used, used);
        assertGt(reduced.remaining, 0, "a sale cannot consume the independent dip budget");
        usdg.mint(address(t), used * 30 + bound(rawCash, 0, 100_000e6));
        AuditRisk memory grown = _auditRisk(t);
        assertEq(grown.epoch, epoch);
        assertEq(grown.used, used);
        assertEq(grown.daily, initial.daily, "new capital cannot reopen today's budget");
        t.execute();
        assertGt(t.turnoverInEpoch(), used);
        assertLe(t.turnoverInEpoch(), grown.daily);
    }

    function test_minimumLotCannotRoundUpOneBasisPointCap() public {
        HedgeFunV2TradablePercentEngineTreasuryCore t = _launchPercent(3105, 1, 1, 10_000, 0);
        AuditRisk memory r = _auditRisk(t);
        assertLt(Math.mulDiv(r.sell, 100e18, SCALE), 5e6);
        (bool due,, uint256 amount) = t.preview();
        assertFalse(due);
        assertEq(amount, 0);
        bytes32 before_ = _auditDigest(t);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        t.execute();
        assertEq(_auditDigest(t), before_);
        usdg.mint(address(t), 100_000e6);
        (due,, amount) = t.preview();
        assertTrue(due);
        assertEq(amount, 10e6);
        t.execute();
        assertEq(t.turnoverInEpoch(), 10e6);
    }

    function test_rewardFailureRevertsSwapAndPercentageLedger() public {
        HedgeFunV2TradablePercentEngineTreasuryCore t = _launchPercent(3106, 2000, 2000, 5000, 0);
        usdg.mint(address(t), 100_000e6);
        stock.blockRecipient(KEEPER);
        bytes32 before_ = _auditDigest(t);
        vm.expectRevert();
        vm.prank(KEEPER);
        t.execute();
        assertEq(_auditDigest(t), before_);
    }

    function test_oracleFailureReportsNoCapacityAndCannotChangeSpentHistory() public {
        HedgeFunV2TradablePercentEngineTreasuryCore t = _launchPercent(3107, 2000, 2000, 5000, 0);
        t.execute();
        _advance(600);
        stock.setOraclePaused(true);
        AuditRisk memory r = _auditRisk(t);
        assertFalse(r.healthy);
        assertEq(r.capital, 0);
        assertEq(r.buy, 0);
        assertEq(r.sell, 0);
        assertEq(r.daily, 0);
        assertEq(r.remaining, 0);
        assertGt(r.used, 0);
        bytes32 before_ = _auditDigest(t);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        t.execute();
        assertEq(_auditDigest(t), before_);
    }

    function test_matureUpgradePreservesCurrentDateSpendBeforeAnyEpochRollover() public {
        HedgeFunV2TradablePercentEngineTreasuryCore t = _launchPercent(3108, 2000, 1000, 1000, 0);
        HedgeFunV2TradablePercentEngineTreasury proxy = HedgeFunV2TradablePercentEngineTreasury(payable(address(t)));
        HedgeFunV2TradablePercentEngineTreasuryLogic next = new HedgeFunV2TradablePercentEngineTreasuryLogic(
            address(usdg),
            address(stock),
            address(venue),
            address(oracle),
            address(t.token()),
            address(pm),
            address(factory),
            t.params(),
            _binding(t)
        );
        vm.prank(owner);
        controller.schedule(address(t), address(next), "");
        vm.warp((block.timestamp / 1 days + 3) * 1 days + 1 hours);
        _price(100e18);
        t.execute();
        uint256 used = t.turnoverInEpoch();
        assertGt(used, 0);
        bytes32 before_ = _auditDigest(t);
        AuditRisk memory riskBefore = _auditRisk(t);
        controller.execute(address(t), "");
        assertEq(proxy.implementation(), address(next));
        assertEq(_auditDigest(t), before_);
        assertEq(keccak256(abi.encode(_auditRisk(t))), keccak256(abi.encode(riskBefore)));
        _advance(600);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        t.execute();
        assertEq(t.turnoverInEpoch(), used);
    }

    function _registerUnbounded(uint8 fault) private {
        AuditUnboundedTradablePolicy candidate = new AuditUnboundedTradablePolicy(fault);
        vm.prank(owner);
        percentPolicyKey = deployer.registerPolicy(
            address(candidate),
            150_000,
            160,
            keccak256("audit-unbounded-deps"),
            keccak256(abi.encode("audit-unbounded", fault))
        );
    }

    function testFuzz_unboundedPolicyCannotBypassCoreInputOrDailyCaps(bool buy, uint16 rawBps) public {
        _registerUnbounded(0);
        uint256 bps = bound(rawBps, 1000, 2500);
        HedgeFunV2TradablePercentEngineTreasuryCore t = _launchPercent(3109, bps, bps, 500, 0);
        if (buy) usdg.mint(address(t), 100_000e6);
        uint256 held = t.bookedStock();
        uint256 cash = t.reserveUsdg();
        uint256 cap = _directionCap(t, buy, 500);
        (bool due, StrategyAction action, uint256 offered) = t.preview();
        assertTrue(due);
        assertEq(uint256(action), uint256(buy ? StrategyAction.BuyStock : StrategyAction.SellStock));
        if (buy) {
            assertLe(offered, Math.mulDiv(cash, bps, 10_000));
            assertLe(offered, cap);
        } else {
            assertLe(offered, Math.mulDiv(held, bps, 10_000));
            assertLe(Math.mulDiv(offered, 100e18, SCALE), cap);
        }
        t.execute();
        assertLe(t.turnoverInEpoch(), cap);
        assertGt(t.turnoverInEpoch(), cap / 2, "the daily cap, not the action cap, is what bound this action");
        if (buy) assertLe(cash - t.reserveUsdg(), Math.mulDiv(cash, bps, 10_000));
        else assertLe(held - t.bookedStock(), Math.mulDiv(held, bps, 10_000));
    }

    function test_malformedDomainNonceActionAndWrongDirectionAreAtomicallyRejected() public {
        for (uint8 fault = 1; fault <= 4; ++fault) {
            _registerUnbounded(fault);
            HedgeFunV2TradablePercentEngineTreasuryCore t = _launchPercent(3120 + fault, 2000, 2000, 5000, 0);
            stock.mint(address(t), 3e18); // execute books this before policy evaluation; rejection must undo it.
            bytes32 before_ = _auditDigest(t);
            (bool due,, uint256 offered) = t.preview();
            assertFalse(due);
            assertEq(offered, 0);
            vm.expectRevert(
                fault <= 2
                    ? HedgeFunTreasuryBase.NotDue.selector
                    : HedgeFunV2TradablePercentEngineTreasuryCore.BadIntent.selector
            );
            t.execute();
            assertEq(_auditDigest(t), before_);
        }
    }
}
