// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";
import {HedgeFunBondingCurve as Curve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter as Router} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {MockV3Factory} from "./mocks/Mocks.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

contract V2RouterAsset is ERC20 {
    address public taxedFrom;
    address public taxedTo;
    uint8 public taxMode;
    constructor(string memory symbol_) ERC20(symbol_, symbol_) {}
    function mint(address who, uint256 amount) external { _mint(who, amount); }
    function setTax(address from, address to, uint8 mode) external { taxedFrom = from; taxedTo = to; taxMode = mode; }
    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && from == taxedFrom && to == taxedTo && taxMode != 0) {
            uint256 fee = amount / 100;
            super._update(from, address(0), fee);
            if (taxMode == 1) amount -= fee;
        }
        super._update(from, to, amount);
    }
}

/// Flat-price V3-shaped venue. Malicious modes test callback boundaries even if a canonical venue were compromised.
contract V2RouterPool {
    address public immutable token0;
    address public immutable token1;
    uint24 public constant fee = 3000;
    uint256 public outputPerThousand = 997;
    enum Mode { Normal, Overcharge, BothPositive, WrongDirection, Twice, NoPay, Partial, ForgedData, ShortOutput }
    Mode public mode;
    constructor(address a, address b) { (token0, token1) = a < b ? (a, b) : (b, a); }
    function setMode(Mode m) external { mode = m; }
    function setOutputPerThousand(uint256 value) external { outputPerThousand = value; }
    function swap(address recipient, bool z, int256 amount, uint160, bytes calldata data) external returns (int256 a0, int256 a1) {
        uint256 spent = uint256(amount);
        if (mode == Mode.Partial) spent /= 2;
        uint256 out = spent * outputPerThousand / 1000;
        IERC20(z ? token1 : token0).transfer(recipient, mode == Mode.ShortOutput ? out - 1 : out);
        (a0, a1) = z ? (int256(spent), -int256(out)) : (-int256(out), int256(spent));
        if (mode == Mode.Overcharge) {
            Router(msg.sender).uniswapV3SwapCallback(z ? amount + 1 : a0, z ? a1 : amount + 1, data);
        } else if (mode == Mode.BothPositive) {
            Router(msg.sender).uniswapV3SwapCallback(int256(spent), int256(spent), data);
        } else if (mode == Mode.WrongDirection) {
            Router(msg.sender).uniswapV3SwapCallback(a1, a0, data);
        } else if (mode != Mode.NoPay) {
            Router(msg.sender).uniswapV3SwapCallback(a0, a1, mode == Mode.ForgedData ? abi.encode(address(0xBAD)) : data);
            if (mode == Mode.Twice) Router(msg.sender).uniswapV3SwapCallback(a0, a1, data);
        }
    }
}

contract V2RouterTreasury {
    PoolKey public poolKey;
    constructor(PoolKey memory key) { poolKey = key; }
}
contract V2RouterGraduated { function status() external pure returns (uint8) { return 2; } }
contract V2RouterRegistry {
    IPoolManager public immutable poolManager;
    MockV3Factory public immutable v3Factory;
    address private _token;
    address private _stock;
    address private _treasury;
    mapping(uint256 => address) public curves;
    constructor(IPoolManager manager, MockV3Factory v3) { poolManager = manager; v3Factory = v3; }
    function set(address token, address stock, address treasury, address curve) external {
        _token = token; _stock = stock; _treasury = treasury; curves[0] = curve;
    }
    function strategies(uint256 id) external view returns (address, address, address, address, address) {
        require(id == 0); return (_token, _treasury, address(0), _stock, address(0xC));
    }
    function graduateCurve() external { require(msg.sender == curves[0]); Curve(msg.sender).release(); }
}

