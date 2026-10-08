// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2EngineTreasury, HedgeFunV2EngineTreasuryCore} from "../src/v2/HedgeFunV2EngineTreasury.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {EngineConfig, StrategyCapabilities} from "../src/v2/strategy/IStrategyPolicy.sol";
import {V2RebalancePolicy} from "../src/v2/strategy/V2RebalancePolicy.sol";
import {EngineAccountingVenue} from "./V2StrategyEngineAccounting.t.sol";
import {MockFeed, MockToken} from "./mocks/Mocks.sol";
import {GraduationStock, V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

contract StrategyEngineHandler is Test {
    uint256 private constant MIN_LOT = 5e6;
    uint256 private constant MAX_TRADE = 100e6;
    uint256 private constant MAX_DAILY = 500e6;
    uint256 private constant COOLDOWN = 600;

    HedgeFunV2EngineTreasury public immutable treasury;
    EngineAccountingVenue public immutable venue;
    GraduationStock public immutable stock;
    MockToken public immutable usdg;
    MockFeed public immutable stockFeed;
    MockFeed public immutable usdgFeed;

    bool public violation;
    uint256 public executeAttempts;
    uint256 public failedExecutions;
    uint256 public successfulExecutions;
    uint256 public successfulBuys;
    uint256 public successfulSells;
    uint256 public subMinFillAttempts;
    uint256 public boundaryFillAttempts;
    uint256 public lastSuccessAt;
    uint64 public ghostTurnoverEpoch;
    uint256 public ghostTurnoverInEpoch;

    constructor(
        HedgeFunV2EngineTreasury treasury_,
        EngineAccountingVenue venue_,
        GraduationStock stock_,
        MockToken usdg_,
        MockFeed stockFeed_,
        MockFeed usdgFeed_
    ) {
        treasury = treasury_;
        venue = venue_;
        stock = stock_;
        usdg = usdg_;
        stockFeed = stockFeed_;
        usdgFeed = usdgFeed_;
    }

    function donateStock(uint96 rawAmount) external {
        stock.mint(address(treasury), bound(uint256(rawAmount), 1, 50e18));
    }

    function donateUsdg(uint96 rawAmount) external {
        usdg.mint(address(treasury), bound(uint256(rawAmount), 1, 500e6));
    }

    function setMarket(uint16 rawDollars) external {
        uint256 dollars = bound(uint256(rawDollars), 50, 200);
        venue.setPrice(dollars * 1e18);
        stockFeed.set(int256(dollars * 1e8));
        usdgFeed.set(1e8);
    }

    function shoveVenue(uint16 rawDollars) external {
        venue.setPrice(bound(uint256(rawDollars), 50, 200) * 1e18);
    }

    function setOraclePaused(bool paused) external {
        stock.setOraclePaused(paused);
    }

    function refreshFeeds() external {
        _refreshFeeds();
    }

    function advanceCooldownEdge(uint8 rawEdge) external {
        uint256 edge = uint256(rawEdge) % 3;
        vm.warp(block.timestamp + (edge == 0 ? 599 : edge == 1 ? 600 : 601));
        _refreshFeeds();
    }

    function advanceLive(uint16 rawSeconds) external {
        vm.warp(block.timestamp + bound(uint256(rawSeconds), 1, 1 hours));
        _refreshFeeds();
    }

    function advanceEpoch(uint16 rawOffset) external {
        uint256 nextEpoch = (block.timestamp / 1 days + 1) * 1 days;
        vm.warp(nextEpoch + bound(uint256(rawOffset), 0, 1 hours));
        _refreshFeeds();
    }

    function makeOracleStale(uint16 rawExtra) external {
        vm.warp(block.timestamp + 26 hours + bound(uint256(rawExtra), 1, 1 hours));
    }

    function book() external {
        treasury.book();
    }

    function attemptExecute(uint16 rawFillBps) external {
        uint16 fillBps;
        uint256 fillCase = uint256(rawFillBps) % 5;
        if (fillCase == 0) fillBps = 1;
        else if (fillCase == 1) fillBps = 499;
        else if (fillCase == 2) fillBps = 500;
        else if (fillCase == 3) fillBps = 501;
        else fillBps = uint16(bound(uint256(rawFillBps), 1, 10_000));
        venue.setFillBps(fillBps);
        ++executeAttempts;
        if (fillBps < 500) ++subMinFillAttempts;
        if (fillBps == 500) ++boundaryFillAttempts;

        uint64 nonceBefore = treasury.strategyNonce();
        uint64 epochBefore = treasury.turnoverEpoch();
        uint256 turnoverBefore = treasury.turnoverInEpoch();
        bytes32 digestBefore = _stateDigest();

        (bool ok, bytes memory data) = address(treasury).call(abi.encodeCall(HedgeFunV2EngineTreasuryCore.execute, ()));
        if (!ok) {
            ++failedExecutions;
            if (_stateDigest() != digestBefore) violation = true;
            return;
        }

        (HedgeFunV2Treasury.Action action,) = abi.decode(data, (HedgeFunV2Treasury.Action, uint256));
        if (action == HedgeFunV2Treasury.Action.RebalanceBuy) ++successfulBuys;
        else if (action == HedgeFunV2Treasury.Action.RebalanceSell) ++successfulSells;
        else violation = true;

        if (treasury.strategyNonce() != nonceBefore + 1) violation = true;
        if (lastSuccessAt != 0 && block.timestamp - lastSuccessAt < COOLDOWN) violation = true;

        uint256 turnoverNow = treasury.turnoverInEpoch();
        uint256 consumed;
        if (treasury.turnoverEpoch() == epochBefore) {
            if (turnoverNow < turnoverBefore) violation = true;
            else consumed = turnoverNow - turnoverBefore;
        } else {
            consumed = turnoverNow;
        }
        if (consumed < MIN_LOT || consumed > MAX_TRADE || turnoverNow > MAX_DAILY || fillBps < 500) {
            violation = true;
        }

        // the bucket is the listing calendar's trading date (the fixture's calendar keeps UTC days)
        uint64 expectedEpoch = uint64(treasury.tradingCalendar().tradingDate(block.timestamp));
        if (treasury.turnoverEpoch() != expectedEpoch) violation = true;
        if (ghostTurnoverEpoch != expectedEpoch) {
            ghostTurnoverEpoch = expectedEpoch;
            ghostTurnoverInEpoch = 0;
        }
        ghostTurnoverInEpoch += consumed;
        if (ghostTurnoverInEpoch > MAX_DAILY || turnoverNow != ghostTurnoverInEpoch) violation = true;

        ++successfulExecutions;
        lastSuccessAt = block.timestamp;
    }

    function _refreshFeeds() private {
        stockFeed.set(stockFeed.answer());
        usdgFeed.set(1e8);
    }

    function _stateDigest() private view returns (bytes32) {
        bytes32 strategyDigest = keccak256(
            abi.encode(
                treasury.strategyNonce(),
                treasury.turnoverEpoch(),
                treasury.turnoverInEpoch(),
                treasury.lastStrategyAt(),
                treasury.policyState(),
                treasury.bookedStock(),
                treasury.buybackStock(),
                treasury.avgCost()
            )
        );
        bytes32 accountingDigest = keccak256(
            abi.encode(
                treasury.totalStockReceived(),
                treasury.lastGoodPrice(),
                treasury.lastGoodPriceAt(),
                stock.balanceOf(address(treasury)),
                usdg.balanceOf(address(treasury)),
                stock.balanceOf(address(venue)),
                usdg.balanceOf(address(venue))
            )
        );
        bytes32 anchorDigest = keccak256(abi.encode(treasury.buybackAnchorSqrtP(), treasury.buybackAnchorAt()));
        return keccak256(abi.encode(strategyDigest, accountingDigest, anchorDigest));
    }
}

contract V2StrategyEngineInvariantTest is V2FactoryFixture {
    uint256 private constant PRICE = 100e18;
    uint256 private constant MAX_DAILY = 500e6;

    HedgeFunV2EngineTreasury internal treasury;
    StrategyEngineHandler internal handler;

    function setUp() public {
        _setUpV2(18);
        EngineAccountingVenue venue = new EngineAccountingVenue(address(stock), address(usdg), 3000, 1e30, PRICE);
        stockPool = venue;
        v3f.set(address(stock), address(usdg), 3000, address(venue));
        vm.prank(owner);
        factory.list(address(stock), address(oracle), address(venue), openPrice, true);
        usdg.mint(address(venue), 10_000_000e6);
        stock.mint(address(venue), 100_000e18);

        V2TreasuryDeployer deployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        V2RebalancePolicy policy = new V2RebalancePolicy();
        vm.startPrank(owner);
        bytes32 policyKey = deployer.registerPolicy(
            address(policy),
            150_000,
            deployer.POLICY_RETURN_BYTES(),
            keccak256("invariant-dependencies-v1"),
            keccak256("invariant-audit-v1")
        );
        (address engineA, address engineB) = deployer.makeChunks(type(HedgeFunV2EngineTreasury).creationCode);
        uint8 engineKind = deployer.registerEngineKind(
            engineA,
            engineB,
            StrategyCapabilities.SPOT_ENGINE_V1,
            StrategyCapabilities.CONFIG_SCHEMA_V1,
            StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL
        );
        vm.stopPrank();

        HedgeFunFactory.Request memory request = _request();
        request.nonce = 900;
        EngineConfig memory config;
        config.schema = StrategyCapabilities.CONFIG_SCHEMA_V1;
        config.engineVersion = StrategyCapabilities.SPOT_ENGINE_V1;
        config.policyKey = policyKey;
        config.words[0] = bytes32(uint256(5000) | uint256(500) << 16 | uint256(600) << 32);
        config.words[1] = bytes32(uint256(100e6));
        config.words[2] = bytes32(MAX_DAILY);
        deployer.setEngineConfig(request.symbol, request.nonce, engineKind, config);

        (,, bytes32 terms) = factory.predict(request);
        uint256 id = factory.launch(request, terms);
        (, address treasuryAddress,,,) = factory.strategies(id);
        treasury = HedgeFunV2EngineTreasury(treasuryAddress);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        stock.approve(address(curve), type(uint256).max);
        _graduateV2(curve);

        handler = new StrategyEngineHandler(treasury, venue, stock, usdg, stockFeed, usdgFeed);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_bucketsRemainCovered() public view {
        assertLe(
            treasury.bookedStock() + treasury.buybackStock(),
            stock.balanceOf(address(treasury)),
            "stock buckets exceed balance"
        );
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_turnoverNeverExceedsTheEpochLimit() public view {
        assertLe(treasury.turnoverInEpoch(), MAX_DAILY);
        assertLe(handler.ghostTurnoverInEpoch(), MAX_DAILY);
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_onlySuccessfulExecutionsAdvanceState() public view {
        assertEq(treasury.strategyNonce(), handler.successfulExecutions());
        assertEq(treasury.lastStrategyAt(), handler.lastSuccessAt());
        assertEq(treasury.policyState(), bytes32(0));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_handlerChecksCannotFailSilently() public view {
        assertFalse(handler.violation());
        assertEq(handler.executeAttempts(), handler.failedExecutions() + handler.successfulExecutions());
        assertEq(handler.successfulExecutions(), handler.successfulBuys() + handler.successfulSells());
    }

    function test_handlerCoversSubMinFailureAndExactBoundarySuccess() public {
        handler.attemptExecute(499);
        assertEq(handler.executeAttempts(), 1);
        assertEq(handler.subMinFillAttempts(), 1);
        assertEq(handler.failedExecutions(), 1);
        assertEq(handler.successfulExecutions(), 0);
        assertFalse(handler.violation());

        // raw value 2 deliberately selects the exact 500 bps case in the handler's edge-biased fill generator.
        handler.attemptExecute(2);
        assertEq(handler.executeAttempts(), 2);
        assertEq(handler.boundaryFillAttempts(), 1);
        assertEq(handler.failedExecutions(), 1);
        assertEq(handler.successfulExecutions(), 1);
        assertFalse(handler.violation());
    }
}
