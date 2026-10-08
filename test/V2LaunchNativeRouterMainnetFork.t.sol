// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {HedgeFunFactory, TokenDeployer} from "../src/HedgeFunFactory.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";
import {HedgeFunV2Hook} from "../src/hooks/HedgeFunV2Hook.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {CurveDeployer} from "../src/v2/CurveDeployer.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {HedgeFunV2TradeRouter as TradeRouter} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {HedgeFunV2LaunchNativeRouter as LaunchRouter} from "../src/v2/HedgeFunV2LaunchNativeRouter.sol";
import {IWrappedNative} from "../src/v2/HedgeFunV2NativeRouter.sol";
import {IUniswapV3Factory, IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";
import {AlwaysOpen, IAgg} from "./mocks/Mocks.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// Real mainnet WETH, USDG, GME, canonical V3 pools and deployed V4 manager. The V2 contracts
/// are created inside the fork; vm.deal funds only the test creator. No transaction is broadcast.
/// Run: RH_FORK=1 RH_RPC=blockmachine forge test --threads 1 --mc V2LaunchNativeRouterMainnetForkTest -vv
contract V2LaunchNativeRouterMainnetForkTest is Test, HookMiner {
    IPoolManager private constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IUniswapV3Factory private constant V3_FACTORY = IUniswapV3Factory(0x1f7d7550B1b028f7571E69A784071F0205FD2EfA);
    address private constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address private constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address private constant GME = 0x1b0E319c6A659F002271B69dB8A7df2F911c153E;
    address private constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address private constant GME_FEED = 0x27C71df6A64fB476468EdF256CF72c038baB5B67;
    address private constant WETH_USDG_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address private constant GME_USDG_POOL = 0xE9713f453aDB9245B19559790c96F470a18F2fDF;
    address private constant GME_LISTING_POOL = 0xE2b46c905E12Ab8E2f864e4821a4325884C1B126;
    address private constant OWNER = address(0xA11CE);
    address private constant PROTOCOL = address(0x5AFE);
    address private constant CREATOR = address(0xC4EA704);
    uint256 private constant FEE = 0.01 ether;
    uint256 private constant BUY = 0.003 ether;

    HedgeFunV2Factory private factory;
    TradeRouter private trade;
    LaunchRouter private launcher;
    address private predictedToken;
    bytes32 private terms;
    uint256 private openPrice;

    struct Quote {
        uint256 tokens;
        uint256 stock;
        uint256 refund;
    }

    struct Balances {
        uint256 creatorEth;
        uint256 protocolEth;
        uint256 creatorGme;
        uint256 wethSupply;
        uint256 wethPool;
        uint256 usdgPool;
        uint256 gmePool;
    }

    function _refresh(address feed) private {
        (uint80 round, int256 answer,,,) = IAgg(feed).latestRoundData();
        vm.mockCall(
            feed,
            abi.encodeWithSelector(IAgg.latestRoundData.selector),
            abi.encode(round, answer, block.timestamp, block.timestamp, round)
        );
    }

    function _defaults() private pure returns (HedgeFunFactory.Defaults memory d) {
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
        d.bountyBps = 50;
        d.maxSlippageBps = 100;
        d.maxDeviationBps = 50;
        d.maxBuybackImpactBps = 300;
        d.buybackCooldown = 60;
        d.minLotUsdg = 5e6;
        d.buybackChunkUsdg = 500e6;
        d.sellChunkUsdg = type(uint128).max;
        d.launchFeeCurrency = HedgeFunFactory.FeeCurrency.Native;
        d.launchFeeAmount = FEE;
    }

    function _path() private pure returns (TradeRouter.Hop[] memory path) {
        path = new TradeRouter.Hop[](2);
        path[0] = TradeRouter.Hop(WETH_USDG_POOL, USDG);
        path[1] = TradeRouter.Hop(GME_USDG_POOL, GME);
    }

    function _request(uint256 openingPrice) private pure returns (HedgeFunFactory.Request memory q) {
        q.name = "Native mainnet fork launch";
        q.symbol = "NATIVEGMEFORK";
        q.stock = GME;
        q.creator = CREATOR;
        q.taxBps = 1000;
        q.creatorBps = 1000;
        q.tp1Bps = 3000;
        q.tp2Bps = 6000;
        q.dipBps = 800;
        q.lotBps = 5000;
        q.nonce = 20261001;
        q.maxFee = FEE;
        q.expectedOpenPriceE18 = openingPrice;
    }

    function _setUpFork() private {
        vm.skip(vm.envOr("RH_FORK", uint256(0)) == 0, "fork test: set RH_FORK=1");
        string memory rpc = vm.envOr("RH_RPC", string("blockmachine"));
        uint256 pinnedBlock = vm.envOr("RH_FORK_BLOCK", uint256(70_786_980));
        if (pinnedBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pinnedBlock);
        console2.log("V2 native launch mainnet fork block:", block.number);

        assertGt(address(PM).code.length, 0);
        assertGt(WETH.code.length, 0);
        assertEq(V3_FACTORY.getPool(WETH, USDG, IUniswapV3Pool(WETH_USDG_POOL).fee()), WETH_USDG_POOL);
        assertEq(V3_FACTORY.getPool(USDG, GME, IUniswapV3Pool(GME_USDG_POOL).fee()), GME_USDG_POOL);
        assertGt(IERC20(WETH).balanceOf(WETH_USDG_POOL), 0);
        assertGt(IERC20(USDG).balanceOf(WETH_USDG_POOL), 0);
        assertGt(IERC20(GME).balanceOf(GME_USDG_POOL), 0);

        _refresh(USDG_FEED);
        _refresh(GME_FEED);
        PriceOracle oracle = new PriceOracle(GME, GME_FEED, USDG_FEED, address(new AlwaysOpen()), 26 hours, 26 hours);
        openPrice = Math.mulDiv(25e18, 1e18, oracle.price()) / 1_000_000;
        HedgeFunV2Hook hook = _deployV2Hook(PM);
        factory = new HedgeFunV2Factory(
            OWNER,
            address(PM),
            address(V3_FACTORY),
            USDG,
            PROTOCOL,
            address(new V2TreasuryDeployer()),
            address(new TokenDeployer()),
            address(hook),
            address(new CurveDeployer(8000)),
            _defaults()
        );
        vm.startPrank(OWNER);
        factory.list(GME, address(oracle), GME_LISTING_POOL, openPrice, true);
        factory.setPublicLaunch(true);
        vm.stopPrank();
        trade = new TradeRouter(factory);
        launcher = new LaunchRouter(trade, IWrappedNative(WETH));
        vm.prank(OWNER);
        factory.setLauncher(address(launcher), true);

        HedgeFunFactory.Request memory q = _request(openPrice);
        vm.prank(CREATOR);
        factory.curveDeployer().setCurveConfig(q.symbol, q.nonce, 8000, 3);
        (predictedToken,, terms) = factory.predict(q);
        vm.deal(CREATOR, 1 ether);
    }

    function _info() private pure returns (HedgeFunToken.Info memory info) {
        info.description = "Native mainnet fork first buy";
    }

    function _params(uint256 minStock, uint256 minTokens) private view returns (LaunchRouter.BuyParams memory) {
        return LaunchRouter.BuyParams(BUY, minStock, minTokens, block.timestamp + 300, true);
    }

    function _quote() private returns (Quote memory result) {
        uint256 snapshot = vm.snapshotState();
        uint256 gmePoolBefore = IERC20(GME).balanceOf(GME_USDG_POOL);
        vm.prank(CREATOR);
        (uint256 id, uint256 tokens, uint256 refund) =
            launcher.launchAndBuy{value: FEE + BUY}(_request(openPrice), terms, _info(), _params(1, 1), _path());
        result = Quote(tokens, gmePoolBefore - IERC20(GME).balanceOf(GME_USDG_POOL), refund);
        assertEq(id, 0);
        assertGt(result.tokens, 0);
        assertGt(result.stock, 0);
        assertTrue(vm.revertToState(snapshot));
    }

    function _balances() private view returns (Balances memory b) {
        b.creatorEth = CREATOR.balance;
        b.protocolEth = PROTOCOL.balance;
        b.creatorGme = IERC20(GME).balanceOf(CREATOR);
        b.wethSupply = IERC20(WETH).totalSupply();
        b.wethPool = IERC20(WETH).balanceOf(WETH_USDG_POOL);
        b.usdgPool = IERC20(USDG).balanceOf(WETH_USDG_POOL);
        b.gmePool = IERC20(GME).balanceOf(GME_USDG_POOL);
    }

    function _assertRollback(Quote memory quote, Balances memory before_) private {
        // The final output floor fails after fee payment, WETH deposit and both live V3 swaps.
        // All of them must roll back together with the predicted CREATE2 launch.
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(TradeRouter.TooLittle.selector, quote.tokens));
        launcher.launchAndBuy{value: FEE + BUY}(
            _request(openPrice), terms, _info(), _params(quote.stock, quote.tokens + 1), _path()
        );
        assertEq(factory.strategyCount(), 0);
        assertEq(predictedToken.code.length, 0);
        Balances memory after_ = _balances();
        assertEq(after_.creatorEth, before_.creatorEth);
        assertEq(after_.protocolEth, before_.protocolEth);
        assertEq(after_.creatorGme, before_.creatorGme);
        assertEq(after_.wethSupply, before_.wethSupply);
        assertEq(after_.wethPool, before_.wethPool);
        assertEq(after_.usdgPool, before_.usdgPool);
        assertEq(after_.gmePool, before_.gmePool);
    }

    function _assertSuccess(Quote memory quote, Balances memory before_) private {
        vm.prank(CREATOR);
        (uint256 id, uint256 tokensOut, uint256 stockRefund) = launcher.launchAndBuy{value: FEE + BUY}(
            _request(openPrice), terms, _info(), _params(quote.stock, quote.tokens), _path()
        );
        assertEq(id, 0);
        assertEq(tokensOut, quote.tokens);
        assertEq(stockRefund, quote.refund);
        assertEq(factory.strategyCount(), 1);
        assertEq(factory.predictToken(_request(openPrice)), predictedToken);
        assertEq(HedgeFunToken(predictedToken).balanceOf(CREATOR), tokensOut);
        assertEq(HedgeFunToken(predictedToken).description(), "Native mainnet fork first buy");
        assertEq(uint8(HedgeFunBondingCurve(factory.curves(id)).status()), 0);
        assertEq(CREATOR.balance, before_.creatorEth - FEE - BUY);
        assertEq(PROTOCOL.balance, before_.protocolEth + FEE);
        assertEq(IERC20(WETH).totalSupply(), before_.wethSupply + BUY);
        assertEq(IERC20(WETH).balanceOf(WETH_USDG_POOL), before_.wethPool + BUY);
        assertEq(before_.gmePool - IERC20(GME).balanceOf(GME_USDG_POOL), quote.stock);
        assertEq(IERC20(GME).balanceOf(CREATOR), before_.creatorGme + stockRefund);
        assertEq(address(launcher).balance, 0);
        assertEq(IERC20(WETH).balanceOf(address(launcher)), 0);
        assertEq(IERC20(USDG).balanceOf(address(launcher)), 0);
        assertEq(IERC20(GME).balanceOf(address(launcher)), 0);
        assertEq(IERC20(WETH).allowance(address(launcher), address(trade)), 0);
        assertEq(IERC20(WETH).balanceOf(address(trade)), 0);
        assertEq(IERC20(USDG).balanceOf(address(trade)), 0);
        assertEq(IERC20(GME).balanceOf(address(trade)), 0);
    }

    function test_fork_nativeLaunchAndFirstBuy_realWethUsdgGmePools_andAtomicRollback() public {
        _setUpFork();
        Quote memory quote = _quote();
        Balances memory before_ = _balances();
        _assertRollback(quote, before_);
        _assertSuccess(quote, before_);
    }
}
