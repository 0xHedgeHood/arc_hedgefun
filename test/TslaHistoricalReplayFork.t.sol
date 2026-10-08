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
import {TestFeed, TestnetRoles} from "../script/testnet/TestnetAssets.sol";
import {TestnetMarket} from "../script/testnet/TestnetMarket.sol";

interface IHistoricalV3Position {
    function liquidity() external view returns (uint128);
    function tickSpacing() external view returns (int24);
    function positions(bytes32 key) external view returns (uint128, uint256, uint256, uint128, uint128);
    function burn(int24 lower, int24 upper, uint128 amount) external returns (uint256, uint256);
    function collect(address recipient, int24 lower, int24 upper, uint128 amount0Max, uint128 amount1Max) external returns (uint128, uint128);
}

/// Daily historical Close inputs applied to actual current contracts in an ephemeral testnet fork.
/// This is not a historical-chain backtest: calendar, local funding and constant V3 depth are counterfactual.
/// In particular one keeper opportunity per daily Close cannot test an intraday one-basis-point rule.
contract TslaHistoricalReplayForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    HedgeFunV2Factory constant FACTORY = HedgeFunV2Factory(0x2363B102D37BBa1dc3f9aBEdC4d6121C8e90B9cF);
    Router constant ROUTER = Router(0xEF6bE3C3A19F33C0F62beC3FFb37228e8c47F755);
    IERC20 constant STOCK = IERC20(0xcee322837F181Bd93AC2d71e4dDf334BFF565b98);
    IERC20 constant USDG = IERC20(0x539574139BB4Ac74Fd2183ba0E38ed777E30B58d);
    TestnetMarket constant ORIGINAL_MARKET = TestnetMarket(0xc1AF2f52980F8A7AA4E90A8E30D5c3FaF0375f21);
    address constant STOCK_POOL = 0x04083643FF9E8c27f66C9dD99947743A9B777244;
    address constant CREATOR = address(0xFACB01);
    address constant HOLDER = address(0xFACB02);
    address constant KEEPER = address(0xFACB03);
    uint256 constant FORK_BLOCK = 128172359;
    TestnetMarket market;
    PriceOracle oracle;
    Curve curve;
    IERC20 token;
    HedgeFunV2Treasury treasury;
    PoolKey key;
    uint256 id;
    uint256 actions;
    uint256 stopActions;
    uint256 tpActions;
    uint256 dipActions;
    uint256 buybacks;
    uint256 burned;
    uint256 buybackStockSpentRaw;
    uint256 buybackOracleUsdgValueRaw;
    uint256 dailyBuybackStockSpentRaw;
    uint256 dailyBuybackOracleUsdgValueRaw;
    uint256 executeNotDue;
    uint256 buybackNotDue;
    uint256 estimatedActionGas;
    uint256 lastActionCode;
    bytes4 lastExecuteRevert;
    bytes4 lastBuybackRevert;
    bool lastExecuteSuccess;
    bool lastBuybackSuccess;
    bool lastImmediateHealthy;
    uint256 startingHolderFun;
    uint128 expectedV3Liquidity;

    function setUp() public {
        vm.skip(!vm.envOr("HISTORICAL_REPLAY", false), "opt-in local-only historical Close replay");
        vm.createSelectFork(vm.envOr("HISTORICAL_FORK_RPC", string("https://rpc.testnet.chain.robinhood.com")), FORK_BLOCK);
        assertEq(block.chainid, 46630);
        (address o,,,) = FACTORY.listings(address(STOCK));
        oracle = PriceOracle(o);
        vm.mockCall(address(oracle.calendar()), abi.encodeWithSignature("isClosed(uint256)"), abi.encode(false));
        _widenLocalPosition();
    }

    /// Preserve current active V3 liquidity, widening only the market maker's local position.
    /// Historical prices below the original narrow range would otherwise be impossible to execute.
    function _widenLocalPosition() private {
        IHistoricalV3Position pool = IHistoricalV3Position(STOCK_POOL);
        (,,,,int24 oldLower,int24 oldUpper) = ORIGINAL_MARKET.lines(STOCK_POOL);
        (uint128 oldL,,,,) = pool.positions(keccak256(abi.encodePacked(address(ORIGINAL_MARKET), oldLower, oldUpper)));
        uint128 activeBefore = pool.liquidity();
        expectedV3Liquidity = activeBefore;
        assertGt(oldL, 0);
        assertEq(activeBefore, oldL, "single active seeded position required for fixed-depth assumption");
        vm.startPrank(address(ORIGINAL_MARKET));
        pool.burn(oldLower, oldUpper, oldL);
        pool.collect(address(ORIGINAL_MARKET), oldLower, oldUpper, type(uint128).max, type(uint128).max);
        vm.stopPrank();
        assertEq(pool.liquidity(), 0);
        market = new TestnetMarket(address(this), address(USDG));
        _operator(address(STOCK));
        _operator(address(USDG));
        _operator(address(oracle.stockFeed()));
        int24 newLower = TickMath.minUsableTick(pool.tickSpacing());
        int24 newUpper = TickMath.maxUsableTick(pool.tickSpacing());
        market.addLine(STOCK_POOL, address(STOCK), TestFeed(address(oracle.stockFeed())), 18, newLower, newUpper);
        market.provide(STOCK_POOL, oldL);
        assertEq(pool.liquidity(), activeBefore, "widening preserves active liquidity exactly");
        (uint128 newL,,,,) = pool.positions(keccak256(abi.encodePacked(address(market), newLower, newUpper)));
        assertEq(newL, oldL);
        string memory name = "venue";
        vm.serializeAddress(name, "pool", STOCK_POOL);
        vm.serializeAddress(name, "oldPositionOwner", address(ORIGINAL_MARKET));
        vm.serializeAddress(name, "newPositionOwner", address(market));
        vm.serializeInt(name, "oldTickLower", oldLower);
        vm.serializeInt(name, "oldTickUpper", oldUpper);
        vm.serializeInt(name, "newTickLower", newLower);
        vm.serializeInt(name, "newTickUpper", newUpper);
        vm.serializeUint(name, "oldPositionLiquidity", oldL);
        vm.serializeUint(name, "newPositionLiquidity", newL);
        vm.serializeUint(name, "activeLiquidityBefore", activeBefore);
        console2.log("HISTORICAL_VENUE", vm.serializeUint(name, "activeLiquidityAfter", pool.liquidity()));
    }

    function _operator(address target) private {
        TestnetRoles roles = TestnetRoles(target);
        vm.prank(roles.owner());
        roles.setOperator(address(market), true);
        assertTrue(roles.operators(address(market)));
    }

    function _move(uint256 price) private {
        market.setPrice(STOCK_POOL, price);
        if (address(treasury) != address(0)) (lastImmediateHealthy,) = treasury.health();
        vm.warp(block.timestamp + 601);
        market.poke(STOCK_POOL);
        assertEq(oracle.price(), price, "historical input uses eight-decimal feed precision");
        assertEq(IHistoricalV3Position(STOCK_POOL).liquidity(), expectedV3Liquidity, "V3 depth must stay fixed across historical ticks");
    }

    function _launch(uint256 year, uint256 mode, uint256 firstClose) private {
        _move(firstClose);
        deal(address(USDG), CREATOR, 25e6);
        deal(address(STOCK), HOLDER, 100e18);
        HedgeFunFactory.Request memory q;
        q.name = "Local historical Close replay";
        q.symbol = "TSLAHIST";
        q.creator = CREATOR;
        q.stock = address(STOCK);
        q.nonce = uint96(year * 10 + mode);
        q.taxBps = 300;
        q.creatorBps = 1000;
        q.tp1Bps = mode == 2 ? 1 : 500;
        q.tp2Bps = mode == 2 ? 2 : 1000;
        q.dipBps = mode == 2 ? 1 : 500;
        q.stopBps = mode == 2 ? 1 : 500;
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
        assertEq(treasury.params().tp1Bps, q.tp1Bps);
        assertEq(treasury.params().tp2Bps, q.tp2Bps);
        assertEq(treasury.params().dipBps, q.dipBps);
        assertEq(treasury.params().stopBps, q.stopBps);
        vm.warp(block.timestamp + 181);
        vm.startPrank(HOLDER);
        STOCK.approve(address(ROUTER), 50e18);
        ROUTER.buy(Router.TradeParams(id, address(STOCK), 50e18, 50e18, 1, block.timestamp, 0, true), new Router.Hop[](0));
        vm.stopPrank();
        assertEq(uint8(curve.status()), 2);
        assertEq(treasury.bookedStock(), 8833333333333333335);
        assertEq(treasury.reserveUsdg(), 0);
        assertEq(treasury.lotCount(), 1);
        assertApproxEqAbs(_funPrice(), 73611111111, 1);
        startingHolderFun = token.balanceOf(HOLDER);
    }

    function _funPrice() private view returns (uint256) {
        (uint160 sqrtP,,,) = FACTORY.poolManager().getSlot0(key.toId());
        uint256 ratioX96 = Math.mulDiv(sqrtP, sqrtP, 1 << 96);
        return address(token) < address(STOCK) ? Math.mulDiv(1e18, ratioX96, 1 << 96) : Math.mulDiv(1e18, 1 << 96, ratioX96);
    }

    function _lp() private view returns (uint256 stockAmount, uint256 tokenAmount) {
        (uint160 sqrtP,,,) = FACTORY.poolManager().getSlot0(key.toId());
        uint128 l = FACTORY.poolManager().getLiquidity(key.toId());
        uint256 a0 = SqrtPriceMath.getAmount0Delta(sqrtP, TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(key.tickSpacing)), l, false);
        uint256 a1 = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(key.tickSpacing)), sqrtP, l, false);
        return address(token) < address(STOCK) ? (a1,a0) : (a0,a1);
    }

    function _keeper() private {
        lastActionCode = 255;
        dailyBuybackStockSpentRaw = 0;
        dailyBuybackOracleUsdgValueRaw = 0;
        lastExecuteRevert = bytes4(0);
        lastBuybackRevert = bytes4(0);
        lastExecuteSuccess = false;
        lastBuybackSuccess = false;
        uint256 beforeGas = gasleft();
        vm.prank(KEEPER);
        try treasury.execute() returns (HedgeFunV2Treasury.Action action, uint256) {
            lastExecuteSuccess = true;
            ++actions;
            lastActionCode = uint256(action);
            if (action == HedgeFunV2Treasury.Action.Stop) ++stopActions;
            else if (action == HedgeFunV2Treasury.Action.TakeProfit) ++tpActions;
            else if (action == HedgeFunV2Treasury.Action.BuyDip) ++dipActions;
            else revert("unexpected kind-zero action");
        } catch (bytes memory reason) {
            lastExecuteRevert = bytes4(reason);
            if (lastExecuteRevert != bytes4(keccak256("NotDue()"))) console2.log("HISTORICAL_UNEXPECTED_EXECUTE_REVERT", vm.toString(reason));
            assertEq(lastExecuteRevert, bytes4(keccak256("NotDue()")), "investigate unexpected execute rejection");
            ++executeNotDue;
        }
        uint256 stockBeforeBuyback = STOCK.balanceOf(address(treasury));
        uint256 usdgBeforeBuyback = treasury.reserveUsdg();
        vm.prank(KEEPER);
        try treasury.buyback() returns (uint256 stockSpent, uint256 amountBurned) {
            assertEq(stockBeforeBuyback - STOCK.balanceOf(address(treasury)), stockSpent);
            assertEq(treasury.reserveUsdg(), usdgBeforeBuyback, "buyback pays TSLA, never USDG");
            dailyBuybackStockSpentRaw = stockSpent;
            dailyBuybackOracleUsdgValueRaw = Math.mulDiv(stockSpent, oracle.price(), 1e30);
            buybackStockSpentRaw += dailyBuybackStockSpentRaw;
            buybackOracleUsdgValueRaw += dailyBuybackOracleUsdgValueRaw;
            lastBuybackSuccess = true;
            ++buybacks;
            burned += amountBurned;
        } catch (bytes memory reason) {
            lastBuybackRevert = bytes4(reason);
            if (lastBuybackRevert != bytes4(keccak256("NotDue()"))) console2.log("HISTORICAL_UNEXPECTED_BUYBACK_REVERT", vm.toString(reason));
            assertEq(lastBuybackRevert, bytes4(keccak256("NotDue()")), "investigate unexpected buyback rejection");
            ++buybackNotDue;
        }
        // Test-call gas including harness control, excluding tx intrinsic gas. Never an actual gas bill.
        estimatedActionGas += beforeGas - gasleft();
    }

    function _accounting() private view {
        assertEq(IHistoricalV3Position(STOCK_POOL).liquidity(), expectedV3Liquidity, "post-action V3 depth must match the replay assumption");
        assertEq(treasury.bookedStock() + treasury.unbookedStock() + treasury.buybackStock(), STOCK.balanceOf(address(treasury)));
        uint256 accounted = token.balanceOf(HOLDER) + token.balanceOf(address(curve))
            + token.balanceOf(address(FACTORY.poolManager())) + token.balanceOf(address(FACTORY.hook()))
            + token.balanceOf(KEEPER) + token.balanceOf(address(treasury)) + token.balanceOf(address(FACTORY));
        assertEq(accounted, token.totalSupply(), "all FUN units accounted");
        assertEq(token.balanceOf(HOLDER), startingHolderFun, "passive holder never trades");
        assertEq(token.balanceOf(address(ROUTER)), 0);
        assertEq(STOCK.balanceOf(address(ROUTER)), 0);
        assertEq(USDG.balanceOf(address(ROUTER)), 0);
    }

    function _row(uint256 year, string memory mode, uint256 index, uint256 elapsed, string memory date, uint256 price) private {
        _accounting();
        string memory name = string.concat(vm.toString(year), mode, vm.toString(index));
        vm.serializeUint(name, "year", year);
        vm.serializeString(name, "mode", mode);
        vm.serializeUint(name, "index", index);
        vm.serializeString(name, "date", date);
        vm.serializeUint(name, "elapsedSeconds", elapsed);
        vm.serializeUint(name, "evmTimestamp", block.timestamp);
        vm.serializeUint(name, "forkBlock", FORK_BLOCK);
        vm.serializeUint(name, "tslaOracleUsdE18", price);
        vm.serializeUint(name, "stockSpotUsdE18", treasury.spotPrice());
        vm.serializeUint(name, "stockTwapUsdE18", treasury.twapPrice());
        vm.serializeUint(name, "stockPoolLiquidity", IHistoricalV3Position(STOCK_POOL).liquidity());
        vm.serializeBool(name, "immediateHealthy", lastImmediateHealthy);
        (bool healthy,) = treasury.health();
        vm.serializeBool(name, "healthyAfterAction", healthy);
        _portfolioRow(name, price);
        _actionRow(name);
        console2.log("HISTORICAL_ROW", vm.serializeUint(name, "estimatedActionGas", estimatedActionGas));
    }

    function _portfolioRow(string memory name, uint256 price) private {
        uint256 funStock = _funPrice();
        uint256 funDollar = Math.mulDiv(funStock, price, 1e18);
        vm.serializeUint(name, "funStockE18", funStock);
        vm.serializeUint(name, "funOracleUsdE18", funDollar);
        vm.serializeUint(name, "holderFunRaw", token.balanceOf(HOLDER));
        (uint256 lpStock, uint256 lpFun) = _lp();
        vm.serializeUint(name, "lpStockRaw", lpStock);
        vm.serializeUint(name, "lpFunRaw", lpFun);
        vm.serializeUint(name, "treasuryStockRaw", STOCK.balanceOf(address(treasury)));
        vm.serializeUint(name, "treasuryUsdgRaw", treasury.reserveUsdg());
        vm.serializeUint(name, "treasuryNavOracleUsdE18", Math.mulDiv(STOCK.balanceOf(address(treasury)), price, 1e18) + treasury.reserveUsdg()*1e12);
        vm.serializeUint(name, "treasuryBookedRaw", treasury.bookedStock());
        vm.serializeUint(name, "treasuryUnbookedRaw", treasury.unbookedStock());
        vm.serializeUint(name, "treasuryBuybackRaw", treasury.buybackStock());
        vm.serializeUint(name, "lotCount", treasury.lotCount());
        vm.serializeUint(name, "totalSupplyRaw", token.totalSupply());
        vm.serializeUint(name, "keeperStockRaw", STOCK.balanceOf(KEEPER));
        vm.serializeUint(name, "keeperUsdgRaw", USDG.balanceOf(KEEPER));
        vm.serializeUint(name, "keeperFunRaw", token.balanceOf(KEEPER));
        vm.serializeUint(name, "curveUnclaimedFeesRaw", curve.totalFees());
    }

    function _actionRow(string memory name) private {
        vm.serializeUint(name, "actions", actions);
        vm.serializeUint(name, "stopActions", stopActions);
        vm.serializeUint(name, "tpActions", tpActions);
        vm.serializeUint(name, "dipActions", dipActions);
        vm.serializeUint(name, "buybacks", buybacks);
        vm.serializeUint(name, "burnedRaw", burned);
        vm.serializeUint(name, "buybackStockSpentRaw", buybackStockSpentRaw);
        vm.serializeUint(name, "buybackOracleUsdgValueRaw", buybackOracleUsdgValueRaw);
        vm.serializeUint(name, "dailyBuybackStockSpentRaw", dailyBuybackStockSpentRaw);
        vm.serializeUint(name, "dailyBuybackOracleUsdgValueRaw", dailyBuybackOracleUsdgValueRaw);
        vm.serializeUint(name, "executeNotDue", executeNotDue);
        vm.serializeUint(name, "buybackNotDue", buybackNotDue);
        vm.serializeBool(name, "executeSuccess", lastExecuteSuccess);
        vm.serializeBool(name, "buybackSuccess", lastBuybackSuccess);
        vm.serializeUint(name, "actionCode", lastActionCode);
        vm.serializeBytes(name, "executeRevert", abi.encodePacked(lastExecuteRevert));
        vm.serializeBytes(name, "buybackRevert", abi.encodePacked(lastBuybackRevert));
    }

    function _run(uint256 year, uint256 mode) private {
        string memory input = vm.readFile("data/tsla-history-2022-2025.json");
        string memory prefix = string.concat(".windows.", vm.toString(year));
        uint256[] memory prices = vm.parseJsonUintArray(input, string.concat(prefix, ".pricesE18"));
        uint256[] memory elapsed = vm.parseJsonUintArray(input, string.concat(prefix, ".elapsedSeconds"));
        string[] memory dates = vm.parseJsonStringArray(input, string.concat(prefix, ".dates"));
        assertEq(prices.length, elapsed.length);
        assertEq(prices.length, dates.length);
        assertGt(prices.length, 240);
        assertEq(elapsed[0], 0);
        _launch(year, mode, prices[0]);
        uint256 epoch = block.timestamp;
        uint256 initialFunStock = _funPrice();
        uint256 initialStock = treasury.bookedStock();
        string memory modeName = mode == 0 ? "passive" : mode == 1 ? "keeper500" : "keeper1";
        lastActionCode = 255;
        for (uint256 i; i < prices.length; ++i) {
            if (i != 0) {
                assertGe(elapsed[i] - elapsed[i-1], 86400);
                uint256 nextPriceAt = epoch + elapsed[i] - 601;
                assertGt(nextPriceAt, block.timestamp, "synthetic EVM time may never go backwards");
                vm.warp(nextPriceAt);
                uint256 beforeFunStock = _funPrice();
                _move(prices[i]);
                assertEq(block.timestamp, epoch + elapsed[i], "actual calendar-day sample spacing");
                assertEq(_funPrice(), beforeFunStock, "external stock repricing leaves FUN/TSLA unchanged");
                (bool healthy,) = treasury.health();
                assertTrue(healthy, "oracle, spot and 600-second TWAP must corroborate the new Close");
                if (mode != 0) _keeper();
            }
            if (mode == 0) {
                assertEq(_funPrice(), initialFunStock);
                assertEq(treasury.bookedStock(), initialStock);
                assertEq(treasury.reserveUsdg(), 0);
            }
            _row(year, modeName, i, elapsed[i], dates[i], prices[i]);
        }
    }

    function testHistorical_2022_Passive() public { _run(2022,0); }
    function testHistorical_2022_Keeper500() public { _run(2022,1); }
    function testHistorical_2022_Keeper1() public { _run(2022,2); }
    function testHistorical_2023_Passive() public { _run(2023,0); }
    function testHistorical_2023_Keeper500() public { _run(2023,1); }
    function testHistorical_2023_Keeper1() public { _run(2023,2); }
    function testHistorical_2024_Passive() public { _run(2024,0); }
    function testHistorical_2024_Keeper500() public { _run(2024,1); }
    function testHistorical_2024_Keeper1() public { _run(2024,2); }
    function testHistorical_2025_Passive() public { _run(2025,0); }
    function testHistorical_2025_Keeper500() public { _run(2025,1); }
    function testHistorical_2025_Keeper1() public { _run(2025,2); }
}
