// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {V2LiquidityVault} from "../src/v2/V2LiquidityVault.sol";
import {DeployV2Testnet} from "../script/testnet/DeployV2Testnet.s.sol";
import {TestnetMarket, IV3Pool} from "../script/testnet/TestnetMarket.sol";
import {TestStock, TestFeed, TestUsdg, Drip, TestnetRoles} from "../script/testnet/TestnetAssets.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {MockToken} from "./mocks/Mocks.sol";

/// The testnet deployment script, run offline: the real PoolManager is deployed at the testnet's address and a
/// stand-in token at the testnet WETH, then the script deploys everything else exactly as it would on chain 46630.
/// A launch is taken through the trade router with tUSDG -- through the test V3 pool, the curve, graduation into
/// V4 -- which is the path a team member's wallet takes from the front end.
contract DeployV2TestnetTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant WETH = 0x7943e237c7F95DA44E0301572D358911207852Fa;
    address operator = makeAddr("testnet operator");
    address alice = makeAddr("testnet alice");
    DeployV2Testnet.Deployment x;

    function setUp() public {
        vm.chainId(46630);
        vm.warp(1_790_690_000);   // Tuesday 2026-09-29 13:13 UTC: the calendar is open
        _deployAt(bytes.concat(type(PoolManager).creationCode, abi.encode(address(this))), PM);
        _deployAt(bytes.concat(type(MockToken).creationCode, abi.encode("WETH", uint8(18))), WETH);
        DeployV2Testnet script = new DeployV2Testnet();
        DeployV2Testnet.Deployment memory d = script.deploy(operator, operator, 0);
        _store(d);
    }

    /// forge-std's deployCodeTo without an artifact read: run the constructor AT `where`, so immutables that record
    /// the contract's own address (PoolManager's NoDelegateCall) hold the testnet address
    function _deployAt(bytes memory creation, address where) internal {
        vm.etch(where, creation);
        (bool ok, bytes memory runtime) = where.call("");
        require(ok, "constructor");
        vm.etch(where, runtime);
    }

    /// storage copy, field by field: a memory struct holding a dynamic array of structs cannot be assigned whole
    function _store(DeployV2Testnet.Deployment memory d) internal {
        x.operator = d.operator; x.owner = d.owner; x.protocol = d.protocol; x.usdg = d.usdg; x.usdgFeed = d.usdgFeed;
        x.calendar = d.calendar; x.v3Factory = d.v3Factory; x.market = d.market; x.treasury = d.treasury;
        x.token = d.token; x.curve = d.curve; x.hook = d.hook; x.factory = d.factory; x.router = d.router;
        x.nativeRouter = d.nativeRouter; x.policy = d.policy; x.policyKey = d.policyKey; x.engineKind = d.engineKind;
        x.hookSalt = d.hookSalt;
        for (uint256 i; i < d.lines.length; i++) x.lines.push(d.lines[i]);
    }

    function test_refusesOtherChains() public {
        vm.chainId(4663);
        DeployV2Testnet script = new DeployV2Testnet();
        vm.expectRevert(abi.encodeWithSelector(DeployV2Testnet.WrongChain.selector, 4663));
        script.deploy(operator, operator, 0);
    }

    function test_deploysListsAndOpens() public view {
        assertEq(x.factory.owner(), operator);
        assertTrue(x.factory.publicLaunch());
        assertEq(x.hook.version(), 3);
        assertEq(x.factory.getDefaults().sweepTipBps, 0);
        assertEq(x.factory.getDefaults().maxCreatorBps, 5000);
        assertEq(uint8(x.factory.getDefaults().launchFeeCurrency), uint8(HedgeFunFactory.FeeCurrency.Native));
        assertEq(x.factory.getDefaults().launchFeeAmount, 0.0005 ether);
        assertEq(x.treasury.kindCount(), 3);
        assertEq(x.lines.length, 4);
        for (uint256 i; i < x.lines.length; i++) {
            DeployV2Testnet.Line memory l = x.lines[i];
            (bool ok, uint256 p) = l.oracle.tryPrice();
            assertTrue(ok);
            assertEq(p, l.priceE18);
            (uint160 s,,,,,,) = IV3Pool(l.pool).slot0();
            assertEq(s, x.market.sqrtFor(l.pool, l.priceE18));
            assertApproxEqRel(x.market.priceAt(l.pool, s), l.priceE18, 1e9);   // sqrt rounding only
        }
    }

    /// Verify graduation into two locked positions without burning project-token supply, for every fresh listing.
    /// The buyer here is only a fixture for aggregate issuance; this does not model trading to a target price.
    function test_default7931GraduatesNear50kAcrossReferenceStocks() public {
        assertEq(x.curve.DEFAULT_SALE_BPS(), 7931);
        vm.warp(block.timestamp + 11 minutes);
        for (uint256 i; i < x.lines.length; ++i) {
            vm.prank(operator);
            x.market.poke(x.lines[i].pool);
        }
        for (uint256 i; i < x.lines.length; ++i) _verifyReferenceGraduation(i);
    }

    function _verifyReferenceGraduation(uint256 i) private {
        DeployV2Testnet.Line memory l = x.lines[i];
        vm.startPrank(operator);
        l.stock.mint(alice, 10_000e18);
        vm.stopPrank();
        HedgeFunFactory.Request memory q;
        q.name = "Reference public launch";
        q.symbol = "REF";
        q.nonce = uint96(i + 1);
        q.stock = address(l.stock);
        q.creator = alice;
        q.taxBps = 100;
        q.creatorBps = 1000;
        q.tp1Bps = 500;
        q.tp2Bps = 1000;
        q.dipBps = 500;
        q.stopBps = 0;
        q.lotBps = 2000;
        q.maxFee = 0.0005 ether;
        q.expectedOpenPriceE18 = l.openPriceE18;
        vm.deal(alice, 0.0005 ether);
        vm.startPrank(alice);
        (,, bytes32 terms) = x.factory.predict(q);
        uint256 id = x.factory.launch{value: 0.0005 ether}(q, terms);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(x.factory.curves(id));
        l.stock.approve(address(curve), type(uint256).max);
        vm.warp(block.timestamp + 4); // equal base fee; no opening surcharge or opening burn
        (uint256 paid, uint256 received) = curve.buy(type(uint256).max, 1, alice, block.timestamp);
        vm.stopPrank();
        assertEq(uint256(curve.status()), uint256(HedgeFunBondingCurve.Status.Graduated));
        assertEq(received, 793_100_000e18);
        _recordReferenceGraduation(l, id, curve, paid);
    }

    function _recordReferenceGraduation(
        DeployV2Testnet.Line memory l, uint256 id, HedgeFunBondingCurve curve, uint256 paid
    ) private {
        address token = curve.token();
        uint256 supply = IERC20(token).totalSupply();
        assertEq(supply, 1_000_000_000e18, "graduation must not burn project tokens");
        uint256 fdvUsd = _referenceFdvUsd(id, token, address(l.stock), l.priceE18);
        assertApproxEqAbs(fdvUsd, 50_000e18, 1e16, "reference FDV within one cent");
        uint256 principal = curve.terminalStock() - curve.virtualStock();
        assertEq(paid - paid / 100, principal, "1% stock fee excluded from net raise");
        _assertReferenceGraduationAccounting(l, id, curve, principal);
        string memory row = "reference7931";
        vm.serializeString(row, "stock", l.symbol);
        vm.serializeUint(row, "stockUsdE18", l.priceE18);
        vm.serializeUint(row, "openPriceE18", l.openPriceE18);
        vm.serializeUint(row, "grossStockRaw", paid);
        vm.serializeUint(row, "netRaiseStockRaw", principal);
        vm.serializeUint(row, "postGraduationSupplyRaw", supply);
        vm.serializeUint(row, "poolTokenRaw", IERC20(token).balanceOf(PM));
        vm.serializeUint(row, "treasuryStockRaw", l.stock.balanceOf(curve.treasury()));
        vm.serializeUint(row, "poolStockRaw", l.stock.balanceOf(PM));
        console2.log(string.concat("REFERENCE7931_RESULT ", vm.serializeUint(row, "graduationFdvUsdE18", fdvUsd)));
    }

    /// Graduation locks all unsold inventory and must not create a marginal-price jump.
    function _assertReferenceGraduationAccounting(
        DeployV2Testnet.Line memory l, uint256 id, HedgeFunBondingCurve curve, uint256 principal
    ) private view {
        IERC20 token = IERC20(curve.token());
        assertEq(token.balanceOf(alice), 793_100_000e18, "graduation preserves issued holder balances");
        V2LiquidityVault vault = V2LiquidityVault(HedgeFunV2Treasury(curve.treasury()).liquidityVault());
        assertEq(token.totalSupply(), token.balanceOf(alice) + token.balanceOf(PM) + token.balanceOf(address(vault)),
            "all project tokens accounted for, including locked rounding residue");
        assertEq(token.balanceOf(address(vault)), vault.lockedSeedTokens());
        assertGt(vault.surplusLiquidity(), 0, "surplus goes into locked LP, not a burn");
        assertEq(token.balanceOf(address(curve)), 0, "no migration surplus remains on the curve");
        assertEq(token.balanceOf(address(x.factory)), 0, "factory retains no unsold migration inventory");
        assertEq(l.stock.balanceOf(PM) + l.stock.balanceOf(curve.treasury()), principal, "LP plus treasury equals real principal");
        assertEq(l.stock.balanceOf(address(curve)), curve.totalFees(), "fees remain segregated from liquidity principal");
        (PoolKey memory key,) = x.factory.graduationConfig(id);
        (uint160 actualPrice,,,) = IPoolManager(PM).getSlot0(key.toId());
        uint160 expectedPrice = uint160(Math.sqrt(address(token) < address(l.stock)
            ? Math.mulDiv(curve.terminalStock(), 1 << 192, curve.minTokenReserve())
            : Math.mulDiv(curve.minTokenReserve(), 1 << 192, curve.terminalStock())));
        assertEq(actualPrice, expectedPrice, "migration preserves terminal marginal price without supply burn");
        assertEq(HedgeFunV2Treasury(curve.treasury()).buybackAnchorSqrtP(), actualPrice,
            "first buyback starts from the graduation reference");
    }

    function _referenceFdvUsd(uint256 id, address token, address stock, uint256 stockUsd) private view returns (uint256) {
        (PoolKey memory key,) = x.factory.graduationConfig(id);
        (uint160 sqrt,,,) = IPoolManager(PM).getSlot0(key.toId());
        uint256 ratio = Math.mulDiv(sqrt, sqrt, 1 << 96);
        uint256 supply = IERC20(token).totalSupply();
        uint256 fdvStock = token < stock
            ? Math.mulDiv(supply, ratio, 1 << 96) : Math.mulDiv(supply, 1 << 96, ratio);
        return Math.mulDiv(fdvStock, stockUsd, 1e18);
    }

    function test_pokeMakesTheRingLive_andKeepsThePrice() public {
        vm.warp(block.timestamp + 1);
        for (uint256 i; i < x.lines.length; i++) {
            address pool = x.lines[i].pool;
            (uint160 before,,,,,,) = IV3Pool(pool).slot0();
            vm.prank(operator);
            x.market.poke(pool);
            (uint160 afterPoke,,, uint16 card,,,) = IV3Pool(pool).slot0();
            assertEq(afterPoke, before);
            assertGe(card, 660);
        }
    }

    function test_setPriceMovesPoolAndFeedTogether() public {
        DeployV2Testnet.Line memory l = x.lines[0];
        vm.prank(operator);
        x.market.setPrice(l.pool, l.priceE18 * 103 / 100);
        (bool ok, uint256 p) = l.oracle.tryPrice();
        assertTrue(ok);
        assertEq(p, l.priceE18 * 103 / 100);
        (uint160 s,,,,,,) = IV3Pool(l.pool).slot0();
        assertEq(s, x.market.sqrtFor(l.pool, p));
        vm.expectRevert(TestnetMarket.OutsideRange.selector);
        vm.prank(operator);
        x.market.setPrice(l.pool, l.priceE18 * 3);
    }

    function test_rolesAndDrip() public {
        TestUsdg usdg = x.usdg;
        vm.expectRevert(TestnetRoles.NotOperator.selector);
        vm.prank(alice);
        usdg.mint(alice, 1);
        vm.prank(alice);
        usdg.drip();
        assertEq(usdg.balanceOf(alice), 10_000e6);
        vm.expectRevert(abi.encodeWithSelector(Drip.DripTooSoon.selector, block.timestamp + 1 days));
        vm.prank(alice);
        usdg.drip();
        vm.expectRevert();
        vm.prank(alice);
        x.market.setPrice(x.lines[0].pool, 1e18);
        TestFeed feed = x.lines[0].feed;
        vm.prank(operator);
        feed.setAlwaysFresh(false);
        vm.warp(block.timestamp + 27 hours);
        (bool ok,) = x.lines[0].oracle.tryPrice();
        assertFalse(ok, "a stale test feed must fail the oracle closed");
        TestStock stock = x.lines[0].stock;
        vm.prank(operator);
        feed.setAlwaysFresh(true);
        vm.prank(operator);
        stock.setOraclePaused(true);
        (ok,) = x.lines[0].oracle.tryPrice();
        assertFalse(ok, "oraclePaused must fail the oracle closed");
    }

    /// what a team member does from the front end: launch, buy with tUSDG through the V3 pool until the curve
    /// graduates, then trade the graduated token on V4 and sell it back to tUSDG
    function test_launchBuyGraduateTradeWithTestUsdg() public {
        vm.warp(block.timestamp + 11 minutes);   // past the pool's 600 s mean window
        for (uint256 i; i < x.lines.length; i++) {
            vm.prank(operator);
            x.market.poke(x.lines[i].pool);
        }
        DeployV2Testnet.Line memory l = x.lines[2];   // GME: the most stock per raise
        vm.prank(operator);
        x.usdg.mint(alice, 200_000e6);

        HedgeFunFactory.Request memory q;
        q.name = "Testnet strategy";
        q.symbol = "TST";
        q.stock = address(l.stock);
        q.creator = alice;
        q.taxBps = 300;
        q.creatorBps = 1000;
        q.tp1Bps = 500;
        q.tp2Bps = 1000;
        q.dipBps = 500;
        q.stopBps = 500;
        q.lotBps = 2000;
        q.maxFee = type(uint256).max;
        q.expectedOpenPriceE18 = l.openPriceE18;
        vm.deal(alice, 0.0005 ether);
        vm.startPrank(alice);
        (,, bytes32 terms) = x.factory.predict(q);
        uint256 id = x.factory.launch{value: 0.0005 ether}(q, terms);
        (address token, address treasury,,,) = x.factory.strategies(id);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(x.factory.curves(id));
        assertEq(uint256(curve.status()), uint256(HedgeFunBondingCurve.Status.Active));

        HedgeFunV2TradeRouter.Hop[] memory buyPath = new HedgeFunV2TradeRouter.Hop[](1);
        buyPath[0] = HedgeFunV2TradeRouter.Hop(l.pool, address(l.stock));
        x.usdg.approve(address(x.router), type(uint256).max);
        vm.warp(block.timestamp + 4);   // after the default 3-second opening window
        x.router.buy(HedgeFunV2TradeRouter.TradeParams(id, address(x.usdg), 100_000e6, 1, 1, block.timestamp,
            x.router.ACTIVE(), true), buyPath);
        assertEq(uint256(curve.status()), uint256(HedgeFunBondingCurve.Status.Graduated));
        (bool healthy,) = HedgeFunV2Treasury(treasury).health();
        assertTrue(healthy, "the raise left the pool inside every treasury's deviation gate");

        uint256 before = IERC20(token).balanceOf(alice);
        x.router.buy(HedgeFunV2TradeRouter.TradeParams(id, address(x.usdg), 500e6, 1, 1, block.timestamp,
            x.router.GRADUATED(), false), buyPath);
        assertGt(IERC20(token).balanceOf(alice), before);

        HedgeFunV2TradeRouter.Hop[] memory sellPath = new HedgeFunV2TradeRouter.Hop[](1);
        sellPath[0] = HedgeFunV2TradeRouter.Hop(l.pool, address(x.usdg));
        IERC20(token).approve(address(x.router), type(uint256).max);
        uint256 usdgBefore = x.usdg.balanceOf(alice);
        x.router.sell(HedgeFunV2TradeRouter.TradeParams(id, address(x.usdg), IERC20(token).balanceOf(alice) / 10, 0, 1,
            block.timestamp, x.router.GRADUATED(), false), sellPath);
        assertGt(x.usdg.balanceOf(alice), usdgBefore);
        vm.stopPrank();
        _checkProtocolReceipts(id);
    }

    function _checkProtocolReceipts(uint256 id) private {
        (address token,,, address stockAddress,) = x.factory.strategies(id);
        IERC20 stock = IERC20(stockAddress);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(x.factory.curves(id));
        uint256 curveCut = curve.claimable(x.protocol);
        uint256 protocolBefore = stock.balanceOf(x.protocol);
        assertGt(curveCut, 0, "the USDG-funded curve buy accrued stock fees for the protocol");
        curve.claimFees(x.protocol);
        assertEq(stock.balanceOf(x.protocol) - protocolBefore, curveCut);

        (PoolKey memory key,) = x.factory.graduationConfig(id);
        PoolId pid = key.toId();
        (uint256 tokenFees, uint256 stockFees) = x.hook.accrued(pid);
        assertEq(tokenFees, 0, "the V4 buy's fee was taken in stock, never in the token");
        assertGt(stockFees, 0);
        assertEq(IPoolManager(PM).balanceOf(address(x.hook), uint256(uint160(token))), 0);
        protocolBefore = stock.balanceOf(x.protocol);
        x.hook.sweep(pid);
        assertEq(stock.balanceOf(x.protocol) - protocolBefore, stockFees * 3000 / 10_000,
            "one sweep paid the V4 buy's and the V4 sale's stock fees to the protocol exactly once");
        (tokenFees, stockFees) = x.hook.accrued(pid);
        assertEq(tokenFees + stockFees, 0);
    }
}
