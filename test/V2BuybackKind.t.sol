// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunV2BuybackTreasury} from "../src/v2/HedgeFunV2BuybackTreasury.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

/// Kind 1 through the whole lifecycle: registered by the owner, chosen by the creator, launched, graduated, and
/// then spending its stock only through the paced, TWAP-bounded buy-back. It never holds a lot.
contract V2BuybackKindTest is V2FactoryFixture {
    using PoolIdLibrary for PoolKey;

    V2TreasuryDeployer internal deployer;
    HedgeFunV2BuybackTreasury internal treasury;
    HedgeFunBondingCurve internal curve;
    PoolKey internal key;

    function setUp() public {
        _setUpV2(18);
        deployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        (address a, address b) = deployer.makeChunks(type(HedgeFunV2BuybackTreasury).creationCode);
        vm.prank(owner);
        assertEq(deployer.registerKind(a, b), 1);
        HedgeFunFactory.Request memory q = _request();
        deployer.setStrategyKind(q.symbol, q.nonce, 1);
        (,, bytes32 terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        curve = HedgeFunBondingCurve(factory.curves(id));
        (, address t,,,) = factory.strategies(id);
        treasury = HedgeFunV2BuybackTreasury(t);
        (key,) = factory.graduationConfig(id);
        stock.approve(address(curve), type(uint256).max);
        vm.warp(curve.launchedAt() + curve.snipeSeconds());
    }

    function test_graduationPrincipalIsProtectedAndCannotFundBuybacks() public {
        assertFalse(treasury.book(), "nothing to book before graduation");
        _graduateV2(curve);
        uint256 share = stock.balanceOf(address(treasury));
        assertGt(share, 0);
        assertEq(treasury.buybackStock(), 0, "graduation principal is not income");
        assertEq(treasury.bookedStock(), share);
        assertEq(treasury.protectedGraduationStock(), share);
        assertEq(treasury.lotCount(), 0);
        assertEq(treasury.unbookedStock(), 0);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        treasury.buyback();
        vm.expectRevert(HedgeFunV2BuybackTreasury.UseBuyback.selector);
        treasury.execute();
        vm.expectRevert(HedgeFunV2Treasury.UseExecute.selector);
        treasury.buyDip();
    }

    function test_feesClaimedBeforeGraduationRemainBuybackIncome() public {
        curve.buy(1e18, 1, address(this), block.timestamp);
        uint256 fees = curve.claimable(address(treasury));
        assertGt(fees, 0);
        curve.claimFees(address(treasury));
        assertEq(stock.balanceOf(address(treasury)), fees);
        assertFalse(treasury.book(), "income waits until the pool is wired");

        _graduateV2(curve);
        uint256 principal = stock.balanceOf(address(treasury)) - fees;
        assertEq(treasury.protectedGraduationStock(), principal);
        assertEq(treasury.bookedStock(), principal);
        assertEq(treasury.buybackStock(), fees, "earned fees are not graduation capital");
        assertEq(treasury.totalStockReceived(), principal + fees);
        assertEq(treasury.unbookedStock(), 0);
        assertFalse(treasury.book(), "income cannot be counted twice");
    }

    function test_failedOptionalBookCannotExposePrincipalToLaterIncomeBooking() public {
        curve.buy(1e18, 1, address(this), block.timestamp);
        uint256 fees = curve.claimable(address(treasury));
        curve.claimFees(address(treasury));
        // Fault injection checks the factory's documented catch path, not an assumed live exploit.
        vm.mockCallRevert(address(treasury), abi.encodeWithSelector(treasury.book.selector), bytes("book failed"));
        _graduateV2(curve);
        vm.clearMockedCalls();

        uint256 principal = stock.balanceOf(address(treasury)) - fees;
        assertEq(treasury.protectedGraduationStock(), principal);
        assertEq(treasury.buybackStock(), 0);
        stock.transfer(address(treasury), 3e18);
        assertTrue(treasury.book());
        assertEq(treasury.buybackStock(), fees + 3e18);
        assertEq(treasury.bookedStock(), principal);
        assertEq(treasury.totalStockReceived(), principal + fees + 3e18);
        assertFalse(treasury.book());
    }

    function test_principalInitializerRequiresFactoryAndCannotRepeat() public {
        vm.expectRevert(HedgeFunTreasuryBase.NotFactory.selector);
        treasury.wireWithGraduation(key, 1);
        _graduateV2(curve);
        uint256 principal = treasury.protectedGraduationStock();
        vm.prank(address(factory));
        vm.expectRevert(HedgeFunTreasuryBase.AlreadyWired.selector);
        treasury.wireWithGraduation(key, 0);
        assertEq(treasury.protectedGraduationStock(), principal);
    }

    function testFuzz_preclaimedIncomeNeverBecomesGraduationPrincipal(
        uint96 grossInput, uint96 donationInput, bool failOptionalBook
    ) public {
        uint256 gross = bound(uint256(grossInput), 1e16, 5e18);
        uint256 donation = bound(uint256(donationInput), 0, 3e18);
        curve.buy(gross, 1, address(this), block.timestamp);
        uint256 fees = curve.claimable(address(treasury));
        assertGt(fees, 0);
        curve.claimFees(address(treasury));
        if (donation != 0) stock.transfer(address(treasury), donation);
        assertFalse(treasury.book());
        uint256 supplyBefore = IERC20(curve.token()).totalSupply();
        if (failOptionalBook) {
            vm.mockCallRevert(address(treasury), abi.encodeWithSelector(treasury.book.selector), bytes("book failed"));
        }
        _graduateV2(curve);
        vm.clearMockedCalls();
        assertEq(IERC20(curve.token()).totalSupply(), supplyBefore, "graduation must not burn FUN");
        uint256 income = fees + donation;
        uint256 principal = stock.balanceOf(address(treasury)) - income;
        assertGt(principal, 0);
        assertEq(treasury.protectedGraduationStock(), principal);
        assertEq(treasury.bookedStock(), principal);
        if (failOptionalBook) {
            assertEq(treasury.buybackStock(), 0);
            assertTrue(treasury.book());
        }
        assertEq(treasury.buybackStock(), income);
        assertEq(treasury.totalStockReceived(), principal + income);
        assertEq(treasury.unbookedStock(), 0);
        assertFalse(treasury.book(), "no duplicate income");
    }

    function test_failedPrincipalInitializationCannotFallBackToLegacyWire() public {
        vm.mockCallRevert(address(treasury),
            abi.encodeWithSelector(treasury.wireWithGraduation.selector), bytes("wire failed"));
        vm.expectRevert(HedgeFunV2BuybackTreasury.GraduationPrincipalRequired.selector);
        curve.buy(type(uint256).max, 1, address(this), block.timestamp);
        assertEq(uint256(curve.status()), uint256(HedgeFunBondingCurve.Status.Active));
        assertEq(treasury.hook(), address(0));
        assertEq(treasury.liquidityVault(), address(0));
        assertEq(treasury.protectedGraduationStock(), 0);
    }

    function test_buybackPacesSpendsBurnsWithoutRearmingSellSpike() public {
        _graduateV2(curve);
        _creditFeeIncome();
        uint256 budget = treasury.buybackStock();
        IERC20 token = IERC20(curve.token());
        uint256 supplyBefore = token.totalSupply();
        (uint256 spent, uint256 burned) = treasury.buyback();
        assertGt(spent, 0); assertGt(burned, 0);
        assertGt(treasury.lastGoodPrice(), 0, "a live buy-back records the oracle observation");
        assertEq(treasury.lastGoodPriceAt(), block.timestamp);
        assertLt(spent, budget, "one chunk, not the whole budget");
        assertEq(treasury.buybackStock(), budget - spent);
        assertEq(token.totalSupply(), supplyBefore - burned);
        assertEq(hook.sellRateBps(key.toId()), 1000, "LP-funded buy-backs cannot arm the sell spike");
        uint256 cachedAt = treasury.lastGoodPriceAt();
        vm.expectRevert(HedgeFunTreasuryBase.Cooldown.selector);
        treasury.buyback();
        assertEq(treasury.lastGoodPriceAt(), cachedAt, "a cooldown rejection cannot refresh the cache");
        vm.warp(block.timestamp + 61);
        (uint256 spent2,) = treasury.buyback();
        assertGt(spent2, 0);
        assertEq(treasury.lotCount(), 0, "still no stock position after two buy-backs");
    }

    function test_openMarketOracleOutageCannotUseCachedPrice() public {
        _graduateV2(curve);
        _creditFeeIncome();
        (uint256 spent,) = treasury.buyback();
        uint256 left = treasury.buybackStock();
        assertGt(spent, 0);
        assertGt(left, 0);

        // An open-market outage must not be mistaken for a scheduled closure, even with a recent cache.
        vm.warp(block.timestamp + 27 hours);
        usdgFeed.set(1e8);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        treasury.buyback();
        assertEq(treasury.buybackStock(), left);
    }

    function test_staleOracleWithoutACacheStillFailsClosed() public {
        _graduateV2(curve);
        _creditFeeIncome();
        assertEq(treasury.lastGoodPrice(), 0);
        assertEq(treasury.lastGoodPriceAt(), 0);
        vm.warp(block.timestamp + 27 hours);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        treasury.buyback();
    }

    function test_weekendTwapWorksWithoutCacheAndWithStrategyBandDisabled() public {
        _graduateV2(curve);
        _creditFeeIncome();
        assertEq(treasury.lastGoodPrice(), 0);
        assertEq(treasury.params().bandBpsPerHour, 0);
        _weekend();
        _poolPrice(120e18);
        assertFalse(treasury.book());
        (bool healthy,) = treasury.health();
        assertFalse(healthy, "stock strategy remains disabled out of hours");
        _assertTwapBuyback();
        assertEq(treasury.lastGoodPrice(), 0, "TWAP must not become an oracle observation");
        assertEq(treasury.lastGoodPriceAt(), 0);
    }

    function test_weekendTwapTakesPriorityOverOldCache() public {
        _graduateV2(curve);
        _creditFeeIncome();
        treasury.buyback();
        uint256 cached = treasury.lastGoodPrice();
        uint256 cachedAt = treasury.lastGoodPriceAt();
        _weekend();
        _poolPrice(120e18);
        _assertTwapBuyback();
        assertEq(treasury.lastGoodPrice(), cached);
        assertEq(treasury.lastGoodPriceAt(), cachedAt);
    }

    function testFuzz_weekendSizingUsesBoundedTwap(uint96 priceSeed) public {
        _graduateV2(curve);
        _creditFeeIncome();
        _weekend();
        _poolPrice(bound(uint256(priceSeed), 71e18, 129e18));
        _assertTwapBuyback();
    }

    function test_weekendWithoutObservationHistoryFailsClosed() public {
        _fundWeekend();
        vm.mockCallRevert(address(stockPool), abi.encodeWithSignature("observe(uint32[])"), bytes("OLD"));
        _assertRejected();
    }

    function test_weekendSpotShoveCannotUseTwapOrCachedPrice() public {
        _graduateV2(curve);
        _creditFeeIncome();
        treasury.buyback(); // a valid cache must not bypass the weekend checks
        _weekend();
        int56[] memory tc = new int56[](2);
        tc[1] = int56(stockPool.tick()) * 600;
        vm.mockCall(address(stockPool), abi.encodeWithSignature("observe(uint32[])"),
            abi.encode(tc, new uint160[](2)));
        _poolPrice(120e18);
        _assertRejected();
    }

    function test_weekendTwapOutsideLastFeedBandFailsClosed() public {
        _fundWeekend();
        _poolPrice(140e18);
        _assertRejected();
        _poolPrice(60e18);
        _assertRejected();
    }

    function test_weekendPausedStockFailsClosed() public {
        _fundWeekend();
        stock.setOraclePaused(true);
        _assertRejected();
    }

    function test_weekendStaleDollarFeedFailsClosed() public {
        _fundWeekend();
        usdgFeed.setAt(1e8, block.timestamp - 27 hours);
        _assertRejected();
    }

    function test_weekendInvalidStockReferenceFailsClosed() public {
        _fundWeekend();
        stockFeed.set(0);
        _assertRejected();
        stockFeed.setAt(100e8, block.timestamp + 1);
        _assertRejected();
    }

    function test_forcedClosureCannotEnableTwap() public {
        _fundWeekend();
        vm.mockCall(address(oracle.calendar()), abi.encodeWithSignature("isScheduledClosure(uint256)"), abi.encode(false));
        _assertRejected();
    }

    function test_brokenCalendarFailsClosed() public {
        _fundWeekend();
        vm.mockCallRevert(address(oracle.calendar()), abi.encodeWithSignature("isScheduledClosure(uint256)"), bytes("broken"));
        _assertRejected();
    }

    function _weekend() private {
        vm.warp(block.timestamp + 2 days);
        usdgFeed.set(1e8);
        vm.mockCall(address(oracle.calendar()), abi.encodeWithSignature("isClosed(uint256)"), abi.encode(true));
        vm.mockCall(address(oracle.calendar()), abi.encodeWithSignature("isScheduledClosure(uint256)"), abi.encode(true));
    }

    function _poolPrice(uint256 price) private {
        stockPool.setSqrt(uint160(Math.sqrt(Math.mulDiv(price, 1 << 192, 1e30))));
    }

    function _fundWeekend() private {
        _graduateV2(curve);
        _creditFeeIncome();
        _weekend();
    }

    function _assertTwapBuyback() private {
        uint256 budget = treasury.buybackStock();
        uint256 principal = treasury.bookedStock();
        uint256 balance = stock.balanceOf(address(treasury));
        uint256 supply = IERC20(curve.token()).totalSupply();
        uint256 chunk = Math.min(budget, Math.mulDiv(treasury.params().buybackChunkUsdg, 1e30, treasury.twapPrice()));
        vm.expectCall(address(pm), abi.encodeCall(IPoolManager.unlock, (abi.encode(chunk))));
        (uint256 spent, uint256 burned) = treasury.buyback();
        assertGt(spent, 0);
        assertGt(burned, 0);
        assertLe(spent, chunk);
        assertEq(treasury.buybackStock(), budget - spent);
        assertEq(stock.balanceOf(address(treasury)), balance - spent);
        assertEq(treasury.bookedStock(), principal, "principal is never spent");
        assertEq(IERC20(curve.token()).totalSupply(), supply - burned, "the acquired FUN is burned");
    }

    function _assertRejected() private {
        uint256 budget = treasury.buybackStock();
        uint256 lastAt = treasury.lastBuybackAt();
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        treasury.buyback();
        assertEq(treasury.buybackStock(), budget);
        assertEq(treasury.lastBuybackAt(), lastAt);
    }

    /// The published score is `(stockEquivalentHeld + totalStockSpentOnBuybacks) / totalStockReceived`. Kind 1
    /// books straight into the budget, never through `_book`, so it must write the denominator itself.
    function test_kindOneBookRecordsReceivedStockSoTheScorecardHasADenominator() public {
        _graduateV2(curve);
        uint256 share = treasury.protectedGraduationStock();
        assertGt(share, 0);
        assertEq(treasury.totalStockReceived(), share, "the graduation share is stock received");
        _creditFeeIncome();
        treasury.buyback();
        assertGt(treasury.totalStockSpentOnBuybacks(), 0);
        assertEq(treasury.totalStockReceived(), share, "spending is not receiving");
        stock.mint(address(treasury), 7e18);
        assertTrue(treasury.book());
        assertEq(treasury.totalStockReceived(), share + 7e18, "every later arrival counts once");
        assertFalse(treasury.book(), "nothing new to book");
        assertEq(treasury.totalStockReceived(), share + 7e18, "a second book() counts nothing twice");
        (bool ok, uint256 held) = treasury.stockEquivalentHeld();
        assertTrue(ok);
        assertGt((held + treasury.totalStockSpentOnBuybacks()) * 1e18 / treasury.totalStockReceived(), 0);
    }

    function test_everyLaterStockArrivalIsBudgetToo() public {
        _graduateV2(curve);
        uint256 before = treasury.buybackStock();
        stock.transfer(address(treasury), 3e18); // a sell-tax claim or a donation land the same way
        assertTrue(treasury.book());
        assertEq(treasury.buybackStock(), before + 3e18);
        assertEq(treasury.lotCount(), 0);
    }

    function test_kindZeroLaunchIsUnaffected() public {
        HedgeFunFactory.Request memory q = _request();
        q.nonce = 7; // no kind chosen for this salt
        (,, bytes32 terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        (, address t,,,) = factory.strategies(id);
        assertEq(deployer.strategyKindOf(keccak256(abi.encode(q.symbol, address(this), q.nonce))), 0);
        vm.expectRevert(); // a kind-0 treasury has no UseBuyback selector: execute reverts for its own reasons
        HedgeFunV2BuybackTreasury(t).execute();
    }

    function _creditFeeIncome() private {
        address vault = treasury.liquidityVault();
        stock.mint(vault, 100e18);
        vm.startPrank(vault);
        stock.approve(address(treasury), 100e18);
        treasury.creditLiquidityFee(100e18);
        vm.stopPrank();
    }
}
