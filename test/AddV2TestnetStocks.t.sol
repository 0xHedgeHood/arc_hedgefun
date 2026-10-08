// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {DeployV2Testnet} from "../script/testnet/DeployV2Testnet.s.sol";
import {AddV2TestnetStocks} from "../script/testnet/AddV2TestnetStocks.s.sol";
import {IV3Pool} from "../script/testnet/TestnetMarket.sol";
import {MockToken} from "./mocks/Mocks.sol";

interface IObservationPool {
    function observe(uint32[] calldata) external view returns (int56[] memory, uint160[] memory);
}

contract AddStockHarness is AddV2TestnetStocks {
    Venue private fixture;

    constructor(Venue memory v) {
        fixture = v;
    }

    function _venue() internal view override returns (Venue memory) {
        return fixture;
    }
}

// Real calls from the operator address: Foundry forbids starting a script broadcast inside a prank frame.
contract OperatorInvoker {
    receive() external payable {}

    function append(AddV2TestnetStocks s) external returns (AddV2TestnetStocks.Line[] memory) {
        return s.append();
    }

    function run(AddV2TestnetStocks s) external {
        s.run();
    }

    function poke(AddV2TestnetStocks s, address[4] calldata pools) external {
        s.poke(pools);
    }
}

contract AddV2TestnetStocksTest is Test {
    address payable constant OPERATOR = payable(0x75Cee941B0eF3A83feA0397BbF903C12c1D7e96D);
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant WETH = 0x7943e237c7F95DA44E0301572D358911207852Fa;
    address alice = makeAddr("stock extension buyer");
    DeployV2Testnet.Deployment base;
    AddStockHarness extension;

    function setUp() public {
        vm.chainId(46630);
        vm.warp(1_790_690_000);
        vm.etch(OPERATOR, type(OperatorInvoker).runtimeCode);
        _deployAt(bytes.concat(type(PoolManager).creationCode, abi.encode(address(this))), PM);
        _deployAt(bytes.concat(type(MockToken).creationCode, abi.encode("WETH", uint8(18))), WETH);
        DeployV2Testnet.Deployment memory d = new DeployV2Testnet().deploy(OPERATOR, OPERATOR, 0);
        base.operator = d.operator;
        base.usdg = d.usdg;
        base.usdgFeed = d.usdgFeed;
        base.calendar = d.calendar;
        base.market = d.market;
        base.v3Factory = d.v3Factory;
        base.factory = d.factory;
        base.treasury = d.treasury;
        base.router = d.router;
        for (uint256 i; i < d.lines.length; i++) {
            base.lines.push(d.lines[i]);
        }
        extension = new AddStockHarness(
            AddV2TestnetStocks.Venue(d.factory, d.market, d.usdg, d.usdgFeed, d.calendar, d.v3Factory, d.treasury)
        );
    }

    function _deployAt(bytes memory creation, address where) private {
        vm.etch(where, creation);
        (bool ok, bytes memory runtime) = where.call("");
        require(ok, "constructor");
        vm.etch(where, runtime);
    }

    function _append() private returns (AddV2TestnetStocks.Line[] memory lines) {
        return OperatorInvoker(OPERATOR).append(extension);
    }

    function _oldState() private view returns (bytes32) {
        bytes memory encoded = abi.encode(
            base.factory.getDefaults(),
            base.factory.strategyCount(),
            base.factory.publicLaunch(),
            address(base.router.factory())
        );
        for (uint256 i; i < base.lines.length; i++) {
            DeployV2Testnet.Line memory l = base.lines[i];
            {
                (address oracle, address pool, uint256 open, bool enabled) = base.factory.listings(address(l.stock));
                encoded = abi.encode(encoded, base.market.pools(i), oracle, pool, open, enabled);
            }
            {
                (uint16 dev, uint16 slip, uint64 chunk) = base.factory.listingGates(address(l.stock));
                encoded = abi.encode(encoded, dev, slip, chunk);
            }
            (uint160 sqrtP,,,,,,) = IV3Pool(l.pool).slot0();
            encoded = abi.encode(
                encoded, base.treasury.lpBps(address(l.stock)), sqrtP, IV3Pool(l.pool).liquidity(), l.feed.answer()
            );
        }
        return keccak256(encoded);
    }

    function test_appendsFourStocksAndPreservesOldListings() public {
        bytes32 beforeState = _oldState();
        AddV2TestnetStocks.Line[] memory lines = _append();
        assertEq(_oldState(), beforeState);
        assertEq(base.market.poolCount(), 8);
        assertEq(lines.length, 4);
        string[4] memory symbols = [string("MSFT"), "AMZN", "GOOGL", "META"];
        for (uint256 i; i < lines.length; i++) {
            AddV2TestnetStocks.Line memory l = lines[i];
            assertEq(l.symbol, symbols[i]);
            assertEq(l.stock.symbol(), symbols[i]);
            assertEq(l.stock.owner(), OPERATOR);
            assertEq(l.feed.owner(), OPERATOR);
            assertTrue(l.stock.operators(address(base.market)));
            assertTrue(l.feed.operators(address(base.market)));
            assertEq(l.oracle.stock(), address(l.stock));
            assertEq(address(l.oracle.usdgFeed()), address(base.usdgFeed));
            assertEq(address(l.oracle.calendar()), address(base.calendar));
            assertEq(l.oracle.maxStockAge(), 26 hours);
            assertEq(base.market.pools(i + 4), l.pool);
            assertEq(base.v3Factory.getPool(address(l.stock), address(base.usdg), l.fee), l.pool);
            uint256 virtualStock = l.openPriceE18 * 1_000_000_000;
            uint256 raiseUsdgE18 = (virtualStock * 4400 / 5600) * l.priceE18 / 1e18;
            assertApproxEqAbs(raiseUsdgE18, 7_857_142_857_142_857_142_857, 1e12);
            vm.prank(alice);
            l.stock.drip();
            assertEq(l.stock.balanceOf(alice), l.stock.dripAmount());
        }
    }

    function test_refusesWrongChainBeforeMutation() public {
        vm.chainId(4663);
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(AddV2TestnetStocks.WrongChain.selector, 4663));
        extension.append();
    }

    function test_refusesWrongCallerBeforeMutation() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AddV2TestnetStocks.NotOperator.selector, alice));
        extension.append();
    }

    function test_refusesBrokenVenueOperatorBinding() public {
        vm.prank(OPERATOR);
        base.usdg.setOperator(address(base.market), false);
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(AddV2TestnetStocks.BadBinding.selector, "venue"));
        extension.append();
        assertEq(base.market.poolCount(), 4);
    }

    function test_refusesRepeatInsteadOfCreatingDuplicateTickers() public {
        _append();
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(AddV2TestnetStocks.AlreadyExtended.selector, 8));
        extension.append();
    }

    function test_pokeOnlyNewPoolsAndStartsUsableTwapAfter600Seconds() public {
        AddV2TestnetStocks.Line[] memory lines = _append();
        address[4] memory pools;
        for (uint256 i; i < 4; i++) {
            pools[i] = lines[i].pool;
        }
        vm.warp(block.timestamp + 1);
        OperatorInvoker(OPERATOR).poke(extension, pools);
        for (uint256 i; i < 4; i++) {
            (,,, uint16 card,,,) = IV3Pool(pools[i]).slot0();
            assertGe(card, 720);
        }
        vm.warp(block.timestamp + 600);
        uint32[] memory ages = new uint32[](2);
        ages[0] = 600;
        for (uint256 i; i < 4; i++) {
            IObservationPool(pools[i]).observe(ages);
        }
        pools[0] = base.lines[0].pool;
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(AddV2TestnetStocks.BadPoke.selector, pools[0]));
        extension.poke(pools);
    }

    function test_runWritesOnlyUnverifiedDryRunCandidate() public {
        OperatorInvoker(OPERATOR).run(extension);
        string memory json = vm.readFile("deploy/testnet-v2-stock-extension.dryrun.json");
        assertFalse(vm.parseJsonBool(json, ".broadcast"));
        assertFalse(vm.parseJsonBool(json, ".broadcastRequested"));
        assertEq(vm.parseJsonString(json, ".schema"), "v2-testnet-stock-extension-v1");
        assertEq(vm.parseJsonAddress(json, ".baseFactory"), address(base.factory));
        assertEq(vm.parseJsonKeys(json, ".stocks").length, 4);
        assertEq(vm.parseJsonUint(json, ".stocks.MSFT.priceE18"), 500e18);
    }

    function test_eachStockLaunchesGraduatesAndTradesWithLowerTargets() public {
        AddV2TestnetStocks.Line[] memory lines = _append();
        address[4] memory pools;
        for (uint256 i; i < 4; i++) {
            pools[i] = lines[i].pool;
        }
        vm.warp(block.timestamp + 1);
        OperatorInvoker(OPERATOR).poke(extension, pools);
        vm.warp(block.timestamp + 601);
        vm.prank(OPERATOR);
        base.usdg.mint(alice, 200_000e6);
        for (uint256 i; i < 4; i++) {
            _journey(lines[i], uint96(i + 1));
        }
    }

    function _journey(AddV2TestnetStocks.Line memory l, uint96 nonce) private {
        HedgeFunFactory.Request memory q;
        q.name = "Synthetic stock strategy";
        q.symbol = string.concat("EXT", l.symbol);
        q.stock = address(l.stock);
        q.creator = alice;
        q.taxBps = 100;
        q.creatorBps = 1000;
        q.tp1Bps = 300;
        q.tp2Bps = 600;
        q.dipBps = 500;
        q.lotBps = 2000;
        q.nonce = nonce;
        q.maxFee = type(uint256).max;
        q.expectedOpenPriceE18 = l.openPriceE18;
        vm.deal(alice, 0.0005 ether);
        vm.startPrank(alice);
        (,, bytes32 terms) = base.factory.predict(q);
        uint256 id = base.factory.launch{value: 0.0005 ether}(q, terms);
        (address token, address treasury,,,) = base.factory.strategies(id);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(base.factory.curves(id));
        HedgeFunV2TradeRouter.Hop[] memory path = new HedgeFunV2TradeRouter.Hop[](1);
        path[0] = HedgeFunV2TradeRouter.Hop(l.pool, address(l.stock));
        base.usdg.approve(address(base.router), type(uint256).max);
        vm.warp(block.timestamp + 4);
        // Quote the actual configured curve; a fixed historical payment assumed the old 44% default.
        (uint256 graduationStock,,) = curve.quoteBuy(type(uint128).max);
        uint256 payment = Math.mulDiv(graduationStock, l.priceE18, 1e30) * 11 / 10 + 1e6;
        base.router
            .buy(
                HedgeFunV2TradeRouter.TradeParams(
                    id, address(base.usdg), payment, 1, 1, block.timestamp, base.router.ACTIVE(), true
                ),
                path
            );
        assertEq(uint256(curve.status()), uint256(HedgeFunBondingCurve.Status.Graduated));
        (bool healthy,) = HedgeFunV2Treasury(treasury).health();
        assertTrue(healthy);
        uint256 beforeBuy = IERC20(token).balanceOf(alice);
        base.router
            .buy(
                HedgeFunV2TradeRouter.TradeParams(
                    id, address(base.usdg), 500e6, 1, 1, block.timestamp, base.router.GRADUATED(), false
                ),
                path
            );
        assertGt(IERC20(token).balanceOf(alice), beforeBuy);
        path[0] = HedgeFunV2TradeRouter.Hop(l.pool, address(base.usdg));
        IERC20(token).approve(address(base.router), type(uint256).max);
        uint256 beforeSell = base.usdg.balanceOf(alice);
        base.router
            .sell(
                HedgeFunV2TradeRouter.TradeParams(
                    id,
                    address(base.usdg),
                    IERC20(token).balanceOf(alice) / 10,
                    0,
                    1,
                    block.timestamp,
                    base.router.GRADUATED(),
                    false
                ),
                path
            );
        assertGt(base.usdg.balanceOf(alice), beforeSell);
        vm.stopPrank();
    }
}
