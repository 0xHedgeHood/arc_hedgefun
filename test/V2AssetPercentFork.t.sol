// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {HedgeFunFactory, TokenDeployer} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunV2AssetPercentEngineTreasury} from "../src/v2/HedgeFunV2AssetPercentEngineTreasury.sol";
import {V2LiquidityVault} from "../src/v2/V2LiquidityVault.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {CurveDeployer} from "../src/v2/CurveDeployer.sol";
import {V2AssetPercentRebalancePolicy} from "../src/v2/strategy/V2AssetPercentRebalancePolicy.sol";
import {EngineConfig, StrategyAction} from "../src/v2/strategy/IStrategyPolicy.sol";
import {AlwaysOpen, IAgg} from "./mocks/Mocks.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {FundAssetMath} from "./utils/FundAssetMath.sol";

/// @notice Opt-in mainnet-state execution simulation, not historical returns or a broadcast.
/// Genuine GME/USDG tokens, listing V3 venue and V4 manager at block 70786980; new factory/policy/kind,
/// fund and locked LP exist only in this fork. Funding uses real transfers from an impersonated deep pool.
/// Feed answers are the pinned chain's answers; only their timestamps are refreshed. AlwaysOpen isolates
/// the execution tests from market-calendar wall time. No swap, balance or asset-reader call is mocked.
/// Run: RH_FORK=1 RH_RPC=blockmachine V2_LP_BPS=5000 forge test --threads 1 --mc V2AssetPercentForkTest -vv
/// The same four tests also support V2_LP_BPS=7000; archive access to the pinned block is required.
contract V2AssetPercentForkTest is Test, HookMiner {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager private constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address private constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address private constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address private constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address private constant GME = 0x1b0E319c6A659F002271B69dB8A7df2F911c153E;
    address private constant GME_FEED = 0x27C71df6A64fB476468EdF256CF72c038baB5B67;
    address private constant MARKET = 0xE2b46c905E12Ab8E2f864e4821a4325884C1B126;
    address private constant FUNDING_POOL = 0xE9713f453aDB9245B19559790c96F470a18F2fDF;
    address private constant OWNER = address(0xA11CE);
    address private constant CREATOR = address(0xC4EA704);
    address private constant BUYER = address(0xB0B);
    address private constant KEEPER = address(0xB07);
    uint256 private constant PINNED_BLOCK = 70_786_980;
    uint256 private constant SCALE = 1e30;

    PriceOracle private oracle;
    HedgeFunV2AssetPercentEngineTreasury private treasury;
    V2LiquidityVault private vault;
    PoolKey private key;
    uint256 private price;
    uint256 private chunk;
    uint256 private tradeBps;
    uint256 private dailyBps;

    struct Risk { bool healthy; uint256 nav; uint256 trade; uint256 daily; uint256 remaining; uint64 epoch; uint256 used; }
    struct Before { uint256 held; uint256 cash; uint256 bb; uint256 keeperStock; uint256 keeperCash; uint256 actualTreasuryStock; }

    function _refresh(address feed) private {
        (uint80 round, int256 answer,,,) = IAgg(feed).latestRoundData();
        vm.mockCall(feed, abi.encodeWithSelector(IAgg.latestRoundData.selector),
            abi.encode(round, answer, block.timestamp, block.timestamp, round));
    }
    function _advance(uint256 seconds_) private {
        vm.warp(block.timestamp + seconds_); _refresh(GME_FEED); _refresh(USDG_FEED);
    }
    function _transferFromPool(address asset, address to, uint256 amount) private {
        vm.prank(FUNDING_POOL); assertTrue(IERC20(asset).transfer(to, amount));
    }
    function _defaults(uint256 chunk_) private pure returns (HedgeFunFactory.Defaults memory d) {
        d.supply = 1_000_000e18; d.lpFee = 3000; d.tickSpacing = 60;
        d.minTaxBps = 100; d.maxTaxBps = 1500; d.protocolBps = 2000; d.maxCreatorBps = 3000;
        d.spikeBps = 9000; d.spikeSeconds = 120; d.snipeBps = 9900; d.snipeSeconds = 3;
        d.bountyBps = 50; d.maxSlippageBps = 100; d.maxDeviationBps = 50;
        d.maxBuybackImpactBps = 300; d.buybackCooldown = 60; d.minLotUsdg = 5e6;
        d.buybackChunkUsdg = 500e6; d.sellChunkUsdg = chunk_;
    }
    function _setup(uint256 trade_, uint256 daily_, uint256 chunk_) private {
        vm.skip(vm.envOr("RH_FORK", uint256(0)) == 0, "set RH_FORK=1; pinned live-venue simulation, no broadcast");
        vm.createSelectFork(vm.envOr("RH_RPC", string("blockmachine")), PINNED_BLOCK);
        assertEq(block.chainid, 4663); assertEq(block.number, PINNED_BLOCK);
        assertGt(address(PM).code.length, 0); assertGt(MARKET.code.length, 0);
        assertGt(GME.code.length, 0); assertGt(USDG.code.length, 0);
        assertGt(GME_FEED.code.length, 0); assertGt(USDG_FEED.code.length, 0);
        _refresh(GME_FEED); _refresh(USDG_FEED);
        oracle = new PriceOracle(GME, GME_FEED, USDG_FEED, address(new AlwaysOpen()), 26 hours, 26 hours);
        price = oracle.price(); chunk = chunk_; tradeBps = trade_; dailyBps = daily_;
        HedgeFunV2Factory factory = new HedgeFunV2Factory(OWNER, address(PM), V3_FACTORY, USDG, address(0x5AFE),
            address(new V2TreasuryDeployer()), address(new TokenDeployer()), address(_deployV2Hook(PM)),
            address(new CurveDeployer(8000)), _defaults(chunk_));
        V2TreasuryDeployer deployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        V2AssetPercentRebalancePolicy policy = new V2AssetPercentRebalancePolicy();
        (address a, address b) = deployer.makeChunks(type(HedgeFunV2AssetPercentEngineTreasury).creationCode);
        uint256 lp = vm.envOr("V2_LP_BPS", uint256(5000)); require(lp == 5000 || lp == 7000, "fork LP profile");
        uint256 initialPrice = Math.mulDiv(25e18, 1e18, price) / 1_000_000;
        vm.startPrank(OWNER);
        bytes32 policyKey = deployer.registerPolicy(address(policy), 150_000, 160,
            keccak256("asset-percent-fork-dependencies"), keccak256("asset-percent-fork-audit"));
        uint8 kind = deployer.registerEngineKind(a, b, 1, 2, 3);
        deployer.setLpBps(GME, uint16(lp));
        factory.list(GME, address(oracle), MARKET, initialPrice, true); factory.setPublicLaunch(true);
        vm.stopPrank();
        _launch(factory, deployer, kind, policyKey, initialPrice);
        assertEq(deployer.lpBpsOfTreasury(address(treasury)), lp);
        _assertRisk();
        console2.log("Asset-percent pinned fork block:", block.number);
        console2.log("Asset-percent frozen LP bps:", lp);
        console2.log("Asset-percent GME/USDG oracle price E18:", price);
    }
    function _launch(HedgeFunV2Factory factory, V2TreasuryDeployer deployer, uint8 kind, bytes32 policyKey, uint256 initialPrice)
        private
    {
        HedgeFunFactory.Request memory q;
        q.name = "Asset-percent live venue fork only"; q.symbol = "V2APFORK";
        q.stock = GME; q.creator = CREATOR; q.taxBps = 1000; q.creatorBps = 1000;
        q.tp1Bps = 3000; q.tp2Bps = 6000; q.dipBps = 800; q.lotBps = 5000;
        q.expectedOpenPriceE18 = initialPrice;
        EngineConfig memory c = EngineConfig(2, 1, policyKey, [
            bytes32(uint256(7000) | uint256(500) << 16 | uint256(600) << 32), bytes32(tradeBps), bytes32(dailyBps)
        ]);
        vm.startPrank(CREATOR);
        deployer.setEngineConfig(q.symbol, q.nonce, kind, c);
        factory.curveDeployer().setCurveConfig(q.symbol, q.nonce, 8000, 3);
        (, address predicted, bytes32 terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        vm.stopPrank();
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        treasury = HedgeFunV2AssetPercentEngineTreasury(curve.treasury()); assertEq(address(treasury), predicted);
        _transferFromPool(GME, BUYER, 20e18);
        vm.prank(BUYER); IERC20(GME).approve(address(curve), type(uint256).max);
        _advance(4);
        (uint256 needed, uint256 expected,) = curve.quoteBuy(type(uint256).max);
        vm.prank(BUYER); (uint256 spent, uint256 got) = curve.buy(needed, expected, BUYER, block.timestamp);
        assertEq(spent, needed); assertEq(got, expected);
        assertEq(uint256(curve.status()), uint256(HedgeFunBondingCurve.Status.Graduated));
        (key,) = factory.graduationConfig(id);
        vault = V2LiquidityVault(treasury.liquidityVault()); assertTrue(vault.seeded());
        (uint128 owned,,) = PM.getPositionInfo(key.toId(), address(vault), TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing), bytes32(0));
        assertGt(owned, 0); assertGt(treasury.bookedStock(), 0);
        assertEq(treasury.engineConfig().schema, 2); assertEq(treasury.policyGasLimit(), 150_000);
        (bool healthy, uint256 p) = treasury.health(); assertTrue(healthy); assertEq(p, price);
    }
    function _risk() private view returns (Risk memory r) {
        (r.healthy, r.nav, r.trade, r.daily, r.remaining, r.epoch, r.used) = treasury.riskLimits();
    }
    function _assertRisk() private view returns (Risk memory r) {
        r = _risk(); assertTrue(r.healthy);
        // The ghost reads actual token balances and own position directly, never production reader/riskLimits.
        assertEq(r.nav, FundAssetMath.nav(treasury, IERC20(GME), price, SCALE));
        assertEq(r.trade, Math.min(Math.mulDiv(r.nav, tradeBps, 10000), chunk));
        assertEq(r.daily, Math.mulDiv(r.nav, dailyBps, 10000));
        assertEq(r.remaining, r.daily > r.used ? r.daily - r.used : 0);
    }
    function _before() private view returns (Before memory b) {
        b.held = treasury.bookedStock(); b.cash = treasury.reserveUsdg(); b.bb = treasury.buybackStock();
        b.keeperStock = IERC20(GME).balanceOf(KEEPER); b.keeperCash = IERC20(USDG).balanceOf(KEEPER);
        b.actualTreasuryStock = IERC20(GME).balanceOf(address(treasury));
    }
    function _digest() private view returns (bytes32) {
        return keccak256(abi.encode(treasury.strategyNonce(), treasury.turnoverEpoch(), treasury.turnoverInEpoch(),
            treasury.lastStrategyAt(), treasury.policyState(), treasury.bookedStock(), treasury.avgCost(),
            treasury.buybackStock(), IERC20(GME).balanceOf(address(treasury)), treasury.reserveUsdg()));
    }
    function _wait() private {
        bytes32 before_ = _digest();
        (bool due, StrategyAction action, uint256 amount) = treasury.preview();
        assertFalse(due); assertEq(uint256(action), uint256(StrategyAction.Hold)); assertEq(amount, 0);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector); vm.prank(KEEPER); treasury.execute();
        assertEq(_digest(), before_, "wait/dust cannot consume inventory, nonce, cooldown or ledger");
    }

    function test_forkSellUsesFullNavAndPaysActualOutputReward() public {
        _setup(1000, 5000, type(uint128).max);
        Risk memory r = _assertRisk(); Before memory b = _before();
        uint256 tradable = Math.mulDiv(b.held, price, SCALE) + b.cash;
        assertGt(r.nav, tradable, "owned locked LP stock belongs to full NAV");
        (bool due, StrategyAction action, uint256 offered) = treasury.preview(); assertTrue(due);
        assertEq(uint256(action), uint256(StrategyAction.SellStock));
        uint256 value = Math.mulDiv(offered, price, SCALE);
        assertGt(value, Math.mulDiv(tradable, 1000, 10000)); assertLe(value, r.trade);
        vm.prank(KEEPER); (HedgeFunV2Treasury.Action executed,) = treasury.execute();
        assertEq(uint256(executed), uint256(HedgeFunV2Treasury.Action.RebalanceSell));
        uint256 sold = b.held - treasury.bookedStock(); uint256 reward = IERC20(USDG).balanceOf(KEEPER) - b.keeperCash;
        uint256 gross = treasury.reserveUsdg() - b.cash + reward;
        assertEq(sold, offered);
        assertEq(b.actualTreasuryStock - IERC20(GME).balanceOf(address(treasury)), sold);
        assertGt(gross, 0); assertEq(reward, Math.mulDiv(gross, 50, 10000));
        assertEq(treasury.turnoverInEpoch(), Math.mulDiv(sold, price, SCALE));
        assertLe(treasury.turnoverInEpoch(), r.remaining); assertEq(treasury.strategyNonce(), 1);
        _assertRisk();
        console2.log("Sell full NAV USDG raw:", r.nav); console2.log("Sell cap USDG raw:", r.trade);
        console2.log("Sell actual turnover USDG raw:", treasury.turnoverInEpoch()); console2.log("Sell actual keeper USDG raw:", reward);
    }

    function test_forkBuyBandAndCooldownWaitWithoutConsumingState() public {
        _setup(1000, 5000, type(uint128).max);
        uint256 stockValue = Math.mulDiv(treasury.bookedStock(), price, SCALE);
        _transferFromPool(USDG, address(treasury), Math.mulDiv(stockValue, 3000, 7000));
        _wait(); // about 70% tradable stock, independently of locked LP assets
        _transferFromPool(USDG, address(treasury), 80e6);
        Risk memory r = _assertRisk(); Before memory b = _before();
        (bool due, StrategyAction action, uint256 offered) = treasury.preview(); assertTrue(due);
        assertEq(uint256(action), uint256(StrategyAction.BuyStock));
        vm.prank(KEEPER); treasury.execute();
        uint256 spent = b.cash - treasury.reserveUsdg(); uint256 retained = treasury.bookedStock() - b.held;
        uint256 reward = IERC20(GME).balanceOf(KEEPER) - b.keeperStock;
        assertEq(spent, offered); assertGt(retained, 0);
        assertEq(IERC20(GME).balanceOf(address(treasury)) - b.actualTreasuryStock, retained);
        assertEq(reward, Math.mulDiv(retained + reward, 50, 10000));
        assertEq(treasury.turnoverInEpoch(), spent); assertLe(spent, r.trade); assertLe(spent, r.remaining);
        uint256 used = treasury.turnoverInEpoch(); uint64 epoch = treasury.turnoverEpoch();
        _wait(); _advance(599); _wait(); _advance(1);
        (due, action,) = treasury.preview(); assertTrue(due); assertEq(uint256(action), uint256(StrategyAction.BuyStock));
        assertEq(treasury.turnoverInEpoch(), used); assertEq(treasury.turnoverEpoch(), epoch);
        _assertRisk();
        console2.log("Buy full NAV USDG raw:", r.nav); console2.log("Buy actual input USDG raw:", spent);
        console2.log("Buy keeper stock raw:", reward); console2.log("Same-session used after cooldown USDG raw:", used);
    }

    function test_forkOwnLpFeesCollectIntoBuybackWithoutDoubleCounting() public {
        _setup(1000, 5000, type(uint128).max);
        vm.prank(KEEPER); treasury.execute(); uint256 used = treasury.turnoverInEpoch(); uint64 epoch = treasury.turnoverEpoch();
        _advance(600);
        PoolSwapTest swapper = new PoolSwapTest(PM);
        vm.prank(BUYER); IERC20(GME).approve(address(swapper), type(uint256).max);
        bool stockFirst = Currency.unwrap(key.currency0) == GME;
        vm.prank(BUYER); swapper.swap(key, SwapParams(stockFirst, -int256(Math.mulDiv(5e6, SCALE, price)),
            stockFirst ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false), "");
        Risk memory before_ = _assertRisk(); uint256 bb = treasury.buybackStock();
        (uint256 stockFee,) = vault.collectFees(); assertGt(stockFee, 0);
        Risk memory after_ = _assertRisk();
        assertEq(after_.nav, before_.nav, "uncollected fee -> vault stock -> treasury BB counted once");
        assertEq(treasury.buybackStock(), bb + stockFee); assertEq(IERC20(GME).balanceOf(address(vault)), 0);
        assertEq(after_.used, used); assertEq(after_.epoch, epoch); assertEq(treasury.turnoverInEpoch(), used);
        uint256 tradable = Math.mulDiv(treasury.bookedStock() + treasury.unbookedStock(), price, SCALE) + treasury.reserveUsdg();
        assertGt(after_.nav, tradable + Math.mulDiv(treasury.buybackStock(), price, SCALE));
        console2.log("LP stock fee raw:", stockFee); console2.log("Fee collection NAV before USDG raw:", before_.nav);
        console2.log("Fee collection NAV after USDG raw:", after_.nav); console2.log("Fee collection unchanged used USDG raw:", used);
    }

    function test_forkChunkAndDynamicDailyBudgetKeepAbsoluteUsed() public {
        _setup(1000, 1000, 6e6);
        Risk memory r = _assertRisk(); assertEq(r.trade, 6e6);
        vm.prank(KEEPER); treasury.execute(); _advance(600);
        uint256 used = treasury.turnoverInEpoch(); uint64 epoch = treasury.turnoverEpoch();
        Risk memory depleted = _assertRisk(); assertLe(used, 6e6); assertGe(used, 5e6);
        assertLt(depleted.remaining, 5e6); _wait();
        _transferFromPool(USDG, address(treasury), 30e6);
        Risk memory grown = _assertRisk(); assertEq(grown.used, used); assertEq(grown.epoch, epoch);
        assertGt(grown.remaining, depleted.remaining);
        (bool due, StrategyAction action, uint256 offered) = treasury.preview(); assertTrue(due);
        assertEq(uint256(action), uint256(StrategyAction.BuyStock)); assertLe(offered, 6e6);
        vm.prank(KEEPER); treasury.execute();
        assertEq(treasury.turnoverInEpoch(), used + offered); assertLe(treasury.turnoverInEpoch(), grown.daily);
        assertEq(treasury.turnoverEpoch(), epoch); _assertRisk();
        console2.log("Frozen hard chunk USDG raw:", r.trade); console2.log("Depleted daily remaining USDG raw:", depleted.remaining);
        console2.log("Donation-reopened daily remaining USDG raw:", grown.remaining);
        console2.log("Cumulative absolute used USDG raw:", treasury.turnoverInEpoch());
    }
}
