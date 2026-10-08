// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunV2UpgradeableTreasury} from "../src/v2/HedgeFunV2UpgradeableTreasury.sol";
import {
    HedgeFunV2PercentBuybackTreasury,
    HedgeFunV2PercentBuybackTreasuryLogic
} from "../src/v2/HedgeFunV2PercentBuybackTreasury.sol";
import {
    HedgeFunV2UpgradeableCycleTreasury,
    HedgeFunV2UpgradeableCycleTreasuryLogic
} from "../src/v2/HedgeFunV2UpgradeableCycleTreasury.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {V2TreasuryUpgradeController} from "../src/v2/V2TreasuryUpgradeController.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {RegisterV2PercentBuyback} from "../script/RegisterV2PercentBuyback.s.sol";
import {RegisterV2UpgradeableCycle} from "../script/RegisterV2UpgradeableCycle.s.sol";
import {TestnetMarket} from "../script/testnet/TestnetMarket.sol";
import {TestnetForkVenue} from "./utils/TestnetForkVenue.sol";

/// The three lot-rule kinds on the deployed testnet venue: the ordinary strategy (kind 0), the same strategy with
/// the percentage buy-back, and the cycle strategy. Each is launched through the real factory, graduated through
/// the real curve, traded on the real stock pool as its price is moved, bought back through its real token pool,
/// and upgraded through the real controller. Everything happens in an in-memory fork: no key, no transaction.
///
/// The other fork suites cover the kinds without lots (buy-back, spot engine, rebalance). The factory under test is
/// `V2_FACTORY`; a kind it does not have yet is registered on the fork by the script that would register it.
///
/// RELEASE_KINDS_FORK=true RELEASE_KINDS_FORK_BLOCK=<fresh block> [V2_FACTORY=0x...]
///   forge test --match-contract TestnetV2ReleaseKindsForkTest -vv
contract TestnetV2ReleaseKindsForkTest is Test {
    HedgeFunV2Factory internal factory;
    V2TreasuryDeployer internal registry;
    V2TreasuryUpgradeController internal controller;
    TestnetMarket internal market;
    IERC20 internal stock;
    IERC20 internal usdg;
    address internal oracle;
    address internal venue;
    uint8 internal percentKind;
    uint8 internal cycleKind;
    address internal creator = makeAddr("release kinds fork creator");
    address internal keeper = makeAddr("release kinds fork keeper");

    struct Launch {
        HedgeFunBondingCurve curve;
        HedgeFunV2Treasury treasury;
        IERC20 token;
    }

    function setUp() public {
        vm.skip(!vm.envOr("RELEASE_KINDS_FORK", false), "set RELEASE_KINDS_FORK=true");
        uint256 forkBlock = vm.envUint("RELEASE_KINDS_FORK_BLOCK");
        vm.createSelectFork(
            vm.envOr("RELEASE_KINDS_FORK_RPC", string("https://rpc.testnet.chain.robinhood.com")), forkBlock
        );
        assertEq(block.chainid, 46630, "Robinhood testnet only");
        emit log_named_uint("release kinds fork block", forkBlock);
        factory = HedgeFunV2Factory(vm.envOr("V2_FACTORY", address(0x6847318D28aB2f9343DDd2067871DC4f48609383)));
        registry = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        controller = registry.upgradeController();
        usdg = IERC20(factory.usdg());
        market = TestnetMarket(vm.envOr("TESTNET_MARKET", address(0xc1AF2f52980F8A7AA4E90A8E30D5c3FaF0375f21)));
        stock = IERC20(TestnetForkVenue.listedStock(factory, market));
        (oracle, venue,,) = factory.listings(address(stock));

        percentKind = _kindOf(keccak256(type(HedgeFunV2PercentBuybackTreasury).creationCode));
        if (percentKind == 0) percentKind = new RegisterV2PercentBuyback().register(factory.owner(), factory);
        cycleKind = _kindOf(keccak256(type(HedgeFunV2UpgradeableCycleTreasury).creationCode));
        if (cycleKind == 0) cycleKind = new RegisterV2UpgradeableCycle().register(factory.owner(), factory);
        emit log_named_uint("percentage buy-back kind", percentKind);
        emit log_named_uint("cycle kind", cycleKind);
        _openSession();
    }

    /// Kind 0 sells a lot above its cost, keeps the profit in stock, burns the token with it, and buys again under
    /// its last sale. Its owner can then move it to the percentage buy-back without touching what it holds.
    function test_ordinaryStrategy_takesProfit_burns_buysTheDip_thenUpgradesToThePercentageBuyback() public {
        Launch memory l = _launch(0, "LOTRULE", 1000);
        HedgeFunV2Treasury t = l.treasury;
        uint256 open = _price();
        assertGt(t.lotCount(), 0, "the graduation stock is a lot");

        _movePrice(open * 106 / 100);
        uint256 cash = t.reserveUsdg();
        assertEq(uint256(_execute(t)), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        assertGt(t.reserveUsdg(), cash, "principal sold for USDG on the stock pool");
        assertGt(t.buybackStock(), 0, "the profit stays in stock for the buy-back");
        _burnOnce(l);

        _movePrice(open);
        while (_due(t) == HedgeFunV2Treasury.Action.TakeProfit) _execute(t);
        uint256 lots = t.lotCount();
        assertEq(uint256(_execute(t)), uint256(HedgeFunV2Treasury.Action.BuyDip), "5.7% under the last sale");
        assertEq(t.lotCount(), lots + 1);

        // Leave a budget for after the upgrade, then replace the logic.
        _movePrice(open * 107 / 100);
        while (t.buybackStock() == 0) _execute(t);
        HedgeFunV2UpgradeableTreasury proxy = HedgeFunV2UpgradeableTreasury(payable(address(t)));
        HedgeFunV2PercentBuybackTreasuryLogic next = new HedgeFunV2PercentBuybackTreasuryLogic(
            address(usdg), address(stock), venue, oracle, address(l.token), address(factory.poolManager()),
            address(factory), t.params()
        );
        assertEq(next.upgradeConfigHash(), proxy.upgradeConfigHash(), "kind 0's own identity");
        bytes32 before = _ledger(l);
        _upgradeAfterDelay(address(proxy), address(next));
        assertEq(proxy.implementation(), address(next));
        assertEq(_ledger(l), before, "the upgrade moved nothing");

        _syncMarket();
        uint256 budget = t.buybackStock();
        (uint256 spent,) = _burnOnce(l);
        assertLe(spent, _tenthOrALot(t, budget), "the same treasury now offers a tenth of its budget");
    }

    /// The percentage buy-back kind from launch: each call offers a tenth of what is waiting, never under a lot.
    function test_percentageBuybackKind_burnsATenthOfTheBudgetPerCall() public {
        Launch memory l = _launch(percentKind, "TENTH", 1000);
        HedgeFunV2Treasury t = l.treasury;
        _movePrice(_price() * 106 / 100);
        assertEq(uint256(_execute(t)), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        while (_due(t) == HedgeFunV2Treasury.Action.TakeProfit) _execute(t);

        uint256 supply = l.token.totalSupply();
        for (uint256 i; i < 3; ++i) {
            uint256 budget = t.buybackStock();
            assertGt(budget, 0);
            (uint256 spent, uint256 burned) = _burnOnce(l);
            assertLe(spent, _tenthOrALot(t, budget));
            assertEq(t.buybackStock(), budget - spent);
            assertGt(burned, 0);
            vm.warp(block.timestamp + t.params().buybackCooldown);
            _syncMarket();
        }
        assertLt(l.token.totalSupply(), supply);
        assertEq(stock.balanceOf(address(t)), t.bookedStock() + t.buybackStock() + t.unbookedStock());
    }

    /// The cycle kind's extra entry: after a real sale, a rise of `dipBps` over that sale buys once more. Then the
    /// treasury is upgraded to a second build of the same logic and trades again.
    function test_cycleKind_buysBackInAfterARiseOverItsSale_thenUpgradesAndTradesAgain() public {
        Launch memory l = _launch(cycleKind, "CYCLE", 0);
        HedgeFunV2UpgradeableCycleTreasuryLogic t = HedgeFunV2UpgradeableCycleTreasuryLogic(address(l.treasury));
        uint256 open = _price();

        // The whole lot is sold at the first rung, one listing chunk per call. Every one of those sales is a live
        // sale of a lot or more, so each one re-arms the entry at its own price: the last one is the anchor.
        _movePrice(open * 106 / 100);
        assertEq(uint256(_execute(l.treasury)), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        assertGt(t.reentrySaleAt(), 0, "a live sale of a lot or more arms the recovery entry");
        while (_due(l.treasury) == HedgeFunV2Treasury.Action.TakeProfit) _execute(l.treasury);
        assertEq(t.lotCount(), 0, "in cash: without the recovery entry the next buy needs a 5% fall");
        uint256 sale = t.reentrySalePrice();

        // Under the rise the entry asks for, nothing is due.
        _movePrice(sale * 103 / 100);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        _execute(l.treasury);

        _movePrice(sale * 1055 / 1000);
        assertEq(uint256(_execute(l.treasury)), uint256(HedgeFunV2Treasury.Action.BuyRecovery));
        assertEq(t.reentrySaleAt(), 0, "the entry is consumed");
        assertEq(t.lotCount(), 1);

        HedgeFunV2UpgradeableCycleTreasury proxy = HedgeFunV2UpgradeableCycleTreasury(payable(address(t)));
        HedgeFunV2UpgradeableCycleTreasuryLogic next = new HedgeFunV2UpgradeableCycleTreasuryLogic(
            address(usdg), address(stock), venue, oracle, address(l.token), address(factory.poolManager()),
            address(factory), t.params()
        );
        assertEq(next.upgradeConfigHash(), proxy.upgradeConfigHash());
        bytes32 before = _ledger(l);
        uint256 lots = t.lotCount();
        _upgradeAfterDelay(address(proxy), address(next));
        assertEq(proxy.implementation(), address(next));
        assertEq(_ledger(l), before, "the upgrade moved nothing");
        assertEq(t.lotCount(), lots);

        // The lot the recovery bought is sold at a profit by the replacement logic.
        _syncMarket();
        _movePrice(_price() * 106 / 100);
        assertEq(uint256(_execute(l.treasury)), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        assertGt(t.reentrySaleAt(), 0, "and that sale arms the next entry");
    }

    // ------------------------------------------------------------------------------------------------ the venue
    function _launch(uint8 kind, string memory symbol, uint32 tp2Bps) private returns (Launch memory l) {
        HedgeFunFactory.Defaults memory d = factory.getDefaults();
        HedgeFunFactory.Request memory q;
        q.name = "Release kinds fork rehearsal";
        q.symbol = symbol;
        q.nonce = uint96(kind) + 1;
        q.stock = address(stock);
        q.creator = creator;
        q.taxBps = d.minTaxBps;
        q.creatorBps = d.maxCreatorBps;
        q.tp1Bps = 500;
        q.tp2Bps = tp2Bps;
        q.dipBps = 500;
        q.lotBps = 2000;
        q.maxFee = d.launchFeeAmount;
        (,, q.expectedOpenPriceE18,) = factory.listings(address(stock));
        bool nativeFee = d.launchFeeCurrency == HedgeFunFactory.FeeCurrency.Native;
        if (nativeFee) vm.deal(creator, d.launchFeeAmount);
        else deal(address(usdg), creator, d.launchFeeAmount);
        deal(address(stock), creator, 10_000e18);
        vm.startPrank(creator);
        if (kind != 0) registry.setStrategyKind(q.symbol, q.nonce, kind);
        usdg.approve(address(factory), d.launchFeeAmount);
        (address token, address treasury, bytes32 terms) = factory.predict(q);
        uint256 id = nativeFee ? factory.launch{value: d.launchFeeAmount}(q, terms) : factory.launch(q, terms);
        l.curve = HedgeFunBondingCurve(factory.curves(id));
        l.treasury = HedgeFunV2Treasury(treasury);
        l.token = IERC20(token);
        stock.approve(address(l.curve), type(uint256).max);
        l.curve.buy(type(uint256).max, 1, creator, block.timestamp);
        vm.stopPrank();
        assertEq(uint256(l.curve.status()), uint256(HedgeFunBondingCurve.Status.Graduated));
        assertGt(l.treasury.bookedStock(), 0, "a live session books the graduation stock");
    }

    function _execute(HedgeFunV2Treasury t) private returns (HedgeFunV2Treasury.Action action) {
        vm.prank(keeper);
        (action,) = t.execute();
    }

    /// @dev what `execute()` would do now, without doing it
    function _due(HedgeFunV2Treasury t) private returns (HedgeFunV2Treasury.Action action) {
        uint256 snapshot = vm.snapshotState();
        vm.prank(keeper);
        try t.execute() returns (HedgeFunV2Treasury.Action a, uint256) { action = a; }
        catch { action = HedgeFunV2Treasury.Action.Stop; }
        vm.revertToState(snapshot);
    }

    function _burnOnce(Launch memory l) private returns (uint256 spent, uint256 burned) {
        uint256 supply = l.token.totalSupply();
        vm.prank(keeper);
        (spent, burned) = l.treasury.buyback();
        assertGt(spent, 0, "a real swap on the deployed token pool");
        assertEq(l.token.totalSupply(), supply - burned);
    }

    function _tenthOrALot(HedgeFunV2Treasury t, uint256 budget) private view returns (uint256) {
        uint256 lot = t.params().minLotUsdg * 1e30 / _price() + 1;
        uint256 tenth = budget / 10;
        uint256 offer = tenth > lot ? tenth : lot;
        return offer < budget ? offer : budget;
    }

    function _ledger(Launch memory l) private view returns (bytes32) {
        HedgeFunV2Treasury t = l.treasury;
        return keccak256(
            abi.encode(
                t.bookedStock(), t.buybackStock(), t.lotCount(), t.lastSalePrice(), t.totalBurned(),
                t.totalStockReceived(), t.params(), stock.balanceOf(address(t)), usdg.balanceOf(address(t)),
                l.token.totalSupply(), t.liquidityVault()
            )
        );
    }

    function _upgradeAfterDelay(address proxy, address next) private {
        vm.prank(factory.owner());
        controller.schedule(proxy, next, "");
        vm.warp(block.timestamp + 2 days - 1);
        vm.expectRevert(V2TreasuryUpgradeController.NotReady.selector);
        controller.execute(proxy, "");
        vm.warp(block.timestamp + 1);
        controller.execute(proxy, "");
    }

    function _kindOf(bytes32 creationCodeHash) private view returns (uint8) {
        uint256 count = registry.kindCount();
        for (uint256 i = 1; i < count; ++i) {
            (,, bytes32 hash,) = registry.kindManifest(uint8(i));
            if (hash == creationCodeHash) return uint8(i);
        }
        return 0;
    }

    /// @dev the oracle's price, 1e18 USDG per whole stock token, which is what the test market takes
    function _price() private view returns (uint256 p) {
        (bool live, uint256 price) = PriceOracle(oracle).tryPrice();
        assertTrue(live, "the test market has a live oracle within the US session");
        return price;
    }

    /// @dev Move the pool and the feed together, let the pool's 600-second mean catch up with the new spot, and
    ///      print a fresh report at the same price.
    function _movePrice(uint256 priceE18) private {
        vm.prank(market.owner());
        market.setPrice(venue, priceE18);
        vm.warp(block.timestamp + 660);
        _syncMarket();
    }

    function _syncMarket() private {
        vm.prank(market.owner());
        market.syncFeed(venue);
    }

    /// @dev a Tuesday, 15:00 UTC: the US session is open and stays open through a two-day upgrade notice
    function _openSession() private {
        uint256 day = block.timestamp / 1 days + 1;
        while ((day + 4) % 7 != 2) ++day;
        vm.warp(day * 1 days + 15 hours);
        _syncMarket();
    }
}
