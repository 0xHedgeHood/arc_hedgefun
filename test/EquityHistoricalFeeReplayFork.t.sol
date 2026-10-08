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
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunBondingCurve as Curve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter as Router} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {TestFeed, TestnetRoles} from "../script/testnet/TestnetAssets.sol";
import {HedgeFunV2Hook} from "../src/hooks/HedgeFunV2Hook.sol";
import {ILegacyV2FeeConversion} from "../script/testnet/ILegacyV2FeeConversion.sol";
import {V2LiquidityVault} from "../src/v2/V2LiquidityVault.sol";
import {V2FundAssetReader} from "../src/v2/V2FundAssetReader.sol";
import {TestnetMarket} from "../script/testnet/TestnetMarket.sol";

interface IEquityV3Position {
    function liquidity() external view returns (uint128);
    function fee() external view returns (uint24);
    function token0() external view returns (address);
    function swap(address,bool,int256,uint160,bytes calldata) external returns (int256,int256);
    function tickSpacing() external view returns (int24);
    function positions(bytes32 key) external view returns (uint128, uint256, uint256, uint128, uint128);
    function burn(int24 lower, int24 upper, uint128 amount) external returns (uint256, uint256);
    function collect(address recipient, int24 lower, int24 upper, uint128 amount0Max, uint128 amount1Max) external returns (uint128, uint128);
}

