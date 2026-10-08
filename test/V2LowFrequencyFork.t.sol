// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {HedgeFunFactory, TokenDeployer} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {CurveDeployer} from "../src/v2/CurveDeployer.sol";
import {AlwaysOpen, IAgg} from "./mocks/Mocks.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @dev Moves a real forked V3 pool by an actual swap, with a bounded input and target sqrt price.
/// Funding is supplied only by the fork test. This is a market-path actor, not a production keeper.
contract V3ScenarioMover {
    IUniswapV3Pool public immutable pool;
    address public immutable token0;
    address public immutable token1;

    constructor(IUniswapV3Pool pool_) {
        pool = pool_;
        token0 = pool_.token0();
        token1 = pool_.token1();
    }

    function moveTo(uint160 target, uint256 maxInput) external returns (uint256 spent, uint256 received) {
        (uint160 current,,,,,,) = pool.slot0();
        require(target != current && maxInput != 0 && maxInput <= uint256(type(int256).max), "bad target");
        bool zeroForOne = target < current;
        (int256 d0, int256 d1) = pool.swap(address(this), zeroForOne, int256(maxInput), target, "");
        (uint160 actual,,,,,,) = pool.slot0();
        require(actual == target, "target not reached");
        (int256 input, int256 output) = zeroForOne ? (d0, d1) : (d1, d0);
        require(input > 0 && output < 0, "bad swap");
        return (uint256(input), uint256(-output));
    }

    function tradeExactInput(address inputToken, uint256 amount) external returns (uint256 received) {
        require((inputToken == token0 || inputToken == token1) && amount != 0
            && amount <= uint256(type(int256).max), "bad exact input");
        bool zeroForOne = inputToken == token0;
        (int256 d0, int256 d1) = pool.swap(address(this), zeroForOne, int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1, "");
        (int256 spent, int256 out) = zeroForOne ? (d0, d1) : (d1, d0);
        require(spent == int256(amount) && out < 0, "short exact input");
        return uint256(-out);
    }

    function uniswapV3SwapCallback(int256 d0, int256 d1, bytes calldata) external {
        require(msg.sender == address(pool), "not pool");
        if (d0 > 0) require(IERC20(token0).transfer(msg.sender, uint256(d0)), "token0 transfer");
        if (d1 > 0) require(IERC20(token1).transfer(msg.sender, uint256(d1)), "token1 transfer");
    }
}

