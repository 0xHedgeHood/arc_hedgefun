// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {CalibrateV2Listings} from "../script/testnet/CalibrateV2Listings.s.sol";
import {DeployV2Testnet} from "../script/testnet/DeployV2Testnet.s.sol";
import {TestnetMarket} from "../script/testnet/TestnetMarket.sol";
import {TestStock} from "../script/testnet/TestnetAssets.sol";
import {TradingCalendar} from "../src/TradingCalendar.sol";

contract ListingCalibrationInvoker {
    function run(CalibrateV2Listings script) external { script.run(); }
}

/// The calibration that brings a core on the existing test market to the release settings: the default 79.31%
/// sale raising about $8,205 and graduating near a $50,000 FDV, with 70% of the raise to the locked LP.
///
/// LISTING_CALIBRATION_FORK=true LISTING_CALIBRATION_FORK_BLOCK=<fresh block> [V2_FACTORY=0x...]
///   forge test --match-contract TestnetV2ListingCalibrationForkTest -vv
contract TestnetV2ListingCalibrationForkTest is Test {
    uint256 constant REFERENCE_RAISE_USD_E18 = 8_204.6e18;
    uint256 constant REFERENCE_FDV_USD_E18 = 50_000e18;

    HedgeFunV2Factory internal factory;
    TestnetMarket internal market;
    V2TreasuryDeployer internal registry;
    CalibrateV2Listings internal script;

    function test_referenceIsTheFreshDeployments() public {
        script = new CalibrateV2Listings();
        DeployV2Testnet fresh = new DeployV2Testnet();
        assertEq(script.TARGET_GRADUATION_FDV_USD_E18(), fresh.TARGET_GRADUATION_FDV_USD_E18());
        assertEq(script.REFERENCE_SALE_BPS(), fresh.REFERENCE_SALE_BPS());
        uint256[7] memory prices = [uint256(24e18), 200e18, 228e18, 339e18, 358e18, 500e18, 600e18];
        for (uint256 i; i < prices.length; ++i) {
            assertEq(script.referenceOpenPriceE18(prices[i]), fresh.referenceOpenPriceE18(prices[i]));
        }
    }

    /// Opt-in, pinned public-testnet fork. No signing or broadcast to the public chain.
    function test_forkCalibratesEveryStockAndTheDefaultSaleGraduatesNear50kAtSeventyThirty() public {
        vm.skip(!vm.envOr("LISTING_CALIBRATION_FORK", false), "set LISTING_CALIBRATION_FORK=true");
        uint256 forkBlock = vm.envUint("LISTING_CALIBRATION_FORK_BLOCK");
        vm.createSelectFork(
            vm.envOr("LISTING_CALIBRATION_FORK_RPC", string("https://rpc.testnet.chain.robinhood.com")), forkBlock
        );
        assertEq(block.chainid, 46630);
        emit log_named_uint("requested fork block", forkBlock);
        factory = HedgeFunV2Factory(vm.envOr("V2_FACTORY", address(0x7BbaAb5d1426650FaaAEB0214D5a045A80FD2621)));
        market = TestnetMarket(vm.envOr("TESTNET_MARKET", address(0xc1AF2f52980F8A7AA4E90A8E30D5c3FaF0375f21)));
        registry = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        script = new CalibrateV2Listings();
        address operator = factory.owner();

        _openTheMarket();
        _putBackTheInheritedSettings(operator);
        CalibrateV2Listings.Calibration[] memory p = script.planFor(factory, market);
        _assertThePlanNeedsALivePriceAndNamesItsMarket(p);
        bytes32 defaultsBefore = keccak256(abi.encode(factory.getDefaults()));
        bytes32[] memory untouchedBefore = new bytes32[](p.length);
        HedgeFunFactory.Request memory stale = _request(p[0].stock, 0);
        for (uint256 i; i < p.length; ++i) {
            untouchedBefore[i] = _untouched(p[i].stock);
            assertGt(p[i].oldOpenPriceE18, p[i].newOpenPriceE18, "this core already opens at the reference");
            assertEq(p[i].newLpBps, 7000);
            assertTrue(p[i].oldLpBps != p[i].newLpBps, "this core already splits seventy to thirty");
        }

        vm.setEnv("V2_FACTORY", vm.toString(address(factory)));
        vm.setEnv("OPERATOR", vm.toString(operator));
        vm.setEnv("TESTNET_MARKET", vm.toString(address(market)));
        vm.etch(operator, type(ListingCalibrationInvoker).runtimeCode);
        vm.setEnv("EXPECTED_PLAN_HASH", vm.toString(bytes32(uint256(1))));
        vm.expectRevert(bytes("plan changed"));
        ListingCalibrationInvoker(operator).run(script);
        vm.setEnv("EXPECTED_PLAN_HASH", vm.toString(keccak256(abi.encode(p))));
        vm.expectRevert(bytes("plan changed"));   // the rows alone are not the hash: it names where they apply
        ListingCalibrationInvoker(operator).run(script);
        vm.setEnv("EXPECTED_PLAN_HASH", vm.toString(script.planHash(factory, market, p)));
        ListingCalibrationInvoker(operator).run(script);

        assertEq(keccak256(abi.encode(factory.getDefaults())), defaultsBefore, "defaults changed");
        CalibrateV2Listings.Calibration[] memory again = script.planFor(factory, market);
        assertEq(again.length, p.length);
        for (uint256 i; i < p.length; ++i) {
            _assertCalibrated(p[i]);
            assertEq(again[i].oldOpenPriceE18, again[i].newOpenPriceE18, "a second run has nothing to send");
            assertEq(again[i].oldLpBps, again[i].newLpBps, "a second run has nothing to send");
            assertEq(_untouched(p[i].stock), untouchedBefore[i], "gates or band ceiling changed");
            _assertDefaultLaunchGraduatesAtTheReference(p[i].stock, i + 1);
        }

        // A second run of the reviewed-again plan sends nothing.
        vm.setEnv("EXPECTED_PLAN_HASH", vm.toString(script.planHash(factory, market, again)));
        vm.recordLogs();
        ListingCalibrationInvoker(operator).run(script);
        assertEq(vm.getRecordedLogs().length, 0, "a calibrated core is left alone");

        // A quote read before the calibration no longer launches.
        (,, bytes32 staleTerms) = factory.predict(stale);
        vm.deal(stale.creator, stale.maxFee);
        vm.prank(stale.creator);
        vm.expectRevert(HedgeFunFactory.Restated.selector);
        factory.launch{value: stale.maxFee}(stale, staleTerms);
    }

    /// The fork may be taken on a weekend; the calendar's owner opens the session, as for a test session on chain.
    function _openTheMarket() private {
        (address stock,,,,,) = market.lines(market.pools(0));
        (address oracle,,,) = factory.listings(stock);
        TradingCalendar calendar = TradingCalendar(address(PriceOracle(oracle).calendar()));
        if (!calendar.isClosed(block.timestamp)) return;
        vm.prank(calendar.owner());
        calendar.setOverride(calendar.tradingDate(block.timestamp), 2);
    }

    function _assertThePlanNeedsALivePriceAndNamesItsMarket(CalibrateV2Listings.Calibration[] memory p) private {
        assertTrue(script.planHash(factory, market, p) != script.planHash(factory, TestnetMarket(address(0xdead)), p));
        TestStock stock = TestStock(p[0].stock);
        vm.prank(stock.owner());
        stock.setOraclePaused(true);
        vm.expectRevert(bytes("no live oracle price"));
        script.planFor(factory, market);
        vm.prank(stock.owner());
        stock.setOraclePaused(false);
    }

    /// What a core that reuses the test market starts with: opening prices chosen for a 44% sale and an even
    /// split. Set here so the calibration is exercised at any block, including after it has been broadcast.
    function _putBackTheInheritedSettings(address operator) private {
        uint256 count = market.poolCount();
        vm.startPrank(operator);
        for (uint256 i; i < count; ++i) {
            (address stock,,,,,) = market.lines(market.pools(i));
            (address oracle, address pool,, bool enabled) = factory.listings(stock);
            if (!enabled) continue;
            (, uint256 priceE18,) = PriceOracle(oracle).lastPriceAt();
            factory.list(stock, oracle, pool, script.referenceOpenPriceE18(priceE18) * 9 / 2, true);
            registry.setLpBps(stock, 5000);
        }
        vm.stopPrank();
    }

    function _assertCalibrated(CalibrateV2Listings.Calibration memory r) private view {
        (address oracle, address pool, uint256 open, bool enabled) = factory.listings(r.stock);
        assertEq(oracle, r.oracle);
        assertEq(pool, r.pool);
        assertEq(open, r.newOpenPriceE18);
        assertTrue(enabled);
        assertEq(registry.lpBps(r.stock), 7000);
    }

    function _untouched(address stock) private view returns (bytes32) {
        (uint16 deviation, uint16 slippage, uint64 chunk) = factory.listingGates(stock);
        return keccak256(abi.encode(deviation, slippage, chunk, factory.bandCeiling(stock)));
    }

    function _request(address stock, uint256 n) private returns (HedgeFunFactory.Request memory q) {
        q.name = "Listing Calibration Fork Test";
        q.symbol = "CALIBRATED";
        q.stock = stock;
        q.creator = makeAddr("listing calibration fork creator");
        q.taxBps = 100;
        q.tp1Bps = 500;
        q.tp2Bps = 1000;
        q.dipBps = 500;
        q.lotBps = 2000;
        q.nonce = uint96(factory.strategyCount() + 2000000 + n);
        q.maxFee = factory.getDefaults().launchFeeAmount;
        (,, q.expectedOpenPriceE18,) = factory.listings(stock);
    }

    function _assertDefaultLaunchGraduatesAtTheReference(address stock, uint256 n) private {
        HedgeFunFactory.Request memory q = _request(stock, n);
        (,, bytes32 terms) = factory.predict(q);
        vm.deal(q.creator, q.maxFee);
        vm.prank(q.creator);
        uint256 id = factory.launch{value: q.maxFee}(q, terms);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        (, address treasury,,,) = factory.strategies(id);
        assertEq(registry.lpBpsOfTreasury(treasury), 7000, "the launch froze seventy to thirty");
        (address oracle,,,) = factory.listings(stock);
        (bool ok, uint256 priceE18,) = PriceOracle(oracle).lastPriceAt();
        assertTrue(ok);

        uint256 remainingBps = 10_000 - script.REFERENCE_SALE_BPS();
        uint256 raiseUsd = (curve.terminalStock() - curve.virtualStock()) * priceE18 / 1e18;
        uint256 graduationFdvUsd = curve.terminalStock() * 10_000 / remainingBps * priceE18 / 1e18;
        emit log_named_address("stock", stock);
        emit log_named_decimal_uint("  net raise, USD", raiseUsd, 18);
        emit log_named_decimal_uint("  graduation FDV, USD", graduationFdvUsd, 18);
        assertApproxEqRel(raiseUsd, REFERENCE_RAISE_USD_E18, 0.001e18);
        assertApproxEqRel(graduationFdvUsd, REFERENCE_FDV_USD_E18, 0.001e18);
    }
}
