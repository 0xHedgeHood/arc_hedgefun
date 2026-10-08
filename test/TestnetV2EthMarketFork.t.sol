// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TestnetV2EthMarket} from "../script/testnet/TestnetV2EthMarket.s.sol";
import {TestnetMarket, IV3Pool} from "../script/testnet/TestnetMarket.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {CurveDeployer} from "../src/v2/CurveDeployer.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter as Router} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {HedgeFunV2NativeRouter as Native} from "../src/v2/HedgeFunV2NativeRouter.sol";

contract NativeMarketRoleInvoker {
    function deploy(TestnetV2EthMarket tool, string memory json) external returns (TestnetV2EthMarket.Deployment memory) {
        return tool.deploy(json, sha256(bytes(json)));
    }
    function poke(TestnetV2EthMarket tool, TestnetV2EthMarket.Deployment memory x) external { tool.poke(x); }
    function activate(TestnetV2EthMarket tool, TestnetV2EthMarket.Deployment memory x) external { tool.activate(x); }
}

/// Opt-in local fork only. vm.deal funds the rehearsal with two native ETH; it is NOT evidence of faucet funding
/// or a live deployment. Real WETH deposit/withdraw, canonical V3 and deployed fee/creator routers execute here.
contract TestnetV2EthMarketForkTest is Test {
    address private constant OPERATOR = 0x75Cee941B0eF3A83feA0397BbF903C12c1D7e96D;
    address private constant CREATOR = 0xD4f69D180a9bc36F27D307E90E365d1E012816d5;
    TestnetV2EthMarket private tool;
    string private json;
    bool private enabled;
    struct Preserved {
        address factory; address registry; address market; address calendar;
        bytes32 factoryHash; bytes32 registryHash; bytes32 calendarHash; bytes32 listings; uint256 marketCount;
    }

    function setUp() public {
        enabled = vm.envOr("ETH_MARKET_FORK", false);
        if (!enabled) return;
        vm.createSelectFork("https://rpc.testnet.chain.robinhood.com", vm.envUint("ETH_MARKET_FORK_BLOCK"));
        json = vm.readFile(vm.envString("ETH_BASE_BOOK"));
        tool = new TestnetV2EthMarket();
        vm.etch(tool.OPERATOR(), address(new NativeMarketRoleInvoker()).code);
    }

    function test_actualOperatorBalanceStopsBeforeAnyNativeMarketTransaction() public {
        if (!enabled) { vm.skip(true); return; }
        uint256 balance = tool.OPERATOR().balance;
        assertLt(balance, tool.SEED_ETH() + tool.GAS_RESERVE());
        uint256 nonce = vm.getNonce(tool.OPERATOR());
        vm.expectRevert(abi.encodeWithSelector(TestnetV2EthMarket.InsufficientNative.selector, balance, tool.SEED_ETH() + tool.GAS_RESERVE()));
        NativeMarketRoleInvoker(OPERATOR).deploy(tool, json);
        assertEq(vm.getNonce(tool.OPERATOR()), nonce);
    }

    function test_realWrappedNativeVenueSupportsStockPaymentAndEthUnderlyingGraduationWithoutChangingEightListings() public {
        if (!enabled) { vm.skip(true); return; }
        Preserved memory original = _capture();
        // Explicit fork-only financing; the actual public wallet is tested separately as insufficient.
        vm.deal(tool.OPERATOR(), 2 ether);
        uint256 backingBefore = tool.WETH().balance; uint256 supplyBefore = IERC20(tool.WETH()).totalSupply();
        TestnetV2EthMarket.Deployment memory x = NativeMarketRoleInvoker(OPERATOR).deploy(tool, json);
        assertEq(tool.WETH().balance, backingBefore + 1 ether);
        assertEq(IERC20(tool.WETH()).totalSupply(), supplyBefore + 1 ether);
        (bool initiallyHealthy,) = x.oracle.tryPrice(); assertFalse(initiallyHealthy); assertFalse(x.calendar.isClosed(block.timestamp));
        vm.expectRevert(TestnetV2EthMarket.BadStage.selector); NativeMarketRoleInvoker(OPERATOR).activate(tool, x);
        vm.warp(x.initializedAt + 1); NativeMarketRoleInvoker(OPERATOR).poke(tool, x);
        (,,, uint16 cardinality, uint16 next,,) = IV3Pool(x.pool).slot0(); assertEq(cardinality, 720); assertEq(next, 720);
        vm.warp(x.initializedAt + 600); NativeMarketRoleInvoker(OPERATOR).activate(tool, x);
        _unchanged(original);
        _stockNativeRoundTrip(x);
        _ethUnderlyingGraduateAndTrade(x);
        _ethUnderlyingExplicitRefund(x);
        _unchanged(original);
    }

    function _capture() private view returns (Preserved memory x) {
        x.factory=vm.parseJsonAddress(json,".factory"); x.registry=vm.parseJsonAddress(json,".treasuryDeployer");
        x.market=vm.parseJsonAddress(json,".market"); x.calendar=vm.parseJsonAddress(json,".calendar");
        x.factoryHash=x.factory.codehash;x.registryHash=x.registry.codehash;x.calendarHash=x.calendar.codehash;
        x.listings=_stockSnapshot(x.factory,x.registry);x.marketCount=TestnetMarket(x.market).poolCount();
    }

    function _unchanged(Preserved memory x) private view {
        assertEq(_stockSnapshot(x.factory,x.registry),x.listings);assertEq(TestnetMarket(x.market).poolCount(),x.marketCount);
        assertEq(x.factory.codehash,x.factoryHash);assertEq(x.registry.codehash,x.registryHash);assertEq(x.calendar.codehash,x.calendarHash);
    }

    function _stockSnapshot(address factory, address registry) private view returns (bytes32 result) {
        string[] memory symbols = vm.parseJsonKeys(json, ".stocks"); assertEq(symbols.length, 8);
        for (uint256 i; i < symbols.length; ++i) {
            address stock = vm.parseJsonAddress(json, string.concat(".stocks.", symbols[i], ".token"));
            result = keccak256(abi.encode(result, _stockRow(factory, registry, stock)));
        }
    }

    function _stockRow(address factory, address registry, address stock) private view returns (bytes32) {
        return keccak256(abi.encode(_listingRow(factory,stock),_gatesRow(factory,registry,stock)));
    }

    function _listingRow(address factory,address stock) private view returns(bytes32) {
        (address oracle,address pool,uint256 opening,bool live)=HedgeFunV2Factory(factory).listings(stock);
        return keccak256(abi.encode(stock,oracle,pool,opening,live));
    }

    function _gatesRow(address factory,address registry,address stock) private view returns(bytes32) {
        (uint16 dev,uint16 slip,uint64 chunk)=HedgeFunV2Factory(factory).listingGates(stock);
        return keccak256(abi.encode(dev,slip,chunk,HedgeFunV2Factory(factory).bandCeiling(stock),V2TreasuryDeployer(registry).lpBps(stock)));
    }

    function _launch(TestnetV2EthMarket.Deployment memory x, address stock, string memory symbol, uint96 nonce)
        private returns (uint256 id, HedgeFunBondingCurve curve)
    {
        HedgeFunV2Factory f = HedgeFunV2Factory(x.base.factory);
        (,, uint256 openPrice,) = f.listings(stock);
        HedgeFunFactory.Request memory q;
        q.name = "Fork native asset rehearsal"; q.symbol = symbol; q.stock = stock; q.creator = CREATOR;
        q.taxBps = 300; q.creatorBps = 1000; q.tp1Bps = 300; q.tp2Bps = 600; q.dipBps = 300; q.stopBps = 0;
        q.lotBps = 2000; q.nonce = nonce; q.maxFee = f.getDefaults().launchFeeAmount; q.expectedOpenPriceE18 = openPrice;
        vm.startPrank(CREATOR);
        f.curveDeployer().setCurveConfig(q.symbol, q.nonce, 4400, 0);
        (,, bytes32 terms) = f.predict(q); assertTrue(IERC20(tool.USDG()).approve(address(f), q.maxFee));
        id = f.launch(q, terms); vm.stopPrank(); curve = HedgeFunBondingCurve(f.curves(id));
    }

    function _stockNativeRoundTrip(TestnetV2EthMarket.Deployment memory x) private {
        address stock = vm.parseJsonAddress(json, ".stocks.TSLA.token");
        address stockPool = vm.parseJsonAddress(json, ".stocks.TSLA.pool");
        (uint256 id, HedgeFunBondingCurve curve) = _launch(x, stock, "HFETHSTOCKFX", 202610010201);
        Native native = Native(payable(x.base.nativeRouter)); vm.deal(CREATOR, 2 ether);
        Router.Hop[] memory path = new Router.Hop[](2);
        path[0] = Router.Hop(x.pool, tool.USDG()); path[1] = Router.Hop(stockPool, stock);
        (uint256 exactInput, uint256 attempts) = _exactStockInput(native, id, path);
        emit log_named_uint("stock ETH exact input", exactInput); emit log_named_uint("stock ETH match attempts", attempts);
        Router.TradeParams memory p = Router.TradeParams(id, tool.WETH(), exactInput, 0, 1, block.timestamp + 300, 0, false);
        vm.prank(CREATOR); (uint256 got, uint256 refund) = native.buy{value: exactInput}(p, path);
        assertGt(got, 0); assertEq(refund, 0); assertEq(uint8(curve.status()), 0); assertEq(CREATOR.balance, 2 ether - p.amountIn);
        address strategyToken = curve.token();
        vm.prank(CREATOR); IERC20(strategyToken).approve(address(native), got);
        path[0] = Router.Hop(stockPool, tool.USDG()); path[1] = Router.Hop(x.pool, tool.WETH());
        p.amountIn = got; vm.prank(CREATOR); (uint256 proceeds, uint256 tokenRefund) = native.sell(p, path);
        assertGt(proceeds, 0); assertEq(tokenRefund, 0); assertEq(IERC20(curve.token()).balanceOf(CREATOR), 0);
        assertEq(CREATOR.balance, 2 ether - exactInput + proceeds);
        _assertClean(native, stock, curve.token());
    }

    function _exactStockInput(Native native, uint256 id, Router.Hop[] memory path) private returns (uint256 amount, uint256 attempts) {
        uint256 step = Math.mulDiv(2, 1e30, 3000e18, Math.Rounding.Ceil);
        for (uint256 i; i < 32; ++i) {
            amount = 0.0001 ether - i * step;
            uint256 snapshot = vm.snapshotState();
            Router.TradeParams memory probe = Router.TradeParams(id, tool.WETH(), amount, 0, 1, block.timestamp + 300, 0, true);
            vm.prank(CREATOR); (, uint256 refund) = native.buy{value: amount}(probe, path);
            assertTrue(vm.revertToStateAndDelete(snapshot));
            if (refund == 0) return (amount, i + 1);
        }
        fail("bounded integer ETH matching did not find an executable no-refund input");
    }

    function _exactGraduationInput(HedgeFunBondingCurve curve) private view returns (uint256 spent, uint256 expected) {
        uint256 burn; (spent, expected, burn) = curve.quoteBuyFor(0.03 ether, CREATOR);
        assertGt(spent, 0); assertLt(spent, 0.03 ether); assertEq(burn, 0);
        (uint256 again, uint256 output, uint256 secondBurn) = curve.quoteBuyFor(spent, CREATOR);
        assertEq(again, spent); assertEq(output, expected); assertEq(secondBurn, 0);
    }

    function _ethUnderlyingGraduateAndTrade(TestnetV2EthMarket.Deployment memory x) private {
        (uint256 id, HedgeFunBondingCurve curve) = _launch(x, tool.WETH(), "HFETHBASEFX", 202610010202);
        Native native = Native(payable(x.base.nativeRouter));
        vm.deal(CREATOR, 2 ether);
        {
            (uint256 spent, uint256 expected) = _exactGraduationInput(curve);
            Router.TradeParams memory p = Router.TradeParams(id, tool.WETH(), spent, spent, expected, block.timestamp + 300, 0, false);
            Router.Hop[] memory empty = new Router.Hop[](0);
            vm.prank(CREATOR); (uint256 got, uint256 refund) = native.buy{value: spent}(p, empty);
            assertEq(got, expected); assertEq(refund, 0); assertEq(CREATOR.balance, 2 ether - spent);
            assertEq(uint8(curve.status()), 2); assertEq(got, 440_000_000e18);
        }
        HedgeFunV2Treasury t = _graduatedTreasury(x, id);
        _v4NativeRoundTrip(native, id, curve);
        _assertClean(native, tool.WETH(), curve.token());
        _executeWithPoolTwap(x, t);
    }

    function _graduatedTreasury(TestnetV2EthMarket.Deployment memory x, uint256 id) private view returns (HedgeFunV2Treasury t) {
        (,address treasury,,,) = HedgeFunV2Factory(x.base.factory).strategies(id); t = HedgeFunV2Treasury(treasury);
        assertGt(t.bookedStock(), 0); assertEq(t.bookedStock() + t.buybackStock(), IERC20(tool.WETH()).balanceOf(treasury));
        assertTrue(t.params().bandBpsPerHour == 0); (bool healthy, uint256 price) = t.health();
        assertTrue(healthy); assertApproxEqRel(price, 3000e18, 1e14);
    }

    function _v4NativeRoundTrip(Native native, uint256 id, HedgeFunBondingCurve curve) private {
        uint256 balanceBefore = CREATOR.balance;
        address strategyToken = curve.token();
        vm.prank(CREATOR); IERC20(strategyToken).approve(address(native), 440_000_000e18);
        Router.Hop[] memory empty = new Router.Hop[](0);
        Router.TradeParams memory p = Router.TradeParams(id, tool.WETH(), 4_400_000e18, 0, 1, block.timestamp + 300, 2, false);
        vm.prank(CREATOR); (uint256 proceeds, uint256 refund) = native.sell(p, empty);
        assertGt(proceeds, 0); assertEq(refund, 0); assertEq(CREATOR.balance, balanceBefore + proceeds);
        p.amountIn = 0.00001 ether;
        vm.prank(CREATOR); (uint256 more, uint256 buyRefund) = native.buy{value: p.amountIn}(p, empty);
        assertGt(more, 0); assertEq(buyRefund, 0);
    }

    function _executeWithPoolTwap(TestnetV2EthMarket.Deployment memory x, HedgeFunV2Treasury t) private {
        uint256 beforePrice = x.oracle.price();
        vm.prank(tool.OPERATOR()); x.seeder.setPrice(3120e18, 300e6, 0.1 ether, block.timestamp);
        assertEq(x.oracle.price(), beforePrice, "instant pool move must not immediately move the strategy TWAP");
        (bool healthy,) = t.health(); assertFalse(healthy, "spot/TWAP deviation gates trades during transition");
        vm.expectRevert(); t.execute();
        vm.warp(block.timestamp + 600);
        (healthy, beforePrice) = t.health(); assertTrue(healthy); assertApproxEqRel(beforePrice, 3120e18, 1e14);
        address keeper = 0xdA1AEE7018a3925AA06dEEb8631Fca09E1067614;
        uint256 beforeReward = IERC20(tool.WETH()).balanceOf(keeper);
        uint256 beforeUsdg = IERC20(tool.USDG()).balanceOf(address(t));
        vm.prank(keeper); (HedgeFunV2Treasury.Action action, uint256 lotId) = t.execute();
        assertEq(uint8(action), 1); assertEq(lotId, 0);
        assertGt(IERC20(tool.WETH()).balanceOf(keeper), beforeReward);
        assertGt(IERC20(tool.USDG()).balanceOf(address(t)), beforeUsdg);
        assertEq(t.bookedStock() + t.buybackStock(), IERC20(tool.WETH()).balanceOf(address(t)));
    }

    function _ethUnderlyingExplicitRefund(TestnetV2EthMarket.Deployment memory x) private {
        (uint256 id, HedgeFunBondingCurve curve) = _launch(x, tool.WETH(), "HFETHREFUNDFX", 202610010203);
        Native native = Native(payable(x.base.nativeRouter)); Router.Hop[] memory empty = new Router.Hop[](0);
        vm.deal(CREATOR, 2 ether); uint256 offer = 0.03 ether;
        (uint256 spent, uint256 expected,) = curve.quoteBuyFor(offer, CREATOR);
        Router.TradeParams memory p = Router.TradeParams(id, tool.WETH(), offer, offer, expected, block.timestamp + 300, 0, true);
        vm.prank(CREATOR); (uint256 got, uint256 refund) = native.buy{value: offer}(p, empty);
        assertEq(got, expected); assertEq(refund, offer - spent); assertGt(refund, 0);
        assertEq(CREATOR.balance, 2 ether - spent); assertEq(uint8(curve.status()), 2);
        _assertClean(native, tool.WETH(), curve.token());
    }

    function _assertClean(Native native, address stock, address token) private view {
        assertEq(address(native).balance, 0); assertEq(IERC20(tool.WETH()).balanceOf(address(native)), 0);
        assertEq(IERC20(stock).balanceOf(address(native)), 0); assertEq(IERC20(token).balanceOf(address(native)), 0);
        assertEq(IERC20(tool.WETH()).allowance(address(native), xRouter(native)), 0);
        assertEq(IERC20(token).allowance(address(native), xRouter(native)), 0);
    }
    function xRouter(Native native) private view returns (address) { return address(native.router()); }
}