/// @notice Synthetic market paths on one pinned Robinhood Chain state. The USDG/GME V3 pool and V4 manager
/// are real forked contracts; the new V2 contracts, market actor, feed reports and time steps exist only here.
/// The 1.5% paths explicitly select the legacy V2 treasury, preserving existing immutable strategy behavior.
/// The new all-in trigger wrapper is covered separately by V2AllInTriggerFloor and its testnet append replay.
/// No historical stock path or strategy return is claimed. No transaction is broadcast.
/// Run: RH_FORK=1 RH_RPC=https://rpc-robinhood.blockmachine.io forge test --threads 1 --mc V2LowFrequencyForkTest -vv
contract V2LowFrequencyForkTest is Test, HookMiner {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager private constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IUniswapV3Pool private constant MARKET = IUniswapV3Pool(0xE2b46c905E12Ab8E2f864e4821a4325884C1B126);
    address private constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address private constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address private constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address private constant GME = 0x1b0E319c6A659F002271B69dB8A7df2F911c153E;
    address private constant GME_FEED = 0x27C71df6A64fB476468EdF256CF72c038baB5B67;
    address private constant FUNDING_POOL = 0xE9713f453aDB9245B19559790c96F470a18F2fDF;
    address private constant OWNER = address(0xA11CE);
    address private constant PROTOCOL = address(0x5AFE);
    address private constant CREATOR = address(0xC4EA704);
    address private constant BUYER = address(0xB0B);
    address private constant KEEPER = address(0xB07);
    address private constant PUBLIC_CALLER = address(0xCA11);
    uint256 private constant PINNED_BLOCK = 70_786_980;
    uint256 private constant SCALE = 1e30; // 1e18 * 10^GME decimals / 10^USDG decimals
    uint256 private constant Q192 = 1 << 192;

    PriceOracle private oracle;
    HedgeFunV2Treasury private treasury;
    V3ScenarioMover private mover;
    uint256 private startPrice;
    uint256 private usdFeedAnswer;
    uint80 private gmeRound;
    uint80 private usdRound;

    struct RuleBefore {
        uint256 qty;
        uint256 cost;
        uint256 booked;
        uint256 cash;
        uint256 budget;
        uint256 burned;
        uint256 keeperStock;
        uint256 keeperCash;
        uint256 treasuryStock;
        uint256 marketStock;
        uint256 marketCash;
    }

    struct ForkRuleConfig {
        uint16 stopBps;
        uint16 dipBps;
        uint16 lotBps;
        uint16 bountyBps;
        uint16 maxSlippageBps;
        uint16 maxDeviationBps;
        uint256 sellChunkUsdg;
    }

    struct SandwichMeasure {
        uint256 p;
        uint160 originalSqrt;
        uint256 botUsdBefore;
        uint256 botStockBefore;
        uint256 botFrontStock;
        uint256 cleanSpent;
        uint256 cleanGot;
        uint256 cleanKeeperBounty;
        uint256 cleanTreasuryMark;
        uint256 attackedGot;
        uint256 attackedSpent;
        uint256 attackedKeeperBounty;
        uint256 botUsdAfter;
        uint256 botStockAfter;
        uint256 frontGas;
        uint256 backGas;
    }

    function _capture() private view returns (RuleBefore memory b) {
        if (treasury.lotCount() != 0) (b.qty, b.cost,,) = treasury.lots(0);
        b.booked = treasury.bookedStock();
        b.cash = treasury.reserveUsdg();
        b.budget = treasury.buybackStock();
        b.burned = treasury.totalBurned();
        b.keeperStock = IERC20(GME).balanceOf(KEEPER);
        b.keeperCash = IERC20(USDG).balanceOf(KEEPER);
        b.treasuryStock = IERC20(GME).balanceOf(address(treasury));
        b.marketStock = IERC20(GME).balanceOf(address(MARKET));
        b.marketCash = IERC20(USDG).balanceOf(address(MARKET));
    }

    function _feed(address feed, uint80 round, int256 answer, uint256 updatedAt) private {
        vm.mockCall(feed, abi.encodeWithSelector(IAgg.latestRoundData.selector),
            abi.encode(round, answer, updatedAt, updatedAt, round));
    }

    function _setPriceReport(uint256 price, uint256 updatedAt) private {
        uint256 stockAnswer = Math.mulDiv(price, usdFeedAnswer, 1e18);
        assertGt(stockAnswer, 0);
        _feed(GME_FEED, gmeRound, int256(stockAnswer), updatedAt);
    }

    function _defaults(ForkRuleConfig memory c) private pure returns (HedgeFunFactory.Defaults memory d) {
        d.supply = 1_000_000e18;
        d.lpFee = 3000;
        d.tickSpacing = 60;
        d.minTaxBps = 100;
        d.maxTaxBps = 1500;
        d.protocolBps = 2000;
        d.maxCreatorBps = 3000;
        d.spikeBps = 9000;
        d.spikeSeconds = 120;
        d.snipeBps = 9900;
        d.snipeSeconds = 3;
        d.sweepTipBps = 0;
        d.bountyBps = c.bountyBps;
        d.maxSlippageBps = c.maxSlippageBps;
        d.maxDeviationBps = c.maxDeviationBps;
        d.maxBuybackImpactBps = 300;
        d.buybackCooldown = 60;
        d.minLotUsdg = 5e6;
        d.buybackChunkUsdg = 500e6;
        d.sellChunkUsdg = c.sellChunkUsdg;
    }

    function _defaultRule(uint16 lotBps) private pure returns (ForkRuleConfig memory c) {
        c = ForkRuleConfig({stopBps: 150, dipBps: 150, lotBps: lotBps,
            bountyBps: 50, maxSlippageBps: 50, maxDeviationBps: 20,
            sellChunkUsdg: type(uint128).max});
    }

    function _setupGraduated() private { _setupGraduatedConfig(_defaultRule(2000)); }

    function _setupGraduated(uint16 dipLotBps) private { _setupGraduatedConfig(_defaultRule(dipLotBps)); }

    function _newFactory(ForkRuleConfig memory c) private returns (HedgeFunV2Factory factory) {
        V2TreasuryDeployer deployer = new V2TreasuryDeployer();
        factory = new HedgeFunV2Factory(OWNER, address(PM), V3_FACTORY, USDG, PROTOCOL,
            address(deployer), address(new TokenDeployer()), address(_deployV2Hook(PM)),
            address(new CurveDeployer(8000)), _defaults(c));
        // A fresh registry now defaults to the stricter wrapper. These historical
        // price paths remain compatibility tests of the original immutable core.
        bytes memory legacyCode = type(HedgeFunV2Treasury).creationCode;
        (address a, address b) = deployer.makeChunks(legacyCode);
        vm.prank(OWNER);
        assertEq(deployer.registerKind(a, b), 1, "explicit legacy treasury kind");
        (uint32 version, uint32 schema, bytes32 creationHash, uint256 capabilities) = deployer.kindManifest(1);
        assertEq(creationHash, keccak256(legacyCode), "legacy creation code is pinned");
        assertEq(keccak256(bytes.concat(a.code, b.code)), creationHash, "legacy chunks match the selected core");
        assertEq(version, 0);
        assertEq(schema, 0);
        assertEq(capabilities, 0);
        assertTrue(creationHash != deployer.allInTriggerCodeHash(), "legacy tests must not select the new wrapper");
    }

    function _setupGraduatedConfig(ForkRuleConfig memory c) private {
        vm.skip(vm.envOr("RH_FORK", uint256(0)) == 0, "set RH_FORK=1; this is a live-venue fork test");
        string memory rpc = vm.envOr("RH_RPC", string("robinhood"));
        uint256 forkBlock = vm.envOr("RH_FORK_BLOCK", PINNED_BLOCK);
        if (forkBlock == 0) vm.createSelectFork(rpc); else vm.createSelectFork(rpc, forkBlock);
        assertGt(address(PM).code.length, 0);
        assertGt(address(MARKET).code.length, 0);
        int256 gmeAnswer;
        int256 usdAnswer;
        (gmeRound, gmeAnswer,,,) = IAgg(GME_FEED).latestRoundData();
        (usdRound, usdAnswer,,,) = IAgg(USDG_FEED).latestRoundData();
        assertGt(gmeAnswer, 0);
        assertGt(usdAnswer, 0);
        usdFeedAnswer = uint256(usdAnswer);
        _feed(GME_FEED, gmeRound, gmeAnswer, block.timestamp);
        _feed(USDG_FEED, usdRound, usdAnswer, block.timestamp);
        oracle = new PriceOracle(GME, GME_FEED, USDG_FEED, address(new AlwaysOpen()), 26 hours, 26 hours);
        startPrice = oracle.price();

        uint256 initialPrice = Math.mulDiv(25e18, 1e18, startPrice) / 1_000_000;
        HedgeFunV2Factory factory = _newFactory(c);
        vm.startPrank(OWNER);
        factory.list(GME, address(oracle), address(MARKET), initialPrice, true);
        factory.setPublicLaunch(true);
        vm.stopPrank();
        HedgeFunFactory.Request memory request;
        request.name = "V2 low-frequency fork only";
        request.symbol = "V2LFF";
        request.stock = GME;
        request.creator = CREATOR;
        request.taxBps = 1000;
        request.creatorBps = 1000;
        request.tp1Bps = 150;
        request.tp2Bps = 300;
        request.dipBps = c.dipBps;
        request.stopBps = c.stopBps;
        request.lotBps = c.lotBps;
        request.expectedOpenPriceE18 = initialPrice;
        // The creator chooses the raise: the scenarios' lot sizes were measured on an 80% sale (Rg ~ 100 USDG).
        CurveDeployer curveDeployer = factory.curveDeployer();
        V2TreasuryDeployer treasuryDeployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        vm.prank(CREATOR);
        treasuryDeployer.setStrategyKind(request.symbol, request.nonce, 1);
        assertEq(treasuryDeployer.strategyKindOf(keccak256(abi.encode(request.symbol, CREATOR, request.nonce))), 1,
            "select the legacy core before predicting terms");
        vm.prank(CREATOR);
        curveDeployer.setCurveConfig(request.symbol, request.nonce, 8000, 3);
        (,, bytes32 terms) = factory.predict(request);
        vm.prank(CREATOR);
        uint256 id = factory.launch(request, terms);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        vm.prank(FUNDING_POOL);
        assertTrue(IERC20(GME).transfer(BUYER, 20e18));
        vm.prank(BUYER);
        IERC20(GME).approve(address(curve), type(uint256).max);
        vm.warp(block.timestamp + 4); // test the ordinary flat tax, after the opening window
        (uint256 stockNeeded, uint256 expectedOut,) = curve.quoteBuy(type(uint256).max);
        vm.prank(BUYER);
        (uint256 stockSpent, uint256 tokensOut) = curve.buy(stockNeeded, expectedOut, BUYER, block.timestamp);
        assertEq(stockSpent, stockNeeded);
        assertEq(tokensOut, expectedOut);
        assertEq(uint256(curve.status()), uint256(HedgeFunBondingCurve.Status.Graduated));
        (PoolKey memory key,) = factory.graduationConfig(id);
        assertGt(PM.getLiquidity(key.toId()), 0, "real V4 manager holds the graduated LP");
        treasury = HedgeFunV2Treasury(curve.treasury());
        assertGt(treasury.bookedStock(), 0, "graduation seeds a real strategy lot");
        (bool healthy,) = treasury.health();
        assertTrue(healthy, "initial real V3 spot, mean and feed must agree");

        mover = new V3ScenarioMover(MARKET);
        vm.startPrank(FUNDING_POOL);
        assertTrue(IERC20(USDG).transfer(address(mover), 100_000e6));
        assertTrue(IERC20(GME).transfer(address(mover), 5_000e18));
        vm.stopPrank();
        console2.log("Scenario fork block:", block.number);
        console2.log("Initial GME/USDG oracle price E18:", startPrice);
    }

    function _sqrtForPrice(uint256 price) private view returns (uint160) {
        uint256 rawX192 = MARKET.token0() == GME
            ? Math.mulDiv(price, Q192, SCALE) : Math.mulDiv(SCALE, Q192, price);
        return uint160(Math.sqrt(rawX192));
    }

    function _moveMarket(uint256 targetPrice) private returns (uint256 spent, uint256 received) {
        uint160 target = _sqrtForPrice(targetPrice);
        (uint160 beforePrice,,,,,,) = MARKET.slot0();
        bool zeroForOne = target < beforePrice;
        address inputToken = zeroForOne ? MARKET.token0() : MARKET.token1();
        uint256 maxInput = IERC20(inputToken).balanceOf(address(mover));
        (spent, received) = mover.moveTo(target, maxInput);
        (uint160 actual,,,,,,) = MARKET.slot0();
        assertEq(actual, target);
    }

    function _assertHealth(bool expected) private view {
        (bool healthy,) = treasury.health();
        assertEq(healthy, expected);
    }

    function _assertTwapLagBlocksFreshFeed() private view {
        (bool feedOk, uint256 reported) = oracle.tryPrice();
        assertTrue(feedOk, "the stock feed must be fresh");
        uint256 spot = treasury.spotPrice();
        uint256 mean = treasury.twapPrice();
        assertGt(mean, 0, "the real V3 pool must supply its mean");
        uint256 limit = Math.mulDiv(reported, 20, 10_000);
        assertLe(spot > reported ? spot - reported : reported - spot, limit,
            "the current V3 spot must agree with the feed");
        assertGt(spot > mean ? spot - mean : mean - spot, limit,
            "only the V3 mean must remain outside the 20 bps gate");
        _assertHealth(false);
    }

    function _assertDipBuy(address caller) private returns (uint256 spent, uint256 got) {
        (bool healthy, uint256 p) = treasury.health();
        assertTrue(healthy);
        RuleBefore memory before = _capture();
        uint256 lotsBefore = treasury.lotCount();
        uint256 callerCashBefore = IERC20(USDG).balanceOf(caller);
        vm.prank(caller);
        treasury.execute();
        spent = IERC20(USDG).balanceOf(address(MARKET)) - before.marketCash;
        got = before.marketStock - IERC20(GME).balanceOf(address(MARKET));
        uint256 bounty = IERC20(USDG).balanceOf(caller) - callerCashBefore;
        assertGe(spent, 5e6, "a real V3 dip fill must meet minLotUsdg");
        assertGt(got, 0, "a real V3 dip fill must receive stock");
        assertGt(bounty, 0);
        assertEq(bounty, Math.mulDiv(spent, 50, 10_000));
        assertEq(before.cash - treasury.reserveUsdg(), spent + bounty);
        assertEq(IERC20(GME).balanceOf(address(treasury)) - before.treasuryStock, got);
        assertEq(treasury.bookedStock() - before.booked, got);
        assertEq(treasury.lotCount(), lotsBefore + 1);
        (uint256 qty, uint256 cost, bool half,) = treasury.lots(lotsBefore);
        assertEq(qty, got);
        assertEq(cost, Math.mulDiv(spent, SCALE, got));
        assertFalse(half);
        assertEq(treasury.lastSalePrice(), p);
        assertEq(treasury.buybackStock(), before.budget, "re-entry is not realized profit");
    }

    function test_fork_uptrendWaitsForMeanThenTakesProfit() public {
        _setupGraduated();
        uint256 targetPrice = startPrice * 102 / 100;
        _setPriceReport(targetPrice, block.timestamp);
        _assertHealth(false); // fresh feed alone cannot force a trade at an unchanged V3 market
        (uint256 marketSpent, uint256 marketReceived) = _moveMarket(targetPrice);
        _assertHealth(false); // the 600-second V3 mean still reflects the prior price
        vm.prank(KEEPER);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        treasury.execute();
        vm.warp(block.timestamp + 601);
        _assertHealth(true);

        RuleBefore memory before = _capture();
        vm.prank(KEEPER);
        treasury.execute();
        (uint256 afterQty,, bool half,) = treasury.lots(0);
        assertTrue(half, "first take-profit stage completed");
        assertGt(before.qty, afterQty);
        uint256 lotReduced = before.qty - afterQty;
        uint256 bounty = IERC20(GME).balanceOf(KEEPER) - before.keeperStock;
        uint256 sold = IERC20(GME).balanceOf(address(MARKET)) - before.marketStock;
        uint256 cashReceived = treasury.reserveUsdg() - before.cash;
        uint256 profitStock = lotReduced - sold;
        assertGt(sold, 0, "real V3 take-profit must sell stock");
        assertGt(cashReceived, 0, "take-profit must receive USDG");
        assertGt(bounty, 0, "keeper must receive a positive bounty");
        assertGt(profitStock, 0);
        assertEq(treasury.bookedStock(), before.booked - lotReduced);
        assertEq(before.treasuryStock - IERC20(GME).balanceOf(address(treasury)), sold + bounty);
        assertEq(before.marketCash - IERC20(USDG).balanceOf(address(MARKET)), cashReceived);
        assertGe(cashReceived, Math.mulDiv(Math.mulDiv(sold, targetPrice, SCALE), 9_945, 10_000, Math.Rounding.Ceil));
        assertEq(bounty, Math.mulDiv(profitStock, 50, 10_000));
        assertEq(treasury.buybackStock(), before.budget + profitStock - bounty);
        console2.log("Uptrend market mover input raw:", marketSpent);
        console2.log("Uptrend market mover output raw:", marketReceived);
        console2.log("Uptrend realized USDG raw:", cashReceived);
        console2.log("Uptrend stock buyback credit raw:", treasury.buybackStock() - before.budget);
    }

    function test_fork_sidewaysTenMinuteKeeperChecksDoNothing() public {
        _setupGraduated();
        uint256 stockBefore = IERC20(GME).balanceOf(address(treasury));
        uint256 cashBefore = treasury.reserveUsdg();
        uint256 budgetBefore = treasury.buybackStock();
        uint256 bookedBefore = treasury.bookedStock();
        uint256 lotsBefore = treasury.lotCount();
        // One onchain safety probe establishes that every write path refuses an idle market.
        // The ten keeper polls below are view-only preflights: an actual keeper should not
        // broadcast 30 known-to-revert transactions and pay gas for them.
        vm.prank(KEEPER);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        treasury.execute();
        vm.prank(KEEPER);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        treasury.execute();
        vm.prank(KEEPER);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        treasury.execute();
        HedgeFunTreasuryBase.Params memory rule = treasury.params();
        for (uint256 minute = 1; minute <= 10; ++minute) {
            vm.warp(block.timestamp + 60);
            (bool healthy, uint256 p) = treasury.health();
            assertTrue(healthy);
            (, uint256 cost,,) = treasury.lots(0);
            assertLt(p * 10_000, cost * (10_000 + rule.tp1Bps), "no take-profit signal");
            assertGt(p * 10_000, cost * (10_000 - rule.stopBps), "no stop-loss signal");
            assertGt(p * 10_000, treasury.lastSalePrice() * (10_000 - rule.dipBps), "no dip signal");
        }
        assertEq(IERC20(GME).balanceOf(address(treasury)), stockBefore);
        assertEq(treasury.reserveUsdg(), cashBefore);
        assertEq(treasury.buybackStock(), budgetBefore);
        assertEq(treasury.bookedStock(), bookedBefore);
        assertEq(treasury.lotCount(), lotsBefore);
        console2.log("Sideways no-trade minute checks:", uint256(10));
    }

    function test_fork_gapDownRejectsMismatchThenStopsAtRealV3Price() public {
        _setupGraduated();
        uint256 targetPrice = startPrice * 96 / 100;
        RuleBefore memory before = _capture();
        _setPriceReport(targetPrice, block.timestamp); // new report, old pool: no execution
        _assertHealth(false);
        vm.prank(KEEPER);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        treasury.execute();
        assertEq(treasury.bookedStock(), before.booked);
        assertEq(treasury.reserveUsdg(), before.cash);
        (uint256 marketSpent, uint256 marketReceived) = _moveMarket(targetPrice);
        _assertHealth(false); // pool spot has moved, but its 600-second mean has not
        vm.warp(block.timestamp + 601);
        _assertHealth(true);
        before = _capture();
        vm.prank(KEEPER);
        treasury.execute();
        uint256 sold = before.booked - treasury.bookedStock();
        uint256 netCash = treasury.reserveUsdg() - before.cash;
        uint256 bounty = IERC20(USDG).balanceOf(KEEPER) - before.keeperCash;
        uint256 grossCash = netCash + bounty;
        assertGt(sold, 0, "real V3 sell reduces the loss-making lot");
        assertGt(netCash, 0, "actual USDG proceeds enter reserve");
        assertEq(before.treasuryStock - IERC20(GME).balanceOf(address(treasury)), sold);
        assertEq(IERC20(GME).balanceOf(address(MARKET)) - before.marketStock, sold);
        assertEq(before.marketCash - IERC20(USDG).balanceOf(address(MARKET)), grossCash);
        assertGe(grossCash, Math.mulDiv(Math.mulDiv(sold, targetPrice, SCALE), 9_945, 10_000, Math.Rounding.Ceil));
        assertLt(grossCash, Math.mulDiv(sold, before.cost, SCALE), "stop realizes a loss against the booked cost");
        assertEq(bounty, Math.mulDiv(grossCash, 50, 10_000));
        assertEq(treasury.buybackStock(), before.budget, "a stop cannot mint strategy buyback profit");
        assertEq(treasury.totalBurned(), before.burned);
        console2.log("Gap-down market mover input raw:", marketSpent);
        console2.log("Gap-down market mover output raw:", marketReceived);
        console2.log("Gap-down lot GME sold raw:", sold);
        console2.log("Gap-down USDG reserved raw:", netCash);
    }

    function test_fork_staleStockFeedHaltsStrategyAndRecovers() public {
        _setupGraduated();
        vm.prank(FUNDING_POOL);
        assertTrue(IERC20(GME).transfer(address(treasury), 1e18));
        uint256 bookedBefore = treasury.bookedStock();
        uint256 cashBefore = treasury.reserveUsdg();
        uint256 budgetBefore = treasury.buybackStock();
        uint256 lotCountBefore = treasury.lotCount();
        uint256 stockBefore = IERC20(GME).balanceOf(address(treasury));
        vm.warp(block.timestamp + 26 hours + 1);
        // USDG remains live; only the stock report is left at its original timestamp.
        _feed(USDG_FEED, usdRound, int256(usdFeedAnswer), block.timestamp);
        (bool feedOk,) = oracle.tryPrice();
        assertFalse(feedOk, "stock report older than maxStockAge must fail closed");
        _assertHealth(false);
        assertFalse(treasury.book(), "unbooked stock cannot acquire a stale cost basis");
        vm.prank(KEEPER);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        treasury.execute();
        vm.prank(KEEPER);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        treasury.execute();
        vm.prank(KEEPER);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        treasury.execute();
        assertEq(treasury.bookedStock(), bookedBefore);
        assertEq(treasury.reserveUsdg(), cashBefore);
        assertEq(treasury.buybackStock(), budgetBefore);
        assertEq(treasury.lotCount(), lotCountBefore);
        assertEq(IERC20(GME).balanceOf(address(treasury)), stockBefore);
        _setPriceReport(startPrice, block.timestamp);
        _assertHealth(true);
        assertTrue(treasury.book(), "fresh stock report resumes booking");
        assertEq(treasury.bookedStock(), bookedBefore + 1e18);
        console2.log("Stale stock-feed halt seconds:", uint256(26 hours + 1));
    }

    function test_fork_transientCrashRecoversWithoutStopLoss() public {
        _setupGraduated();
        RuleBefore memory before = _capture();
        uint256 lastSaleBefore = treasury.lastSalePrice();
        uint256 lowPrice = startPrice * 96 / 100;
        _setPriceReport(lowPrice, block.timestamp);
        _moveMarket(lowPrice);
        _assertTwapLagBlocksFreshFeed(); // the sudden move has not formed a 10-minute mean
        vm.prank(KEEPER);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        treasury.execute();

        vm.warp(block.timestamp + 120); // a two-minute crash, not a sustained new market
        _setPriceReport(lowPrice, block.timestamp); // the low report is still fresh at minute two
        assertLt(treasury.spotPrice(), startPrice * 97 / 100);
        _assertTwapLagBlocksFreshFeed();
        vm.prank(KEEPER);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        treasury.execute();
        _moveMarket(startPrice);
        _setPriceReport(startPrice, block.timestamp);
        _assertTwapLagBlocksFreshFeed(); // a rebound does not instantly erase the 120-second low
        vm.warp(block.timestamp + 601); // wash the crash out of the mean
        _assertHealth(true);
        vm.prank(KEEPER);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        treasury.execute();
        RuleBefore memory afterState = _capture();
        assertEq(afterState.qty, before.qty);
        assertEq(afterState.booked, before.booked);
        assertEq(afterState.cash, before.cash);
        assertEq(afterState.budget, before.budget);
        assertEq(afterState.treasuryStock, before.treasuryStock);
        assertEq(afterState.keeperCash, before.keeperCash);
        assertEq(treasury.lastSalePrice(), lastSaleBefore);
        console2.log("Transient crash seconds before recovery:", uint256(120));
    }

    function test_fork_freshButDivergentFeedFailsClosedUntilCorrected() public {
        _setupGraduated();
        vm.prank(FUNDING_POOL);
        assertTrue(IERC20(GME).transfer(address(treasury), 1e18));
        uint256 bookedBefore = treasury.bookedStock();
        uint256 cashBefore = treasury.reserveUsdg();
        uint256 budgetBefore = treasury.buybackStock();
        uint256 lotsBefore = treasury.lotCount();
        uint256 stockBefore = IERC20(GME).balanceOf(address(treasury));
        uint256 keeperStockBefore = IERC20(GME).balanceOf(KEEPER);
        uint256 keeperCashBefore = IERC20(USDG).balanceOf(KEEPER);
        _setPriceReport(startPrice * 105 / 100, block.timestamp); // fresh, but no supporting V3 trade
        for (uint256 minute = 0; minute < 20; ++minute) {
            (bool feedOk,) = oracle.tryPrice();
            assertTrue(feedOk, "the divergent report must still be fresh");
            uint256 spot = treasury.spotPrice();
            uint256 mean = treasury.twapPrice();
            assertGt(mean, 0);
            assertLe(spot > mean ? spot - mean : mean - spot, startPrice / 1000,
                "the V3 spot and mean must agree; only the feed diverges");
            _assertHealth(false);
            assertFalse(treasury.book(), "a live but divergent report cannot book stock");
            vm.warp(block.timestamp + 60);
            _setPriceReport(startPrice * 105 / 100, block.timestamp);
        }
        vm.prank(KEEPER);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        treasury.execute();
        vm.prank(KEEPER);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        treasury.execute();
        vm.prank(KEEPER);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        treasury.execute();
        assertEq(treasury.bookedStock(), bookedBefore);
        assertEq(treasury.reserveUsdg(), cashBefore);
        assertEq(treasury.buybackStock(), budgetBefore);
        assertEq(treasury.lotCount(), lotsBefore);
        assertEq(IERC20(GME).balanceOf(address(treasury)), stockBefore);
        assertEq(IERC20(GME).balanceOf(KEEPER), keeperStockBefore);
        assertEq(IERC20(USDG).balanceOf(KEEPER), keeperCashBefore);
        _setPriceReport(startPrice, block.timestamp);
        _assertHealth(true);
        assertTrue(treasury.book(), "booking resumes only after the report agrees with V3");
        assertEq(treasury.bookedStock(), bookedBefore + 1e18);
        console2.log("Fresh divergent feed minutes rejected:", uint256(20));
    }

    function test_fork_takeProfitThenDipBuysBackStock() public {
        ForkRuleConfig memory c = _defaultRule(2500);
        c.stopBps = 0; // isolate the profit-to-dip path; with a stop enabled the 98% price must stop first
        _setupGraduatedConfig(c);
        uint256 highPrice = startPrice * 102 / 100;
        _setPriceReport(highPrice, block.timestamp);
        _moveMarket(highPrice);
        vm.warp(block.timestamp + 601);
        _assertHealth(true);
        vm.prank(KEEPER);
        treasury.execute();
        uint256 cashAfterProfit = treasury.reserveUsdg();
        assertGt(cashAfterProfit, 20e6, "profit sale must fund the later dip");

        uint256 lowPrice = startPrice * 98 / 100;
        _setPriceReport(lowPrice, block.timestamp);
        _moveMarket(lowPrice);
        _assertHealth(false); // a reversal cannot execute until the V3 mean catches up
        vm.prank(KEEPER);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        treasury.execute();
        vm.warp(block.timestamp + 601);
        (uint256 spent, uint256 got) = _assertDipBuy(KEEPER);
        console2.log("Profit-to-dip USDG spent raw:", spent);
        console2.log("Profit-to-dip GME bought raw:", got);
    }

    function test_fork_stopLossThenFurtherDipReenters() public {
        _setupGraduated();
        uint256 firstLow = startPrice * 96 / 100;
        _setPriceReport(firstLow, block.timestamp);
        _moveMarket(firstLow);
        vm.warp(block.timestamp + 601);
        (bool firstHealthy, uint256 stopPrice) = treasury.health();
        assertTrue(firstHealthy);
        RuleBefore memory beforeStop = _capture();
        vm.prank(KEEPER);
        treasury.execute();
        uint256 cashAfterStop = treasury.reserveUsdg();
        uint256 lastSaleAfterStop = treasury.lastSalePrice();
        uint256 stoppedStock = beforeStop.booked - treasury.bookedStock();
        uint256 stopNetCash = cashAfterStop - beforeStop.cash;
        uint256 stopBounty = IERC20(USDG).balanceOf(KEEPER) - beforeStop.keeperCash;
        assertGt(stoppedStock, 0);
        assertGt(stopNetCash, 40e6);
        assertEq(beforeStop.treasuryStock - IERC20(GME).balanceOf(address(treasury)), stoppedStock);
        assertEq(IERC20(GME).balanceOf(address(MARKET)) - beforeStop.marketStock, stoppedStock);
        assertEq(beforeStop.marketCash - IERC20(USDG).balanceOf(address(MARKET)), stopNetCash + stopBounty);
        assertEq(stopBounty, Math.mulDiv(stopNetCash + stopBounty, 50, 10_000));
        assertEq(treasury.lotCount(), 0, "the original loss-making lot is fully stopped");
        assertEq(treasury.bookedStock(), 0);
        assertEq(lastSaleAfterStop, stopPrice);

        // The first down-leg consumes most of the market actor's initial GME.
        // This extra test-only funding permits a second actual V3 down-leg.
        vm.prank(FUNDING_POOL);
        assertTrue(IERC20(GME).transfer(address(mover), 3_000e18));
        uint256 secondLow = startPrice * 94 / 100;
        _setPriceReport(secondLow, block.timestamp);
        _moveMarket(secondLow);
        _assertHealth(false);
        vm.warp(block.timestamp + 601);
        (bool healthy, uint256 p) = treasury.health();
        assertTrue(healthy);
        assertLt(p * 10_000, lastSaleAfterStop * (10_000 - 150), "new low meets the dip rung");
        (uint256 spent, uint256 got) = _assertDipBuy(KEEPER);
        assertEq(treasury.lotCount(), 1, "lot 0 is the new 94% dip lot");
        console2.log("Stop-then-dip USDG spent raw:", spent);
        console2.log("Stop-then-dip GME bought raw:", got);

        // A second lower rung is stop-due on the 94% lot. No caller may buy ahead of it.
        vm.prank(FUNDING_POOL);
        assertTrue(IERC20(GME).transfer(address(mover), 1_000e18));
        uint256 thirdLow = startPrice * 92 / 100;
        _setPriceReport(thirdLow, block.timestamp);
        _moveMarket(thirdLow);
        vm.warp(block.timestamp + 601);
        (healthy, p) = treasury.health();
        assertTrue(healthy);
        assertLt(p * 10_000, treasury.lastSalePrice() * (10_000 - 150));
        // At this point the 94% dip lot is also below its stop.
        uint256 bookedBeforeCompetingStop = treasury.bookedStock();
        vm.prank(PUBLIC_CALLER);
        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        assertLt(treasury.bookedStock(), bookedBeforeCompetingStop);
        assertEq(treasury.lastSalePrice(), p);
        vm.prank(PUBLIC_CALLER);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        treasury.execute();
    }

    /// @dev Build the reserve from a real V3 take-profit, not a test-only USDG gift. Signals
    /// are judged at one healthy low report after the pool's full mean window has caught up.
    function _prepareParamRace(ForkRuleConfig memory c, uint256 lowBps) private returns (uint256 p) {
        _setupGraduatedConfig(c);
        uint256 high = startPrice * 102 / 100;
        _setPriceReport(high, block.timestamp);
        _moveMarket(high);
        vm.warp(block.timestamp + 601);
        _assertHealth(true);
        vm.prank(KEEPER);
        treasury.execute();
        assertGt(treasury.reserveUsdg(), 18e6, "a real take-profit must fund the dip");

        uint256 low = startPrice * lowBps / 10_000;
        _setPriceReport(low, block.timestamp);
        _moveMarket(low);
        vm.warp(block.timestamp + 601);
        (bool ok, uint256 reported) = treasury.health();
        assertTrue(ok, "the real V3 spot and ten-minute mean must agree with the report");
        return reported;
    }

    function _markedTreasury(uint256 p) private view returns (uint256) {
        return treasury.reserveUsdg() + Math.mulDiv(IERC20(GME).balanceOf(address(treasury)), p, SCALE);
    }

    /// A separate bot touches the genuine V3 stock venue around an ordinary keeper's dip buy.
    /// All three calls share the fork's timestamp; the price path is synthetic, but the swaps are real.
    function test_fork_keeperDipBuySandwichedByV3Bot() public {
        SandwichMeasure memory s;
        ForkRuleConfig memory c = _defaultRule(3000);
        c.stopBps = 0; // isolate the buy signal from the independent stop-order race
        c.sellChunkUsdg = 20e6;
        s.p = _prepareParamRace(c, 9600);
        V3ScenarioMover bot = new V3ScenarioMover(MARKET);
        vm.startPrank(FUNDING_POOL);
        assertTrue(IERC20(USDG).transfer(address(bot), 5_000e6));
        vm.stopPrank();
        s.botUsdBefore = IERC20(USDG).balanceOf(address(bot));
        s.botStockBefore = IERC20(GME).balanceOf(address(bot));
        (s.originalSqrt,,,,,,) = MARKET.slot0();
        uint256 state = vm.snapshotState();

        (s.cleanSpent, s.cleanGot) = _assertDipBuy(KEEPER);
        s.cleanKeeperBounty = IERC20(USDG).balanceOf(KEEPER);
        s.cleanTreasuryMark = _markedTreasury(s.p);
        assertTrue(vm.revertToState(state));

        s.frontGas = gasleft();
        (, s.botFrontStock) = bot.moveTo(_sqrtForPrice(s.p * 10_010 / 10_000), s.botUsdBefore);
        s.frontGas -= gasleft();
        _assertHealth(true);
        uint256 treasuryStockBefore = IERC20(GME).balanceOf(address(treasury));
        uint256 marketUsdBefore = IERC20(USDG).balanceOf(address(MARKET));
        uint256 keeperUsdBefore = IERC20(USDG).balanceOf(KEEPER);
        vm.prank(KEEPER);
        treasury.execute();
        s.attackedGot = IERC20(GME).balanceOf(address(treasury)) - treasuryStockBefore;
        s.attackedSpent = IERC20(USDG).balanceOf(address(MARKET)) - marketUsdBefore;
        s.attackedKeeperBounty = IERC20(USDG).balanceOf(KEEPER) - keeperUsdBefore;
        s.backGas = gasleft();
        bot.tradeExactInput(GME, s.botFrontStock);
        s.backGas -= gasleft();
        (uint160 finalSqrt,,,,,,) = MARKET.slot0();
        s.botUsdAfter = IERC20(USDG).balanceOf(address(bot));
        s.botStockAfter = IERC20(GME).balanceOf(address(bot));
        assertEq(s.botStockAfter, s.botStockBefore, "bot must close its stock position");
        int256 botPnl = int256(s.botUsdAfter) - int256(s.botUsdBefore);
        assertEq(s.attackedKeeperBounty, Math.mulDiv(s.attackedSpent, c.bountyBps, 10_000),
            "the ordinary keeper, not the pool bot, receives the rule bounty");
        assertLt(Math.mulDiv(s.attackedGot, s.cleanSpent, s.attackedSpent), s.cleanGot,
            "pool pretrade must worsen stock received per USDG");
        assertLt(_markedTreasury(s.p), s.cleanTreasuryMark,
            "this accepted pretrade leaves the treasury worse at the unchanged oracle report");
        assertLt(botPnl, 0, "this exact-input bot round trip loses USDG before gas");
        console2.log("V3 pool fee bps", MARKET.fee() / 100);
        console2.log("clean dip spent/got raw", s.cleanSpent, s.cleanGot);
        console2.log("attacked dip spent/got raw", s.attackedSpent, s.attackedGot);
        console2.log("clean/attacked keeper bounty USDG raw", s.cleanKeeperBounty, s.attackedKeeperBounty);
        console2.log("clean/attacked treasury mark USDG raw", s.cleanTreasuryMark, _markedTreasury(s.p));
        console2.log("bot stock balance before/after raw", s.botStockBefore, s.botStockAfter);
        console2.log("bot USDG balance before/after raw", s.botUsdBefore, s.botUsdAfter);
        console2.log("V3 sqrt price before/after bot round trip", s.originalSqrt, finalSqrt);
        console2.logInt(botPnl);
        console2.log("bot front/back EVM gas units", s.frontGas, s.backGas);
    }

    function test_fork_params_partialStopBlocksAnyCallerFromBuyingFirst() public {
        ForkRuleConfig memory c = _defaultRule(3000);
        c.sellChunkUsdg = 20e6;
        uint256 p = _prepareParamRace(c, 9600);
        assertGt(treasury.reserveUsdg() * c.lotBps / 10_000, 5e6);
        uint256 initialQty = treasury.bookedStock();
        uint256 initialLots = treasury.lotCount();
        vm.prank(PUBLIC_CALLER);
        (HedgeFunV2Treasury.Action action, uint256 chosen) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        assertEq(chosen, 0);
        uint256 stoppedFirst = initialQty - treasury.bookedStock();
        uint256 stopFirstBounty = IERC20(USDG).balanceOf(PUBLIC_CALLER);
        uint256 stopFirstWorth = _markedTreasury(p);
        assertGt(stoppedFirst, 0);
        assertEq(treasury.lotCount(), initialLots);
        (uint256 oldRemaining, uint256 oldCost,,) = treasury.lots(0);
        assertGt(oldRemaining, 0, "the 20 USDG sell cap leaves the old lot partly unsold");
        assertLt(oldRemaining, initialQty);
        assertLe(p * 10_000, oldCost * (10_000 - c.stopBps), "the residual old lot remains stop-due");
        assertEq(treasury.lastSalePrice(), p);
        vm.prank(PUBLIC_CALLER);
        vm.expectRevert(HedgeFunV2Treasury.UseExecute.selector);
        treasury.buyDip();
        _moveMarket(p);
        vm.warp(block.timestamp + 601);
        _assertHealth(true);
        vm.prank(PUBLIC_CALLER);
        (action, chosen) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        assertEq(chosen, 0);
        assertLe(treasury.lotCount(), initialLots, "the second stop must not add a dip lot");
        console2.log("Param race stop-first bounty USDG raw:", stopFirstBounty);
        console2.log("Param race stop-first treasury mark USDG raw:", stopFirstWorth);
    }

    function test_fork_params_10PercentLotFallsBelowMinimumAfterProfit() public {
        ForkRuleConfig memory c = _defaultRule(1000);
        c.stopBps = 0;
        c.sellChunkUsdg = 20e6;
        _prepareParamRace(c, 9600);
        uint256 intended = treasury.reserveUsdg() * c.lotBps / 10_000;
        assertLt(intended, 5e6, "the smaller fraction must be below the immutable min lot");
        vm.prank(PUBLIC_CALLER);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        treasury.execute();
        console2.log("10% lot offered USDG raw:", intended);
    }

    function test_fork_params_stopOffLeavesOnlyDip() public {
        ForkRuleConfig memory c = _defaultRule(3000);
        c.stopBps = 0;
        c.bountyBps = 0;
        c.sellChunkUsdg = 20e6;
        uint256 p = _prepareParamRace(c, 9600);
        uint256 beforeQty = treasury.bookedStock();
        uint256 beforeCash = treasury.reserveUsdg();
        vm.prank(PUBLIC_CALLER);
        treasury.execute();
        assertGt(treasury.bookedStock(), beforeQty);
        assertLt(treasury.reserveUsdg(), beforeCash);
        assertEq(treasury.lastSalePrice(), p);
        assertEq(IERC20(USDG).balanceOf(PUBLIC_CALLER), 0);
    }

    function test_fork_params_widerDipDelaysButDoesNotDisableStop() public {
        ForkRuleConfig memory c = _defaultRule(3000);
        c.dipBps = 500;
        c.maxSlippageBps = 25;
        c.maxDeviationBps = 10;
        c.sellChunkUsdg = 20e6;
        uint256 p = _prepareParamRace(c, 9800);
        uint256 before = treasury.bookedStock();
        vm.prank(PUBLIC_CALLER);
        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        assertLt(treasury.bookedStock(), before);
        assertEq(treasury.lastSalePrice(), p);
        console2.log("Wide-dip 98% stop sold GME raw:", before - treasury.bookedStock());
    }
}
