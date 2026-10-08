// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunHook} from "../src/hooks/HedgeFunHook.sol";
import {HedgeFunV2TradeRouter} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {DeployV2Testnet} from "../script/testnet/DeployV2Testnet.s.sol";
import {DeployV2FeeUpgradeTestnet} from "../script/testnet/DeployV2FeeUpgradeTestnet.s.sol";
import {DeployV2FreshCreatorTestnet} from "../script/testnet/DeployV2FreshCreatorTestnet.s.sol";
import {DeployV2ReleaseTestnet} from "../script/testnet/DeployV2ReleaseTestnet.s.sol";
import {IV3Pool} from "../script/testnet/TestnetMarket.sol";
import {MockToken} from "./mocks/Mocks.sol";

/// Eight real synthetic V3 venues, plus an already-bound factory. Only the test fixture overrides addresses.
contract EightStockFeeFixture is DeployV2Testnet {
    function appendNinth(Deployment memory x, address operator) external returns (Line memory l) {
        x.operator = operator;
        vm.startBroadcast(operator);
        l = _deployLine(x, StockSpec("EXTRA", "Additional test stock", 100e18, 100_000_000_000, 3000, 100e18));
        vm.stopBroadcast();
    }

    function deployEight(address operator) external returns (Deployment memory x) {
        x = deploy(operator, operator, 0);
        Line[] memory lines = new Line[](8);
        for (uint256 i; i < 4; ++i) {
            lines[i] = x.lines[i];
        }
        StockSpec[] memory extra = new StockSpec[](4);
        extra[0] = StockSpec("MSFT", "Microsoft test stock", 500e18, 20_000_000_000, 3000, 20e18);
        extra[1] = StockSpec("AMZN", "Amazon test stock", 200e18, 50_000_000_000, 3000, 50e18);
        extra[2] = StockSpec("GOOGL", "Alphabet test stock", 200e18, 50_000_000_000, 500, 50e18);
        extra[3] = StockSpec("META", "Meta test stock", 600e18, 16_666_666_667, 3000, 20e18);
        vm.startBroadcast(operator);
        for (uint256 i; i < 4; ++i) {
            Line memory l = _deployLine(x, extra[i]);
            lines[i + 4] = l;
            x.factory.list(address(l.stock), address(l.oracle), l.pool, l.openPriceE18, true);
            x.factory.setListingGates(address(l.stock), 50, 100, 2_000e6);
            x.treasury.setLpBps(address(l.stock), 5000);
        }
        vm.stopBroadcast();
        x.lines = lines;
    }
}

contract FeeUpgradeFixtureHarness is DeployV2FeeUpgradeTestnet {
    Venue private fixture;
    Seed[] private inventory;

    constructor(Venue memory v, Seed[] memory s) {
        fixture = v;
        for (uint256 i; i < s.length; ++i) {
            inventory.push(s[i]);
        }
    }

    function _venue() internal view override returns (Venue memory) {
        return fixture;
    }

    function _seeds() internal view override returns (Seed[] memory s) {
        s = new Seed[](inventory.length);
        for (uint256 i; i < s.length; ++i) {
            s[i] = inventory[i];
        }
    }
}

// A real call frame is needed: Foundry refuses startBroadcast within a prank.
contract FeeUpgradeOperatorInvoker {
    receive() external payable {}

    function deploy(DeployV2FeeUpgradeTestnet s) external returns (DeployV2FeeUpgradeTestnet.Deployment memory) {
        return s.deploy(0);
    }

    function run(DeployV2FeeUpgradeTestnet s) external {
        s.run();
    }
}

contract ReleaseFixtureHarness is DeployV2ReleaseTestnet {
    Venue private fixture;
    Seed[] private inventory;

    constructor(Venue memory v, Seed[] memory s) {
        fixture = v;
        for (uint256 i; i < s.length; ++i) {
            inventory.push(s[i]);
        }
    }

    function _venue() internal view override returns (Venue memory) {
        return fixture;
    }

    function _seeds() internal view override returns (Seed[] memory) {
        return inventory;
    }
}

