// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunBondingCurve as Curve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter as Router} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {TestnetMarket} from "../script/testnet/TestnetMarket.sol";

/// Actual latest creator contracts and actual V3/V4 venues, in an ephemeral testnet fork.
/// Counterfactual inputs: funded local actors, open-calendar mock, privileged local market-maker swaps.
/// No signing, keys, broadcast, public-chain state changes, or claim of a future TSLA forecast.
contract PersonaPriceImpactForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    HedgeFunV2Factory constant FACTORY = HedgeFunV2Factory(0x2363B102D37BBa1dc3f9aBEdC4d6121C8e90B9cF);
    Router constant ROUTER = Router(0xEF6bE3C3A19F33C0F62beC3FFb37228e8c47F755);
    IERC20 constant STOCK = IERC20(0xcee322837F181Bd93AC2d71e4dDf334BFF565b98);
    IERC20 constant USDG = IERC20(0x539574139BB4Ac74Fd2183ba0E38ed777E30B58d);
    TestnetMarket constant MARKET = TestnetMarket(0xc1AF2f52980F8A7AA4E90A8E30D5c3FaF0375f21);
    address constant STOCK_POOL = 0x04083643FF9E8c27f66C9dD99947743A9B777244;
    address constant CREATOR = address(0xFACA01);
    address constant HOLDER = address(0xFACA02);
    address constant FLOW = address(0xFACA03);
    address constant KEEPER = address(0xFACA04);
    uint256 constant FORK_BLOCK = 128172359;
    uint256 constant INITIAL_TSLA = 358e18;
    Curve curve;
    IERC20 token;
    HedgeFunV2Treasury treasury;
    PriceOracle oracle;
    PoolKey key;
    uint256 id;
    uint256 flowBuys;
    uint256 flowSells;
    uint256 actions;
    uint256 keeperBuybacks;
    uint256 totalBurned;
    uint256 samples;

    function setUp() public {
        vm.skip(!vm.envOr("PERSONA_PRICE_FORK", false), "opt-in local-only price experiment");
        vm.createSelectFork("https://rpc.testnet.chain.robinhood.com", FORK_BLOCK);
        assertEq(block.chainid, 46630);
        (address o,,,) = FACTORY.listings(address(STOCK));
        oracle = PriceOracle(o);
        // Weekend is the real pinned state. This explicit local-only override exercises an open session.
        vm.mockCall(address(oracle.calendar()), abi.encodeWithSignature("isClosed(uint256)"), abi.encode(false));
        _move(INITIAL_TSLA);
        deal(address(USDG), CREATOR, 25e6);
        deal(address(USDG), FLOW, 10_000e6);
        deal(address(STOCK), HOLDER, 100e18);
        deal(address(STOCK), FLOW, 10e18);
        HedgeFunFactory.Request memory q;
        q.name = "Local TSLA price impact";
        q.symbol = "PRICEFORK";
        q.creator = CREATOR;
        q.stock = address(STOCK);
        q.nonce = 2026100307;
        q.taxBps = 300;
        q.creatorBps = 1000;
        q.tp1Bps = 1;
        q.tp2Bps = 2;
        q.dipBps = 1;
        q.stopBps = 1;
        q.lotBps = 2000;
        q.maxFee = 25e6;
        (,,q.expectedOpenPriceE18,) = FACTORY.listings(address(STOCK));
        vm.startPrank(CREATOR);
        FACTORY.curveDeployer().setCurveConfig(q.symbol, q.nonce, 4000, 180);
        USDG.approve(address(FACTORY), 25e6);
        (,,bytes32 terms) = FACTORY.predict(q);
        id = FACTORY.launch(q, terms);
        vm.stopPrank();
        curve = Curve(FACTORY.curves(id));
        token = IERC20(curve.token());
        treasury = HedgeFunV2Treasury(curve.treasury());
        (key,) = FACTORY.graduationConfig(id);
        assertEq(treasury.params().tp1Bps, 1);
        assertEq(treasury.params().tp2Bps, 2);
        assertEq(treasury.params().dipBps, 1);
        assertEq(treasury.params().stopBps, 1);
        vm.warp(block.timestamp + 181);
        vm.startPrank(HOLDER);
        STOCK.approve(address(ROUTER), type(uint256).max);
        token.approve(address(ROUTER), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(FLOW);
        STOCK.approve(address(ROUTER), type(uint256).max);
        USDG.approve(address(ROUTER), type(uint256).max);
        token.approve(address(ROUTER), type(uint256).max);
        vm.stopPrank();
        _buyStock(HOLDER, 3e18);
        _buyStock(FLOW, 1e18);
        assertEq(uint8(curve.status()), 0);
    }

    function _buyStock(address who, uint256 amount) private {
        vm.startPrank(who);
        ROUTER.buy(Router.TradeParams(id, address(STOCK), amount, amount, 1, block.timestamp, uint8(curve.status()), true), new Router.Hop[](0));
        vm.stopPrank();
    }

    function _move(uint256 price) private returns (bool immediateHealthy) {
        vm.prank(MARKET.owner());
        MARKET.setPrice(STOCK_POOL, price);
        if (address(treasury) != address(0)) (immediateHealthy,) = treasury.health();
        vm.warp(block.timestamp + 601);
        vm.prank(MARKET.owner());
        MARKET.poke(STOCK_POOL);
        assertEq(oracle.price(), price);
    }

    function _funPrice() private view returns (uint256 stockPerFunE18) {
        if (curve.status() == Curve.Status.Active) {
            return Math.mulDiv(curve.virtualStock() + curve.realStockReserve(), 1e18, curve.tokenReserve());
        }
        (uint160 sqrtP,,,) = FACTORY.poolManager().getSlot0(key.toId());
        uint256 ratioX96 = Math.mulDiv(sqrtP, sqrtP, 1 << 96);
        return address(token) < address(STOCK)
            ? Math.mulDiv(1e18, ratioX96, 1 << 96)
            : Math.mulDiv(1e18, 1 << 96, ratioX96);
    }

    function _lp() private view returns (uint256 stockAmount, uint256 tokenAmount, uint256 liquidity) {
        if (curve.status() != Curve.Status.Graduated) return (0,0,0);
        (uint160 sqrtP,,,) = FACTORY.poolManager().getSlot0(key.toId());
        uint128 l = FACTORY.poolManager().getLiquidity(key.toId());
        uint256 a0 = SqrtPriceMath.getAmount0Delta(sqrtP, TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(key.tickSpacing)), l, false);
        uint256 a1 = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(key.tickSpacing)), sqrtP, l, false);
        return address(token) < address(STOCK) ? (a1,a0,l) : (a0,a1,l);
    }

    function _row(string memory scenario, string memory mode, uint256 point, string memory phase, uint256 target, bool immediateHealthy) private {
        _accounting();
        string memory name = string.concat(scenario, mode, vm.toString(point), phase);
        vm.serializeString(name, "scenario", scenario);
        vm.serializeString(name, "mode", mode);
        vm.serializeString(name, "phase", phase);
        vm.serializeUint(name, "point", point);
        vm.serializeUint(name, "stage", uint256(curve.status()));
        vm.serializeUint(name, "timestamp", block.timestamp);
        vm.serializeUint(name, "forkBlock", FORK_BLOCK);
        vm.serializeUint(name, "tslaUsdE18", target);
        vm.serializeUint(name, "stockSpotUsdE18", treasury.spotPrice());
        vm.serializeUint(name, "stockTwapUsdE18", treasury.twapPrice());
        _priceRow(name, target);
        _treasuryRow(name, target);
        vm.serializeBool(name, "immediateTreasuryHealthy", immediateHealthy);
        (bool health, uint256 healthPrice) = treasury.health();
        vm.serializeBool(name, "settledTreasuryHealthy", health);
        string memory json = vm.serializeUint(name, "healthPriceE18", healthPrice);
        console2.log("PRICE_IMPACT_ROW", json);
        ++samples;
    }

    function _priceRow(string memory name, uint256 target) private {
        uint256 funStock = _funPrice();
        uint256 funUsd = Math.mulDiv(funStock, target, 1e18);
        (uint256 lpStock, uint256 lpFun, uint256 liquidity) = _lp();
        vm.serializeUint(name, "funStockE18", funStock);
        vm.serializeUint(name, "funUsdE18", funUsd);
        vm.serializeUint(name, "holderFunRaw", token.balanceOf(HOLDER));
        vm.serializeUint(name, "holderMarkUsdE18", Math.mulDiv(token.balanceOf(HOLDER), funUsd, 1e18));
        vm.serializeUint(name, "flowFunRaw", token.balanceOf(FLOW));
        vm.serializeUint(name, "flowUsdRaw", USDG.balanceOf(FLOW));
        vm.serializeUint(name, "flowStockRaw", STOCK.balanceOf(FLOW));
        vm.serializeUint(name, "flowBuyCount", flowBuys);
        vm.serializeUint(name, "flowSellCount", flowSells);
        vm.serializeUint(name, "curveStockRaw", curve.realStockReserve());
        vm.serializeUint(name, "curveFeesStockRaw", curve.totalFees());
        vm.serializeUint(name, "lpStockRaw", lpStock);
        vm.serializeUint(name, "lpFunRaw", lpFun);
        vm.serializeUint(name, "lpLiquidity", liquidity);
        vm.serializeUint(name, "lpMarkUsdE18", Math.mulDiv(lpStock, target, 1e18) + Math.mulDiv(lpFun, funUsd, 1e18));
    }

    function _treasuryRow(string memory name, uint256 target) private {
        vm.serializeUint(name, "treasuryStockRaw", STOCK.balanceOf(address(treasury)));
        vm.serializeUint(name, "treasuryUsdRaw", treasury.reserveUsdg());
        vm.serializeUint(name, "treasuryNavUsdE18", Math.mulDiv(STOCK.balanceOf(address(treasury)), target, 1e18) + treasury.reserveUsdg()*1e12);
        vm.serializeUint(name, "treasuryBookedRaw", treasury.bookedStock());
        vm.serializeUint(name, "treasuryUnbookedRaw", treasury.unbookedStock());
        vm.serializeUint(name, "treasuryBuybackRaw", treasury.buybackStock());
        vm.serializeUint(name, "lots", treasury.lotCount());
        vm.serializeUint(name, "keeperActions", actions);
        vm.serializeUint(name, "keeperBuybacks", keeperBuybacks);
        vm.serializeUint(name, "burnedRaw", totalBurned);
        vm.serializeUint(name, "keeperStockRaw", STOCK.balanceOf(KEEPER));
        vm.serializeUint(name, "keeperUsdRaw", USDG.balanceOf(KEEPER));
        vm.serializeUint(name, "totalSupplyRaw", token.totalSupply());
        (uint256 tokenTax, uint256 stockTax) = FACTORY.hook().accrued(key.toId());
        vm.serializeUint(name, "hookTokenFeesRaw", tokenTax);
        vm.serializeUint(name, "hookStockFeesRaw", stockTax);
    }

    function _accounting() private view {
        assertEq(treasury.bookedStock() + treasury.unbookedStock() + treasury.buybackStock(), STOCK.balanceOf(address(treasury)));
        uint256 accounted = token.balanceOf(HOLDER) + token.balanceOf(FLOW) + token.balanceOf(address(curve))
            + token.balanceOf(address(FACTORY.poolManager())) + token.balanceOf(address(FACTORY.hook()))
            + token.balanceOf(KEEPER) + token.balanceOf(address(treasury)) + token.balanceOf(address(FACTORY));
        assertEq(accounted, token.totalSupply(), "all FUN units accounted including pending hook fees");
        assertEq(token.balanceOf(address(ROUTER)), 0);
        assertEq(STOCK.balanceOf(address(ROUTER)), 0);
        assertEq(USDG.balanceOf(address(ROUTER)), 0);
    }

    function _flow(bool buy) private {
        Router.Hop[] memory path = new Router.Hop[](1);
        if (buy) {
            path[0] = Router.Hop(STOCK_POOL, address(STOCK));
            vm.startPrank(FLOW);
            ROUTER.buy(Router.TradeParams(id, address(USDG), 100e6, 1, 1, block.timestamp, uint8(curve.status()), true), path);
            vm.stopPrank();
            ++flowBuys;
        } else {
            path[0] = Router.Hop(STOCK_POOL, address(USDG));
            uint256 offered = token.balanceOf(FLOW) / 5;
            vm.startPrank(FLOW);
            ROUTER.sell(Router.TradeParams(id, address(USDG), offered, 1, 1, block.timestamp, uint8(curve.status()), true), path);
            vm.stopPrank();
            ++flowSells;
        }
        assertEq(STOCK.balanceOf(address(ROUTER)), 0);
        assertEq(token.balanceOf(address(ROUTER)), 0);
        assertEq(USDG.balanceOf(address(ROUTER)), 0);
    }

    function _keeper(uint256 point) private {
        vm.prank(KEEPER);
        try treasury.execute() returns (HedgeFunV2Treasury.Action action, uint256) {
            ++actions;
            console2.log("KEEPER_ACTION", point, uint256(action));
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), bytes4(keccak256("NotDue()")), "unexpected keeper strategy revert");
            console2.log("KEEPER_EXECUTE_REVERT", point, vm.toString(reason));
        }
        vm.prank(KEEPER);
        try treasury.buyback() returns (uint256, uint256 burned) {
            ++keeperBuybacks;
            totalBurned += burned;
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), bytes4(keccak256("NotDue()")), "unexpected keeper buyback revert");
            console2.log("KEEPER_BUYBACK_REVERT", point, vm.toString(reason));
        }
    }

    function _path(uint256 which) private pure returns (string memory name, uint256[] memory values) {
        values = new uint256[](4);
        values[0] = INITIAL_TSLA;
        if (which == 0) { name = "up20"; values[1]=3759e17; values[2]=3938e17; values[3]=4296e17; }
        if (which == 1) { name = "down20"; values[1]=3401e17; values[2]=3222e17; values[3]=2864e17; }
        if (which == 2) { name = "crash50_recover"; values[1]=179e18; values[2]=2506e17; values[3]=358e18; }
        if (which == 3) { name = "flat_one_bps_noise"; values[1]=3580358e14; values[2]=3579642e14; values[3]=358e18; }
    }

    function _experiment(bool graduated, uint256 mode) private {
        if (graduated) {
            _buyStock(HOLDER, 50e18);
            assertEq(uint8(curve.status()), 2);
            assertGt(treasury.bookedStock(), 0);
        }
        string memory modeName = mode == 0 ? "passive" : mode == 1 ? "scripted_flow" : "keeper";
        uint256 checkpoint = vm.snapshotState();
        for (uint256 scenario; scenario < 4; ++scenario) {
            (string memory name, uint256[] memory path) = _path(scenario);
            for (uint256 i; i < path.length; ++i) {
                uint256 beforeFunStock = _funPrice();
                uint256 beforeHeld = token.balanceOf(HOLDER);
                bool immediate = _move(path[i]);
                // A TSLA/USDG repricing cannot directly move the separate FUN/TSLA pool or the holder's units.
                assertEq(_funPrice(), beforeFunStock);
                assertEq(token.balanceOf(HOLDER), beforeHeld);
                if (graduated) { (bool healthy,) = treasury.health(); assertTrue(healthy); }
                _row(name, modeName, i, "after_stock_move", path[i], immediate);
                if (i != 0 && mode == 1) {
                    // Explicit behavioural assumption: positive/flat print buys $100; negative print sells 20% holdings.
                    _flow(path[i] >= path[i-1]);
                    _row(name, modeName, i, "after_user_trade", path[i], immediate);
                }
                if (i != 0 && mode == 2) {
                    _keeper(i);
                    _row(name, modeName, i, "after_keeper", path[i], immediate);
                }
            }
            assertTrue(vm.revertToState(checkpoint));
        }
        vm.deleteStateSnapshot(checkpoint);
    }

    function testPricePaths_ActivePassive() public { _experiment(false,0); }
    function testPricePaths_ActiveOrderFlow() public { _experiment(false,1); }
    function testPricePaths_GraduatedPassive() public { _experiment(true,0); }
    function testPricePaths_GraduatedOrderFlow() public { _experiment(true,1); }
    function testPricePaths_GraduatedKeeper() public { _experiment(true,2); }

    function testPricePaths_WeekendAndImmediateShockGates() public {
        _buyStock(HOLDER, 50e18);
        (bool beforeHealth,) = treasury.health();
        assertTrue(beforeHealth);
        uint256 beforeBook = treasury.bookedStock();
        vm.prank(MARKET.owner());
        MARKET.setPrice(STOCK_POOL, INITIAL_TSLA*120/100);
        (bool immediate,) = treasury.health();
        assertFalse(immediate, "600-second mean blocks instant 20% market move");
        vm.expectRevert(bytes4(keccak256("Unhealthy()")));
        treasury.execute();
        assertEq(treasury.bookedStock(), beforeBook);
        _move(INITIAL_TSLA*120/100);
        (bool settled,) = treasury.health();
        assertTrue(settled);
        vm.clearMockedCalls();
        (bool weekend,) = treasury.health();
        assertFalse(weekend, "actual pinned Saturday calendar remains closed");
        vm.expectRevert(bytes4(keccak256("Unhealthy()")));
        treasury.execute();
        console2.log("PRICE_GATE_RESULT immediate_rejected=true settled_healthy=true weekend_rejected=true");
    }
}
