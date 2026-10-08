// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunHook} from "../src/hooks/HedgeFunHook.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunV2TradeRouter as Router} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {HedgeFunV2IncomeTreasury} from "../src/v2/HedgeFunV2IncomeTreasury.sol";
import {HedgeFunV2StrategyIncomeTreasury} from "../src/v2/HedgeFunV2StrategyIncomeTreasury.sol";
import {V2StakingIncome} from "../src/v2/V2StakingIncome.sol";
import {TestnetMarket} from "../script/testnet/TestnetMarket.sol";
import {TestnetForkVenue} from "./utils/TestnetForkVenue.sol";
import {V2LiquidityVault} from "../src/v2/V2LiquidityVault.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {RegisterV2IncomeKinds} from "../script/RegisterV2IncomeKinds.s.sol";
import {TestnetMarket} from "../script/testnet/TestnetMarket.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";

/// Opt-in, in-memory fork only: no key, no broadcast. The registration script runs as the DEPLOYED testnet factory's
/// owner against the deployed registry, then a creator launches with each income kind through the deployed factory,
/// hook and vault code. This is the compatibility check a local fixture cannot give.
///
///   INCOME_KINDS_FORK=true INCOME_KINDS_FORK_BLOCK=<fresh block> forge test --mc TestnetV2IncomeKindsForkTest -vv
///
/// The public RPC prunes old state: use a fresh block.
contract TestnetV2IncomeKindsForkTest is Test {
    using PoolIdLibrary for PoolKey;

    HedgeFunV2Factory factory;
    V2TreasuryDeployer registry;
    Router router;
    IERC20 stock;
    IERC20 usdg;
    RegisterV2IncomeKinds.Kinds kinds;
    uint8 dividendKind;
    uint8 splitKind;
    address creator = makeAddr("income kinds fork creator");
    address staker = makeAddr("income kinds fork staker");

    function setUp() public {
        vm.skip(!vm.envOr("INCOME_KINDS_FORK", false), "set INCOME_KINDS_FORK=true");
        uint256 forkBlock = vm.envUint("INCOME_KINDS_FORK_BLOCK");
        emit log_named_uint("income kinds fork block", forkBlock);
        vm.createSelectFork(
            vm.envOr("INCOME_KINDS_FORK_RPC", string("https://rpc.testnet.chain.robinhood.com")),
            forkBlock
        );
        assertEq(block.chainid, 46630, "Robinhood testnet only");
        factory = HedgeFunV2Factory(vm.envOr("V2_FACTORY", address(0x6847318D28aB2f9343DDd2067871DC4f48609383)));
        assertGt(address(factory).code.length, 0, "the selected factory exists at the recorded block");
        registry = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        usdg = IERC20(factory.usdg());
        // a stock this factory lists; a core nobody has launched on yet has no `strategies(0)` to read
        TestnetMarket market = TestnetMarket(vm.envOr("TESTNET_MARKET", address(0xc1AF2f52980F8A7AA4E90A8E30D5c3FaF0375f21)));
        address listed = TestnetForkVenue.listedStock(factory, market);
        stock = IERC20(listed);
        assertGt(listed.code.length, 0, "the factory has a deployed stock listing");
        uint256 before = registry.kindCount();
        kinds = new RegisterV2IncomeKinds().register(factory.owner(), factory);
        (dividendKind, splitKind) = (kinds.dividend, kinds.split);
        assertEq(registry.kindCount(), before + 4, "appended, nothing replaced");
        router = new Router(factory);
    }

    function test_dividendKindOnDeployedFactory() public { _lifecycle(dividendKind, 10000); }
    function test_splitKindOnDeployedFactory() public { _lifecycle(splitKind, 5000); }
    function test_strategy25KindOnDeployedFactory() public { _strategyLifecycle(kinds.strategy25, 2500); }
    function test_strategy50KindOnDeployedFactory() public { _strategyLifecycle(kinds.strategy50, 5000); }

    // The same graduation assertions are run through the deployed factory for every opt-in kind. The failure
    // cases inject the factory's documented optional-book failure; they are not a claim of a live exploit.
    function test_dividendKindPreclaimedFeesRemainIncome() public { _graduationIncome(dividendKind, 10000, false); }
    function test_splitKindPreclaimedFeesRemainIncome() public { _graduationIncome(splitKind, 5000, false); }
    function test_strategy25PreclaimedFeesRemainIncome() public { _graduationIncome(kinds.strategy25, 2500, false); }
    function test_strategy50PreclaimedFeesRemainIncome() public { _graduationIncome(kinds.strategy50, 5000, false); }
    function test_dividendKindOptionalBookFailureProtectsPrincipal() public { _graduationIncome(dividendKind, 10000, true); }
    function test_splitKindOptionalBookFailureProtectsPrincipal() public { _graduationIncome(splitKind, 5000, true); }
    function test_strategy25OptionalBookFailureProtectsPrincipal() public { _graduationIncome(kinds.strategy25, 2500, true); }
    function test_strategy50OptionalBookFailureProtectsPrincipal() public { _graduationIncome(kinds.strategy50, 5000, true); }

    function _graduationIncome(uint8 kind, uint256 bps, bool failBook) private {
        _launch(kind);
        vm.startPrank(creator);
        stock.approve(address(curve), type(uint256).max);
        curve.buy(1e18, 1, creator, block.timestamp);
        vm.stopPrank();
        assertEq(uint256(curve.status()), uint256(HedgeFunBondingCurve.Status.Active));
        uint256 fees = curve.claimable(address(treasury));
        assertGt(fees, 0, "a partial curve buy earned a treasury fee");
        curve.claimFees(address(treasury));
        assertEq(stock.balanceOf(address(treasury)), fees);
        assertFalse(treasury.book(), "income waits for graduation");
        if (failBook) {
            vm.mockCallRevert(address(treasury), abi.encodeWithSelector(treasury.book.selector), bytes("book failed"));
        }
        vm.prank(creator);
        curve.buy(type(uint256).max, 1, creator, block.timestamp);
        vm.clearMockedCalls();
        assertEq(uint256(curve.status()), uint256(HedgeFunBondingCurve.Status.Graduated));
        bool strategy = kind == kinds.strategy25 || kind == kinds.strategy50;
        uint256 principal = strategy
            ? HedgeFunV2StrategyIncomeTreasury(address(treasury)).principalStock()
            : treasury.protectedGraduationStock();
        assertGt(principal, 0, "principal initialized independently of book");
        assertEq(stock.balanceOf(address(treasury)) + staking.totalFunded(), principal + fees,
            "preclaimed fees cannot inflate graduation principal");
        if (failBook) {
            assertEq(staking.totalFunded(), 0);
            assertEq(treasury.buybackStock(), 0);
        }
        vm.prank(staker); // the retry is permissionless, not the factory
        treasury.book();
        assertEq(staking.totalFunded(), fees * bps / 10000, "only the fee funds the dividend");
        assertEq(treasury.buybackStock(), fees - staking.totalFunded());
        assertEq(stock.balanceOf(address(treasury)), principal + treasury.buybackStock());
        uint256 funded = staking.totalFunded();
        treasury.book();
        assertEq(staking.totalFunded(), funded, "retry cannot pay twice");
    }

    /// The strategy's rungs on the deployed venue. The clock is moved to a Tuesday session so the stock oracle is
    /// live; the deployed test market's owner moves the stock's V3 pool and feed together, as it does on testnet.
    function test_strategy25TakesProfitAndBuysTheDipOnDeployedVenue() public { _profitAndDip(kinds.strategy25); }
    function test_strategy50TakesProfitAndBuysTheDipOnDeployedVenue() public { _profitAndDip(kinds.strategy50); }

    function _profitAndDip(uint8 kind) private {
        TestnetMarket market = TestnetMarket(vm.envOr("TESTNET_MARKET", address(0xc1AF2f52980F8A7AA4E90A8E30D5c3FaF0375f21)));
        (address oracle_, address pool,,) = factory.listings(address(stock));
        vm.warp(_nextTuesdaySession());
        (bool live, uint256 p0) = PriceOracle(oracle_).tryPrice();
        assertTrue(live, "the stock oracle is live in the session");

        _launch(kind);
        HedgeFunV2StrategyIncomeTreasury s = HedgeFunV2StrategyIncomeTreasury(address(treasury));
        vm.startPrank(creator);
        stock.approve(address(curve), type(uint256).max);
        curve.buy(type(uint256).max, 1, creator, block.timestamp);
        vm.stopPrank();
        assertEq(s.lotCount(), 1, "the principal's lot opened at graduation");
        (uint256 qty, uint256 cost,,) = s.lots(0);
        assertEq(qty, s.principalStock());
        assertEq(cost, p0);

        _move(market, pool, p0 * 106 / 100);
        (bool healthy,) = s.health();
        assertTrue(healthy);
        uint256 usdgBefore = s.reserveUsdg();
        vm.prank(staker); // any keeper
        (HedgeFunV2Treasury.Action a,) = s.execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        uint256 toStakers = staking.totalFunded();
        assertGt(toStakers, 0, "profit reached the staking pool");
        assertEq(toStakers, (toStakers + s.buybackStock()) * s.stakingBps() / 10000);
        assertGt(s.reserveUsdg(), usdgBefore, "the sold principal is USDG for the next dip");
        assertGt(stock.balanceOf(staker), 0, "the keeper was paid its bounty in stock");
        assertEq(stock.balanceOf(address(s)), s.bookedStock() + s.buybackStock());

        // tax arrives, then the stock falls more than 5% below the sale
        vm.prank(creator);
        stock.transfer(address(s), 1e18);
        _move(market, pool, p0);
        uint256 lots = s.lotCount();
        vm.expectRevert();
        s.execute();
        assertEq(s.lotCount(), lots, "no dip while arrived stock is unclassified");
        assertTrue(s.book());
        assertEq(staking.totalFunded(), toStakers + uint256(1e18) * s.stakingBps() / 10000);
        (a,) = s.execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.BuyDip));
        assertEq(s.lotCount(), lots + 1);
        assertEq(stock.balanceOf(address(s)), s.bookedStock() + s.buybackStock());
    }

    /// A stop is a loss: it must still execute, and it pays no dividend.
    function test_strategy25StopLossOnDeployedVenue() public { _stopLoss(kinds.strategy25); }
    function test_strategy50StopLossOnDeployedVenue() public { _stopLoss(kinds.strategy50); }

    function _stopLoss(uint8 kind) private {
        TestnetMarket market = TestnetMarket(vm.envOr("TESTNET_MARKET", address(0xc1AF2f52980F8A7AA4E90A8E30D5c3FaF0375f21)));
        (address oracle_, address pool,,) = factory.listings(address(stock));
        vm.warp(_nextTuesdaySession());
        (bool live, uint256 p0) = PriceOracle(oracle_).tryPrice();
        assertTrue(live);
        stopBps = 500;
        _launch(kind);
        HedgeFunV2StrategyIncomeTreasury s = HedgeFunV2StrategyIncomeTreasury(address(treasury));
        vm.startPrank(creator);
        stock.approve(address(curve), type(uint256).max);
        curve.buy(type(uint256).max, 1, creator, block.timestamp);
        vm.stopPrank();
        assertEq(s.lotCount(), 1);
        uint256 booked = s.bookedStock();
        _move(market, pool, p0 * 94 / 100);
        vm.prank(staker);
        (HedgeFunV2Treasury.Action a,) = s.execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.Stop));
        assertLt(s.bookedStock(), booked, "stock was sold at the stop");
        assertGt(s.reserveUsdg(), 0);
        assertEq(staking.totalFunded(), 0, "a loss pays no dividend");
        assertEq(s.buybackStock(), 0);
        assertEq(stock.balanceOf(address(s)), s.bookedStock());
    }

    function _move(TestnetMarket market, address pool, uint256 price) private {
        address marketOwner = market.owner();
        vm.prank(marketOwner);
        market.setPrice(pool, price);
        vm.warp(block.timestamp + 11 minutes); // past the treasury's 10-minute pool mean
        vm.prank(marketOwner);
        market.poke(pool);
    }

    /// 15:00 UTC on the first Tuesday after the fork block: inside the US session in either daylight regime.
    function _nextTuesdaySession() private view returns (uint256) {
        uint256 day = block.timestamp / 1 days + 1;
        while ((day + 4) % 7 != 2) ++day; // day 0 was a Thursday
        return day * 1 days + 15 hours;
    }

    /// The deployed registry, factory, hook and vault accept a strategy kind: it launches, graduates, records its
    /// principal, splits the tax share and sends LP fees to the buy-back. Whether the principal's lot opens at
    /// graduation depends on the testnet stock market being open at the fork block, so both outcomes are checked.
    function _strategyLifecycle(uint8 kind, uint256 bps) private {
        _launch(kind);
        HedgeFunV2StrategyIncomeTreasury s = HedgeFunV2StrategyIncomeTreasury(address(treasury));
        assertEq(s.stakingBps(), bps);
        vm.startPrank(creator);
        stock.approve(address(curve), type(uint256).max);
        curve.buy(type(uint256).max, 1, creator, block.timestamp);
        stock.approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        uint8 stage = router.GRADUATED();
        router.buy(Router.TradeParams(id, address(stock), 1e18, 1e18, 1, block.timestamp, stage, false), new Router.Hop[](0));
        router.sell(Router.TradeParams(id, address(stock), 5_000_000e18, 0, 1, block.timestamp, stage, false),
            new Router.Hop[](0));
        vm.stopPrank();
        _stake();
        uint256 principal = s.principalStock();
        assertGt(principal, 0);
        assertEq(s.buybackStock(), 0);
        bool lotOpen = s.lotCount() == 1;
        assertEq(s.bookedStock(), lotOpen ? principal : 0);

        (PoolKey memory key,) = factory.graduationConfig(id);
        curve.claimFees(address(s));
        HedgeFunHook(address(factory.hook())).sweep(key.toId());
        uint256 tax = stock.balanceOf(address(s)) - principal;
        assertGt(tax, 0);
        s.book();
        assertEq(staking.totalFunded(), tax * bps / 10000);
        assertEq(s.buybackStock(), tax - staking.totalFunded());
        assertLe(s.lotCount(), 1, "tax never opens a lot");
        uint256 budget = s.buybackStock();
        (uint256 lpStock,) = V2LiquidityVault(s.liquidityVault()).collectFees();
        assertGt(lpStock, 0);
        assertEq(s.buybackStock(), budget + lpStock, "LP fees all fund the buy-back");
        assertEq(stock.balanceOf(address(s)), principal + s.buybackStock(), "principal untouched");
        _exerciseBuyback(principal);
        _claimAndWithdraw();
    }

    uint16 stopBps; // 0 unless a test sets it before _launch
    uint256 id;
    HedgeFunBondingCurve curve;
    HedgeFunV2IncomeTreasury treasury;
    V2StakingIncome staking;
    IERC20 token;

    function _lifecycle(uint8 kind, uint256 bps) private {
        _launch(kind);
        assertEq(treasury.stakingBps(), bps);
        assertEq(staking.incomeSource(), address(treasury));
        uint256 principal = _graduateAndTrade();
        _settle(bps, principal);
    }

    function _launch(uint8 kind) private {
        HedgeFunFactory.Defaults memory d = factory.getDefaults();
        HedgeFunFactory.Request memory q;
        q.name = "Income kind fork rehearsal";
        q.symbol = "INCOME";
        q.nonce = kind;
        q.stock = address(stock);
        q.creator = creator;
        q.taxBps = d.minTaxBps;
        q.creatorBps = 1000;
        q.tp1Bps = 500; q.tp2Bps = 1000; q.dipBps = 500; q.lotBps = 2000; q.stopBps = stopBps;
        q.maxFee = d.launchFeeAmount;
        (,, q.expectedOpenPriceE18,) = factory.listings(address(stock));
        bool native = d.launchFeeCurrency == HedgeFunFactory.FeeCurrency.Native;
        if (native) vm.deal(creator, d.launchFeeAmount); else deal(address(usdg), creator, d.launchFeeAmount);
        deal(address(stock), creator, 10_000e18);
        vm.startPrank(creator);
        registry.setStrategyKind(q.symbol, q.nonce, kind);
        usdg.approve(address(factory), d.launchFeeAmount);
        (,, bytes32 terms) = factory.predict(q);
        id = native ? factory.launch{value: d.launchFeeAmount}(q, terms) : factory.launch(q, terms);
        vm.stopPrank();
        curve = HedgeFunBondingCurve(factory.curves(id));
        (address token_, address treasury_,,,) = factory.strategies(id);
        treasury = HedgeFunV2IncomeTreasury(treasury_);
        staking = treasury.staking();
        token = IERC20(token_);
    }

    function _graduateAndTrade() private returns (uint256 principal) {
        // the creator is exempt from the opening surcharge: one buy graduates the curve
        vm.startPrank(creator);
        stock.approve(address(curve), type(uint256).max);
        curve.buy(type(uint256).max, 1, creator, block.timestamp);
        assertEq(uint256(curve.status()), uint256(HedgeFunBondingCurve.Status.Graduated));
        principal = treasury.protectedGraduationStock();
        assertGt(principal, 0);
        assertEq(stock.balanceOf(address(treasury)), principal);
        assertEq(treasury.buybackStock(), 0);
        assertEq(treasury.totalIncomeStock(), 0);

        // stake, then trade both ways in the graduated pool
        stock.approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        uint8 stage = router.GRADUATED();
        router.buy(Router.TradeParams(id, address(stock), 1e18, 1e18, 1, block.timestamp, stage, false), new Router.Hop[](0));
        router.sell(Router.TradeParams(id, address(stock), 5_000_000e18, 0, 1, block.timestamp, stage, false),
            new Router.Hop[](0));
        vm.stopPrank();
        _stake();
    }

    /// tax share (curve claim + hook sweep) and LP fees all become income, split at `bps`
    function _settle(uint256 bps, uint256 principal) private {
        (PoolKey memory key,) = factory.graduationConfig(id);
        curve.claimFees(address(treasury));
        HedgeFunHook(address(factory.hook())).sweep(key.toId());
        assertTrue(treasury.book());
        (uint256 lpStock,) = V2LiquidityVault(treasury.liquidityVault()).collectFees();
        assertGt(lpStock, 0, "the deployed vault accepted this kind's fee credit");
        treasury.distribute();
        uint256 income = treasury.totalIncomeStock();
        assertGt(income, lpStock, "tax share plus LP fees");
        assertEq(treasury.totalDividendStock(), income * bps / 10000);
        assertEq(treasury.pendingDividendStock(), 0);
        assertEq(stock.balanceOf(address(staking)), treasury.totalDividendStock());
        assertEq(treasury.buybackStock(), income - treasury.totalDividendStock());
        assertEq(stock.balanceOf(address(treasury)), principal + treasury.buybackStock(), "principal untouched");

        if (bps < 10000) _exerciseBuyback(principal);
        _claimAndWithdraw();
    }

    function _stake() private {
        vm.prank(creator);
        token.transfer(staker, 1_000_000e18);
        vm.startPrank(staker);
        token.approve(address(staking), type(uint256).max);
        staking.stake(1_000_000e18);
        vm.expectRevert(V2StakingIncome.StakeLocked.selector);
        staking.withdraw(1_000_000e18, staker);
        vm.stopPrank();
    }

    function _exerciseBuyback(uint256 principal) private {
        // Refresh the test venue in an open session; all price changes stay inside this memory-only fork.
        vm.warp(_nextTuesdaySession());
        (, address pool,,) = factory.listings(address(stock));
        TestnetMarket market = TestnetMarket(vm.envOr("TESTNET_MARKET", address(0xc1AF2f52980F8A7AA4E90A8E30D5c3FaF0375f21)));
        vm.prank(market.owner());
        market.syncFeed(pool);
        uint256 budget = treasury.buybackStock();
        uint256 funded = staking.totalFunded();
        uint256 supply = token.totalSupply();
        (uint256 spent, uint256 burned) = treasury.buyback();
        assertGt(spent, 0, "funded buyback actually trades");
        assertGt(burned, 0, "buyback actually burns bought tokens");
        assertEq(token.totalSupply(), supply - burned);
        assertEq(treasury.buybackStock(), budget - spent);
        assertEq(staking.totalFunded(), funded, "buyback cannot consume or relabel dividend funds");
        assertEq(stock.balanceOf(address(treasury)), principal + treasury.buybackStock());
    }

    function _claimAndWithdraw() private {
        vm.warp(block.timestamp + 7 days);
        vm.startPrank(staker);
        uint256 paid = staking.claim(staker);
        staking.withdraw(1_000_000e18, staker);
        vm.stopPrank();
        assertApproxEqAbs(paid, staking.totalFunded(), 1e6, "the only staker earns the whole stream");
        assertEq(stock.balanceOf(staker), paid);
        assertEq(token.balanceOf(staker), 1_000_000e18, "all stake principal is withdrawable");
        assertEq(staking.totalStaked(), 0);
    }
}