contract FreshCreatorFixtureHarness is DeployV2FreshCreatorTestnet {
    Venue private fixture;
    Seed[] private inventory;

    constructor(Venue memory v, Seed[] memory s) {
        fixture = v;
        for (uint256 i; i < s.length; ++i) {
            inventory.push(s[i]);
        }
    }

    function _venue() internal view override returns (Venue memory) {
        return fixture;
    }

    function _seeds() internal view override returns (Seed[] memory s) {
        s = new Seed[](inventory.length);
        for (uint256 i; i < s.length; ++i) {
            s[i] = inventory[i];
        }
    }
}

contract DeployV2FeeUpgradeTestnetTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    address payable constant OPERATOR = payable(0x75Cee941B0eF3A83feA0397BbF903C12c1D7e96D);
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant WETH = 0x7943e237c7F95DA44E0301572D358911207852Fa;
    address alice = makeAddr("fee upgrade buyer");
    DeployV2Testnet.Deployment base;
    DeployV2FeeUpgradeTestnet.Deployment x;
    FeeUpgradeFixtureHarness upgrade;

    function setUp() public {
        vm.chainId(46630);
        vm.warp(1_790_690_000); // Open trading calendar; synthetic assets have no value.
        vm.etch(OPERATOR, type(FeeUpgradeOperatorInvoker).runtimeCode);
        _deployAt(bytes.concat(type(PoolManager).creationCode, abi.encode(address(this))), PM);
        _deployAt(bytes.concat(type(MockToken).creationCode, abi.encode("WETH", uint8(18))), WETH);
        DeployV2Testnet.Deployment memory b = new EightStockFeeFixture().deployEight(OPERATOR);
        base.factory = b.factory;
        base.treasury = b.treasury;
        base.market = b.market;
        base.usdg = b.usdg;
        base.usdgFeed = b.usdgFeed;
        base.calendar = b.calendar;
        base.v3Factory = b.v3Factory;
        base.router = b.router;
        base.curve = b.curve;
        base.hook = b.hook;
        base.token = b.token;
        DeployV2FeeUpgradeTestnet.Seed[] memory seeds = new DeployV2FeeUpgradeTestnet.Seed[](8);
        vm.warp(block.timestamp + 1);
        for (uint256 i; i < b.lines.length; ++i) {
            DeployV2Testnet.Line memory l = b.lines[i];
            base.lines.push(l);
            seeds[i] =
                DeployV2FeeUpgradeTestnet.Seed(l.symbol, address(l.stock), address(l.feed), address(l.oracle), l.pool);
            vm.prank(OPERATOR);
            b.market.poke(l.pool);
        }
        upgrade = new FeeUpgradeFixtureHarness(
            DeployV2FeeUpgradeTestnet.Venue(
                b.factory, b.treasury, b.market, b.usdg, b.usdgFeed, b.calendar, b.v3Factory
            ),
            seeds
        );
    }

    function _deployAt(bytes memory creation, address where) private {
        vm.etch(where, creation);
        (bool ok, bytes memory runtime) = where.call("");
        require(ok, "fixture constructor");
        vm.etch(where, runtime);
    }

    function _deploy() private {
        DeployV2FeeUpgradeTestnet.Deployment memory d = FeeUpgradeOperatorInvoker(OPERATOR).deploy(upgrade);
        x.venue = d.venue;
        x.treasury = d.treasury;
        x.token = d.token;
        x.curve = d.curve;
        x.hook = d.hook;
        x.factory = d.factory;
        x.router = d.router;
        x.nativeRouter = d.nativeRouter;
        x.policy = d.policy;
        x.policyKey = d.policyKey;
        x.engineKind = d.engineKind;
        x.hookSalt = d.hookSalt;
        for (uint256 i; i < d.lines.length; ++i) {
            x.lines.push(d.lines[i]);
        }
    }

    function _venueState() private view returns (bytes32) {
        bytes memory data = abi.encode(
            base.factory.getDefaults(),
            base.factory.strategyCount(),
            base.factory.publicLaunch(),
            base.treasury.factory(),
            base.curve.factory(),
            base.hook.factory(),
            base.token.factory(),
            address(base.router.factory())
        );
        for (uint256 i; i < base.lines.length; ++i) {
            DeployV2Testnet.Line memory l = base.lines[i];
            {
                (address oracle, address pool, uint256 open, bool enabled) = base.factory.listings(address(l.stock));
                data = abi.encode(data, oracle, pool, open, enabled);
            }
            {
                (uint16 dev, uint16 slip, uint64 chunk) = base.factory.listingGates(address(l.stock));
                data = abi.encode(data, dev, slip, chunk, base.treasury.lpBps(address(l.stock)));
            }
            data = abi.encode(
                data,
                l.feed.answer(),
                l.feed.round(),
                IV3Pool(l.pool).liquidity(),
                base.usdg.balanceOf(l.pool),
                l.stock.balanceOf(l.pool)
            );
        }
        return keccak256(data);
    }

    /// The release candidate is deployed by the current deployer wallet, which owns only what it deploys.
    function test_releaseDeployerOwnsOnlyTheNewCoreAndTheVenueIsUntouched() public {
        DeployV2FeeUpgradeTestnet.Seed[] memory seeds = new DeployV2FeeUpgradeTestnet.Seed[](8);
        for (uint256 i; i < base.lines.length; ++i) {
            DeployV2Testnet.Line memory l = base.lines[i];
            seeds[i] =
                DeployV2FeeUpgradeTestnet.Seed(l.symbol, address(l.stock), address(l.feed), address(l.oracle), l.pool);
        }
        ReleaseFixtureHarness release = new ReleaseFixtureHarness(
            DeployV2FeeUpgradeTestnet.Venue(
                base.factory, base.treasury, base.market, base.usdg, base.usdgFeed, base.calendar, base.v3Factory
            ),
            seeds
        );
        address signer = release.deploymentOperator();
        assertEq(signer, 0x36437b878415EdA1a24186CF79AFffBc9ecEd298);
        bytes32 beforeState = _venueState();
        vm.etch(signer, type(FeeUpgradeOperatorInvoker).runtimeCode);
        DeployV2FeeUpgradeTestnet.Deployment memory d = FeeUpgradeOperatorInvoker(payable(signer)).deploy(release);
        assertEq(d.factory.owner(), signer);
        assertEq(d.factory.protocol(), OPERATOR);
        assertEq(d.treasury.upgradeController().owner(), signer);
        assertEq(d.treasury.kindCount(), 3);
        assertTrue(d.factory.publicLaunch());
        assertEq(d.factory.getDefaults().launchFeeAmount, 0.0005 ether);
        assertEq(d.factory.getDefaults().maxCreatorBps, 5000);
        assertEq(release.plannedTransactionCount(), 40);
        assertEq(_venueState(), beforeState);
        assertEq(base.factory.owner(), OPERATOR);
        assertEq(base.market.owner(), OPERATOR);
        // any other wallet is refused before anything is sent
        vm.expectRevert(abi.encodeWithSelector(DeployV2FeeUpgradeTestnet.NotOperator.selector, address(this)));
        release.deploy(0);
    }

    function test_freshSignerOwnsOnlyNewCreatorCore() public {
        DeployV2FeeUpgradeTestnet.Seed[] memory seeds = new DeployV2FeeUpgradeTestnet.Seed[](8);
        for (uint256 i; i < base.lines.length; ++i) {
            DeployV2Testnet.Line memory l = base.lines[i];
            seeds[i] =
                DeployV2FeeUpgradeTestnet.Seed(l.symbol, address(l.stock), address(l.feed), address(l.oracle), l.pool);
        }
        FreshCreatorFixtureHarness fresh = new FreshCreatorFixtureHarness(
            DeployV2FeeUpgradeTestnet.Venue(
                base.factory, base.treasury, base.market, base.usdg, base.usdgFeed, base.calendar, base.v3Factory
            ),
            seeds
        );
        address signer = fresh.deploymentOperator();
        assertNotEq(signer, OPERATOR);
        bytes32 beforeState = _venueState();
        vm.etch(signer, type(FeeUpgradeOperatorInvoker).runtimeCode);
        DeployV2FeeUpgradeTestnet.Deployment memory d = FeeUpgradeOperatorInvoker(payable(signer)).deploy(fresh);
        assertEq(d.factory.owner(), signer);
        assertEq(d.factory.protocol(), OPERATOR);
        assertEq(d.treasury.kindCount(), 3);
        assertEq(fresh.plannedTransactionCount(), 40);
        assertEq(_venueState(), beforeState);
        assertEq(base.factory.owner(), OPERATOR);
        assertEq(base.market.owner(), OPERATOR);
    }

    function test_freshDeploymentRejectsLegacyOperatorBeforeVenueAccess() public {
        DeployV2FreshCreatorTestnet fresh = new DeployV2FreshCreatorTestnet();
        vm.expectRevert(abi.encodeWithSelector(DeployV2FeeUpgradeTestnet.NotOperator.selector, OPERATOR));
        FeeUpgradeOperatorInvoker(OPERATOR).deploy(fresh);
    }

    function test_newBindingsAndEightMarketsPreserveOldState() public {
        bytes32 beforeState = _venueState();
        _deploy();
        assertEq(_venueState(), beforeState);
        assertNotEq(address(x.factory), address(base.factory));
        assertNotEq(address(x.treasury), address(base.treasury));
        assertNotEq(address(x.curve), address(base.curve));
        assertNotEq(address(x.token), address(base.token));
        assertNotEq(address(x.hook), address(base.hook));
        assertEq(x.hook.version(), 3);
        assertEq(x.hook.factory(), address(x.factory));
        assertEq(x.treasury.factory(), address(x.factory));
        assertEq(x.curve.factory(), address(x.factory));
        assertEq(x.token.factory(), address(x.factory));
        assertEq(address(x.router.factory()), address(x.factory));
        assertEq(address(x.nativeRouter.router()), address(x.router));
        assertEq(address(x.nativeRouter.wrappedNative()), WETH);
        assertEq(x.factory.getDefaults().sweepTipBps, 0);
        assertEq(x.factory.getDefaults().protocolBps, 3000);
        assertEq(x.treasury.kindCount(), 3);
        assertEq(x.engineKind, 2);
        assertEq(x.lines.length, 8);
        assertEq(x.treasury.policy(x.policyKey).implementation, address(x.policy));
        for (uint256 i; i < x.lines.length; ++i) {
            DeployV2FeeUpgradeTestnet.Line memory l = x.lines[i];
            assertEq(l.pool, base.lines[i].pool);
            assertEq(address(l.stock), address(base.lines[i].stock));
            assertEq(address(l.feed), address(base.lines[i].feed));
            assertEq(address(l.oracle), address(base.lines[i].oracle));
            (address oracle, address pool, uint256 open, bool enabled) = x.factory.listings(address(l.stock));
            assertEq(oracle, address(l.oracle));
            assertEq(pool, l.pool);
            assertEq(open, l.openPriceE18);
            assertTrue(enabled);
        }
    }

    function test_refusesWrongChainAndSender() public {
        vm.chainId(4663);
        vm.expectRevert(abi.encodeWithSelector(DeployV2FeeUpgradeTestnet.WrongChain.selector, 4663));
        FeeUpgradeOperatorInvoker(OPERATOR).deploy(upgrade);
        vm.chainId(46630);
        vm.expectRevert(abi.encodeWithSelector(DeployV2FeeUpgradeTestnet.NotOperator.selector, address(this)));
        upgrade.deploy(0);
    }

    function test_refusesBrokenOldBindingBeforeDeploying() public {
        vm.mockCall(address(base.factory), abi.encodeWithSignature("owner()"), abi.encode(alice));
        vm.expectRevert(abi.encodeWithSelector(DeployV2FeeUpgradeTestnet.BadBinding.selector, "base venue"));
        FeeUpgradeOperatorInvoker(OPERATOR).deploy(upgrade);
    }

    function test_refusesBaseDefaultsThatExcludeOnePercentTax() public {
        HedgeFunFactory.Defaults memory defaults = base.factory.getDefaults();
        defaults.minTaxBps = 300;
        vm.prank(OPERATOR);
        base.factory.setDefaults(defaults);
        vm.expectRevert(abi.encodeWithSelector(DeployV2FeeUpgradeTestnet.BadBinding.selector, "base fee defaults"));
        FeeUpgradeOperatorInvoker(OPERATOR).deploy(upgrade);
    }

    function test_appendedNinthMarketDoesNotBlockOrExpandReviewedDeployment() public {
        DeployV2Testnet.Line memory extra = new EightStockFeeFixture().appendNinth(base, OPERATOR);
        assertEq(base.market.poolCount(), 9);
        bytes32 beforeState = _venueState();
        uint256 extraStock = extra.stock.balanceOf(extra.pool);
        uint256 extraUsdg = base.usdg.balanceOf(extra.pool);
        _deploy();
        assertEq(x.lines.length, 8);
        assertEq(base.market.poolCount(), 9);
        assertEq(base.market.pools(8), extra.pool);
        assertEq(_venueState(), beforeState);
        assertEq(extra.stock.balanceOf(extra.pool), extraStock);
        assertEq(base.usdg.balanceOf(extra.pool), extraUsdg);
        (address oracle, address pool,, bool enabled) = x.factory.listings(address(extra.stock));
        assertEq(oracle, address(0));
        assertEq(pool, address(0));
        assertFalse(enabled, "unreviewed ninth asset is not implicitly listed");
    }

    function test_extraMarketCannotReplaceAnOriginalReviewedPool() public {
        DeployV2Testnet.Line memory extra = new EightStockFeeFixture().appendNinth(base, OPERATOR);
        vm.mockCall(address(base.market), abi.encodeWithSignature("pools(uint256)", 0), abi.encode(extra.pool));
        vm.expectRevert(abi.encodeWithSelector(DeployV2FeeUpgradeTestnet.BadBinding.selector, "market line"));
        FeeUpgradeOperatorInvoker(OPERATOR).deploy(upgrade);
    }

    function test_fewerThanEightMarketsStillRefusedBeforeDeployment() public {
        vm.mockCall(address(base.market), abi.encodeWithSignature("poolCount()"), abi.encode(uint256(7)));
        vm.expectRevert(abi.encodeWithSelector(DeployV2FeeUpgradeTestnet.BadBinding.selector, "eight markets"));
        FeeUpgradeOperatorInvoker(OPERATOR).deploy(upgrade);
    }

    function test_refusesEmptyPoolBeforeDeploying() public {
        vm.mockCall(base.lines[0].pool, abi.encodeWithSignature("liquidity()"), abi.encode(uint128(0)));
        vm.expectRevert(abi.encodeWithSelector(DeployV2FeeUpgradeTestnet.BadBinding.selector, "pool depth/ring"));
        FeeUpgradeOperatorInvoker(OPERATOR).deploy(upgrade);
    }

    function test_candidateCannotBecomePublishedAndRequiresCommit() public {
        vm.setEnv("GIT_COMMIT", "not-a-commit");
        vm.expectRevert(DeployV2FeeUpgradeTestnet.BadCommit.selector);
        FeeUpgradeOperatorInvoker(OPERATOR).run(upgrade);
        vm.setEnv("GIT_COMMIT", "77914c9d26d2f8c24385882abaa2ad48e79affeb");
        FeeUpgradeOperatorInvoker(OPERATOR).run(upgrade);
        string memory json = vm.readFile("deploy/testnet-v2-fees.dryrun.json");
        assertFalse(vm.parseJsonBool(json, ".broadcast"));
        assertFalse(vm.parseJsonBool(json, ".broadcastRequested"));
        assertEq(vm.parseJsonString(json, ".featureVersion"), "v2-two-sided-stock-fees-v2");
        assertEq(vm.parseJsonUint(json, ".plannedTransactionCount"), 38);
        assertEq(vm.parseJsonUint(json, ".recommendedTaxBps"), 100);
        assertEq(vm.parseJsonUint(json, ".recommendedCreatorBps"), 1000);
        assertEq(vm.parseJsonAddress(json, ".stocks.MSFT.token"), address(base.lines[4].stock));
        assertEq(vm.parseJsonAddress(json, ".baseFactory"), address(base.factory));
    }

    function test_tslaLaunchCurveTradesGraduateV4AndSettleFees() public {
        _deploy();
        vm.warp(block.timestamp + 11 minutes);
        DeployV2FeeUpgradeTestnet.Line memory l = x.lines[1]; // TSLA in the fixture's original ordering
        vm.prank(OPERATOR);
        base.usdg.mint(alice, 100_000e6);
        HedgeFunFactory.Request memory q;
        q.name = "Two-sided fee test";
        q.symbol = "HFFEE";
        q.stock = address(l.stock);
        q.creator = alice;
        q.taxBps = 100;
        q.creatorBps = 1000;
        q.tp1Bps = 360; // This fixture deploys a fresh registry with the new ordinary V2 all-in floor.
        q.tp2Bps = 600;
        q.dipBps = 500;
        q.lotBps = 2000;
        q.maxFee = 0.0005 ether;
        q.expectedOpenPriceE18 = l.openPriceE18;
        vm.deal(alice, 0.0005 ether);
        vm.startPrank(alice);
        (,, bytes32 terms) = x.factory.predict(q);
        uint256 id = x.factory.launch{value: 0.0005 ether}(q, terms);
        (address token, address treasury,,,) = x.factory.strategies(id);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(x.factory.curves(id));
        assertEq(curve.taxBps(), 100);
        assertEq(curve.protocolBps(), 3000);
        assertEq(curve.creatorBps(), 1000);
        base.usdg.approve(address(x.router), type(uint256).max);
        IERC20(token).approve(address(x.router), type(uint256).max);
        HedgeFunV2TradeRouter.Hop[] memory buyPath = new HedgeFunV2TradeRouter.Hop[](1);
        buyPath[0] = HedgeFunV2TradeRouter.Hop(l.pool, address(l.stock));
        HedgeFunV2TradeRouter.Hop[] memory sellPath = new HedgeFunV2TradeRouter.Hop[](1);
        sellPath[0] = HedgeFunV2TradeRouter.Hop(l.pool, address(base.usdg));
        vm.warp(block.timestamp + 4);
        x.router.buy(_p(id, 100e6, 0, false), buyPath);
        assertGt(curve.totalFees(), 0);
        _assertCurveSplit(curve);
        uint256 feesBefore = curve.totalFees();
        x.router.sell(_p(id, IERC20(token).balanceOf(alice) / 3, 0, false), sellPath);
        assertGt(curve.totalFees(), feesBefore);
        x.router.buy(_p(id, 20_000e6, 0, true), buyPath);
        assertEq(uint8(curve.status()), 2);
        assertEq(curve.realStockReserve(), 0);
        assertEq(IERC20(address(l.stock)).balanceOf(address(curve)), curve.totalFees());
        assertGt(curve.totalFees(), 0, "migration leaves unpaid liabilities in the curve");
        x.router.buy(_p(id, 100e6, 2, false), buyPath);
        x.router.sell(_p(id, IERC20(token).balanceOf(alice) / 20, 2, false), sellPath);
        vm.stopPrank();
        _settle(curve, id, token, treasury, l);
        assertEq(IERC20(address(l.stock)).balanceOf(address(x.router)), 0);
        assertEq(IERC20(token).balanceOf(address(x.router)), 0);
        (bool healthy,) = HedgeFunV2Treasury(treasury).health();
        assertTrue(healthy);
    }

    function _assertCurveSplit(HedgeFunBondingCurve curve) private view {
        uint256 fee = curve.totalFees();
        assertEq(curve.claimable(OPERATOR), fee * 3000 / 10_000);
        assertEq(curve.claimable(alice), fee * 1000 / 10_000);
        assertEq(curve.claimable(curve.treasury()), fee - fee * 3000 / 10_000 - fee * 1000 / 10_000);
    }

    function _settle(
        HedgeFunBondingCurve curve,
        uint256 id,
        address token,
        address treasury,
        DeployV2FeeUpgradeTestnet.Line memory l
    ) private {
        _claimCurve(curve, IERC20(address(l.stock)), OPERATOR);
        _claimCurve(curve, IERC20(address(l.stock)), alice);
        _claimCurve(curve, IERC20(address(l.stock)), treasury);
        assertEq(curve.totalFees(), 0);
        assertEq(l.stock.balanceOf(address(curve)), 0);
        _frozenAndStockSplit(id, token, IERC20(address(l.stock)), treasury);
    }

    function _claimCurve(HedgeFunBondingCurve curve, IERC20 stock, address recipient) private {
        uint256 before = stock.balanceOf(recipient);
        uint256 owed = curve.claimable(recipient);
        curve.claimFees(recipient);
        assertEq(stock.balanceOf(recipient) - before, owed);
        before = stock.balanceOf(recipient);
        curve.claimFees(recipient);
        assertEq(stock.balanceOf(recipient), before);
    }

    function _frozenAndStockSplit(uint256 id, address token, IERC20 stock, address treasury) private {
        (PoolKey memory key,) = x.factory.graduationConfig(id);
        PoolId pid = key.toId();
        HedgeFunHook.Rates memory rates = x.hook.rates(pid);
        assertEq(rates.taxBps, 100);
        assertEq(rates.protocolBps, 3000);
        assertEq(rates.creatorBps, 1000);
        assertEq(rates.sweepTipBps, 0);
        assertEq(rates.snipeBps, 0);
        assertEq(rates.spikeBps, 0);
        (uint256 tokenFees, uint256 stockFees) = x.hook.accrued(pid);
        assertEq(tokenFees, 0, "the V4 buy's fee is stock, like the sale's");
        assertGt(stockFees, 0);
        assertEq(IPoolManager(PM).balanceOf(address(x.hook), uint256(uint160(token))), 0);
        _assertStockSplit(pid, stock, treasury, stockFees);
    }

    function _assertStockSplit(PoolId pid, IERC20 stock, address treasury, uint256 stockOut) private {
        uint256 before = stock.balanceOf(OPERATOR);
        uint256 creatorBefore = stock.balanceOf(alice);
        uint256 treasuryBefore = stock.balanceOf(treasury);
        x.hook.sweep(pid);
        assertEq(stock.balanceOf(OPERATOR) - before, stockOut * 3000 / 10_000);
        assertEq(stock.balanceOf(alice) - creatorBefore, stockOut * 1000 / 10_000);
        assertEq(
            stock.balanceOf(treasury) - treasuryBefore, stockOut - stockOut * 3000 / 10_000 - stockOut * 1000 / 10_000
        );
        before = stock.balanceOf(OPERATOR);
        x.hook.sweep(pid);
        assertEq(stock.balanceOf(OPERATOR), before);
        assertEq(x.hook.owedProtocol(pid), 0);
        assertEq(x.hook.owedCreator(pid), 0);
        assertEq(x.hook.owedTreasury(pid), 0);
    }

    function _p(uint256 id, uint256 amount, uint8 stage, bool allowPartial)
        private
        view
        returns (HedgeFunV2TradeRouter.TradeParams memory)
    {
        return HedgeFunV2TradeRouter.TradeParams(
            id, address(base.usdg), amount, 1, 1, block.timestamp, stage, allowPartial
        );
    }
}
