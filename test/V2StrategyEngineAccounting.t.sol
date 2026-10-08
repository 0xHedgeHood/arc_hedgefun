// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2BuybackTreasury} from "../src/v2/HedgeFunV2BuybackTreasury.sol";
import {HedgeFunV2EngineTreasury} from "../src/v2/HedgeFunV2EngineTreasury.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {
    EngineConfig,
    IStrategyPolicy,
    StrategyAction,
    StrategyCapabilities,
    StrategyContext,
    StrategyIntent
} from "../src/v2/strategy/IStrategyPolicy.sol";
import {V2RebalancePolicy} from "../src/v2/strategy/V2RebalancePolicy.sol";
import {ISwapCallback, MockLpPool} from "./mocks/Mocks.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

/// @dev Flat-price V3 fixture that can consume only a chosen fraction of the offered exact input.
///      This models a real V3 swap stopping at the treasury's oracle-derived price limit.
contract EngineAccountingVenue is MockLpPool {
    uint256 internal immutable scale;
    uint256 public price;
    uint16 public fillBps = 10_000;

    constructor(address stock, address usdg, uint24 fee_, uint256 scale_, uint256 price_)
        MockLpPool(stock, usdg, fee_)
    {
        scale = scale_;
        setPrice(price_);
    }

    function setFillBps(uint16 value) external {
        require(value != 0 && value <= 10_000, "fill");
        fillBps = value;
    }

    function setPrice(uint256 value) public {
        price = value;
        sqrtPriceX96 = uint160(Math.sqrt(Math.mulDiv(value, 1 << 192, scale)));
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 limit, bytes calldata data)
        external
        returns (int256 a0, int256 a1)
    {
        require(amountSpecified > 0, "exact input");
        require(zeroForOne ? limit < sqrtPriceX96 : limit > sqrtPriceX96, "SPL");
        uint256 offered = uint256(amountSpecified);
        uint256 amountIn = Math.max(1, Math.mulDiv(offered, fillBps, 10_000));
        uint256 net = Math.mulDiv(amountIn, 1_000_000 - fee, 1_000_000);
        uint256 amountOut = zeroForOne ? Math.mulDiv(net, price, scale) : Math.mulDiv(net, scale, price);
        IERC20(zeroForOne ? token1 : token0).transfer(recipient, amountOut);
        (a0, a1) = zeroForOne ? (int256(amountIn), -int256(amountOut)) : (-int256(amountOut), int256(amountIn));
        IERC20 input = IERC20(zeroForOne ? token0 : token1);
        uint256 beforeBalance = input.balanceOf(address(this));
        ISwapCallback(msg.sender).uniswapV3SwapCallback(a0, a1, data);
        require(input.balanceOf(address(this)) >= beforeBalance + amountIn, "IIA");
    }
}

/// @dev Deliberately ignores the configured cooldown so the Engine core's independent cooldown can be exercised.
contract AccountingAlwaysSellPolicy is IStrategyPolicy {
    function policyMetadata() external pure returns (uint32, uint32, uint256) {
        return
            (StrategyCapabilities.SPOT_ENGINE_V1, StrategyCapabilities.CONFIG_SCHEMA_V1, StrategyCapabilities.SPOT_SELL);
    }

    function decide(StrategyContext calldata context, EngineConfig calldata, bytes32 state)
        external
        pure
        returns (StrategyIntent memory)
    {
        return StrategyIntent(context.configHash, context.nonce, StrategyAction.SellStock, type(uint256).max, state);
    }
}