/// Local-only 2025 Close replay against the deployed creator kind-zero core and real V3/V4 venues.
/// All profiles start with $10k treasury and $10k LP stock; flow is a synthetic $100 buy/sell load.
/// Harvest on/off uses identical addresses, funding and orders. No historical FUN demand is inferred.
/// Calendar is mocked open and each venue's current liquidity is preserved in a widened local range.
contract EquityHistoricalFeeReplayForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    HedgeFunV2Factory constant FACTORY = HedgeFunV2Factory(0x2363B102D37BBa1dc3f9aBEdC4d6121C8e90B9cF);
    Router constant ROUTER = Router(0xEF6bE3C3A19F33C0F62beC3FFb37228e8c47F755);
    IERC20 stock;
    IERC20 constant USDG = IERC20(0x539574139BB4Ac74Fd2183ba0E38ed777E30B58d);
    TestnetMarket constant ORIGINAL_MARKET = TestnetMarket(0xc1AF2f52980F8A7AA4E90A8E30D5c3FaF0375f21);
    address stockPool;
    address constant CREATOR = address(0xFACC01);
    address constant HOLDER = address(0xFACC02);
    address constant KEEPER = address(0xFACC03);
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
    address constant TRADER = address(0xFACC04);
    address constant DEPTH = address(0xFACC05);
    uint256 constant TREASURY_CAPITAL_USDG = 10_000e6;
    uint256 constant TRADER_INITIAL_USDG = 100_000e6;
    uint256 constant DAILY_BUY_USDG = 100e6;
    V2LiquidityVault vault;
    V2FundAssetReader reader;
    string ticker;
    string profileName;
    bool harvestEnabled;
    bool strategyEnabled;
    bool flowEnabled;
    bool buybackEnabled;
    bool depthCallback;
    uint256 traderUsdIn;
    uint256 traderUsdOut;
    uint256 flowPairs;
    uint256 collectedStockFees;
    uint256 collectedTokenBurn;
    uint256 externalStockFeesGenerated;
    uint256 externalTokenFeesGenerated;
    uint256 selfStockFeesGenerated;
    uint256 selfTokenFeesGenerated;
    uint256 conversionStockFeesGenerated;
    uint256 conversionTokenFeesGenerated;
    uint256 convertedFeeTokens;
    uint256 convertedFeeStock;
    uint256 hookStockDelivered;
    uint256 hookTokenBurn;
    uint256 hookProtocolStockPaid;
    uint256 hookCreatorStockPaid;
    uint256 hookSweeperStockPaid;
    uint256 conversionCount;
    uint256 collectedFeesOracleUsdgValueRaw;
    uint256 dailyCollectedStock;
    uint256 dailyCollectedBurn;
    uint256 expectedInitialSupply;
    uint256 normalizedOpenPrice;
    uint256 launchStockSpent;
    uint256 maxStrategyStockInputUsd;
    uint256 maxStrategyUsdgInput;
    uint256 maxBuybackStockInputUsd;
    uint256 maxBuybackExternalAssetDustUsdgRaw;
    uint256 initialExternalAssets;
    uint256 lastExternalAssets;
    uint256 runEpoch;
    uint256 runInitialFunStock;
    uint256 runInitialStock;
    uint256 runLastElapsed;
    uint256 cumulativePriceMarkDeltaPositive;
    uint256 cumulativePriceMarkDeltaNegative;
    uint256 cumulativeActionDeltaPositive;
    uint256 cumulativeActionDeltaNegative;

    struct Fees { uint256 stockAmount; uint256 tokenAmount; }
    struct DepthQuote { uint256 spent; uint256 received; uint256 inputUsd; uint256 outputUsd; uint256 costPpm; uint256 feePpm; }


    function setUp() public {
        vm.skip(!vm.envOr("EQUITY_FEE_REPLAY", false), "opt-in local-only equity fee replay");
        vm.createSelectFork(vm.envOr("EQUITY_FORK_RPC", string("https://robinhood-testnet.drpc.org")), FORK_BLOCK);
        assertEq(block.chainid, 46630);
    }

    /// Preserve current active V3 liquidity, widening only the market maker's local position.
    /// Historical prices below the original narrow range would otherwise be impossible to execute.
    function _widenLocalPosition() private {
        IEquityV3Position pool = IEquityV3Position(stockPool);
        (,,,,int24 oldLower,int24 oldUpper) = ORIGINAL_MARKET.lines(stockPool);
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
        _operator(address(stock));
        _operator(address(USDG));
        _operator(address(oracle.stockFeed()));
        int24 newLower = TickMath.minUsableTick(pool.tickSpacing());
        int24 newUpper = TickMath.maxUsableTick(pool.tickSpacing());
        market.addLine(stockPool, address(stock), TestFeed(address(oracle.stockFeed())), 18, newLower, newUpper);
        market.provide(stockPool, oldL);
        assertEq(pool.liquidity(), activeBefore, "widening preserves active liquidity exactly");
        (uint128 newL,,,,) = pool.positions(keccak256(abi.encodePacked(address(market), newLower, newUpper)));
        assertEq(newL, oldL);
        string memory name = "venue";
        vm.serializeString(name, "ticker", ticker);
        vm.serializeAddress(name, "pool", stockPool);
        vm.serializeAddress(name, "oldPositionOwner", address(ORIGINAL_MARKET));
        vm.serializeAddress(name, "newPositionOwner", address(market));
        vm.serializeInt(name, "oldTickLower", oldLower);
        vm.serializeInt(name, "oldTickUpper", oldUpper);
        vm.serializeInt(name, "newTickLower", newLower);
        vm.serializeInt(name, "newTickUpper", newUpper);
        vm.serializeUint(name, "oldPositionLiquidity", oldL);
        vm.serializeUint(name, "newPositionLiquidity", newL);
        vm.serializeUint(name, "activeLiquidityBefore", activeBefore);
        console2.log("EQUITY_VENUE", vm.serializeUint(name, "activeLiquidityAfter", pool.liquidity()));
    }

    function _operator(address target) private {
        TestnetRoles roles = TestnetRoles(target);
        vm.prank(roles.owner());
        roles.setOperator(address(market), true);
        assertTrue(roles.operators(address(market)));
    }

    function _move(uint256 price) private {
        market.setPrice(stockPool, price);
        if (address(treasury) != address(0)) (lastImmediateHealthy,) = treasury.health();
        vm.warp(block.timestamp + 601);
        market.poke(stockPool);
        assertEq(oracle.price(), price, "historical input uses eight-decimal feed precision");
        assertEq(IEquityV3Position(stockPool).liquidity(), expectedV3Liquidity, "V3 depth must stay fixed across historical ticks");
    }

    function _launch(uint256 profile, uint256 firstClose) private {
        _move(firstClose);
        // Only this fork's listing is changed. At sale40%/LP50%, treasury stock is virtualStock/3.
        uint256 virtualStock = Math.mulDiv(3 * TREASURY_CAPITAL_USDG, 1e30, firstClose, Math.Rounding.Ceil);
        uint256 supply = FACTORY.getDefaults().supply;
        normalizedOpenPrice = Math.mulDiv(virtualStock, 1e18, supply, Math.Rounding.Ceil);
        vm.prank(FACTORY.owner());
        FACTORY.list(address(stock), address(oracle), stockPool, normalizedOpenPrice, true);
        deal(address(USDG), CREATOR, 25e6);
        deal(address(stock), HOLDER, virtualStock * 2);
        HedgeFunFactory.Request memory q;
        q.name = "Local normalized equity fee replay";
        q.symbol = "EQFEES2025";
        q.creator = CREATOR;
        q.stock = address(stock);
        // Harvest flag deliberately excluded: matched on/off uses identical deterministic contracts.
        q.nonce = uint96(202500 + profile * 100);
        q.taxBps = 300;
        q.creatorBps = 1000;
        uint16 rung = profile == 2 ? 100 : profile == 3 ? 300 : profile == 5 ? 1000 : 500;
        q.tp1Bps = rung;
        q.tp2Bps = uint32(rung) * 2;
        q.dipBps = rung;
        q.stopBps = profile == 6 ? 0 : rung;
        q.lotBps = 2000;
        q.maxFee = 25e6;
        q.expectedOpenPriceE18 = normalizedOpenPrice;
        vm.startPrank(CREATOR);
        while (FACTORY.predictToken(q) >= address(stock)) ++q.nonce;
        FACTORY.curveDeployer().setCurveConfig(q.symbol, q.nonce, 4000, 180);
        USDG.approve(address(FACTORY), 25e6);
        (,,bytes32 terms) = FACTORY.predict(q);
        id = FACTORY.launch(q, terms);
        vm.stopPrank();
        curve = Curve(FACTORY.curves(id));
        token = IERC20(curve.token());
        assertTrue(address(token) < address(stock), "same token ordering across profiles");
        treasury = HedgeFunV2Treasury(curve.treasury());
        (key,) = FACTORY.graduationConfig(id);
        assertEq(treasury.params().tp1Bps, q.tp1Bps);
        assertEq(treasury.params().tp2Bps, q.tp2Bps);
        assertEq(treasury.params().dipBps, q.dipBps);
        assertEq(treasury.params().stopBps, q.stopBps);
        vm.warp(block.timestamp + 181);
        uint256 beforeStock = stock.balanceOf(HOLDER);
        vm.startPrank(HOLDER);
        stock.approve(address(ROUTER), virtualStock * 2);
        ROUTER.buy(Router.TradeParams(id, address(stock), virtualStock * 2, virtualStock * 2, 1, block.timestamp, 0, true), new Router.Hop[](0));
        vm.stopPrank();
        launchStockSpent = beforeStock - stock.balanceOf(HOLDER);
        assertEq(uint8(curve.status()), 2);
        assertApproxEqAbs(Math.mulDiv(treasury.bookedStock(), firstClose, 1e30), TREASURY_CAPITAL_USDG, 1);
        assertEq(treasury.reserveUsdg(), 0);
        assertEq(treasury.lotCount(), 1);
        startingHolderFun = token.balanceOf(HOLDER);
        expectedInitialSupply = token.totalSupply();
        vault = V2LiquidityVault(treasury.liquidityVault());
        // Auxiliary read-only production reader; local prank binds its immutable treasury correctly.
        address manager = address(FACTORY.poolManager());
        vm.prank(address(treasury));
        reader = new V2FundAssetReader(address(stock), address(USDG), manager, address(token), address(FACTORY), 1e30);
        assertEq(reader.treasury(), address(treasury));
        initialExternalAssets = reader.totalAssets(firstClose);
        assertApproxEqAbs(initialExternalAssets, 2 * TREASURY_CAPITAL_USDG, 2);
        deal(address(USDG), TRADER, TRADER_INITIAL_USDG);
        vm.startPrank(TRADER);
        USDG.approve(address(ROUTER), type(uint256).max);
        token.approve(address(ROUTER), type(uint256).max);
        vm.stopPrank();
        _profileMetadata(q.nonce, firstClose);
    }

    function _funPrice() private view returns (uint256) {
        (uint160 sqrtP,,,) = FACTORY.poolManager().getSlot0(key.toId());
        uint256 ratioX96 = Math.mulDiv(sqrtP, sqrtP, 1 << 96);
        return address(token) < address(stock) ? Math.mulDiv(1e18, ratioX96, 1 << 96) : Math.mulDiv(1e18, 1 << 96, ratioX96);
    }

    function _lp() private view returns (uint256 stockAmount, uint256 tokenAmount) {
        (uint160 sqrtP,,,) = FACTORY.poolManager().getSlot0(key.toId());
        uint128 l = FACTORY.poolManager().getLiquidity(key.toId());
        uint256 a0 = SqrtPriceMath.getAmount0Delta(sqrtP, TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(key.tickSpacing)), l, false);
        uint256 a1 = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(key.tickSpacing)), sqrtP, l, false);
        return address(token) < address(stock) ? (a1,a0) : (a0,a1);
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
        if (strategyEnabled) _executeStrategy();
        if (buybackEnabled) _buyback();
        estimatedActionGas += beforeGas - gasleft();
    }

    function _executeStrategy() private {
        uint256 stockBefore = stock.balanceOf(address(treasury));
        uint256 usdgBefore = treasury.reserveUsdg();
        vm.prank(KEEPER);
        try treasury.execute() returns (HedgeFunV2Treasury.Action action, uint256) {
            lastExecuteSuccess = true;
            ++actions;
            lastActionCode = uint256(action);
            if (action == HedgeFunV2Treasury.Action.Stop) ++stopActions;
            else if (action == HedgeFunV2Treasury.Action.TakeProfit) ++tpActions;
            else if (action == HedgeFunV2Treasury.Action.BuyDip) ++dipActions;
            else revert("unexpected kind-zero action");
            uint256 stockAfter = stock.balanceOf(address(treasury));
            uint256 usdgAfter = treasury.reserveUsdg();
            if (stockBefore > stockAfter) maxStrategyStockInputUsd = Math.max(maxStrategyStockInputUsd, Math.mulDiv(stockBefore-stockAfter, oracle.price(), 1e30));
            if (usdgBefore > usdgAfter) maxStrategyUsdgInput = Math.max(maxStrategyUsdgInput, usdgBefore-usdgAfter);
        } catch (bytes memory reason) {
            lastExecuteRevert = bytes4(reason);
            if (lastExecuteRevert != bytes4(keccak256("NotDue()"))) console2.log("EQUITY_UNEXPECTED_EXECUTE_REVERT", vm.toString(reason));
            assertEq(lastExecuteRevert, bytes4(keccak256("NotDue()")), "investigate unexpected execute rejection");
            ++executeNotDue;
        }
    }

    function _buyback() private {
        Fees memory feeBefore = _probeFees();
        uint256 externalBeforeBuyback = reader.totalAssets(oracle.price());
        uint256 stockBeforeBuyback = stock.balanceOf(address(treasury));
        uint256 usdgBeforeBuyback = treasury.reserveUsdg();
        vm.prank(KEEPER);
        try treasury.buyback() returns (uint256 stockSpent, uint256 amountBurned) {
            assertEq(stockBeforeBuyback - stock.balanceOf(address(treasury)), stockSpent);
            assertEq(treasury.reserveUsdg(), usdgBeforeBuyback, "buyback pays stock, never USDG");
            dailyBuybackStockSpentRaw = stockSpent;
            dailyBuybackOracleUsdgValueRaw = Math.mulDiv(stockSpent, oracle.price(), 1e30);
            maxBuybackStockInputUsd = Math.max(maxBuybackStockInputUsd, dailyBuybackOracleUsdgValueRaw);
            buybackStockSpentRaw += stockSpent;
            buybackOracleUsdgValueRaw += dailyBuybackOracleUsdgValueRaw;
            lastBuybackSuccess = true;
            ++buybacks;
            burned += amountBurned;
        } catch (bytes memory reason) {
            lastBuybackRevert = bytes4(reason);
            if (lastBuybackRevert != bytes4(keccak256("NotDue()"))) console2.log("EQUITY_UNEXPECTED_BUYBACK_REVERT", vm.toString(reason));
            assertEq(lastBuybackRevert, bytes4(keccak256("NotDue()")), "investigate unexpected buyback rejection");
            ++buybackNotDue;
        }
        uint256 externalAfterBuyback = reader.totalAssets(oracle.price());
        assertApproxEqAbs(externalAfterBuyback, externalBeforeBuyback, 1, "buyback moves own stock into own LP without creating external assets");
        uint256 assetDust = externalAfterBuyback > externalBeforeBuyback ? externalAfterBuyback-externalBeforeBuyback : externalBeforeBuyback-externalAfterBuyback;
        maxBuybackExternalAssetDustUsdgRaw = Math.max(maxBuybackExternalAssetDustUsdgRaw, assetDust);
        Fees memory feeAfter = _probeFees();
        selfStockFeesGenerated += feeAfter.stockAmount - feeBefore.stockAmount;
        selfTokenFeesGenerated += feeAfter.tokenAmount - feeBefore.tokenAmount;
    }

    function _accounting() private view {
        assertEq(IEquityV3Position(stockPool).liquidity(), expectedV3Liquidity, "post-action V3 depth must match the replay assumption");
        assertEq(treasury.bookedStock() + treasury.unbookedStock() + treasury.buybackStock(), stock.balanceOf(address(treasury)));
        uint256 accounted = token.balanceOf(TRADER) + token.balanceOf(address(vault)) + token.balanceOf(HOLDER) + token.balanceOf(address(curve))
            + token.balanceOf(address(FACTORY.poolManager())) + token.balanceOf(address(FACTORY.hook()))
            + token.balanceOf(KEEPER) + token.balanceOf(address(treasury)) + token.balanceOf(address(FACTORY));
        assertEq(accounted, token.totalSupply(), "all FUN units accounted");
        assertEq(token.balanceOf(HOLDER), startingHolderFun, "passive holder never trades");
        assertEq(token.balanceOf(TRADER), 0, "round-trip trader sells exactly acquired net FUN");
        assertEq(USDG.balanceOf(TRADER), TRADER_INITIAL_USDG - traderUsdIn + traderUsdOut);
        assertEq(token.totalSupply() + burned + collectedTokenBurn + hookTokenBurn, expectedInitialSupply);
        assertEq(stock.balanceOf(address(vault)), 0, "no parked LP stock allowed in this fixture");
        assertEq(token.balanceOf(address(ROUTER)), 0);
        assertEq(stock.balanceOf(address(ROUTER)), 0);
        assertEq(USDG.balanceOf(address(ROUTER)), 0);
    }

    function _row(uint256 index, uint256 elapsed, string memory date, uint256 price) private {
        _accounting();
        string memory name = string.concat(ticker, profileName, harvestEnabled ? "on" : "off", vm.toString(index));
        vm.serializeString(name, "ticker", ticker);
        vm.serializeString(name, "profile", profileName);
        vm.serializeBool(name, "harvestEnabled", harvestEnabled);
        vm.serializeUint(name, "index", index);
        vm.serializeString(name, "date", date);
        vm.serializeUint(name, "elapsedSeconds", elapsed);
        vm.serializeUint(name, "evmTimestamp", block.timestamp);
        vm.serializeUint(name, "stockOracleUsdE18", price);
        vm.serializeUint(name, "stockSpotUsdE18", treasury.spotPrice());
        vm.serializeUint(name, "stockPoolLiquidity", IEquityV3Position(stockPool).liquidity());
        (bool healthy,) = treasury.health();
        vm.serializeBool(name, "healthyAfterAction", healthy);
        _portfolioRow(name, price);
        _actionRow(name);
        _feesRow(name, price);
        console2.log("EQUITY_ROW", vm.serializeUint(name, "estimatedActionGas", estimatedActionGas));
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
        vm.serializeUint(name, "treasuryStockRaw", stock.balanceOf(address(treasury)));
        vm.serializeUint(name, "treasuryUsdgRaw", treasury.reserveUsdg());
        vm.serializeUint(name, "treasuryNavOracleUsdE18", Math.mulDiv(stock.balanceOf(address(treasury)), price, 1e18) + treasury.reserveUsdg()*1e12);
        vm.serializeUint(name, "treasuryBookedRaw", treasury.bookedStock());
        vm.serializeUint(name, "treasuryUnbookedRaw", treasury.unbookedStock());
        vm.serializeUint(name, "treasuryBuybackRaw", treasury.buybackStock());
        vm.serializeUint(name, "lotCount", treasury.lotCount());
        vm.serializeUint(name, "totalSupplyRaw", token.totalSupply());
        vm.serializeUint(name, "keeperStockRaw", stock.balanceOf(KEEPER));
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

    function _run(string memory symbol, uint256 profile, bool harvest) private {
        string memory input = vm.readFile("data/equity-history-2025.json");
        string memory prefix = string.concat(".windows.", symbol);
        ticker = symbol;
        stock = IERC20(vm.parseJsonAddress(input, string.concat(prefix, ".stock")));
        stockPool = vm.parseJsonAddress(input, string.concat(prefix, ".pool"));
        (address o,address listedPool,,bool enabled) = FACTORY.listings(address(stock));
        assertTrue(enabled);
        assertEq(stockPool, listedPool);
        oracle = PriceOracle(o);
        vm.mockCall(address(oracle.calendar()), abi.encodeWithSignature("isClosed(uint256)"), abi.encode(false));
        _widenLocalPosition();
        uint256[] memory prices = vm.parseJsonUintArray(input, string.concat(prefix, ".pricesE18"));
        uint256[] memory elapsed = vm.parseJsonUintArray(input, string.concat(prefix, ".elapsedSeconds"));
        string[] memory dates = vm.parseJsonStringArray(input, string.concat(prefix, ".dates"));
        assertEq(prices.length, 250);
        assertEq(prices.length, elapsed.length);
        assertEq(prices.length, dates.length);
        assertEq(elapsed[0], 0);
        profileName = profile == 0 ? "baseline" : profile == 1 ? "fee_only" : profile == 2 ? "p100" : profile == 3 ? "p300" : profile == 4 ? "p500" : profile == 5 ? "p1000" : "p500_stop_off";
        harvestEnabled = harvest;
        strategyEnabled = profile >= 2;
        flowEnabled = profile != 0;
        buybackEnabled = profile != 0;
        _launch(profile, prices[0]);
        _depthProbes();
        runEpoch = block.timestamp;
        runInitialFunStock = _funPrice();
        runInitialStock = treasury.bookedStock();
        lastExternalAssets = initialExternalAssets;
        lastActionCode = 255;
        for (uint256 i; i < prices.length; ++i) {
            // An external call gives each day's rich audit serialization a fresh EVM memory arena.
            this.replayDay(i, elapsed[i], dates[i], prices[i]);
        }
    }

    function replayDay(uint256 index, uint256 elapsed, string memory date, uint256 price) external {
        require(msg.sender == address(this), "test self-call only");
        if (index != 0) {
            assertGe(elapsed - runLastElapsed, 86400);
            uint256 nextPriceAt = runEpoch + elapsed - 601;
            assertGt(nextPriceAt, block.timestamp);
            vm.warp(nextPriceAt);
            uint256 beforeFunStock = _funPrice();
            _move(price);
            assertEq(block.timestamp, runEpoch + elapsed);
            assertEq(_funPrice(), beforeFunStock);
            (bool healthy,) = treasury.health();
            assertTrue(healthy, "oracle/spot/TWAP corroborate daily Close");
            uint256 beforeActionAssets = reader.totalAssets(price);
            if (beforeActionAssets >= lastExternalAssets) cumulativePriceMarkDeltaPositive += beforeActionAssets-lastExternalAssets;
            else cumulativePriceMarkDeltaNegative += lastExternalAssets-beforeActionAssets;
            if (flowEnabled) {
                _externalFlow();
                _processHookFees();
            }
            dailyCollectedStock = 0;
            dailyCollectedBurn = 0;
            if (harvestEnabled) _harvest();
            _keeper();
            uint256 afterActionAssets = reader.totalAssets(price);
            if (afterActionAssets >= beforeActionAssets) cumulativeActionDeltaPositive += afterActionAssets-beforeActionAssets;
            else cumulativeActionDeltaNegative += beforeActionAssets-afterActionAssets;
            lastExternalAssets = afterActionAssets;
        }
        if (!flowEnabled) {
            assertEq(_funPrice(), runInitialFunStock);
            assertEq(treasury.bookedStock(), runInitialStock);
            assertEq(treasury.reserveUsdg(), 0);
        }
        _row(index, elapsed, date, price);
        runLastElapsed = elapsed;
    }

    function _profileMetadata(uint256 nonce, uint256 price) private {
        string memory n = "profile";
        HedgeFunTreasuryBase.Params memory p = treasury.params();
        vm.serializeString(n, "ticker", ticker);
        vm.serializeString(n, "profile", profileName);
        vm.serializeBool(n, "harvestEnabled", harvestEnabled);
        vm.serializeBool(n, "strategyEnabled", strategyEnabled);
        vm.serializeBool(n, "flowEnabled", flowEnabled);
        vm.serializeString(n, "implementation", "pinned deployed creator kind0 AllIn runtime; local-source contracts provide ABI and auxiliary reader only");
        vm.serializeUint(n, "forkBlock", FORK_BLOCK);
        vm.serializeBytes32(n, "factoryRuntimeHash", address(FACTORY).codehash);
        vm.serializeBytes32(n, "treasuryRuntimeHash", address(treasury).codehash);
        vm.serializeAddress(n, "treasury", address(treasury));
        vm.serializeAddress(n, "token", address(token));
        vm.serializeAddress(n, "vault", address(vault));
        vm.serializeUint(n, "nonce", nonce);
        vm.serializeUint(n, "initialPriceE18", price);
        vm.serializeUint(n, "normalizedOpenPriceE18", normalizedOpenPrice);
        vm.serializeUint(n, "initialTreasuryStockRaw", treasury.bookedStock());
        vm.serializeUint(n, "initialExternalAssetsUsdgRaw", initialExternalAssets);
        vm.serializeUint(n, "initialHolderFunRaw", startingHolderFun);
        vm.serializeUint(n, "initialSupplyRaw", expectedInitialSupply);
        vm.serializeUint(n, "launchStockSpentRaw", launchStockSpent);
        vm.serializeUint(n, "launchStockOracleUsdgValueRaw", Math.mulDiv(launchStockSpent, price, 1e30));
        vm.serializeUint(n, "launchFeeUsdgRaw", 25e6);
        vm.serializeUint(n, "traderInitialUsdgRaw", TRADER_INITIAL_USDG);
        vm.serializeUint(n, "dailyBuyUsdgRaw", DAILY_BUY_USDG);
        vm.serializeBool(n, "buybackEnabled", buybackEnabled);
        vm.serializeString(n, "curveFeePolicy", "launch curve fees remain unclaimed, excluded from reader external-assets NAV");
        vm.serializeString(n, "hookFeePolicy", "daily sweep, bounded owner conversion, sweep; LP harvest is independent switch");
        vm.serializeUint(n, "tp1Bps", p.tp1Bps);
        vm.serializeUint(n, "tp2Bps", p.tp2Bps);
        vm.serializeUint(n, "dipBps", p.dipBps);
        vm.serializeUint(n, "stopBps", p.stopBps);
        vm.serializeUint(n, "lotBps", p.lotBps);
        vm.serializeUint(n, "maxSlippageBps", p.maxSlippageBps);
        vm.serializeUint(n, "maxDeviationBps", p.maxDeviationBps);
        vm.serializeUint(n, "bountyBps", p.bountyBps);
        vm.serializeUint(n, "minLotUsdg", p.minLotUsdg);
        vm.serializeUint(n, "sellChunkUsdg", p.sellChunkUsdg);
        vm.serializeUint(n, "buybackChunkUsdg", p.buybackChunkUsdg);
        vm.serializeUint(n, "buybackCooldown", p.buybackCooldown);
        vm.serializeUint(n, "maxBuybackImpactBps", p.maxBuybackImpactBps);
        vm.serializeUint(n, "stockPoolFee", IEquityV3Position(stockPool).fee());
        console2.log("EQUITY_PROFILE", vm.serializeUint(n, "funPoolFee", key.fee));
    }

    function _probeFees() private returns (Fees memory f) {
        assertEq(stock.balanceOf(address(vault)), 0, "no previously parked credit");
        uint256 snapshot = vm.snapshotState();
        (f.stockAmount, f.tokenAmount) = vault.collectFees();
        assertTrue(vm.revertToState(snapshot));
        vm.deleteStateSnapshot(snapshot);
        (,,,uint256 uncollected,) = reader.assetBalances();
        assertEq(f.stockAmount, uncollected, "independent reader matches actual collect-and-revert");
    }

    function _externalFlow() private {
        Fees memory beforeFees = _probeFees();
        uint256 supplyBeforeFlow = token.totalSupply();
        Router.Hop[] memory path = new Router.Hop[](1);
        path[0] = Router.Hop(stockPool, address(stock));
        uint256 beforeUsd = USDG.balanceOf(TRADER);
        vm.prank(TRADER);
        (uint256 bought, uint256 refundStock) = ROUTER.buy(Router.TradeParams(id,address(USDG),DAILY_BUY_USDG,1,1,block.timestamp,2,false),path);
        assertEq(refundStock, 0);
        assertEq(beforeUsd - USDG.balanceOf(TRADER), DAILY_BUY_USDG);
        assertEq(token.balanceOf(TRADER), bought);
        traderUsdIn += DAILY_BUY_USDG;
        path[0] = Router.Hop(stockPool, address(USDG));
        uint256 beforeSellUsd = USDG.balanceOf(TRADER);
        vm.prank(TRADER);
        (uint256 received, uint256 tokenRefund) = ROUTER.sell(Router.TradeParams(id,address(USDG),bought,1,1,block.timestamp,2,false),path);
        assertEq(tokenRefund, 0);
        assertEq(USDG.balanceOf(TRADER) - beforeSellUsd, received);
        assertEq(token.balanceOf(TRADER), 0);
        traderUsdOut += received;
        ++flowPairs;
        hookTokenBurn += supplyBeforeFlow - token.totalSupply();
        Fees memory afterFees = _probeFees();
        externalStockFeesGenerated += afterFees.stockAmount - beforeFees.stockAmount;
        externalTokenFeesGenerated += afterFees.tokenAmount - beforeFees.tokenAmount;
    }

    function _processHookFees() private {
        HedgeFunV2Hook hook = HedgeFunV2Hook(address(FACTORY.hook()));
        uint256 beforeTreasuryStock = stock.balanceOf(address(treasury));
        uint256 supplyBefore = token.totalSupply();
        address protocolRecipient = hook.protocolOf(key.toId());
        assertTrue(protocolRecipient != CREATOR && protocolRecipient != address(this) && CREATOR != address(this));
        uint256[3] memory paidBefore = [stock.balanceOf(protocolRecipient),stock.balanceOf(CREATOR),stock.balanceOf(address(this))];
        hook.sweep(key.toId());
        uint256 pending = ILegacyV2FeeConversion(address(hook)).pendingTokenFees(key.toId());
        if (pending != 0) _convertHookFees(hook, pending);
        hook.sweep(key.toId());
        hookStockDelivered += stock.balanceOf(address(treasury)) - beforeTreasuryStock;
        hookTokenBurn += supplyBefore - token.totalSupply();
        hookProtocolStockPaid += stock.balanceOf(protocolRecipient)-paidBefore[0];
        hookCreatorStockPaid += stock.balanceOf(CREATOR)-paidBefore[1];
        hookSweeperStockPaid += stock.balanceOf(address(this))-paidBefore[2];
        (uint256 tokenAccrued, uint256 stockAccrued) = hook.accrued(key.toId());
        assertEq(tokenAccrued, 0);
        assertEq(stockAccrued, 0);
        assertEq(hook.owedTreasury(key.toId()), 0, "all hook stock fees delivered");
    }

    function _convertHookFees(HedgeFunV2Hook hook, uint256 pending) private {
        Fees memory beforeFees = _probeFees();
        (uint160 sqrtP,,,) = FACTORY.poolManager().getSlot0(key.toId());
        uint160 limit = uint160(Math.mulDiv(sqrtP, 9950, 10_000));
        uint256 deadline = block.timestamp + 300;
        address owner = FACTORY.owner();
        uint256 snapshot = vm.snapshotState();
        vm.prank(owner);
        (uint256 quoteConsumed,uint256 quoteStock) = ILegacyV2FeeConversion(address(hook)).convertFees(key,pending,1,limit,deadline);
        assertTrue(vm.revertToState(snapshot));
        vm.deleteStateSnapshot(snapshot);
        assertGt(quoteConsumed,0);
        assertGt(quoteStock,0);
        uint256 floor = Math.max(1,Math.mulDiv(quoteStock,9900,10_000));
        vm.prank(owner);
        (uint256 consumed,uint256 stockOut) = ILegacyV2FeeConversion(address(hook)).convertFees(key,pending,floor,limit,deadline);
        assertEq(consumed,quoteConsumed);
        assertEq(stockOut,quoteStock);
        assertEq(ILegacyV2FeeConversion(address(hook)).pendingTokenFees(key.toId()), pending-consumed);
        convertedFeeTokens += consumed;
        convertedFeeStock += stockOut;
        ++conversionCount;
        Fees memory afterFees = _probeFees();
        conversionStockFeesGenerated += afterFees.stockAmount-beforeFees.stockAmount;
        conversionTokenFeesGenerated += afterFees.tokenAmount-beforeFees.tokenAmount;
    }

    function _harvest() private {
        uint256 stockBefore = stock.balanceOf(address(treasury));
        uint256 budgetBefore = treasury.buybackStock();
        uint256 supplyBefore = token.totalSupply();
        uint256 externalBefore = reader.totalAssets(oracle.price());
        (uint160 sqrtBefore,,,) = FACTORY.poolManager().getSlot0(key.toId());
        uint128 liquidityBefore = FACTORY.poolManager().getLiquidity(key.toId());
        (uint256 principalStockBefore,uint256 principalFunBefore) = _lp();
        assertEq(stock.balanceOf(address(vault)), 0);
        (uint256 stockFee,uint256 funBurned) = vault.collectFees();
        assertEq(stock.balanceOf(address(treasury)) - stockBefore, stockFee);
        assertEq(treasury.buybackStock() - budgetBefore, stockFee);
        assertEq(supplyBefore - token.totalSupply(), funBurned);
        assertEq(stock.balanceOf(address(vault)), 0);
        (uint160 sqrtAfter,,,) = FACTORY.poolManager().getSlot0(key.toId());
        assertEq(sqrtAfter, sqrtBefore);
        assertEq(FACTORY.poolManager().getLiquidity(key.toId()), liquidityBefore);
        (uint256 principalStockAfter,uint256 principalFunAfter) = _lp();
        assertEq(principalStockAfter, principalStockBefore);
        assertEq(principalFunAfter, principalFunBefore);
        assertEq(reader.totalAssets(oracle.price()), externalBefore, "harvest reallocates external assets, never creates them");
        dailyCollectedStock = stockFee;
        dailyCollectedBurn = funBurned;
        collectedStockFees += stockFee;
        collectedTokenBurn += funBurned;
        collectedFeesOracleUsdgValueRaw += Math.mulDiv(stockFee, oracle.price(), 1e30);
    }

    function _feesRow(string memory name, uint256 price) private {
        Fees memory fees = _probeFees();
        (uint256 held,uint256 parked,uint256 principal,uint256 feeStock,uint256 cash) = reader.assetBalances();
        uint256 externalAssets = Math.mulDiv(held+parked+principal+feeStock, price, 1e30)+cash;
        assertEq(externalAssets, reader.totalAssets(price));
        assertEq(fees.stockAmount, feeStock);
        assertEq(collectedStockFees + fees.stockAmount, externalStockFeesGenerated + selfStockFeesGenerated + conversionStockFeesGenerated);
        assertEq(collectedTokenBurn + fees.tokenAmount, externalTokenFeesGenerated + selfTokenFeesGenerated + conversionTokenFeesGenerated);
        vm.serializeUint(name, "externalAssetsUsdgRaw", externalAssets);
        vm.serializeUint(name, "uncollectedLpStockRaw", fees.stockAmount);
        vm.serializeUint(name, "uncollectedLpFunRaw", fees.tokenAmount);
        vm.serializeUint(name, "collectedLpStockRaw", collectedStockFees);
        vm.serializeUint(name, "collectedLpFunBurnedRaw", collectedTokenBurn);
        vm.serializeUint(name, "dailyCollectedLpStockRaw", dailyCollectedStock);
        vm.serializeUint(name, "dailyCollectedLpFunBurnedRaw", dailyCollectedBurn);
        vm.serializeUint(name, "collectedLpOracleUsdgValueRaw", collectedFeesOracleUsdgValueRaw);
        vm.serializeUint(name, "externalGeneratedLpStockRaw", externalStockFeesGenerated);
        vm.serializeUint(name, "externalGeneratedLpFunRaw", externalTokenFeesGenerated);
        vm.serializeUint(name, "buybackGeneratedLpStockRaw", selfStockFeesGenerated);
        vm.serializeUint(name, "buybackGeneratedLpFunRaw", selfTokenFeesGenerated);
        vm.serializeUint(name, "conversionGeneratedLpStockRaw", conversionStockFeesGenerated);
        vm.serializeUint(name, "conversionGeneratedLpFunRaw", conversionTokenFeesGenerated);
        vm.serializeUint(name, "convertedFeeTokensRaw", convertedFeeTokens);
        vm.serializeUint(name, "convertedFeeStockRaw", convertedFeeStock);
        vm.serializeUint(name, "hookStockDeliveredRaw", hookStockDelivered);
        vm.serializeUint(name, "hookTokenBurnRaw", hookTokenBurn);
        vm.serializeUint(name, "hookProtocolStockPaidRaw", hookProtocolStockPaid);
        vm.serializeUint(name, "hookCreatorStockPaidRaw", hookCreatorStockPaid);
        vm.serializeUint(name, "hookSweeperStockPaidRaw", hookSweeperStockPaid);
        vm.serializeUint(name, "conversionCount", conversionCount);
        vm.serializeUint(name, "pendingHookTokenFeesRaw", ILegacyV2FeeConversion(address(FACTORY.hook())).pendingTokenFees(key.toId()));
        vm.serializeUint(name, "traderUsdgInRaw", traderUsdIn);
        vm.serializeUint(name, "traderUsdgOutRaw", traderUsdOut);
        vm.serializeUint(name, "traderUsdgBalanceRaw", USDG.balanceOf(TRADER));
        vm.serializeUint(name, "traderStockBalanceRaw", stock.balanceOf(TRADER));
        vm.serializeUint(name, "traderFunBalanceRaw", token.balanceOf(TRADER));
        vm.serializeUint(name, "flowPairs", flowPairs);
        vm.serializeUint(name, "priceMarkDeltaPositiveUsdgRaw", cumulativePriceMarkDeltaPositive);
        vm.serializeUint(name, "priceMarkDeltaNegativeUsdgRaw", cumulativePriceMarkDeltaNegative);
        vm.serializeUint(name, "actionDeltaPositiveUsdgRaw", cumulativeActionDeltaPositive);
        vm.serializeUint(name, "actionDeltaNegativeUsdgRaw", cumulativeActionDeltaNegative);
        vm.serializeUint(name, "maxStrategyStockInputOracleUsdRaw", maxStrategyStockInputUsd);
        vm.serializeUint(name, "maxStrategyUsdgInputRaw", maxStrategyUsdgInput);
        vm.serializeUint(name, "maxBuybackStockInputOracleUsdRaw", maxBuybackStockInputUsd);
        vm.serializeUint(name, "maxBuybackExternalAssetDustUsdgRaw", maxBuybackExternalAssetDustUsdgRaw);
        (uint256 hookFun,uint256 hookStock) = FACTORY.hook().accrued(key.toId());
        vm.serializeUint(name, "hookUnsettledFunRaw", hookFun);
        vm.serializeUint(name, "hookUnsettledStockRaw", hookStock);
        vm.serializeUint(name, "hookOwedTreasuryStockRaw", FACTORY.hook().owedTreasury(key.toId()));
    }

    function _depthProbes() private {
        deal(address(USDG), DEPTH, 100_000e6);
        deal(address(stock), DEPTH, Math.mulDiv(100_000e6, 1e30, oracle.price()));
        vm.startPrank(DEPTH);
        stock.approve(address(this), type(uint256).max);
        USDG.approve(address(this), type(uint256).max);
        vm.stopPrank();
        _depthQuote(100e6,true); _depthQuote(100e6,false);
        _depthQuote(1000e6,true); _depthQuote(1000e6,false);
        _depthQuote(2000e6,true); _depthQuote(2000e6,false);
        // Cash can rise with the strategy, so also cover larger hypothetical dip sizes.
        _depthQuote(10_000e6,true); _depthQuote(10_000e6,false);
    }

    function _depthQuote(uint256 usdNotional, bool buy) private {
        uint256 snapshot = vm.snapshotState();
        DepthQuote memory q;
        {
            uint256 price = oracle.price();
            IEquityV3Position pool = IEquityV3Position(stockPool);
            uint256 amount = buy ? usdNotional : Math.mulDiv(usdNotional,1e30,price);
            bool zeroForOne = pool.token0() == (buy ? address(USDG) : address(stock));
            uint256 beforeInput = IERC20(buy ? address(USDG) : address(stock)).balanceOf(DEPTH);
            uint256 beforeOutput = IERC20(buy ? address(stock) : address(USDG)).balanceOf(DEPTH);
            depthCallback = true;
            pool.swap(DEPTH,zeroForOne,int256(amount),zeroForOne ? TickMath.MIN_SQRT_PRICE+1 : TickMath.MAX_SQRT_PRICE-1,"");
            depthCallback = false;
            q.spent = beforeInput - IERC20(buy ? address(USDG) : address(stock)).balanceOf(DEPTH);
            q.received = IERC20(buy ? address(stock) : address(USDG)).balanceOf(DEPTH)-beforeOutput;
            assertEq(q.spent, amount, "depth probe must fully fill the requested input");
            assertGt(q.received, 0);
            q.outputUsd = buy ? Math.mulDiv(q.received,price,1e30) : q.received;
            q.inputUsd = buy ? amount : Math.mulDiv(amount,price,1e30);
            q.costPpm = Math.mulDiv(q.inputUsd-q.outputUsd,1_000_000,q.inputUsd);
            q.feePpm = pool.fee();
            assertLe(q.costPpm, q.feePpm + 1000, "onchain price impact after fee must be <=10bps through $10k");
        }
        string memory n="depth";
        vm.serializeString(n,"ticker",ticker);
        vm.serializeString(n,"profile",profileName);
        vm.serializeBool(n,"harvestEnabled",harvestEnabled);
        vm.serializeBool(n,"buy",buy);
        vm.serializeUint(n,"inputNotionalUsdgRaw",usdNotional);
        vm.serializeUint(n,"inputRaw",q.spent);
        vm.serializeUint(n,"outputRaw",q.received);
        vm.serializeUint(n,"inputOracleUsdgRaw",q.inputUsd);
        vm.serializeUint(n,"outputOracleUsdgRaw",q.outputUsd);
        vm.serializeUint(n,"feePpm",q.feePpm);
        console2.log("EQUITY_DEPTH",vm.serializeUint(n,"effectiveCostPpm",q.costPpm));
        assertTrue(vm.revertToState(snapshot));
        vm.deleteStateSnapshot(snapshot);
    }

    function uniswapV3SwapCallback(int256 d0,int256 d1,bytes calldata) external {
        require(depthCallback && msg.sender==stockPool,"unexpected depth callback");
        address token0=IEquityV3Position(stockPool).token0();
        if(d0>0) assertTrue(IERC20(token0).transferFrom(DEPTH,msg.sender,uint256(d0)));
        if(d1>0) assertTrue(IERC20(token0==address(stock) ? address(USDG) : address(stock)).transferFrom(DEPTH,msg.sender,uint256(d1)));
    }

    function testEquity_TSLA_Baseline() public { _run("TSLA",0,false); }
    function testEquity_TSLA_FeeOnly_NoHarvest() public { _run("TSLA",1,false); }
    function testEquity_TSLA_FeeOnly_Harvest() public { _run("TSLA",1,true); }
    function testEquity_TSLA_P100_NoHarvest() public { _run("TSLA",2,false); }
    function testEquity_TSLA_P100_Harvest() public { _run("TSLA",2,true); }
    function testEquity_TSLA_P300_NoHarvest() public { _run("TSLA",3,false); }
    function testEquity_TSLA_P300_Harvest() public { _run("TSLA",3,true); }
    function testEquity_TSLA_P500_NoHarvest() public { _run("TSLA",4,false); }
    function testEquity_TSLA_P500_Harvest() public { _run("TSLA",4,true); }
    function testEquity_TSLA_P1000_NoHarvest() public { _run("TSLA",5,false); }
    function testEquity_TSLA_P1000_Harvest() public { _run("TSLA",5,true); }
    function testEquity_TSLA_P500StopOff_NoHarvest() public { _run("TSLA",6,false); }
    function testEquity_TSLA_P500StopOff_Harvest() public { _run("TSLA",6,true); }
    function testEquity_NVDA_Baseline() public { _run("NVDA",0,false); }
    function testEquity_NVDA_FeeOnly_NoHarvest() public { _run("NVDA",1,false); }
    function testEquity_NVDA_FeeOnly_Harvest() public { _run("NVDA",1,true); }
    function testEquity_NVDA_P100_NoHarvest() public { _run("NVDA",2,false); }
    function testEquity_NVDA_P100_Harvest() public { _run("NVDA",2,true); }
    function testEquity_NVDA_P300_NoHarvest() public { _run("NVDA",3,false); }
    function testEquity_NVDA_P300_Harvest() public { _run("NVDA",3,true); }
    function testEquity_NVDA_P500_NoHarvest() public { _run("NVDA",4,false); }
    function testEquity_NVDA_P500_Harvest() public { _run("NVDA",4,true); }
    function testEquity_NVDA_P1000_NoHarvest() public { _run("NVDA",5,false); }
    function testEquity_NVDA_P1000_Harvest() public { _run("NVDA",5,true); }
    function testEquity_NVDA_P500StopOff_NoHarvest() public { _run("NVDA",6,false); }
    function testEquity_NVDA_P500StopOff_Harvest() public { _run("NVDA",6,true); }
    function testEquity_META_Baseline() public { _run("META",0,false); }
    function testEquity_META_FeeOnly_NoHarvest() public { _run("META",1,false); }
    function testEquity_META_FeeOnly_Harvest() public { _run("META",1,true); }
    function testEquity_META_P100_NoHarvest() public { _run("META",2,false); }
    function testEquity_META_P100_Harvest() public { _run("META",2,true); }
    function testEquity_META_P300_NoHarvest() public { _run("META",3,false); }
    function testEquity_META_P300_Harvest() public { _run("META",3,true); }
    function testEquity_META_P500_NoHarvest() public { _run("META",4,false); }
    function testEquity_META_P500_Harvest() public { _run("META",4,true); }
    function testEquity_META_P1000_NoHarvest() public { _run("META",5,false); }
    function testEquity_META_P1000_Harvest() public { _run("META",5,true); }
    function testEquity_META_P500StopOff_NoHarvest() public { _run("META",6,false); }
    function testEquity_META_P500StopOff_Harvest() public { _run("META",6,true); }
}
