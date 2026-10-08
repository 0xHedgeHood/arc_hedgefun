// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter as TradeRouter} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {IWrappedNative} from "../src/v2/HedgeFunV2NativeRouter.sol";
import {HedgeFunV2LaunchNativeRouter as LaunchRouter} from "../src/v2/HedgeFunV2LaunchNativeRouter.sol";
import {V2RouterPool} from "./V2TradeRouter.t.sol";
import {V2WrappedNative} from "./V2NativeRouter.t.sol";
import {MockPool, MockLpPool, AlwaysOpen} from "./mocks/Mocks.sol";
import {PriceOracle} from "../src/PriceOracle.sol";

contract V2LaunchNativeRouterTest is V2FactoryFixture {
    uint256 internal constant FEE = 0.01 ether;
    uint256 internal constant BUY = 10 ether;

    TradeRouter internal trade;
    LaunchRouter internal launcher;
    V2WrappedNative internal wrapped;
    V2RouterPool internal venue;
    address internal creator = address(0xB0B);

    function setUp() public {
        _setUpV2(18);
        HedgeFunFactory.Defaults memory d = factory.getDefaults();
        d.launchFeeCurrency = HedgeFunFactory.FeeCurrency.Native;
        d.launchFeeAmount = FEE;
        vm.prank(owner);
        factory.setDefaults(d);

        trade = new TradeRouter(factory);
        wrapped = new V2WrappedNative();
        launcher = new LaunchRouter(trade, IWrappedNative(address(wrapped)));
        vm.prank(owner);
        factory.setLauncher(address(launcher), true);

        venue = new V2RouterPool(address(wrapped), address(stock));
        v3f.set(address(wrapped), address(stock), venue.fee(), address(venue));
        vm.deal(address(this), 2_000 ether);
        wrapped.deposit{value: 1_000 ether}();
        wrapped.transfer(address(venue), 1_000 ether);
        stock.mint(address(venue), 1_000 ether);
        vm.deal(creator, 1_000 ether);
    }

    function _requestForCreator() private view returns (HedgeFunFactory.Request memory q) {
        q = _request();
        q.creator = creator;
        q.name = "Native launch";
        q.symbol = "NATIVEV2";
        q.nonce = 1;
    }

    function _info() private pure returns (HedgeFunToken.Info memory info) {
        info.description = "ETH launch and first buy";
    }

    function _params(uint256 amount) private view returns (LaunchRouter.BuyParams memory p) {
        p = LaunchRouter.BuyParams({
            amountIn: amount,
            minStockReceived: amount * 997 / 1000,
            minFinalOut: 1,
            deadline: block.timestamp + 1 hours,
            allowPartialFill: true
        });
    }

    function _path() private view returns (TradeRouter.Hop[] memory path) {
        path = new TradeRouter.Hop[](1);
        path[0] = TradeRouter.Hop(address(venue), address(stock));
    }

    function _assertNoLaunch(HedgeFunFactory.Request memory q, uint256 creatorBefore, uint256 venueBefore)
        private
        view
    {
        assertEq(factory.strategyCount(), 0);
        assertEq(factory.predictToken(q).code.length, 0);
        assertEq(creator.balance, creatorBefore);
        assertEq(protocol.balance, 0);
        assertEq(wrapped.balanceOf(address(venue)), venueBefore);
        assertEq(address(launcher).balance, 0);
        assertEq(wrapped.balanceOf(address(launcher)), 0);
        assertEq(stock.balanceOf(address(launcher)), 0);
    }

    function _openingQuote(HedgeFunFactory.Request memory q, bytes32 terms)
        private
        returns (uint256 expectedSpent, uint256 exemptOut)
    {
        uint256 state = vm.snapshotState();
        vm.prank(creator);
        uint256 probeId = factory.launch{value: FEE}(q, terms);
        HedgeFunBondingCurve probe = HedgeFunBondingCurve(factory.curves(probeId));
        uint256 stockGot = BUY * 997 / 1000;
        (expectedSpent, exemptOut,) = probe.quoteBuyFor(stockGot, creator);
        (, uint256 routerOut,) = probe.quoteBuyFor(stockGot, address(launcher));
        assertGt(exemptOut, routerOut);
        assertTrue(vm.revertToState(state));
    }

    function testLaunchAndBuyUsesOnlyNativeAndCreatorOpeningTaxExemption() public {
        HedgeFunFactory.Request memory q = _requestForCreator();
        (,, bytes32 terms) = factory.predict(q);
        (uint256 expectedSpent, uint256 exemptOut) = _openingQuote(q, terms);

        LaunchRouter.BuyParams memory p = _params(BUY);
        p.minFinalOut = exemptOut;
        uint256 creatorBefore = creator.balance;
        vm.prank(creator);
        (uint256 id, uint256 out, uint256 refund) =
            launcher.launchAndBuy{value: FEE + BUY}(q, terms, _info(), p, _path());

        assertEq(id, 0);
        assertEq(out, exemptOut);
        assertEq(refund, BUY * 997 / 1000 - expectedSpent);
        assertEq(factory.strategyCount(), 1);
        assertEq(protocol.balance, FEE);
        assertEq(creator.balance, creatorBefore - FEE - BUY);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        HedgeFunToken token = HedgeFunToken(curve.token());
        assertEq(token.balanceOf(creator), out);
        assertEq(token.balanceOf(address(launcher)), 0);
        assertEq(token.deployer(), creator);
        assertEq(token.description(), "ETH launch and first buy");
        assertEq(curve.buyRateBpsFor(creator), q.taxBps);
        assertGt(curve.buyRateBpsFor(address(launcher)), q.taxBps);
        assertEq(stock.balanceOf(creator), refund);
        assertEq(wrapped.balanceOf(address(launcher)), 0);
        assertEq(stock.balanceOf(address(launcher)), 0);
        assertEq(wrapped.allowance(address(launcher), address(trade)), 0);
    }

    function testWrongPaymentAndSlippageRollBackCreationAndFee() public {
        HedgeFunFactory.Request memory q = _requestForCreator();
        (,, bytes32 terms) = factory.predict(q);
        LaunchRouter.BuyParams memory p = _params(BUY);
        uint256 creatorBefore = creator.balance;
        uint256 venueBefore = wrapped.balanceOf(address(venue));

        vm.prank(creator);
        vm.expectRevert();
        launcher.launchAndBuy{value: FEE + BUY - 1}(q, terms, _info(), p, _path());
        _assertNoLaunch(q, creatorBefore, venueBefore);

        p.minFinalOut = type(uint256).max;
        vm.prank(creator);
        vm.expectRevert();
        launcher.launchAndBuy{value: FEE + BUY}(q, terms, _info(), p, _path());
        _assertNoLaunch(q, creatorBefore, venueBefore);
    }

    function testCreatorCannotBeSpoofed() public {
        HedgeFunFactory.Request memory q = _requestForCreator();
        (,, bytes32 terms) = factory.predict(q);
        LaunchRouter.BuyParams memory p = _params(BUY);
        uint256 creatorBefore = creator.balance;
        uint256 venueBefore = wrapped.balanceOf(address(venue));

        vm.deal(address(0xBAD), 100 ether);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        launcher.launchAndBuy{value: FEE + BUY}(q, terms, _info(), p, _path());
        _assertNoLaunch(q, creatorBefore, venueBefore);
    }

    function testUnrelatedLaunchBetweenQuoteAndExecutionUsesActualId() public {
        HedgeFunFactory.Request memory q = _requestForCreator();
        (,, bytes32 terms) = factory.predict(q);
        LaunchRouter.BuyParams memory p = _params(BUY);

        address otherCreator = address(0xCAFE);
        HedgeFunFactory.Request memory other = _requestForCreator();
        other.creator = otherCreator;
        other.symbol = "OTHERV2";
        other.nonce = 2;
        (,, bytes32 otherTerms) = factory.predict(other);
        vm.deal(otherCreator, 1 ether);
        vm.prank(otherCreator);
        uint256 otherId = factory.launch{value: FEE}(other, otherTerms);
        assertEq(otherId, 0);
        assertEq(factory.strategyCount(), 1);

        uint256 creatorBefore = creator.balance;
        vm.prank(creator);
        (uint256 id, uint256 out, uint256 refund) =
            launcher.launchAndBuy{value: FEE + BUY}(q, terms, _info(), p, _path());

        assertEq(id, 1);
        assertGt(out, 0);
        assertEq(factory.strategyCount(), 2);
        assertEq(protocol.balance, 2 * FEE);
        assertEq(creator.balance, creatorBefore - FEE - BUY);
        (address token,,,,) = factory.strategies(id);
        assertEq(IERC20(token).balanceOf(creator), out);
        assertEq(stock.balanceOf(creator), refund);
        assertEq(wrapped.balanceOf(address(launcher)), 0);
        assertEq(stock.balanceOf(address(launcher)), 0);
        assertEq(wrapped.allowance(address(launcher), address(trade)), 0);
        assertEq(
            uint256(HedgeFunBondingCurve(factory.curves(otherId)).status()), uint256(HedgeFunBondingCurve.Status.Active)
        );
    }

    function testStaleFeeTermsRollBackNativeFee() public {
        HedgeFunFactory.Request memory q = _requestForCreator();
        (,, bytes32 terms) = factory.predict(q);
        HedgeFunFactory.Defaults memory d = factory.getDefaults();
        d.launchFeeAmount = 2 * FEE;
        vm.prank(owner);
        factory.setDefaults(d);
        uint256 creatorBefore = creator.balance;
        uint256 venueBefore = wrapped.balanceOf(address(venue));
        LaunchRouter.BuyParams memory p = _params(BUY);

        vm.prank(creator);
        vm.expectRevert();
        launcher.launchAndBuy{value: 2 * FEE + BUY}(q, terms, _info(), p, _path());
        _assertNoLaunch(q, creatorBefore, venueBefore);
    }

    function testNativeFeeAndRouteAreRequired() public {
        HedgeFunFactory.Request memory q = _requestForCreator();
        (,, bytes32 terms) = factory.predict(q);
        LaunchRouter.BuyParams memory p = _params(BUY);
        TradeRouter.Hop[] memory path = _path();
        uint256 creatorBefore = creator.balance;
        uint256 venueBefore = wrapped.balanceOf(address(venue));

        path[0].tokenOut = address(usdg);
        vm.prank(creator);
        vm.expectRevert();
        launcher.launchAndBuy{value: FEE + BUY}(q, terms, _info(), p, path);
        _assertNoLaunch(q, creatorBefore, venueBefore);

        HedgeFunFactory.Defaults memory d = factory.getDefaults();
        d.launchFeeCurrency = HedgeFunFactory.FeeCurrency.Usdg;
        d.launchFeeAmount = 25e6;
        vm.prank(owner);
        factory.setDefaults(d);
        (,, terms) = factory.predict(q);
        path[0].tokenOut = address(stock);
        vm.prank(creator);
        vm.expectRevert();
        launcher.launchAndBuy{value: FEE + BUY}(q, terms, _info(), p, path);
        _assertNoLaunch(q, creatorBefore, venueBefore);
    }

    function testDonatedBalancesStayInRouter() public {
        HedgeFunFactory.Request memory q = _requestForCreator();
        (,, bytes32 terms) = factory.predict(q);
        vm.deal(address(launcher), 7 ether);
        wrapped.deposit{value: 11 ether}();
        wrapped.transfer(address(launcher), 11 ether);
        stock.mint(address(launcher), 13 ether);
        uint256 creatorBefore = creator.balance;
        LaunchRouter.BuyParams memory p = _params(BUY);

        vm.prank(creator);
        (uint256 id, uint256 out, uint256 refund) =
            launcher.launchAndBuy{value: FEE + BUY}(q, terms, _info(), p, _path());

        assertEq(id, 0);
        assertGt(out, 0);
        assertEq(creator.balance, creatorBefore - FEE - BUY);
        assertEq(stock.balanceOf(creator), refund);
        assertEq(address(launcher).balance, 7 ether);
        assertEq(wrapped.balanceOf(address(launcher)), 11 ether);
        assertEq(stock.balanceOf(address(launcher)), 13 ether);
        assertEq(wrapped.allowance(address(launcher), address(trade)), 0);
    }

    function testCurveCapRefundsStockToCreator() public {
        HedgeFunFactory.Request memory q = _requestForCreator();
        (,, bytes32 terms) = factory.predict(q);
        uint256 offer = _graduationOffer(q, terms);
        LaunchRouter.BuyParams memory p = _params(offer);
        vm.prank(creator);
        (uint256 id, uint256 out, uint256 refund) =
            launcher.launchAndBuy{value: FEE + offer}(q, terms, _info(), p, _path());

        assertGt(out, 0);
        assertGt(refund, 0);
        assertEq(stock.balanceOf(creator), refund);
        assertEq(stock.balanceOf(address(launcher)), 0);
        (address token,,,,) = factory.strategies(id);
        assertEq(IERC20(token).balanceOf(creator), out);
        assertEq(
            uint256(HedgeFunBondingCurve(factory.curves(id)).status()), uint256(HedgeFunBondingCurve.Status.Graduated)
        );
    }

    function testTwoHopNativeToUsdgToListedStockLaunch() public {
        // Use the actual V2 listing pool as the second hop, with separate 18/6-decimal venue balances.
        MockPool ethUsdg = new MockPool(address(wrapped), address(usdg), address(wrapped) < address(usdg), 3000, 1e30);
        MockPool stockUsdg = new MockPool(address(stock), address(usdg), address(stock) < address(usdg), 3000, 1e30);
        ethUsdg.setPrice(3000e18);
        stockUsdg.setPrice(100e18);
        v3f.set(address(wrapped), address(usdg), 3000, address(ethUsdg));
        v3f.set(address(stock), address(usdg), 3000, address(stockUsdg));
        vm.prank(owner);
        factory.list(address(stock), address(oracle), address(stockUsdg), openPrice, true);
        usdg.mint(address(ethUsdg), 100_000e6);
        stock.mint(address(stockUsdg), 1_000 ether);

        HedgeFunFactory.Request memory q = _requestForCreator();
        (,, bytes32 terms) = factory.predict(q);
        uint256 buyEth = 0.1 ether;
        uint256 usdgOut = (buyEth * 997_000 / 1_000_000) * 3000e18 / 1e30;
        uint256 stockOut = (usdgOut * 997_000 / 1_000_000) * 1e30 / 100e18;
        LaunchRouter.BuyParams memory p = _params(buyEth);
        p.minStockReceived = stockOut;
        TradeRouter.Hop[] memory path = new TradeRouter.Hop[](2);
        path[0] = TradeRouter.Hop(address(ethUsdg), address(usdg));
        path[1] = TradeRouter.Hop(address(stockUsdg), address(stock));
        uint256 creatorBefore = creator.balance;

        assertEq(usdg.balanceOf(creator), 0);
        assertEq(wrapped.balanceOf(creator), 0);
        assertEq(stock.balanceOf(creator), 0);
        vm.prank(creator);
        (uint256 id, uint256 tokensOut, uint256 stockRefund) =
            launcher.launchAndBuy{value: FEE + buyEth}(q, terms, _info(), p, path);

        assertEq(id, 0);
        assertGt(tokensOut, 0);
        assertEq(factory.strategyCount(), 1);
        assertEq(protocol.balance, FEE);
        assertEq(creator.balance, creatorBefore - FEE - buyEth);
        assertEq(wrapped.balanceOf(address(ethUsdg)), buyEth);
        assertEq(usdg.balanceOf(address(ethUsdg)), 100_000e6 - usdgOut);
        assertEq(usdg.balanceOf(address(stockUsdg)), usdgOut);
        assertEq(stock.balanceOf(address(stockUsdg)), 1_000 ether - stockOut);
        assertEq(stock.balanceOf(creator), stockRefund);
        assertEq(usdg.balanceOf(creator), 0);
        assertEq(wrapped.balanceOf(creator), 0);
        assertEq(address(launcher).balance, 0);
        assertEq(wrapped.balanceOf(address(launcher)), 0);
        assertEq(usdg.balanceOf(address(launcher)), 0);
        assertEq(stock.balanceOf(address(launcher)), 0);
        assertEq(wrapped.allowance(address(launcher), address(trade)), 0);
        assertEq(wrapped.balanceOf(address(trade)), 0);
        assertEq(usdg.balanceOf(address(trade)), 0);
        assertEq(stock.balanceOf(address(trade)), 0);
        assertEq(stock.balanceOf(factory.curves(id)), stockOut - stockRefund);
        (address token,,,,) = factory.strategies(id);
        assertEq(IERC20(token).balanceOf(creator), tokensOut);
    }

    function testCurveCapWithoutPartialFillRollsBackEverything() public {
        HedgeFunFactory.Request memory q = _requestForCreator();
        (,, bytes32 terms) = factory.predict(q);
        uint256 offer = 100 ether;
        LaunchRouter.BuyParams memory p = _params(offer);
        p.allowPartialFill = false;
        uint256 creatorBefore = creator.balance;
        uint256 venueWrappedBefore = wrapped.balanceOf(address(venue));
        uint256 venueStockBefore = stock.balanceOf(address(venue));

        vm.prank(creator);
        vm.expectPartialRevert(TradeRouter.PartialFill.selector);
        launcher.launchAndBuy{value: FEE + offer}(q, terms, _info(), p, _path());

        _assertNoLaunch(q, creatorBefore, venueWrappedBefore);
        assertEq(stock.balanceOf(address(venue)), venueStockBefore);
        assertEq(factory.predictCurve(q).code.length, 0);
        assertEq(stock.balanceOf(creator), 0);
        assertEq(wrapped.balanceOf(address(trade)), 0);
        assertEq(stock.balanceOf(address(trade)), 0);
    }

    function testWrappedNativeStockRefundUnwrapsToCreator() public {
        // The listed stock itself is WETH: no V3 hop is needed, and excess curve input must come back as ETH.
        address t0 = address(wrapped) < address(usdg) ? address(wrapped) : address(usdg);
        address t1 = address(wrapped) < address(usdg) ? address(usdg) : address(wrapped);
        MockLpPool wrappedPool = new MockLpPool(t0, t1, 3000);
        v3f.set(address(wrapped), address(usdg), wrappedPool.fee(), address(wrappedPool));
        PriceOracle wrappedOracle = new PriceOracle(
            address(wrapped), address(stockFeed), address(usdgFeed), address(new AlwaysOpen()), 26 hours, 26 hours
        );
        vm.prank(owner);
        factory.list(address(wrapped), address(wrappedOracle), address(wrappedPool), openPrice, true);

        HedgeFunFactory.Request memory q = _requestForCreator();
        q.stock = address(wrapped);
        q.symbol = "WETHSTOCK";
        (,, bytes32 terms) = factory.predict(q);
        uint256 offer = _graduationOffer(q, terms);
        LaunchRouter.BuyParams memory p = _params(offer);
        p.minStockReceived = offer;
        TradeRouter.Hop[] memory emptyPath = new TradeRouter.Hop[](0);
        uint256 creatorBefore = creator.balance;

        vm.prank(creator);
        (uint256 id, uint256 out, uint256 refund) =
            launcher.launchAndBuy{value: FEE + offer}(q, terms, _info(), p, emptyPath);

        assertEq(id, 0);
        assertGt(out, 0);
        assertGt(refund, 0);
        assertEq(protocol.balance, FEE);
        assertEq(creator.balance, creatorBefore - FEE - offer + refund);
        assertEq(wrapped.balanceOf(creator), 0);
        assertEq(wrapped.balanceOf(address(launcher)), 0);
        assertEq(address(launcher).balance, 0);
        assertEq(wrapped.allowance(address(launcher), address(trade)), 0);
        assertEq(wrapped.balanceOf(address(trade)), 0);
        (address token,,,,) = factory.strategies(id);
        assertEq(IERC20(token).balanceOf(creator), out);
        assertEq(
            uint256(HedgeFunBondingCurve(factory.curves(id)).status()), uint256(HedgeFunBondingCurve.Status.Graduated)
        );
    }

    // Differential fuzz: quote a separately snapshotted direct launch, then execute the
    // native launch against the same initial state. The V3 leg is a synthetic flat-price
    // venue; the curve, factory, hook, V4 PoolManager and graduation are production code.
    function _fuzzQuote(HedgeFunFactory.Request memory q, bytes32 terms, uint256 offer)
        private returns (uint256 spent, uint256 out, bool graduates)
    {
        uint256 snapshot = vm.snapshotState();
        vm.prank(creator);
        uint256 id = factory.launch{value: FEE}(q, terms);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        uint256 burned;
        (spent, out, burned) = curve.quoteBuyFor(offer * 997 / 1000, creator);
        graduates = curve.tokenReserve() - out - burned == curve.minTokenReserve();
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    function _assertFuzzRollback(HedgeFunFactory.Request memory q, uint256 creatorBefore) private view {
        _assertNoLaunch(q, creatorBefore, 1000 ether);
        (, address treasury,) = factory.predict(q);
        assertEq(treasury.code.length, 0, "treasury deployment rolled back");
        assertEq(factory.predictCurve(q).code.length, 0, "curve deployment rolled back");
        assertEq(stock.balanceOf(address(venue)), 1000 ether);
        assertEq(stock.balanceOf(creator), 0);
        assertEq(wrapped.balanceOf(address(trade)), 0);
        assertEq(stock.balanceOf(address(trade)), 0);
        assertEq(wrapped.allowance(address(launcher), address(trade)), 0);
    }

    function testFuzz_nativeLaunchMatchesDirectQuoteAndGraduation(
        uint96 offerSeed, uint96 nonce, uint16 taxSeed, uint16 creatorFeeSeed
    ) public {
        uint256 offer = bound(uint256(offerSeed), 1e10, 200 ether);
        HedgeFunFactory.Request memory q = _requestForCreator();
        q.nonce = nonce;
        q.taxBps = uint16(bound(taxSeed, 100, 1500));
        q.creatorBps = uint16(bound(creatorFeeSeed, 0, 3000));
        (address predicted,, bytes32 terms) = factory.predict(q);
        (uint256 spent, uint256 quotedOut, bool graduates) = _fuzzQuote(q, terms, offer);
        LaunchRouter.BuyParams memory p = _params(offer);
        p.minFinalOut = quotedOut;
        uint256 creatorBefore = creator.balance;
        vm.prank(creator);
        (uint256 id, uint256 out, uint256 refund) =
            launcher.launchAndBuy{value: FEE + offer}(q, terms, _info(), p, _path());
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        assertEq(curve.token(), predicted);
        assertEq(out, quotedOut);
        assertEq(refund + spent, offer * 997 / 1000);
        assertEq(IERC20(predicted).balanceOf(creator), out);
        assertEq(stock.balanceOf(creator), refund);
        assertEq(creatorBefore - creator.balance, FEE + offer);
        assertEq(protocol.balance, FEE);
        assertEq(factory.strategyCount(), 1);
        assertEq(uint256(curve.status()), graduates ? 2 : 0, "no persistent Ready stage");
        assertEq(stock.balanceOf(address(venue)), 1000 ether - offer * 997 / 1000);
        assertEq(wrapped.balanceOf(address(venue)), 1000 ether + offer);
        assertEq(stock.balanceOf(address(curve)), curve.realStockReserve() + curve.totalFees());
        assertEq(address(launcher).balance, 0);
        assertEq(wrapped.balanceOf(address(launcher)), 0);
        assertEq(stock.balanceOf(address(launcher)), 0);
        assertEq(wrapped.balanceOf(address(trade)), 0);
        assertEq(stock.balanceOf(address(trade)), 0);
        assertEq(wrapped.allowance(address(launcher), address(trade)), 0);
        assertEq(stock.allowance(address(trade), address(curve)), 0);
    }

    function testFuzz_nativeLaunchOneUnitSlippageRollsBackAllAssets(uint96 offerSeed, bool stockLeg) public {
        uint256 offer = bound(uint256(offerSeed), 1e10, 200 ether);
        HedgeFunFactory.Request memory q = _requestForCreator();
        (,, bytes32 terms) = factory.predict(q);
        (, uint256 quotedOut,) = _fuzzQuote(q, terms, offer);
        LaunchRouter.BuyParams memory p = _params(offer);
        if (stockLeg) p.minStockReceived = offer * 997 / 1000 + 1;
        else p.minFinalOut = quotedOut + 1;
        uint256 creatorBefore = creator.balance;
        vm.prank(creator);
        vm.expectRevert();
        launcher.launchAndBuy{value: FEE + offer}(q, terms, _info(), p, _path());
        _assertFuzzRollback(q, creatorBefore);
    }

    function testFuzz_nativeLaunchWrongValueCannotChargeOrDeploy(uint96 offerSeed, uint64 deltaSeed, bool excess) public {
        uint256 offer = bound(uint256(offerSeed), 1e10, 200 ether);
        uint256 delta = bound(uint256(deltaSeed), 1, FEE);
        HedgeFunFactory.Request memory q = _requestForCreator();
        (,, bytes32 terms) = factory.predict(q);
        uint256 payment = excess ? FEE + offer + delta : FEE + offer - delta;
        LaunchRouter.BuyParams memory p = _params(offer);
        uint256 creatorBefore = creator.balance;
        vm.prank(creator);
        vm.expectRevert(LaunchRouter.BadPayment.selector);
        launcher.launchAndBuy{value: payment}(q, terms, _info(), p, _path());
        _assertFuzzRollback(q, creatorBefore);
    }

    function testFuzz_nativeLaunchHostileVenueRollsBackCreation(uint96 offerSeed, uint8 modeSeed) public {
        uint256 offer = bound(uint256(offerSeed), 1e10, 200 ether);
        uint256 mode = bound(modeSeed, 1, 7);
        // Callback payload is deliberately ignored: mode 7 (ForgedData) is safe.
        // The seven rejecting modes are 1..6 and 8 (ShortOutput).
        venue.setMode(V2RouterPool.Mode(mode == 7 ? 8 : mode));
        HedgeFunFactory.Request memory q = _requestForCreator();
        (,, bytes32 terms) = factory.predict(q);
        LaunchRouter.BuyParams memory p = _params(offer);
        uint256 creatorBefore = creator.balance;
        vm.prank(creator);
        vm.expectRevert();
        launcher.launchAndBuy{value: FEE + offer}(q, terms, _info(), p, _path());
        _assertFuzzRollback(q, creatorBefore);
    }

    function testFuzz_nativeGraduationRefundRequiresOptIn(uint96 offerSeed) public {
        HedgeFunFactory.Request memory q = _requestForCreator();
        (,, bytes32 terms) = factory.predict(q);
        uint256 minimum = _graduationOffer(q, terms);
        uint256 offer = bound(uint256(offerSeed), minimum, minimum * 2);
        (uint256 spent,, bool graduates) = _fuzzQuote(q, terms, offer);
        assertTrue(graduates);
        assertLt(spent, offer * 997 / 1000);
        LaunchRouter.BuyParams memory p = _params(offer);
        p.allowPartialFill = false;
        uint256 creatorBefore = creator.balance;
        vm.prank(creator);
        vm.expectPartialRevert(TradeRouter.PartialFill.selector);
        launcher.launchAndBuy{value: FEE + offer}(q, terms, _info(), p, _path());
        _assertFuzzRollback(q, creatorBefore);
    }

    function _graduationOffer(HedgeFunFactory.Request memory q, bytes32 terms) private returns (uint256) {
        (uint256 needed,, bool graduates) = _fuzzQuote(q, terms, type(uint128).max);
        assertTrue(graduates);
        return (needed * 1000 + 996) / 997 + 1 ether;
    }

    function testFuzz_nativeLaunchPreservesDonatedAssets(uint96 offerSeed, uint96 donationSeed) public {
        uint256 offer = bound(uint256(offerSeed), 1e10, 200 ether);
        uint256 donation = bound(uint256(donationSeed), 1, 50 ether);
        vm.deal(address(launcher), donation);
        wrapped.deposit{value: donation}();
        wrapped.transfer(address(launcher), donation);
        stock.mint(address(launcher), donation);
        HedgeFunFactory.Request memory q = _requestForCreator();
        (,, bytes32 terms) = factory.predict(q);
        LaunchRouter.BuyParams memory p = _params(offer);
        vm.prank(creator);
        (, uint256 out, uint256 refund) =
            launcher.launchAndBuy{value: FEE + offer}(q, terms, _info(), p, _path());
        assertGt(out, 0);
        assertEq(stock.balanceOf(creator), refund);
        assertEq(address(launcher).balance, donation);
        assertEq(wrapped.balanceOf(address(launcher)), donation);
        assertEq(stock.balanceOf(address(launcher)), donation);
        assertEq(wrapped.allowance(address(launcher), address(trade)), 0);
    }

    function testFuzz_nativeLaunchIgnoresForgedCallbackPaymentData(uint96 offerSeed) public {
        uint256 offer = bound(uint256(offerSeed), 1e10, 200 ether);
        venue.setMode(V2RouterPool.Mode.ForgedData);
        HedgeFunFactory.Request memory q = _requestForCreator();
        (,, bytes32 terms) = factory.predict(q);
        (uint256 spent, uint256 quotedOut,) = _fuzzQuote(q, terms, offer);
        LaunchRouter.BuyParams memory p = _params(offer);
        vm.prank(creator);
        (, uint256 out, uint256 refund) =
            launcher.launchAndBuy{value: FEE + offer}(q, terms, _info(), p, _path());
        assertEq(out, quotedOut);
        assertEq(spent + refund, offer * 997 / 1000);
        assertEq(wrapped.balanceOf(address(0xBAD)), 0);
        assertEq(stock.balanceOf(address(0xBAD)), 0);
        assertEq(wrapped.balanceOf(address(venue)), 1000 ether + offer);
        assertEq(wrapped.balanceOf(address(trade)), 0);
        assertEq(stock.balanceOf(address(trade)), 0);
    }
}