abstract contract V2StrategyEngineAccountingFixture is V2FactoryFixture {
    uint256 internal constant PRICE = 100e18;

    V2TreasuryDeployer internal deployer;
    V2RebalancePolicy internal policyImplementation;
    EngineAccountingVenue internal venue;
    bytes32 internal policyKey;
    uint8 internal engineKind;

    function setUp() public virtual {
        _setUpV2(18);
        venue = new EngineAccountingVenue(address(stock), address(usdg), 3000, 1e30, PRICE);
        stockPool = venue;
        v3f.set(address(stock), address(usdg), 3000, address(venue));
        vm.prank(owner);
        factory.list(address(stock), address(oracle), address(venue), openPrice, true);
        usdg.mint(address(venue), 10_000_000e6);
        stock.mint(address(venue), 100_000e18);

        deployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        (address buybackA, address buybackB) = deployer.makeChunks(type(HedgeFunV2BuybackTreasury).creationCode);
        policyImplementation = new V2RebalancePolicy();
        vm.startPrank(owner);
        deployer.registerKind(buybackA, buybackB);
        policyKey = deployer.registerPolicy(
            address(policyImplementation),
            150_000,
            deployer.POLICY_RETURN_BYTES(),
            keccak256("accounting-dependencies-v1"),
            keccak256("accounting-audit-v1")
        );
        (address engineA, address engineB) = deployer.makeChunks(type(HedgeFunV2EngineTreasury).creationCode);
        engineKind = deployer.registerEngineKind(
            engineA,
            engineB,
            StrategyCapabilities.SPOT_ENGINE_V1,
            StrategyCapabilities.CONFIG_SCHEMA_V1,
            StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL
        );
        vm.stopPrank();
    }

    function _config(uint256 maxTrade, uint256 maxDaily) internal view virtual returns (EngineConfig memory config) {
        config.schema = StrategyCapabilities.CONFIG_SCHEMA_V1;
        config.engineVersion = StrategyCapabilities.SPOT_ENGINE_V1;
        config.policyKey = policyKey;
        config.words[0] = bytes32(uint256(5000) | uint256(500) << 16 | uint256(600) << 32);
        config.words[1] = bytes32(maxTrade);
        config.words[2] = bytes32(maxDaily);
    }

    function _launch(uint96 nonce, uint256 maxTrade, uint256 maxDaily)
        internal
        returns (HedgeFunV2EngineTreasury treasury)
    {
        HedgeFunFactory.Request memory q = _request();
        q.nonce = nonce;
        deployer.setEngineConfig(q.symbol, q.nonce, engineKind, _config(maxTrade, maxDaily));
        (,, bytes32 terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        (, address treasuryAddress,,,) = factory.strategies(id);
        treasury = HedgeFunV2EngineTreasury(treasuryAddress);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        stock.approve(address(curve), type(uint256).max);
        _graduateV2(curve);
    }
}

contract V2StrategyEngineAccountingTest is V2StrategyEngineAccountingFixture {

    function testFuzz_shortSellFillUsesOnlyActualInput(uint16 fillBps) public {
        fillBps = uint16(bound(fillBps, 500, 9_999));
        venue.setFillBps(fillBps);
        HedgeFunV2EngineTreasury treasury = _launch(100, 100e6, 500e6);

        uint256 stockBefore = stock.balanceOf(address(treasury));
        uint256 bookedBefore = treasury.bookedStock();
        uint256 usdgBefore = usdg.balanceOf(address(treasury));
        treasury.execute();
        uint256 stockSpent = stockBefore - stock.balanceOf(address(treasury));
        uint256 usdgReceived = usdg.balanceOf(address(treasury)) - usdgBefore;

        assertGt(stockSpent, 0);
        assertEq(bookedBefore - treasury.bookedStock(), stockSpent, "sell bucket must debit actual input");
        assertEq(treasury.turnoverInEpoch(), Math.mulDiv(stockSpent, PRICE, 1e30));
        assertEq(treasury.bookedStock() + treasury.buybackStock(), stock.balanceOf(address(treasury)));
        assertGt(usdgReceived, 0);
        assertLe(treasury.turnoverInEpoch(), 100e6);
    }

    function testFuzz_shortBuyFillUsesActualInputAndOutput(uint16 fillBps) public {
        fillBps = uint16(bound(fillBps, 500, 9_999));
        venue.setFillBps(fillBps);
        HedgeFunV2EngineTreasury treasury = _launch(101, 100e6, 500e6);
        uint256 initialStockValue = Math.mulDiv(treasury.bookedStock(), PRICE, 1e30);
        usdg.mint(address(treasury), initialStockValue * 3);

        uint256 stockBefore = stock.balanceOf(address(treasury));
        uint256 bookedBefore = treasury.bookedStock();
        uint256 usdgBefore = usdg.balanceOf(address(treasury));
        treasury.execute();
        uint256 usdgSpent = usdgBefore - usdg.balanceOf(address(treasury));
        uint256 stockReceived = stock.balanceOf(address(treasury)) - stockBefore;

        assertGt(usdgSpent, 0);
        assertEq(treasury.bookedStock() - bookedBefore, stockReceived, "buy bucket must credit actual output");
        assertEq(treasury.turnoverInEpoch(), usdgSpent, "buy turnover must be actual USDG input");
        assertEq(treasury.bookedStock() + treasury.buybackStock(), stock.balanceOf(address(treasury)));
        assertLe(usdgSpent, 100e6);
    }

    function test_shortSellBelowMinLotRollsBackWithoutConsumingStrategyState() public {
        venue.setFillBps(499);
        HedgeFunV2EngineTreasury treasury = _launch(106, 100e6, 500e6);

        uint256 treasuryStockBefore = stock.balanceOf(address(treasury));
        uint256 treasuryUsdgBefore = usdg.balanceOf(address(treasury));
        uint256 venueStockBefore = stock.balanceOf(address(venue));
        uint256 venueUsdgBefore = usdg.balanceOf(address(venue));
        uint256 bookedBefore = treasury.bookedStock();
        uint256 receivedBefore = treasury.totalStockReceived();
        uint256 lastGoodPriceBefore = treasury.lastGoodPrice();
        uint256 lastGoodPriceAtBefore = treasury.lastGoodPriceAt();

        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        treasury.execute();

        assertEq(stock.balanceOf(address(treasury)), treasuryStockBefore);
        assertEq(usdg.balanceOf(address(treasury)), treasuryUsdgBefore);
        assertEq(stock.balanceOf(address(venue)), venueStockBefore);
        assertEq(usdg.balanceOf(address(venue)), venueUsdgBefore);
        assertEq(treasury.bookedStock(), bookedBefore);
        assertEq(treasury.strategyNonce(), 0);
        assertEq(treasury.lastStrategyAt(), 0);
        assertEq(treasury.turnoverEpoch(), 0);
        assertEq(treasury.turnoverInEpoch(), 0);
        assertEq(treasury.policyState(), bytes32(0));
        assertEq(treasury.totalStockReceived(), receivedBefore);
        assertEq(treasury.lastGoodPrice(), lastGoodPriceBefore);
        assertEq(treasury.lastGoodPriceAt(), lastGoodPriceAtBefore);
    }

    function test_shortBuyBelowMinLotRollsBackWithoutConsumingStrategyState() public {
        venue.setFillBps(499);
        HedgeFunV2EngineTreasury treasury = _launch(107, 100e6, 500e6);
        uint256 initialStockValue = Math.mulDiv(treasury.bookedStock(), PRICE, 1e30);
        usdg.mint(address(treasury), initialStockValue * 3);

        uint256 treasuryStockBefore = stock.balanceOf(address(treasury));
        uint256 treasuryUsdgBefore = usdg.balanceOf(address(treasury));
        uint256 venueStockBefore = stock.balanceOf(address(venue));
        uint256 venueUsdgBefore = usdg.balanceOf(address(venue));
        uint256 bookedBefore = treasury.bookedStock();
        uint256 receivedBefore = treasury.totalStockReceived();
        uint256 lastGoodPriceBefore = treasury.lastGoodPrice();
        uint256 lastGoodPriceAtBefore = treasury.lastGoodPriceAt();

        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        treasury.execute();

        assertEq(stock.balanceOf(address(treasury)), treasuryStockBefore);
        assertEq(usdg.balanceOf(address(treasury)), treasuryUsdgBefore);
        assertEq(stock.balanceOf(address(venue)), venueStockBefore);
        assertEq(usdg.balanceOf(address(venue)), venueUsdgBefore);
        assertEq(treasury.bookedStock(), bookedBefore);
        assertEq(treasury.strategyNonce(), 0);
        assertEq(treasury.lastStrategyAt(), 0);
        assertEq(treasury.turnoverEpoch(), 0);
        assertEq(treasury.turnoverInEpoch(), 0);
        assertEq(treasury.policyState(), bytes32(0));
        assertEq(treasury.totalStockReceived(), receivedBefore);
        assertEq(treasury.lastGoodPrice(), lastGoodPriceBefore);
        assertEq(treasury.lastGoodPriceAt(), lastGoodPriceAtBefore);
    }

    function test_donationBooksExactlyOnceWithoutTouchingBuybackBucket() public {
        HedgeFunV2EngineTreasury treasury = _launch(102, 100e6, 500e6);
        uint256 lpFee = 9e18 + 1;
        address vault = treasury.liquidityVault();
        stock.mint(vault, lpFee);
        vm.prank(vault);
        stock.approve(address(treasury), lpFee);
        vm.prank(vault);
        treasury.creditLiquidityFee(lpFee);

        uint256 donation = 17e18 + 3;
        uint256 bookedBefore = treasury.bookedStock();
        uint256 receivedBefore = treasury.totalStockReceived();
        uint256 buybackBefore = treasury.buybackStock();
        assertEq(buybackBefore, lpFee, "LP stock fee must stay in the buyback bucket");
        stock.transfer(address(treasury), donation);

        assertEq(treasury.unbookedStock(), donation);
        assertTrue(treasury.book());
        assertEq(treasury.bookedStock(), bookedBefore + donation);
        assertEq(treasury.totalStockReceived(), receivedBefore + donation);
        assertEq(treasury.buybackStock(), buybackBefore);
        assertEq(treasury.unbookedStock(), 0);
        assertFalse(treasury.book());
        assertEq(treasury.bookedStock() + treasury.buybackStock(), stock.balanceOf(address(treasury)));
    }

    function test_cooldownAndDailyCapUseCumulativeActualTurnover() public {
        AccountingAlwaysSellPolicy alwaysSell = new AccountingAlwaysSellPolicy();
        uint16 returnBytes = deployer.POLICY_RETURN_BYTES();
        vm.prank(owner);
        policyKey = deployer.registerPolicy(
            address(alwaysSell),
            100_000,
            returnBytes,
            keccak256("accounting-cooldown-dependencies-v1"),
            keccak256("accounting-cooldown-audit-v1")
        );
        HedgeFunV2EngineTreasury treasury = _launch(103, 100e6, 150e6);
        treasury.execute();
        assertEq(treasury.turnoverInEpoch(), 100e6);

        vm.expectRevert(HedgeFunTreasuryBase.Cooldown.selector);
        treasury.execute();
        vm.warp(block.timestamp + 600);
        treasury.execute();
        assertEq(treasury.turnoverInEpoch(), 150e6, "second call must consume only remaining daily cap");

        vm.warp(block.timestamp + 600);
        (bool due,, uint256 amountIn) = treasury.preview();
        assertFalse(due, "preview must include the core daily-turnover gate");
        assertEq(amountIn, 0);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        treasury.execute();

        vm.warp((block.timestamp / 1 days + 1) * 1 days);
        treasury.execute();
        assertEq(treasury.turnoverInEpoch(), 100e6, "new epoch must reset cumulative turnover");
    }

    function test_sellRoundingCannotExceedPerCallCapOrTarget() public {
        uint256 oddPrice = 123_456_789e12;
        venue.setPrice(oddPrice);
        stockFeed.set(int256(12_345_678_900));
        HedgeFunV2EngineTreasury treasury = _launch(104, 100e6, 500e6);
        uint256 stockBefore = treasury.bookedStock();
        uint256 usdgBefore = treasury.reserveUsdg();
        uint256 totalBefore = Math.mulDiv(stockBefore, oddPrice, 1e30) + usdgBefore;
        uint256 targetBefore = Math.mulDiv(totalBefore, 5_000, 10_000);

        treasury.execute();
        uint256 turnover = treasury.turnoverInEpoch();
        uint256 stockValueAfter = Math.mulDiv(treasury.bookedStock(), oddPrice, 1e30);
        assertLe(turnover, 100e6);
        assertGe(stockValueAfter, targetBefore, "flooring must not sell through the target");
        assertEq(stockBefore - treasury.bookedStock(), stock.balanceOf(address(venue)) - 100_000e18);
    }

    /// @dev A `maxTradeUsdg` under the minimum lot no longer launches, so the dust here is what the daily budget
    ///      leaves: 104 USDG a day against 100 USDG actions leaves 4 USDG, under the 5 USDG lot.
    function test_previewDoesNotClaimDustBelowTheCoreMinimumIsExecutable() public {
        HedgeFunV2EngineTreasury treasury = _launch(105, 100e6, 104e6);
        treasury.execute();
        assertEq(treasury.turnoverInEpoch(), 100e6);
        vm.warp(block.timestamp + 600);
        (bool due, StrategyAction action, uint256 amountIn) = treasury.preview();
        assertFalse(due, "4 USDG of remaining budget is below the 5 USDG lot");
        assertEq(uint256(action), uint256(StrategyAction.Hold));
        assertEq(amountIn, 0);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        treasury.execute();
        // control: the same treasury with a fresh budget is due again
        vm.warp((block.timestamp / 1 days + 1) * 1 days);
        (due,, amountIn) = treasury.preview();
        assertTrue(due);
        assertGt(amountIn, 0);
    }
}
