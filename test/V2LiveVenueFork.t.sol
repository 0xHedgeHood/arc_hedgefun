// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {HedgeFunFactory, TokenDeployer} from "../src/HedgeFunFactory.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2Hook} from "../src/hooks/HedgeFunV2Hook.sol";
import {HedgeFunBondingCurve as Curve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {CurveDeployer} from "../src/v2/CurveDeployer.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {V2LiquidityVault} from "../src/v2/V2LiquidityVault.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunV2BuybackTreasury} from "../src/v2/HedgeFunV2BuybackTreasury.sol";
import {HedgeFunV2TradeRouter as Router} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {AlwaysOpen, IAgg} from "./mocks/Mocks.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// Opt-in local mainnet-state simulation, never a broadcast. Reuses the verified production addresses in
/// TradeRouterFork.t.sol: genuine USDG/GME contracts, canonical V3 pools AND the chain's deployed V4 manager.
/// V2 factory/hook/treasury/curve/router are deployed only inside the fork. As in the existing fork suite,
/// balances are funded by impersonating the deep pool; oracle values stay real but timestamps are refreshed,
/// and AlwaysOpen removes the wall-clock market-calendar dependency. No pricing or swap calls are mocked.
/// Run: RH_FORK=1 RH_RPC=https://rpc-robinhood.blockmachine.io forge test --mc StrategyForkTestV2LiveVenue -vv
/// The default public RPC does not retain the pinned block's historical state; use an archive RPC for replay.
/// Optional RH_RPC chooses an existing RPC alias/URL; RH_FORK_BLOCK overrides the pinned block (0 = latest).
contract StrategyForkTestV2LiveVenue is Test, HookMiner {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager private constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address private constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address private constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address private constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address private constant GME = 0x1b0E319c6A659F002271B69dB8A7df2F911c153E;
    address private constant GME_FEED = 0x27C71df6A64fB476468EdF256CF72c038baB5B67;
    address private constant LISTING_POOL = 0xE2b46c905E12Ab8E2f864e4821a4325884C1B126;
    address private constant ROUTE_POOL = 0xE9713f453aDB9245B19559790c96F470a18F2fDF;
    address private constant OWNER = address(0xA11CE);
    address private constant PROTOCOL = address(0x5AFE);
    address private constant CREATOR = address(0xC4EA704);
    address private constant ALICE = address(0xA11);
    address private constant BOB = address(0xB0B);
    address private constant BOT = address(0xB07);

    HedgeFunV2Factory private factory;
    HedgeFunV2Hook private hook;
    HedgeFunToken private token;
    Curve private curve;
    Router private router;
    PoolKey private key;
    uint256 private id;
    uint256 private initialUsdg;
    uint256 private initialStock;

    struct Balances {
        uint256 usdg; uint256 stock; uint256 token; uint256 supply;
        uint256 routeStock; uint256 reserve; uint256 fees; uint256 taxToken; uint256 taxStock;
    }

    struct SandwichCurveMeasure {
        uint256 botStartUsd;
        uint256 aliceStartUsd;
        uint256 cleanOut;
        uint256 cleanStock;
        uint256 botTokens;
        uint256 attackedOut;
        uint256 botProceeds;
        uint256 frontGas;
        uint256 backGas;
    }

    function _refresh(address feed) private {
        (uint80 round, int256 answer,,,) = IAgg(feed).latestRoundData();
        vm.mockCall(feed, abi.encodeWithSelector(IAgg.latestRoundData.selector),
            abi.encode(round, answer, block.timestamp, block.timestamp, round));
    }

    function _defaults() private pure returns (HedgeFunFactory.Defaults memory d) {
        d.supply = 1_000_000e18;
        d.lpFee = 3000;
        d.tickSpacing = 60; d.minTaxBps = 100; d.maxTaxBps = 1500; d.protocolBps = 2000; d.maxCreatorBps = 3000;
        d.spikeBps = 9000; d.spikeSeconds = 120; d.snipeBps = 9900; d.snipeSeconds = 3;
        d.sweepTipBps = 0; d.bountyBps = 50; d.maxSlippageBps = 100; d.maxDeviationBps = 50;
        d.maxBuybackImpactBps = 300; d.buybackCooldown = 60; d.minLotUsdg = 5e6;
        d.buybackChunkUsdg = 500e6; d.sellChunkUsdg = type(uint128).max;
    }

    function _setUpFork() private {
        _setUpForkKind(0);
    }

    function _setUpForkKind(uint8 strategyKind) private {
        _setUpForkKindAndTax(strategyKind, 1000);
    }

    function _setUpForkKindAndTax(uint8 strategyKind, uint16 taxBps) private {
        vm.skip(vm.envOr("RH_FORK", uint256(0)) == 0, "live V2 fork: set RH_FORK=1; no broadcast");
        string memory rpc = vm.envOr("RH_RPC", string("blockmachine"));
        uint256 pinnedBlock = vm.envOr("RH_FORK_BLOCK", uint256(70_786_980));
        if (pinnedBlock == 0) vm.createSelectFork(rpc); else vm.createSelectFork(rpc, pinnedBlock);
        console2.log("V2 live venue fork block:", block.number);
        assertGt(address(PM).code.length, 0, "the production V4 manager must exist on this fork");
        _refresh(USDG_FEED); _refresh(GME_FEED);
        PriceOracle oracle = new PriceOracle(GME, GME_FEED, USDG_FEED, address(new AlwaysOpen()), 26 hours, 26 hours);
        // About 25 USDG of virtual GME yields a ~100 USDG graduation target at the creator's 80% sale (below).
        // Small real V3 trades limit tick traversal/RPC reads. This is test economics, not production defaults.
        uint256 initialPrice = Math.mulDiv(25e18, 1e18, oracle.price()) / 1_000_000;
        assertGt(initialPrice, 0);
        hook = _deployV2Hook(PM);
        HedgeFunFactory.Defaults memory defaults = _defaults();
        if (strategyKind == 1) {
            // This fork deliberately graduates at only ~100 USDG to keep archive reads small. With that shallow
            // V4 pool, a 3% impact cap fills about 0.7 USDG -- below the 5 USDG production candidate minimum.
            // Lower only this test deployment's minimum so the real-venue lifecycle is executable; production
            // must calibrate minLotUsdg, impact and seeded depth together rather than copying this value.
            defaults.minLotUsdg = 250_000;
            console2.log("V2 live kind-1 test min lot USDG raw:", defaults.minLotUsdg);
        }
        factory = new HedgeFunV2Factory(OWNER, address(PM), V3_FACTORY, USDG, PROTOCOL,
            address(new V2TreasuryDeployer()), address(new TokenDeployer()), address(hook), address(new CurveDeployer(8000)), defaults);
        V2TreasuryDeployer treasuryDeployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        if (strategyKind == 1) {
            (address a, address b) = treasuryDeployer.makeChunks(type(HedgeFunV2BuybackTreasury).creationCode);
            vm.prank(OWNER);
            assertEq(treasuryDeployer.registerKind(a, b), 1, "owner registers exact buyback code as kind 1");
            (address storedA, address storedB) = treasuryDeployer.kinds(1);
            assertEq(keccak256(bytes.concat(storedA.code, storedB.code)),
                keccak256(type(HedgeFunV2BuybackTreasury).creationCode), "registered kind-1 code must match this build");
        }
        uint256 lpBps = vm.envOr("V2_LP_BPS", uint256(5000));
        require(lpBps >= 1000 && lpBps <= 10000, "V2_LP_BPS");
        console2.log("V2 live venue LP bps:", lpBps);
        vm.startPrank(OWNER);
        // Exercise the production owner setter and the per-treasury launch freeze. Non-default experiments must not
        // rewrite DEFAULT_LP_BPS in a copied source tree, because that skips the configuration path being reviewed.
        treasuryDeployer.setLpBps(GME, uint16(lpBps));
        assertEq(treasuryDeployer.lpBps(GME), lpBps,
            "owner LP setting must read back before launch");
        factory.list(GME, address(oracle), LISTING_POOL, initialPrice, true);
        factory.setPublicLaunch(true);
        vm.stopPrank();
        HedgeFunFactory.Request memory request;
        request.name = "V2 live-venue fork only"; request.symbol = "V2FORK";
        request.stock = GME; request.creator = CREATOR; request.taxBps = taxBps; request.creatorBps = 1000;
        request.tp1Bps = 3000; request.tp2Bps = 6000; request.dipBps = 800; request.lotBps = 5000;
        request.expectedOpenPriceE18 = initialPrice;
        if (strategyKind != 0) {
            vm.prank(CREATOR);
            treasuryDeployer.setStrategyKind(request.symbol, request.nonce, strategyKind);
        }
        // The creator chooses the raise: this replay was sized for an 80% sale and the 3-second window.
        CurveDeployer curveDeployer = factory.curveDeployer();
        vm.prank(CREATOR);
        curveDeployer.setCurveConfig(request.symbol, request.nonce, 8000, 3);
        (,, bytes32 terms) = factory.predict(request);
        vm.prank(CREATOR); id = factory.launch(request, terms);
        curve = Curve(factory.curves(id)); token = HedgeFunToken(curve.token());
        uint256 frozenLpBps = V2TreasuryDeployer(address(factory.treasuryDeployer())).lpBpsOfTreasury(curve.treasury());
        assertEq(frozenLpBps, lpBps, "launch must freeze the requested LP share");
        console2.log("V2 live venue frozen LP bps:", frozenLpBps);
        (key,) = factory.graduationConfig(id);
        router = new Router(factory);
        _fund(ALICE); _fund(BOB); _fund(BOT);
        initialUsdg = _sum(IERC20(USDG)); initialStock = _sum(IERC20(GME));
        _assertClean();
    }

    function _fund(address user) private {
        vm.prank(ROUTE_POOL); assertTrue(IERC20(USDG).transfer(user, 500e6));
        vm.startPrank(user);
        IERC20(USDG).approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _holders() private view returns (address[12] memory holders) {
        holders = [ALICE, BOB, CREATOR, PROTOCOL, BOT, address(factory), address(curve), address(router),
            curve.treasury(), address(hook), ROUTE_POOL, address(PM)];
    }

    function _sum(IERC20 asset) private view returns (uint256 total) {
        address[12] memory holders = _holders();
        for (uint256 i; i < holders.length; ++i) total += asset.balanceOf(holders[i]);
    }

    function _assertClean() private view {
        assertEq(_sum(IERC20(USDG)), initialUsdg, "USDG conservation including real V3 venue");
        assertEq(_sum(IERC20(GME)), initialStock, "GME conservation including real V3/V4 venues and tax recipients");
        assertEq(_sum(IERC20(address(token))), token.totalSupply(), "strategy-token balances equal live supply");
        assertEq(IERC20(USDG).balanceOf(address(router)), 0);
        assertEq(IERC20(GME).balanceOf(address(router)), 0); assertEq(token.balanceOf(address(router)), 0);
        assertEq(IERC20(GME).allowance(address(router), address(curve)), 0);
        assertEq(token.allowance(address(router), address(curve)), 0);
        assertEq(IERC20(GME).balanceOf(address(curve)), curve.realStockReserve() + curve.totalFees());
    }

    function _path(bool buy) private pure returns (Router.Hop[] memory path) {
        path = new Router.Hop[](1); path[0] = Router.Hop(ROUTE_POOL, buy ? GME : USDG);
    }

    function _params(uint256 amount, uint8 stage) private view returns (Router.TradeParams memory) {
        return Router.TradeParams(id, USDG, amount, 0, 1, block.timestamp, stage, true);
    }

    function _balances(address user) private view returns (Balances memory b) {
        b.usdg = IERC20(USDG).balanceOf(user); b.stock = IERC20(GME).balanceOf(user);
        b.token = token.balanceOf(user); b.supply = token.totalSupply();
        b.routeStock = IERC20(GME).balanceOf(ROUTE_POOL);
        b.reserve = curve.tokenReserve(); b.fees = curve.totalFees();
        (b.taxToken, b.taxStock) = hook.accrued(key.toId());
    }

    /// Quote the entire actual route in a local EVM snapshot, then execute with BOTH stock and token floors.
    function _quotedBuy(address user, uint256 usdgIn, uint8 stage) private returns (uint256 got, uint256 refund) {
        Router.TradeParams memory p = _params(usdgIn, stage);
        uint256 snapshot = vm.snapshotState();
        uint256 beforeStock = IERC20(GME).balanceOf(ROUTE_POOL);
        vm.prank(user); (p.minFinalOut,) = router.buy(p, _path(true));
        p.minStockReceived = beforeStock - IERC20(GME).balanceOf(ROUTE_POOL);
        vm.revertToState(snapshot);
        Balances memory b = _balances(user);
        uint256 expectedCurveTax;
        if (stage == 0) (,, expectedCurveTax) = curve.quoteBuy(p.minStockReceived);
        vm.prank(user); (got, refund) = router.buy(p, _path(true));
        assertEq(got, p.minFinalOut);
        assertEq(IERC20(USDG).balanceOf(user), b.usdg - usdgIn);
        assertEq(token.balanceOf(user), b.token + got);
        assertEq(IERC20(GME).balanceOf(user), b.stock + refund, "partial buy returns stock to the right user");
        assertEq(b.routeStock - IERC20(GME).balanceOf(ROUTE_POOL), p.minStockReceived);
        if (stage == 0) {
            uint256 actualPaid = p.minStockReceived - refund;
            assertEq(curve.totalFees() - b.fees, Math.mulDiv(actualPaid, curve.taxBps(), 10_000),
                "actual curve stock payment accrues a base fee, including the graduation buy");
            uint256 extraBurn;
            if (curve.status() == Curve.Status.Graduated) {
                extraBurn = b.reserve - got - expectedCurveTax - token.balanceOf(address(PM));
            }
            assertEq(token.totalSupply(), b.supply - expectedCurveTax - extraBurn);
        } else {
            (uint256 taxAfter,) = hook.accrued(key.toId());
            uint256 tax = taxAfter - b.taxToken;
            assertEq(tax, Math.mulDiv(got + tax, curve.taxBps(), 10_000), "graduated buy fee uses the frozen base rate");
            assertEq(token.totalSupply(), b.supply, "V4 basic token fee remains a conversion claim");
        }
        _assertClean();
    }

    function _quotedSell(address user, uint256 amount, uint8 stage) private returns (uint256 proceeds) {
        Router.TradeParams memory p = _params(amount, stage);
        uint256 snapshot = vm.snapshotState();
        vm.prank(user); (p.minFinalOut,) = router.sell(p, _path(false));
        vm.revertToState(snapshot);
        Balances memory b = _balances(user);
        uint256 refund;
        vm.prank(user); (proceeds, refund) = router.sell(p, _path(false));
        assertEq(proceeds, p.minFinalOut); assertEq(refund, 0, "this funded V4/curve sale fully fills");
        assertEq(IERC20(USDG).balanceOf(user), b.usdg + proceeds);
        assertEq(token.balanceOf(user), b.token - amount);
        assertEq(IERC20(GME).balanceOf(user), b.stock, "sell settles to the requested USDG");
        uint256 netStock = IERC20(GME).balanceOf(ROUTE_POOL) - b.routeStock;
        uint256 tax;
        if (stage == 0) tax = curve.totalFees() - b.fees;
        else { (, uint256 afterTax) = hook.accrued(key.toId()); tax = afterTax - b.taxStock; }
        assertGt(tax, 0); assertEq(tax, Math.mulDiv(netStock + tax, curve.taxBps(), 10_000), "sell tax is charged in real GME");
        assertEq(token.totalSupply(), b.supply);
        _assertClean();
    }

    function _claimCurveFees() private {
        address[3] memory roles = [PROTOCOL, CREATOR, curve.treasury()];
        for (uint256 i; i < roles.length; ++i) {
            uint256 beforeBalance = IERC20(GME).balanceOf(roles[i]);
            uint256 owed = curve.claimable(roles[i]);
            vm.prank(BOB); curve.claimFees(roles[i]);
            assertEq(IERC20(GME).balanceOf(roles[i]), beforeBalance + owed);
        }
        assertEq(curve.totalFees(), 0);
        _assertClean();
    }

    function _sweepV4Fees() private {
        (uint256 taxTokens, uint256 taxStock) = hook.accrued(key.toId());
        uint256 supplyBefore = token.totalSupply();
        uint256 tokenTip = token.balanceOf(BOT);
        uint256 protocolBefore = IERC20(GME).balanceOf(PROTOCOL);
        uint256 creatorBefore = IERC20(GME).balanceOf(CREATOR);
        uint256 treasuryBefore = IERC20(GME).balanceOf(curve.treasury());
        uint256 stockBefore = IERC20(GME).balanceOf(PROTOCOL) + IERC20(GME).balanceOf(CREATOR)
            + IERC20(GME).balanceOf(curve.treasury()) + IERC20(GME).balanceOf(BOT);
        vm.prank(BOT); hook.sweep(key.toId());
        assertEq(token.balanceOf(BOT), tokenTip, "V2 has no sweep tip");
        assertEq(token.totalSupply(), supplyBefore, "V2 basic buy fees are not burned");
        assertEq(taxTokens, 0, "V2 takes every fee in stock");
        assertEq(PM.balanceOf(address(hook), uint256(uint160(address(token)))), 0, "no token fee inventory");
        uint256 stockAfter = IERC20(GME).balanceOf(PROTOCOL) + IERC20(GME).balanceOf(CREATOR)
            + IERC20(GME).balanceOf(curve.treasury()) + IERC20(GME).balanceOf(BOT);
        assertEq(stockAfter - stockBefore, taxStock, "tax stays with configured recipients and sweeper");
        uint256 protocolCut = Math.mulDiv(taxStock, 2000, 10_000);
        uint256 creatorCut = Math.mulDiv(taxStock, 1000, 10_000);
        assertEq(IERC20(GME).balanceOf(PROTOCOL) - protocolBefore, protocolCut);
        assertEq(IERC20(GME).balanceOf(CREATOR) - creatorBefore, creatorCut);
        assertEq(IERC20(GME).balanceOf(curve.treasury()) - treasuryBefore, taxStock - protocolCut - creatorCut);
        _assertClean();
    }

    function _buybackFromCollectedFees(HedgeFunV2Treasury treasury, uint256 stockFee)
        private returns (uint256 spent, uint256 burned)
    {
        // LP stock fees are real income, but they are not strategy trading profit.
        uint256 supplyBefore = token.totalSupply();
        uint256 burnedBefore = treasury.totalBurned();
        uint256 botFunBefore = token.balanceOf(BOT);
        uint256 budgetBefore = treasury.buybackStock();
        assertEq(token.balanceOf(address(treasury)), 0);
        vm.prank(BOT);
        (spent, burned) = treasury.buyback();
        assertGt(spent, 0, "live V4 buyback spends stock fees");
        assertEq(spent, stockFee, "this small fee-funded buyback fills completely");
        assertGt(burned, 0, "live V4 buyback burns acquired FUN");
        assertEq(treasury.buybackStock(), budgetBefore - spent);
        assertEq(treasury.totalBurned(), burnedBefore + burned);
        assertEq(token.totalSupply(), supplyBefore - burned);
        uint256 bounty = token.balanceOf(BOT) - botFunBefore;
        assertEq(bounty, (burned + bounty) * 50 / 10_000, "caller gets only configured FUN bounty");
        assertEq(token.balanceOf(address(treasury)), 0, "no acquired FUN remains in treasury");
        assertEq(hook.sellRateBps(key.toId()), 1000, "V2 buyback keeps the flat sell tax");
        _assertClean();
        console2.log("Live V4 treasury buyback GME spent raw:", spent);
        console2.log("Live V4 treasury buyback FUN burned raw:", burned);
    }

    function _assertChasingPriceBlockedWhenApplicable(HedgeFunV2Treasury treasury) private {
        uint256 budgetBefore = treasury.buybackStock();
        assertGt(budgetBefore, 0, "price-gate test needs a funded buyback");
        (uint160 spot,,,) = PM.getSlot0(key.toId());
        uint160 anchor = treasury.buybackAnchorSqrtP();
        assertTrue(treasury.stockIsCurrency0InTokenPool() ? spot < anchor : spot > anchor,
            "the default-depth scenario must cross the trusted anchor");
        uint256 supplyBefore = token.totalSupply();
        uint256 lastBuybackBefore = treasury.lastBuybackAt();
        vm.prank(BOT);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        treasury.buyback();
        assertEq(treasury.buybackStock(), budgetBefore, "rejected buyback preserves budget");
        assertEq(treasury.lastBuybackAt(), lastBuybackBefore, "rejected buyback preserves cooldown");
        assertEq(token.totalSupply(), supplyBefore, "rejected buyback cannot burn");
    }

    function test_fork_twoUsersLiveV3CurveGraduationV4FeesAndBuybackBurn() public {
        _setUpFork();
        (uint256 aliceTokens,) = _quotedBuy(ALICE, 10e6, 0);
        (uint256 bobTokens,) = _quotedBuy(BOB, 10e6, 0);
        assertEq(uint256(curve.status()), 0);
        _quotedSell(ALICE, aliceTokens / 2, 0);
        _quotedSell(BOB, bobTokens / 3, 0);
        uint256 curveFees = curve.totalFees();
        assertGt(curveFees, 0);
        uint256 lpStockBefore = IERC20(GME).balanceOf(address(PM));
        uint256 treasuryStockBefore = IERC20(GME).balanceOf(curve.treasury());
        uint256 routeStockBeforeFinal = IERC20(GME).balanceOf(ROUTE_POOL);
        (, uint256 finalRefund) = _quotedBuy(BOB, 250e6, 0);
        assertEq(uint256(curve.status()), 2); assertGt(finalRefund, 0);
        uint256 lpStock = IERC20(GME).balanceOf(address(PM)) - lpStockBefore;
        uint256 treasuryStock = IERC20(GME).balanceOf(curve.treasury()) - treasuryStockBefore;
        assertGt(lpStock, 0); assertGt(treasuryStock, 0);
        uint256 lpBudget = Math.mulDiv(lpStock + treasuryStock, V2TreasuryDeployer(address(factory.treasuryDeployer())).lpBpsOfTreasury(curve.treasury()), 10_000);
        assertLe(lpStock, lpBudget, "LP seed may not exceed its allocation");
        assertLe(lpBudget - lpStock, 1e12, "LP allocation must be used within GME dust");
        console2.log("Live graduation LP GME raw:", lpStock);
        console2.log("Live graduation treasury GME raw:", treasuryStock);
        assertGt(PM.getLiquidity(key.toId()), 0, "production V4 manager holds graduated position");
        uint256 finalPayment = routeStockBeforeFinal - IERC20(GME).balanceOf(ROUTE_POOL) - finalRefund;
        assertEq(curve.totalFees(), curveFees + Math.mulDiv(finalPayment, curve.taxBps(), 10_000),
            "graduation preserves prior liabilities and adds only the crossing buy's base fee");
        assertEq(hook.buyRateBps(key.toId()), 1000); assertEq(hook.sellRateBps(key.toId()), 1000);
        _claimCurveFees();
        (uint256 aAfter,) = _quotedBuy(ALICE, 5e6, 2);
        (uint256 bAfter,) = _quotedBuy(BOB, 5e6, 2);
        _quotedSell(ALICE, aAfter, 2); _quotedSell(BOB, bAfter, 2);
        _sweepV4Fees();
        V2LiquidityVault vault = V2LiquidityVault(hook.liquidityVaultOf(key.toId()));
        HedgeFunV2Treasury treasury = HedgeFunV2Treasury(curve.treasury());
        uint128 liquidityBefore = PM.getLiquidity(key.toId());
        uint256 buybackBefore = treasury.buybackStock();
        uint256 supplyBefore = token.totalSupply();
        (uint256 stockFee, uint256 funFeeBurned) = vault.collectFees();
        assertGt(stockFee, 0, "live V4 trades must produce a stock-side LP fee");
        assertEq(treasury.buybackStock(), buybackBefore + stockFee);
        assertEq(token.totalSupply(), supplyBefore - funFeeBurned);
        assertEq(PM.getLiquidity(key.toId()), liquidityBefore);
        _assertClean();
        // The earlier post-graduation buys left FUN above the trusted graduation
        // anchor, so a treasury buyback correctly refuses to chase that price.
        // Exercise a genuine market sell to return the pool to an executable level.
        // The original 50/50 scenario also proves the graduation-anchor chase gate. Custom LP depth experiments
        // exercise configuration, launch freezing, graduation and settlement without assuming the same trade sizes
        // cross that economic threshold.
        if (V2TreasuryDeployer(address(factory.treasuryDeployer())).lpBpsOfTreasury(curve.treasury()) == 5000) {
            _assertChasingPriceBlockedWhenApplicable(treasury);
        }
        _quotedSell(ALICE, token.balanceOf(ALICE) / 2, 2);
        // Run the actual treasury against the live forked V4 manager.
        _buybackFromCollectedFees(treasury, stockFee);
        console2.log("Live V4 LP stock fee GME raw:", stockFee);
        console2.log("Live V4 LP FUN fee burned raw:", funFeeBurned);
        console2.log("Final graduation GME refund (raw):", finalRefund);
        console2.log("Live V2 V3/V4 trades, fee settlement and treasury buyback burn passed");
    }

    /// Register and select the shipped kind-1 code, then take it through the real forked V3 route, curve
    /// graduation and deployed V4 manager. This closes the gap between the fixture lifecycle tests and the
    /// deployment rehearsal: kind 1 books its graduation share as buyback budget and spends it only by buying
    /// and burning FUN from the live V4 pool.
    function test_fork_kindOneRegistersLaunchesGraduatesAndBuysBackOnLiveVenue() public {
        _setUpForkKind(1);
        _quotedBuy(ALICE, 10e6, 0);
        _quotedBuy(BOB, 10e6, 0);
        (, uint256 finalRefund) = _quotedBuy(BOB, 250e6, 0);
        assertEq(uint256(curve.status()), 2);
        assertGt(finalRefund, 0);
        assertGt(PM.getLiquidity(key.toId()), 0, "kind 1 must graduate into the deployed V4 manager");

        HedgeFunV2BuybackTreasury treasury = HedgeFunV2BuybackTreasury(curve.treasury());
        uint256 budget = treasury.buybackStock();
        assertGt(budget, 0, "kind 1 books its real GME graduation share as buyback budget");
        assertEq(treasury.bookedStock(), 0);
        assertEq(treasury.lotCount(), 0);
        assertEq(treasury.unbookedStock(), 0);
        vm.expectRevert(HedgeFunV2BuybackTreasury.UseBuyback.selector);
        treasury.execute();

        uint256 supplyBefore = token.totalSupply();
        vm.prank(BOT);
        (uint256 spent, uint256 burned) = treasury.buyback();
        assertGt(spent, 0);
        assertGt(burned, 0);
        assertEq(treasury.buybackStock(), budget - spent);
        assertEq(token.totalSupply(), supplyBefore - burned);
        assertEq(treasury.lotCount(), 0);
        _assertClean();
        console2.log("Live kind-1 graduation budget GME raw:", budget);
        console2.log("Live kind-1 buyback spent GME raw:", spent);
        console2.log("Live kind-1 buyback burned FUN raw:", burned);
    }

    /// The selected 3% fee schedule on deployed stock/V3/V4 contracts: a V4 buy's fee is a stock claim from the
    /// swap itself, and one permissionless sweep pays it out with nothing left to convert.
    function test_fork_selectedThreePercentBuyFeesAreStockAndSplit() public {
        _setUpForkKindAndTax(0, 300);
        _quotedBuy(ALICE, 250e6, 0);
        assertEq(uint256(curve.status()), 2);
        _quotedBuy(BOB, 5e6, 2);
        (uint256 taxTokens, uint256 stockTax) = hook.accrued(key.toId());
        assertEq(taxTokens, 0, "the buy fee is never held in the token");
        assertGt(stockTax, 0);
        assertEq(PM.balanceOf(address(hook), uint256(uint160(address(token)))), 0);
        assertEq(PM.balanceOf(address(hook), uint256(uint160(GME))), stockTax);
        uint256 supplyBefore = token.totalSupply();
        uint256 protocolBefore = IERC20(GME).balanceOf(PROTOCOL);
        uint256 creatorBefore = IERC20(GME).balanceOf(CREATOR);
        uint256 treasuryBefore = IERC20(GME).balanceOf(curve.treasury());
        vm.prank(BOT); hook.sweep(key.toId());
        assertEq(token.totalSupply(), supplyBefore, "the basic buy fee burns nothing");
        uint256 protocolPaid = IERC20(GME).balanceOf(PROTOCOL) - protocolBefore;
        uint256 creatorPaid = IERC20(GME).balanceOf(CREATOR) - creatorBefore;
        uint256 treasuryPaid = IERC20(GME).balanceOf(curve.treasury()) - treasuryBefore;
        assertEq(protocolPaid, Math.mulDiv(stockTax, 2000, 10_000));
        assertEq(creatorPaid, Math.mulDiv(stockTax, 1000, 10_000));
        assertEq(protocolPaid + creatorPaid + treasuryPaid, stockTax);
        assertEq(PM.balanceOf(address(hook), uint256(uint160(GME))), 0);
        _assertClean();
        console2.log("Live 3% buy fee GME raw:", stockTax);
        console2.log("Live protocol/creator/treasury GME payouts raw:", protocolPaid, creatorPaid, treasuryPaid);
    }

    /// Three ordered same-timestamp calls against the real USDG/GME V3 route and a fork-local V2 curve.
    /// The snapshot makes the victim-only quote and the attacked execution start from identical venue state.
    function test_fork_curveUserBuySandwichedByBot() public {
        _curveSandwich(false);
    }

    function test_fork_curveUserTightMinOutRejectsSandwich() public {
        _curveSandwich(true);
    }

    function _curveSandwich(bool tight) private {
        _setUpFork();
        vm.warp(block.timestamp + 4); // avoid mixing opening-window tax with the sandwich measurement
        SandwichCurveMeasure memory s;
        s.botStartUsd = IERC20(USDG).balanceOf(BOT);
        s.aliceStartUsd = IERC20(USDG).balanceOf(ALICE);
        uint256 state = vm.snapshotState();
        Router.TradeParams memory user = _params(30e6, 0);
        user.allowPartialFill = false;
        uint256 routeStockBefore = IERC20(GME).balanceOf(ROUTE_POOL);
        vm.prank(ALICE);
        (s.cleanOut,) = router.buy(user, _path(true));
        s.cleanStock = routeStockBefore - IERC20(GME).balanceOf(ROUTE_POOL);
        assertEq(uint256(curve.status()), 0, "victim-only buy must stay on the curve");
        assertTrue(vm.revertToState(state));

        Router.TradeParams memory front = _params(1e6, 0);
        front.allowPartialFill = false;
        s.frontGas = gasleft();
        vm.prank(BOT);
        (s.botTokens,) = router.buy(front, _path(true));
        s.frontGas -= gasleft();
        assertEq(uint256(curve.status()), 0, "bot front-run must not graduate the curve");
        assertGt(s.botTokens, 0);

        user.minFinalOut = s.cleanOut * (tight ? 99 : 80) / 100;
        user.minStockReceived = s.cleanStock * 99 / 100;
        if (tight) {
            vm.prank(ALICE);
            vm.expectPartialRevert(Router.TooLittle.selector);
            router.buy(user, _path(true));
            assertEq(IERC20(USDG).balanceOf(ALICE), s.aliceStartUsd);
            assertEq(token.balanceOf(ALICE), 0);
        } else {
            vm.prank(ALICE);
            (s.attackedOut,) = router.buy(user, _path(true));
            assertLt(s.attackedOut, s.cleanOut, "front-run must worsen the victim execution");
            assertEq(IERC20(USDG).balanceOf(ALICE), s.aliceStartUsd - 30e6);
        }
        Router.TradeParams memory unwind = _params(s.botTokens, 0);
        unwind.allowPartialFill = false;
        s.backGas = gasleft();
        vm.prank(BOT);
        (s.botProceeds,) = router.sell(unwind, _path(false));
        s.backGas -= gasleft();
        assertEq(token.balanceOf(BOT), 0, "bot must close its strategy-token position");
        assertEq(IERC20(GME).balanceOf(BOT), 0, "bot must have no stock refund");
        assertEq(IERC20(USDG).balanceOf(BOT), s.botStartUsd - 1e6 + s.botProceeds);
        assertEq(uint256(curve.status()), 0);
        if (tight) assertLt(s.botProceeds, 1e6, "rejected victim buy must leave this bot losing after unwind");
        else assertGt(s.botProceeds, 1e6, "this loose floor permits a profitable gross round trip");
        _assertClean();
        console2.log(tight ? "CURVE TIGHT MIN-OUT" : "CURVE LOOSE MIN-OUT");
        console2.log("clean victim FUN raw", s.cleanOut);
        console2.log("attacked victim FUN raw", s.attackedOut);
        console2.log("victim stock route floor raw", user.minStockReceived);
        console2.log("bot gross USDG proceeds raw", s.botProceeds);
        console2.logInt(int256(s.botProceeds) - 1e6);
        console2.log("bot front/back EVM gas units", s.frontGas, s.backGas);
    }
}