contract V2TradeRouterTest is Test {
    Router router;
    V2RouterRegistry registry;
    MockV3Factory v3;
    IPoolManager manager;
    V2RouterAsset stock;
    V2RouterAsset payment;
    V2RouterAsset bridge;
    V2RouterAsset output;
    HedgeFunToken token;
    Curve curve;
    V2RouterPool paymentBridge;
    V2RouterPool bridgeStock;
    V2RouterPool stockOutput;
    address alice = address(0xA11CE);
    uint256 constant SUPPLY = 1_000_000e18;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        v3 = new MockV3Factory();
        registry = new V2RouterRegistry(manager, v3);
        router = new Router(HedgeFunFactory(address(registry)));
        stock = new V2RouterAsset("STOCK");
        payment = new V2RouterAsset("PAY");
        bridge = new V2RouterAsset("BRIDGE");
        output = new V2RouterAsset("OUTPUT");
        token = new HedgeFunToken("Strategy", "STRAT", SUPPLY, address(this), address(this));
        curve = new Curve(Curve.Init(address(registry), address(token), address(stock), address(0x71),
            address(0x72), address(0x73), SUPPLY, 100e18, 8000, 1000, 2000, 1000, 0, 0, new address[](0)));
        token.transfer(address(curve), SUPPLY);
        registry.set(address(token), address(stock), address(0), address(curve));
        paymentBridge = _pool(payment, bridge);
        bridgeStock = _pool(bridge, stock);
        stockOutput = _pool(stock, output);
        payment.mint(alice, 10000e18);
        stock.mint(alice, 10000e18);
        vm.startPrank(alice);
        payment.approve(address(router), type(uint256).max);
        stock.approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _pool(V2RouterAsset a, V2RouterAsset b) private returns (V2RouterPool p) {
        p = new V2RouterPool(address(a), address(b));
        v3.set(address(a), address(b), p.fee(), address(p));
        a.mint(address(p), 1e30); b.mint(address(p), 1e30);
    }
    function _params(address asset, uint256 amount, uint8 stage) private view returns (Router.TradeParams memory p) {
        p = Router.TradeParams(0, asset, amount, 0, 1, block.timestamp, stage, true);
    }
    function _buyPath() private view returns (Router.Hop[] memory path) {
        path = new Router.Hop[](2);
        path[0] = Router.Hop(address(paymentBridge), address(bridge));
        path[1] = Router.Hop(address(bridgeStock), address(stock));
    }
    function _sellPath() private view returns (Router.Hop[] memory path) {
        path = new Router.Hop[](1);
        path[0] = Router.Hop(address(stockOutput), address(output));
    }
    function _empty() private pure returns (Router.Hop[] memory path) { path = new Router.Hop[](0); }
    function _buy(uint256 amount) private returns (uint256 got) {
        vm.prank(alice); (got,) = router.buy(_params(address(payment), amount, 0), _buyPath());
    }
    function _assertNoResidue() private view {
        assertEq(payment.balanceOf(address(router)), 0);
        assertEq(bridge.balanceOf(address(router)), 0);
        assertEq(stock.balanceOf(address(router)), 0);
        assertEq(output.balanceOf(address(router)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(stock.allowance(address(router), address(curve)), 0);
        assertEq(token.allowance(address(router), address(curve)), 0);
    }

    function _openingCurve(address exempt) private {
        address[] memory list = new address[](1);
        list[0] = exempt;
        token = new HedgeFunToken("Opening strategy", "OPEN", SUPPLY, address(this), address(this));
        curve = new Curve(Curve.Init(address(registry), address(token), address(stock), address(0x71),
            address(0x72), address(0x73), SUPPLY, 100e18, 8000, 1000, 2000, 1000, 9900, 60, list));
        token.transfer(address(curve), SUPPLY);
        registry.set(address(token), address(stock), address(0), address(curve));
        vm.prank(alice); token.approve(address(router), type(uint256).max);
    }

    function testOpeningTaxUsesFinalRoutedRecipientAndAbsoluteSlippage() public {
        _openingCurve(alice);
        uint256 stockGot = 10e18 * 997 * 997 / 1_000_000;
        (, uint256 exemptOut,) = curve.quoteBuyFor(stockGot, alice);
        (, uint256 normalOut,) = curve.quoteBuyFor(stockGot, address(0xB0B));
        assertGt(exemptOut, normalOut);
        Router.TradeParams memory p = _params(address(payment), 10e18, 0);
        p.minFinalOut = exemptOut;
        vm.prank(alice);
        (uint256 got,) = router.buy(p, _buyPath());
        uint256 firstGot = got;
        assertEq(got, exemptOut);
        assertEq(token.balanceOf(alice), got);
        assertEq(token.balanceOf(address(router)), 0);

        // The payer may designate a whitelisted recipient, but never receive that recipient's tokens.
        address payer = address(0xB0B);
        payment.mint(payer, 10e18);
        vm.prank(payer); payment.approve(address(router), type(uint256).max);
        (, exemptOut,) = curve.quoteBuyFor(stockGot, alice);
        p.minFinalOut = exemptOut;
        vm.prank(payer);
        (got,) = router.buyFor(p, _buyPath(), alice);
        assertEq(got, exemptOut);
        assertEq(token.balanceOf(payer), 0);
        assertEq(token.balanceOf(alice), firstGot + got);
        _assertNoResidue();
    }

    function testWhitelistingRouterDoesNotExemptItsUsers() public {
        _openingCurve(address(router));
        uint256 stockGot = 10e18 * 997 * 997 / 1_000_000;
        (, uint256 normalOut,) = curve.quoteBuyFor(stockGot, alice);
        (, uint256 routerOut,) = curve.quoteBuyFor(stockGot, address(router));
        assertGt(routerOut, normalOut);
        Router.TradeParams memory p = _params(address(payment), 10e18, 0);
        p.minFinalOut = routerOut;
        vm.prank(alice); vm.expectPartialRevert(Router.TooLittle.selector);
        router.buy(p, _buyPath());
        assertEq(payment.balanceOf(alice), 10_000e18);
        p.minFinalOut = normalOut;
        vm.prank(alice); (uint256 got,) = router.buy(p, _buyPath());
        assertEq(got, normalOut);
        assertEq(token.balanceOf(address(router)), 0);
        _assertNoResidue();
    }

    function testNonUsdgTwoHopBuyAndChosenOutputSell() public {
        uint256 start = payment.balanceOf(alice);
        uint256 got = _buy(10e18);
        assertGt(got, 0); assertEq(token.balanceOf(alice), got);
        assertEq(start - payment.balanceOf(alice), 10e18);
        vm.prank(alice);
        (uint256 received, uint256 refund) = router.sell(_params(address(output), got, 0), _sellPath());
        assertGt(received, 0); assertEq(received, output.balanceOf(alice)); assertEq(refund, 0);
        assertEq(token.balanceOf(alice), 0);
        _assertNoResidue();
    }

    function testDirectStockBuyAndSellNeedNoV3Pool() public {
        Router.TradeParams memory p = _params(address(stock), 10e18, 0);
        vm.prank(alice); (uint256 got,) = router.buy(p, _empty());
        p.amountIn = got;
        uint256 beforeStock = stock.balanceOf(alice);
        vm.prank(alice); (uint256 received,) = router.sell(p, _empty());
        assertEq(stock.balanceOf(alice) - beforeStock, received);
        _assertNoResidue();
    }

    function testMaximumThreeHopRouteAndReverseOutput() public {
        V2RouterPool bridgeOutput = _pool(bridge, output);
        Router.Hop[] memory path = new Router.Hop[](3);
        path[0] = Router.Hop(address(paymentBridge), address(bridge));
        path[1] = Router.Hop(address(bridgeOutput), address(output));
        path[2] = Router.Hop(address(stockOutput), address(stock));
        vm.prank(alice); (uint256 got,) = router.buy(_params(address(payment), 10e18, 0), path);
        path[0] = Router.Hop(address(stockOutput), address(output));
        path[1] = Router.Hop(address(bridgeOutput), address(bridge));
        path[2] = Router.Hop(address(paymentBridge), address(payment));
        vm.prank(alice); (uint256 received,) = router.sell(_params(address(payment), got, 0), path);
        assertGt(received, 0);
        _assertNoResidue();
    }

    function testRepeatedIntermediateTokenIsRejected() public {
        V2RouterPool bridgeOutput = _pool(bridge, output);
        Router.Hop[] memory path = new Router.Hop[](3);
        path[0] = Router.Hop(address(paymentBridge), address(bridge));
        path[1] = Router.Hop(address(bridgeOutput), address(output));
        path[2] = Router.Hop(address(bridgeOutput), address(bridge));
        vm.prank(alice); vm.expectRevert(Router.BadPath.selector);
        router.buy(_params(address(payment), 10e18, 0), path);
        assertEq(payment.balanceOf(alice), 10000e18);
    }

    function testFinalCurveBuyGraduatesAndRequiresExplicitStockRefundConsent() public {
        Router.TradeParams memory p = _params(address(payment), 500e18, 0);
        p.allowPartialFill = false;
        vm.prank(alice); vm.expectPartialRevert(Router.PartialFill.selector); router.buy(p, _buyPath());
        assertEq(uint256(curve.status()), 0);
        assertEq(payment.balanceOf(alice), 10000e18);
        p.allowPartialFill = true;
        uint256 beforeStock = stock.balanceOf(alice);
        vm.prank(alice); (uint256 got, uint256 refund) = router.buy(p, _buyPath());
        assertGt(refund, 0); assertEq(stock.balanceOf(alice) - beforeStock, refund);
        assertEq(token.balanceOf(alice), got);
        assertEq(uint256(curve.status()), 2, "stage is bound only at entry; atomic graduation remains valid");
        _assertNoResidue();
    }

    function testDonationsRemainIsolatedFromBuyRefundAndSell() public {
        payment.mint(address(router), 13e18); bridge.mint(address(router), 17e18);
        stock.mint(address(router), 19e18); output.mint(address(router), 23e18);
        uint256 got = _buy(10e18);
        vm.prank(alice); token.transfer(address(router), got / 10);
        vm.prank(alice); router.sell(_params(address(output), got - got / 10, 0), _sellPath());
        assertEq(payment.balanceOf(address(router)), 13e18); assertEq(bridge.balanceOf(address(router)), 17e18);
        assertEq(stock.balanceOf(address(router)), 19e18); assertEq(output.balanceOf(address(router)), 23e18);
        assertEq(token.balanceOf(address(router)), got / 10);
        vm.prank(alice); router.buy(_params(address(payment), 500e18, 0), _buyPath());
        assertEq(stock.balanceOf(address(router)), 19e18);
        assertEq(token.balanceOf(address(router)), got / 10);
    }

    function testMinimumIsNeverProratedForFinalPartialFill() public {
        Router.TradeParams memory p = _params(address(payment), 500e18, 0);
        p.minFinalOut = SUPPLY;
        vm.prank(alice); vm.expectPartialRevert(Router.TooLittle.selector); router.buy(p, _buyPath());
        assertEq(uint256(curve.status()), 0); assertEq(payment.balanceOf(alice), 10000e18);
    }

    function _assertCappedBuyStockFloor(uint8 stage) private {
        Router.TradeParams memory p = _params(address(payment), 600e18, stage);
        uint256 snapshot = vm.snapshotState();
        vm.prank(alice); (uint256 quotedTokens, uint256 quotedRefund) = router.buy(p, _buyPath());
        assertGt(quotedRefund, 0);
        vm.revertToState(snapshot);

        // Both prices still buy the whole remaining sale/range. A token-only floor misses the worse route.
        bridgeStock.setOutputPerThousand(850);
        p.minFinalOut = quotedTokens;
        snapshot = vm.snapshotState();
        vm.prank(alice); (uint256 actualTokens, uint256 actualRefund) = router.buy(p, _buyPath());
        assertEq(actualTokens, quotedTokens);
        assertLt(actualRefund, quotedRefund);
        vm.revertToState(snapshot);

        p.minStockReceived = 590e18; // original route produces596.4054 stock, worsened route only508.47
        vm.prank(alice); vm.expectRevert(abi.encodeWithSelector(Router.TooLittleStock.selector, 508.47e18));
        router.buy(p, _buyPath());
        assertEq(payment.balanceOf(alice), 10000e18);
        assertEq(token.balanceOf(alice), 0);
        _assertNoResidue();
    }

    function testCurveCapStockFloorProtectsRefundFromWorseV3Price() public {
        _assertCappedBuyStockFloor(0);
        assertEq(uint256(curve.status()), 0);
    }

    function testV4PartialStockFloorProtectsRefundFromWorseV3Price() public {
        _graduateFixture(true);
        _assertCappedBuyStockFloor(2);
    }

    function testDirectStockBuyHonorsStockFloorButSellIgnoresIt() public {
        Router.TradeParams memory p = _params(address(stock), 10e18, 0);
        p.minStockReceived = 10e18 + 1;
        vm.prank(alice); vm.expectRevert(abi.encodeWithSelector(Router.TooLittleStock.selector, 10e18));
        router.buy(p, _empty());
        p.minStockReceived = 10e18;
        vm.prank(alice); (uint256 got,) = router.buy(p, _empty());
        p.amountIn = got;
        p.minStockReceived = type(uint256).max;
        vm.prank(alice); (uint256 received,) = router.sell(p, _empty());
        assertGt(received, 0);
        _assertNoResidue();
    }

    function testDeadlineStageAndMinimumProtectFullRoute() public {
        Router.TradeParams memory p = _params(address(payment), 10e18, 0);
        p.deadline = block.timestamp - 1;
        vm.prank(alice); vm.expectRevert(Router.Expired.selector); router.buy(p, _buyPath());
        p.deadline = block.timestamp; p.expectedStage = 2;
        vm.prank(alice); vm.expectRevert(abi.encodeWithSelector(Router.StageChanged.selector, 0)); router.buy(p, _buyPath());
        p.expectedStage = 0; p.minFinalOut = SUPPLY;
        vm.prank(alice); vm.expectPartialRevert(Router.TooLittle.selector); router.buy(p, _buyPath());
        uint256 got = _buy(10e18);
        p = _params(address(output), got, 0); p.minFinalOut = 10000e18;
        vm.prank(alice); vm.expectPartialRevert(Router.TooLittle.selector); router.sell(p, _sellPath());
        assertEq(token.balanceOf(alice), got); _assertNoResidue();
    }

    function testBadPathsAreRejectedBeforePull() public {
        Router.TradeParams memory p = _params(address(payment), 10e18, 0);
        Router.Hop[] memory path = _buyPath();
        path[0].pool = address(bridgeStock);
        vm.prank(alice); vm.expectRevert(Router.WrongPool.selector); router.buy(p, path);
        path = _buyPath(); path[1].tokenOut = address(payment);
        vm.prank(alice); vm.expectRevert(Router.BadPath.selector); router.buy(p, path);
        path = _buyPath(); path[1].tokenOut = address(token);
        vm.prank(alice); vm.expectRevert(Router.BadPath.selector); router.buy(p, path);
        path = new Router.Hop[](4);
        vm.prank(alice); vm.expectRevert(Router.BadPath.selector); router.buy(p, path);
        vm.prank(alice); vm.expectRevert(Router.BadPath.selector); router.buy(p, _empty());
        p.asset = address(0);
        vm.prank(alice); vm.expectRevert(Router.BadPath.selector); router.buy(p, _empty());
        p.asset = address(payment);
        path = _buyPath();
        V2RouterPool fake = new V2RouterPool(address(payment), address(bridge)); path[0].pool = address(fake);
        vm.prank(alice); vm.expectRevert(Router.WrongPool.selector); router.buy(p, path);
        assertEq(payment.balanceOf(alice), 10000e18); _assertNoResidue();
    }

    function testV3CallbacksCannotOverchargeChangeDirectionOrPayTwice() public {
        Router.TradeParams memory p = _params(address(payment), 10e18, 0);
        Router.Hop[] memory path = _buyPath();
        for (uint256 i = 1; i <= 6; ++i) {
            paymentBridge.setMode(V2RouterPool.Mode(i));
            vm.prank(alice); vm.expectRevert(); router.buy(p, path);
            assertEq(payment.balanceOf(alice), 10000e18); _assertNoResidue();
        }
        vm.prank(address(paymentBridge)); vm.expectRevert(Router.NotThePool.selector);
        router.uniswapV3SwapCallback(1, -1, "");
        vm.expectRevert(Router.NotPoolManager.selector); router.unlockCallback("");
        vm.prank(address(manager)); vm.expectRevert(Router.NotPoolManager.selector); router.unlockCallback("");
    }

    function testCallbackDataCannotSelectPaymentToken() public {
        paymentBridge.setMode(V2RouterPool.Mode.ForgedData);
        assertGt(_buy(10e18), 0);
        _assertNoResidue();
    }

    function testShortPoolOutputCannotBeSubsidizedByDonation() public {
        bridge.mint(address(router), 100e18);
        paymentBridge.setMode(V2RouterPool.Mode.ShortOutput);
        vm.prank(alice); vm.expectRevert(Router.TransferMismatch.selector);
        router.buy(_params(address(payment), 10e18, 0), _buyPath());
        assertEq(bridge.balanceOf(address(router)), 100e18);
    }

    function testTaxedInputAndIntermediateTransferAreRejected() public {
        for (uint8 mode = 1; mode <= 2; ++mode) {
            payment.setTax(alice, address(router), mode);
            vm.prank(alice); vm.expectRevert(Router.TransferMismatch.selector);
            router.buy(_params(address(payment), 10e18, 0), _buyPath());
            assertEq(payment.balanceOf(alice), 10000e18);
        }
        payment.setTax(address(router), address(paymentBridge), 2);
        payment.mint(address(router), 100e18);
        vm.prank(alice); vm.expectRevert(Router.TransferMismatch.selector);
        router.buy(_params(address(payment), 10e18, 0), _buyPath());
        assertEq(payment.balanceOf(address(router)), 100e18);
    }

    function testTaxedFinalOutputCannotUseDonationOrMissUserMinimum() public {
        uint256 got = _buy(10e18);
        output.mint(address(router), 100e18);
        for (uint8 mode = 1; mode <= 2; ++mode) {
            output.setTax(address(router), alice, mode);
            vm.prank(alice); vm.expectRevert(Router.TransferMismatch.selector);
            router.sell(_params(address(output), got, 0), _sellPath());
            assertEq(token.balanceOf(alice), got);
            assertEq(output.balanceOf(address(router)), 100e18);
        }
    }

    /// Use a real V4 PoolManager and concentrated position to exercise settlement, take and partial fills.
    function _graduateFixture(bool thin) private {
        V2RouterAsset strategy = new V2RouterAsset("GRADUATED");
        token = HedgeFunToken(address(strategy));
        PoolKey memory key = address(strategy) < address(stock)
            ? PoolKey(Currency.wrap(address(strategy)), Currency.wrap(address(stock)), 3000, 60, IHooks(address(0)))
            : PoolKey(Currency.wrap(address(stock)), Currency.wrap(address(strategy)), 3000, 60, IHooks(address(0)));
        manager.initialize(key, uint160(1 << 96));
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        strategy.mint(address(this), 1e30); stock.mint(address(this), 1e30);
        strategy.approve(address(lp), type(uint256).max); stock.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(key, ModifyLiquidityParams({tickLower: thin ? int24(-60) : int24(-887220),
            tickUpper: thin ? int24(60) : int24(887220), liquidityDelta: thin ? int256(1e21) : int256(1e24), salt: 0}), "");
        registry.set(address(strategy), address(stock), address(new V2RouterTreasury(key)), address(new V2RouterGraduated()));
        vm.prank(alice); strategy.approve(address(router), type(uint256).max);
    }

    function testRealV4GraduatedTwoHopBuyAndSelectedOutputSell() public {
        _graduateFixture(false);
        vm.prank(alice); (uint256 got, uint256 refund) = router.buy(_params(address(payment), 10e18, 2), _buyPath());
        assertEq(refund, 0); assertEq(token.balanceOf(alice), got);
        vm.prank(alice); (uint256 received, uint256 tokenRefund) = router.sell(_params(address(output), got, 2), _sellPath());
        assertEq(tokenRefund, 0); assertEq(output.balanceOf(alice), received); assertGt(received, 0);
        _assertNoResidue();
    }

    function testRealV4DirectStockAndStaleStage() public {
        _graduateFixture(false);
        Router.TradeParams memory p = _params(address(stock), 10e18, 0);
        vm.prank(alice); vm.expectRevert(abi.encodeWithSelector(Router.StageChanged.selector, 2)); router.buy(p, _empty());
        p.expectedStage = 2;
        vm.prank(alice); (uint256 got,) = router.buy(p, _empty());
        p.amountIn = got;
        uint256 beforeStock = stock.balanceOf(alice);
        vm.prank(alice); (uint256 received,) = router.sell(p, _empty());
        assertEq(stock.balanceOf(alice) - beforeStock, received);
        _assertNoResidue();
    }

    function testRealV4PartialBuyRefundRequiresConsentAndIsolatesDonations() public {
        _graduateFixture(true);
        Router.TradeParams memory p = _params(address(payment), 100e18, 2);
        p.allowPartialFill = false;
        vm.prank(alice); vm.expectPartialRevert(Router.PartialFill.selector); router.buy(p, _buyPath());
        stock.mint(address(router), 19e18);
        p.allowPartialFill = true;
        uint256 beforeStock = stock.balanceOf(alice);
        vm.prank(alice); (uint256 got, uint256 refund) = router.buy(p, _buyPath());
        assertGt(got, 0); assertGt(refund, 0); assertEq(stock.balanceOf(alice) - beforeStock, refund);
        assertEq(stock.balanceOf(address(router)), 19e18);
    }

    function testRealV4PartialSellRefundRequiresConsentAndIsolatesDonations() public {
        _graduateFixture(true);
        V2RouterAsset(address(token)).mint(alice, 100e18);
        V2RouterAsset(address(token)).mint(address(router), 23e18);
        Router.TradeParams memory p = _params(address(output), 100e18, 2);
        p.allowPartialFill = false;
        vm.prank(alice); vm.expectPartialRevert(Router.PartialFill.selector); router.sell(p, _sellPath());
        p.allowPartialFill = true;
        vm.prank(alice); (uint256 received, uint256 refund) = router.sell(p, _sellPath());
        assertGt(received, 0); assertGt(refund, 0); assertEq(token.balanceOf(alice), refund);
        assertEq(token.balanceOf(address(router)), 23e18);
    }

    function testRealV4OutputTransferTaxRevertsWithoutSpendingDonation() public {
        _graduateFixture(false);
        stock.mint(address(router), 50e18);
        stock.setTax(address(manager), address(router), 1);
        V2RouterAsset(address(token)).mint(alice, 10e18);
        vm.prank(alice); vm.expectRevert(Router.TransferMismatch.selector);
        router.sell(_params(address(stock), 10e18, 2), _empty());
        assertEq(stock.balanceOf(address(router)), 50e18);
        assertEq(token.balanceOf(alice), 10e18);
    }
}

/// Full production factory/hook/treasury lifecycle, with real V4 settlement and mocked external V3 liquidity.
contract V2TradeRouterIntegrationTest is V2FactoryFixture {
    Router private router;
    V2RouterAsset private payment;
    V2RouterAsset private bridge;
    V2RouterPool private paymentBridge;
    V2RouterPool private bridgeStock;

    function setUp() public {
        _setUpV2(18);
        router = new Router(factory);
        payment = new V2RouterAsset("PAY");
        bridge = new V2RouterAsset("BRIDGE");
        paymentBridge = new V2RouterPool(address(payment), address(bridge));
        bridgeStock = new V2RouterPool(address(bridge), address(stock));
        v3f.set(address(payment), address(bridge), 3000, address(paymentBridge));
        v3f.set(address(bridge), address(stock), 3000, address(bridgeStock));
        payment.mint(address(paymentBridge), 1e30); bridge.mint(address(paymentBridge), 1e30);
        bridge.mint(address(bridgeStock), 1e30); stock.mint(address(bridgeStock), 1e30);
        payment.mint(address(this), 10000e18);
        payment.approve(address(router), type(uint256).max);
        stock.approve(address(router), type(uint256).max);
    }

    function _route(bool buy) private view returns (Router.Hop[] memory path) {
        path = new Router.Hop[](2);
        path[0] = Router.Hop(buy ? address(paymentBridge) : address(bridgeStock), address(bridge));
        path[1] = Router.Hop(buy ? address(bridgeStock) : address(paymentBridge), buy ? address(stock) : address(payment));
    }

    function _params(uint256 id, uint256 amount, uint8 stage) private view returns (Router.TradeParams memory) {
        return Router.TradeParams(id, address(payment), amount, 0, 1, block.timestamp, stage, true);
    }

    function _lifecycle(bool tokenIs0) private {
        (uint256 id, Curve curve,) = _launchV2(tokenIs0);
        IERC20 token = IERC20(curve.token());
        token.approve(address(router), type(uint256).max);
        {
        (uint256 first,) = router.buy(_params(id, 10e18, 0), _route(true));
        assertEq(token.balanceOf(address(this)), first);
        (uint256 curveBack,) = router.sell(_params(id, first / 2, 0), _route(false));
        assertGt(curveBack, 0);
        assertGt(curve.totalFees(), 0);
        }
        {
        (uint256 last, uint256 refund) = router.buy(_params(id, 500e18, 0), _route(true));
        assertGt(last, 0); assertGt(refund, 0);
        }
        assertEq(uint256(curve.status()), 2);
        vm.expectRevert(abi.encodeWithSelector(Router.StageChanged.selector, 2));
        router.buy(_params(id, 1e18, 0), _route(true));
        {
        uint256 before = token.balanceOf(address(this));
        (uint256 graduatedBuy,) = router.buy(_params(id, 1e18, 2), _route(true));
        assertEq(token.balanceOf(address(this)) - before, graduatedBuy);
        (uint256 graduatedSell, uint256 tokenRefund) = router.sell(_params(id, graduatedBuy, 2), _route(false));
        assertGt(graduatedSell, 0); assertEq(tokenRefund, 0);
        }
        {
        Router.TradeParams memory direct = _params(id, 1e18, 2);
        direct.asset = address(stock);
        Router.Hop[] memory empty = new Router.Hop[](0);
        (uint256 stockBuy,) = router.buy(direct, empty);
        direct.amountIn = stockBuy;
        (uint256 stockBack,) = router.sell(direct, empty);
        assertGt(stockBack, 0);
        }
        assertEq(payment.balanceOf(address(router)), 0); assertEq(bridge.balanceOf(address(router)), 0);
        assertEq(stock.balanceOf(address(router)), 0); assertEq(token.balanceOf(address(router)), 0);
        assertEq(stock.allowance(address(router), address(curve)), 0);
        assertEq(token.allowance(address(router), address(curve)), 0);
    }

    function testRealFactoryLifecycleTokenCurrency0() public { _lifecycle(true); }
    function testRealFactoryLifecycleTokenCurrency1() public { _lifecycle(false); }
}
