// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {CurveDeployer} from "../src/v2/CurveDeployer.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

contract CurveDeployerBuilder {
    // Test-only helper: its runtime embeds CurveDeployer init code.
    bool public constant IS_TEST = true;
    function build(uint16 saleBps) external returns (CurveDeployer) { return new CurveDeployer(saleBps); }
}

/// The share of supply a launch sells on its curve is fixed when the curve deployer is constructed: 7931 on a
/// release. A creator chooses only the opening window (`snipeSeconds`) of their own launch, registered on the curve
/// deployer for the factory salt (symbol, creator, nonce). These pin: no registration, owner or later transaction
/// moves the sale share; the curve is built from it; nobody registers for anyone else; the window is in the launch
/// terms; and a launch that registered nothing gets the factory's window.
contract V2CreatorCurveConfigTest is V2FactoryFixture {
    address internal stranger = address(uint160(uint256(keccak256("creator curve config stranger"))));
    CurveDeployer internal registry;
    uint256 internal constant S = 1_000_000e18;   // the fixture's supply
    uint256 internal constant V = 50e18;          // ceil(openPrice * S / 1e18) for the fixture's 18-decimal stock
    uint16 internal constant SALE = 7931;         // the release's sale share
    uint256 internal constant T_MIN = S * 2069 / 10_000;

    event CurveConfigSet(address indexed creator, string symbol, uint96 nonce, uint16 saleBps, uint8 snipeSeconds);
    event CurveLaunched(uint256 indexed id, address indexed curve, uint16 saleBps, uint256 virtualStock);

    function setUp() public {
        creatorSaleBps = 0; // the fixture deploys the release's 7931 and registers nothing of its own
        _setUpV2(18);
        registry = factory.curveDeployer();
    }

    function _launchWith(uint96 nonce, uint8 window, bool register)
        internal returns (HedgeFunFactory.Request memory q, HedgeFunBondingCurve curve)
    {
        q = _request();
        q.nonce = nonce;
        if (register) registry.setCurveConfig(q.symbol, q.nonce, SALE, window);
        address predicted = factory.predictCurve(q);
        (,, bytes32 terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        curve = HedgeFunBondingCurve(factory.curves(id));
        assertEq(address(curve), predicted, "predictCurve");
        stock.approve(address(curve), type(uint256).max);
    }

    // ------------------------------------------------------------------------------------------------ the sale share

    function test_theSaleShareIsTheDeployersAndNoRegistrationMovesIt() public {
        assertEq(registry.DEFAULT_SALE_BPS(), SALE);
        uint16[9] memory other = [uint16(0), 999, 1000, 4400, 6000, 7930, 7932, 9000, 10_000];
        for (uint256 i; i < other.length; ++i) {
            vm.expectRevert(CurveDeployer.BadCurveConfig.selector);
            registry.setCurveConfig("V2", 0, other[i], 3);
            vm.prank(owner);
            vm.expectRevert(CurveDeployer.BadCurveConfig.selector);
            registry.setCurveConfig("V2", 0, other[i], 3);
        }
        registry.setCurveConfig("V2", 0, SALE, 3);
        assertEq(registry.DEFAULT_SALE_BPS(), SALE);
    }

    function testFuzz_anyOtherSaleShareIsRefused(uint16 sale, uint8 window) public {
        vm.assume(sale != SALE);
        vm.expectRevert(CurveDeployer.BadCurveConfig.selector);
        registry.setCurveConfig("V2", 0, sale, window);
    }

    /// The bounds are the curve constructor's own. A deployer accepts the share it was built with and no other.
    function test_aDeployerIsBuiltWithOneShareInsideTheCurvesBounds() public {
        assertEq(registry.MIN_SALE_BPS(), 1000);
        assertEq(registry.MAX_SALE_BPS(), 9000);
        // Built by another contract: an expected revert on a `new` in the test itself can end the test there.
        CurveDeployerBuilder builder = new CurveDeployerBuilder();
        uint16[4] memory bad = [uint16(999), 9001, 0, 10_000];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(CurveDeployer.BadCurveConfig.selector);
            builder.build(bad[i]);
        }
        uint16[3] memory good = [uint16(1000), 8000, 9000];
        uint256 accepted;
        for (uint256 i; i < good.length; ++i) {
            CurveDeployer d = builder.build(good[i]);
            assertEq(d.DEFAULT_SALE_BPS(), good[i]);
            d.setCurveConfig("V2", 0, good[i], 3);
            vm.expectRevert(CurveDeployer.BadCurveConfig.selector);
            d.setCurveConfig("V2", 0, SALE, 3);
            ++accepted;
        }
        assertEq(accepted, 3, "every case ran");
    }

    /// The curve's edge shares and the release's, end to end on the default 70% LP share: launch, buy out,
    /// graduate, in both currency orderings.
    function test_edgeSharesGraduateOnTheDefaultLpShare() public {
        uint16[3] memory shares = [uint16(1000), SALE, 9000];
        for (uint256 i; i < shares.length; ++i) {
            creatorSaleBps = shares[i];
            _setUpV2(18);
            assertEq(factory.curveDeployer().DEFAULT_SALE_BPS(), shares[i]);
            assertEq(V2TreasuryDeployer(address(factory.treasuryDeployer())).lpBps(address(stock)), 7000);
            for (uint256 side; side < 2; ++side) {
                (, HedgeFunBondingCurve curve,) = _launchV2(side == 0);
                _graduateV2(curve);
                assertEq(uint256(curve.status()), uint256(HedgeFunBondingCurve.Status.Graduated));
            }
        }
    }

    /// Rg = ceil(S * V / Tmin) - V with Tmin = floor(S * 2069 / 10000), which for this supply is
    /// ceil(V * 7931 / 2069): 3.83 V. Registered or not, the curve is the same one.
    function test_theFixedShareBuildsTheCurveAndItsRaise() public {
        for (uint256 i; i < 2; ++i) {
            (, HedgeFunBondingCurve curve) = _launchWith(uint96(i + 1), 3, i == 1);
            assertEq(curve.virtualStock(), V);
            assertEq(curve.minTokenReserve(), T_MIN, "minTokenReserve");
            assertEq(curve.terminalStock(), Math.ceilDiv(S * V, T_MIN), "terminalStock");
            uint256 rg = curve.terminalStock() - curve.virtualStock();
            assertEq(rg, Math.ceilDiv(V * SALE, 10_000 - SALE), "Rg = V * sale / (10000 - sale)");
            assertEq(rg, 191_662_638_956_017_399_711, "Rg literal");
            // The immutable raise is net principal. The buyer additionally funds the base stock
            // fee, and only that fee remains claimable after the net raise seeds the V4 pool.
            uint256 beforeBalance = stock.balanceOf(address(this));
            (uint256 spent,) = curve.buy(type(uint256).max, 1, address(this), block.timestamp);
            uint256 fee = spent * _request().taxBps / 10_000;
            assertEq(beforeBalance - stock.balanceOf(address(this)), spent, "actual gross payment");
            assertEq(spent - fee, rg, "gross payment less base fee funds the whole net raise");
            assertLt((spent - 1) - (spent - 1) * _request().taxBps / 10_000, rg,
                "no smaller gross payment funds the cap");
            assertEq(curve.totalFees(), fee);
            assertEq(stock.balanceOf(address(curve)), fee, "only fee liabilities remain after graduation");
            assertEq(uint256(curve.status()), uint256(HedgeFunBondingCurve.Status.Graduated));
        }
    }

    /// `_preflight` runs on the fixed share and the stock's LP share: on a listing whose raise is 4 raw units, an
    /// LP share that leaves the V4 seed nothing is refused at quote and launch, and one that seeds it launches.
    function test_preflightRefusesAnUnseedableListing() public {
        HedgeFunFactory.Defaults memory d = _defaults();
        d.supply = 1e18;
        V2TreasuryDeployer treasuries = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        vm.startPrank(owner);
        factory.setDefaults(d);
        factory.list(address(stock), address(oracle), address(stockPool), 1, true);
        treasuries.setLpBps(address(stock), 1000);             // Rg = 5 - 1 = 4 wei: an LP stock of 0
        vm.stopPrank();
        HedgeFunFactory.Request memory q = _request();
        q.expectedOpenPriceE18 = 1;
        vm.expectRevert(HedgeFunV2Factory.Unseedable.selector);
        factory.predict(q);
        vm.expectRevert(HedgeFunV2Factory.Unseedable.selector);
        factory.launch(q, bytes32(0));
        vm.prank(owner);
        treasuries.setLpBps(address(stock), 10_000);           // an LP stock of 4 wei: seedable
        (,, bytes32 terms) = factory.predict(q);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(factory.launch(q, terms)));
        assertEq(curve.terminalStock() - curve.virtualStock(), 4);
    }

    // ------------------------------------------------------------------------------------------------ opening window

    /// The #95 schedule: taxBps + ceil((snipeBps - taxBps) * (W - t) / W) for t < W, then the flat tax. W = 0 is off.
    function test_creatorSnipeSecondsSetsTheOpeningWindow() public {
        uint8[4] memory window = [uint8(0), 3, 60, 180];
        for (uint256 i; i < window.length; ++i) {
            uint256 snap = vm.snapshotState();
            (, HedgeFunBondingCurve curve) = _launchWith(uint96(i + 1), window[i], true);
            uint256 w = window[i];
            uint256 tax = curve.taxBps();
            assertEq(tax, 1000);
            assertEq(curve.snipeSeconds(), w, "the creator's window");
            assertEq(curve.snipeBps(), _defaults().snipeBps, "the opening rate stays the owner's");
            uint256 t0 = curve.launchedAt();
            for (uint256 t; t <= w + 1; ++t) {
                vm.warp(t0 + t);
                uint256 expected = t < w ? tax + Math.ceilDiv((9900 - tax) * (w - t), w) : tax;
                assertEq(curve.buyRateBps(), expected, "schedule");
                if (t < w) assertGt(curve.buyRateBps(), tax, "every second inside the window pays more");
            }
            vm.revertToState(snap);
        }
    }

    function test_openingWindowLiterals() public {
        (, HedgeFunBondingCurve curve) = _launchWith(1, 60, true);
        uint256 t0 = curve.launchedAt();
        assertEq(curve.buyRateBps(), 9900);
        vm.warp(t0 + 30); assertEq(curve.buyRateBps(), 5450);   // 1000 + 8900 / 2
        vm.warp(t0 + 59); assertEq(curve.buyRateBps(), 1149);   // 1000 + ceil(8900 / 60)
        vm.warp(t0 + 60); assertEq(curve.buyRateBps(), 1000);
        (, curve) = _launchWith(2, 0, true);
        assertEq(curve.buyRateBps(), 1000, "0 is off: the flat tax from the launch block");
        (, curve) = _launchWith(3, 180, true);
        t0 = curve.launchedAt();
        vm.warp(t0 + 1); assertEq(curve.buyRateBps(), 9851);    // 1000 + ceil(8900 * 179 / 180)
        vm.warp(t0 + 179); assertEq(curve.buyRateBps(), 1050);  // 1000 + ceil(8900 / 180)
        vm.warp(t0 + 180); assertEq(curve.buyRateBps(), 1000);
    }

    function test_snipeSecondsOverTheBoundIsRefusedAtRegistration() public {
        assertEq(registry.MAX_SNIPE_SECONDS(), 180);
        vm.expectRevert(CurveDeployer.BadCurveConfig.selector);
        registry.setCurveConfig("V2", 0, SALE, 181);
        vm.expectRevert(CurveDeployer.BadCurveConfig.selector);
        registry.setCurveConfig("V2", 0, SALE, 255);
        registry.setCurveConfig("V2", 0, SALE, 180);
        registry.setCurveConfig("V2", 0, SALE, 0);
    }

    // ------------------------------------------------------------------------------------------------ defaults

    function test_noRegistrationGivesTheFixedShareAndTheFactorysWindow() public {
        (HedgeFunFactory.Request memory q, HedgeFunBondingCurve curve) = _launchWith(0, 0, false);
        bytes32 salt = keccak256(abi.encode(q.symbol, q.creator, q.nonce));
        (uint16 rawSale, uint8 rawWindow) = registry.curveConfigOf(salt);
        assertEq(rawSale, 0, "nothing registered");
        assertEq(rawWindow, 0);
        assertEq(curve.minTokenReserve(), T_MIN, "7931");
        assertEq(curve.snipeSeconds(), 3, "the factory's snipeSeconds");
        (uint16 sale, uint8 window) = registry.curveConfig(salt, 3);
        assertEq(sale, SALE);
        assertEq(window, 3);

        // The default window is the factory's at quote time, not a constant.
        HedgeFunFactory.Defaults memory d = _defaults();
        d.snipeSeconds = 45;
        vm.prank(owner);
        factory.setDefaults(d);
        (, curve) = _launchWith(1, 0, false);
        assertEq(curve.snipeSeconds(), 45);
        assertEq(curve.minTokenReserve(), T_MIN);
    }

    function test_registrationEmitsAndReadsBack() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit CurveConfigSet(address(this), "V2", 7, SALE, 60);
        registry.setCurveConfig("V2", 7, SALE, 60);
        (uint16 sale, uint8 window) = registry.curveConfigOf(keccak256(abi.encode("V2", address(this), uint96(7))));
        assertEq(sale, SALE);
        assertEq(window, 60);
        (sale, window) = registry.curveConfig(keccak256(abi.encode("V2", address(this), uint96(7))), 3);
        assertEq(sale, SALE);
        assertEq(window, 60, "a registration overrides the default window");
    }

    // ------------------------------------------------------------------------------------------------ salt binding

    function test_strangerCannotChooseForAnotherCreatorsSalt() public {
        HedgeFunFactory.Request memory q = _request();          // the creator is this contract
        (,, bytes32 terms) = factory.predict(q);
        vm.prank(stranger);
        registry.setCurveConfig(q.symbol, q.nonce, SALE, 180);   // same symbol and nonce, from someone else
        bytes32 mine = keccak256(abi.encode(q.symbol, address(this), q.nonce));
        bytes32 theirs = keccak256(abi.encode(q.symbol, stranger, q.nonce));
        assertTrue(mine != theirs, "a different sender is a different salt");
        (uint16 sale, uint8 window) = registry.curveConfigOf(mine);
        assertEq(sale, 0);
        assertEq(window, 0);
        (sale, window) = registry.curveConfigOf(theirs);
        assertEq(sale, SALE);
        assertEq(window, 180);

        // The creator's pending quote is untouched: no Restated, and the window is the factory's.
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(factory.launch(q, terms)));
        assertEq(curve.minTokenReserve(), T_MIN);
        assertEq(curve.snipeSeconds(), 3);

        // The stranger's registration reaches only a launch the stranger makes as its own creator.
        q.creator = stranger;
        (,, terms) = factory.predict(q);
        vm.prank(stranger);
        curve = HedgeFunBondingCurve(factory.curves(factory.launch(q, terms)));
        assertEq(curve.minTokenReserve(), T_MIN, "the same raise for everyone");
        assertEq(curve.snipeSeconds(), 180);
        assertEq(curve.creator(), stranger);
    }

    // ------------------------------------------------------------------------------------------------ terms

    /// The raise of a pending quote cannot be moved, by its creator or anyone: there is nothing to restate.
    function test_theRaiseOfAPendingQuoteCannotBeChanged() public {
        HedgeFunFactory.Request memory q = _request();
        registry.setCurveConfig(q.symbol, q.nonce, SALE, 60);
        (,, bytes32 terms) = factory.predict(q);
        vm.expectRevert(CurveDeployer.BadCurveConfig.selector);
        registry.setCurveConfig(q.symbol, q.nonce, 6000, 60);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(factory.launch(q, terms)));
        assertEq(curve.minTokenReserve(), T_MIN);
        assertEq(curve.snipeSeconds(), 60);
    }

    /// The window is not in any address `super._terms` covers (only the curve's, which is not in terms), so the
    /// V2 terms hash pins it explicitly. A window-only change must restate.
    function test_changingTheWindowAfterPredictRestates() public {
        HedgeFunFactory.Request memory q = _request();
        registry.setCurveConfig(q.symbol, q.nonce, SALE, 60);
        (,, bytes32 terms) = factory.predict(q);
        registry.setCurveConfig(q.symbol, q.nonce, SALE, 61);
        (,, bytes32 moved) = factory.predict(q);
        assertTrue(moved != terms, "the window is in the terms");
        vm.expectRevert(HedgeFunFactory.Restated.selector);
        factory.launch(q, terms);
        registry.setCurveConfig(q.symbol, q.nonce, SALE, 0);
        vm.expectRevert(HedgeFunFactory.Restated.selector);
        factory.launch(q, terms);
        // back to the quoted window, the quote is good again
        registry.setCurveConfig(q.symbol, q.nonce, SALE, 60);
        factory.launch(q, terms);
    }

    /// Terms cover the values, not the act of registering: a first registration after `predict` restates exactly
    /// when its window differs from the one the quote was given.
    function test_firstRegistrationAfterPredictRestatesOnlyIfItChangesTheCurve() public {
        HedgeFunFactory.Request memory q = _request();
        (,, bytes32 terms) = factory.predict(q);
        registry.setCurveConfig(q.symbol, q.nonce, SALE, 60);
        vm.expectRevert(HedgeFunFactory.Restated.selector);
        factory.launch(q, terms);
        registry.setCurveConfig(q.symbol, q.nonce, SALE, 3);    // the defaults, spelt out
        factory.launch(q, terms);
    }

    // ------------------------------------------------------------------------------------------------ addresses

    /// `predictCurve` and an independent CREATE2 derivation from `type(HedgeFunBondingCurve).creationCode` with the
    /// fixed share and the creator's literal window both name the deployed curve.
    function test_predictCurveIsTheDeployedCurveForACreatorsWindow() public {
        HedgeFunFactory.Request memory q = _request();
        q.nonce = 11;
        registry.setCurveConfig(q.symbol, q.nonce, SALE, 60);
        address predicted = factory.predictCurve(q);
        (,, bytes32 terms) = factory.predict(q);
        uint256 id = factory.strategyCount();
        (address token, address treasury,) = factory.predict(q);
        vm.expectEmit(true, true, false, true, address(factory));
        emit CurveLaunched(id, predicted, SALE, V);
        factory.launch(q, terms);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        assertEq(address(curve), predicted);
        HedgeFunBondingCurve.Init memory p = HedgeFunBondingCurve.Init({
            factory: address(factory), token: token, stock: address(stock), treasury: treasury,
            protocol: protocol, creator: address(this), supply: S, virtualStock: V, saleBps: SALE,
            taxBps: q.taxBps, protocolBps: 2000, creatorBps: q.creatorBps, snipeBps: 9900, snipeSeconds: 60,
            openingTaxExemptions: new address[](0)
        });
        bytes32 salt = keccak256(abi.encode(q.symbol, q.creator, q.nonce));
        bytes32 initHash = keccak256(abi.encodePacked(type(HedgeFunBondingCurve).creationCode, abi.encode(p)));
        assertEq(address(curve), vm.computeCreate2Address(salt, initHash, address(registry)), "independent CREATE2");
        // the same launch at the default window would have been a different curve
        p.snipeSeconds = 3;
        assertTrue(registry.predict(salt, abi.encode(p)) != address(curve));
    }

    /// Registering is free and open to every sender: a creator needs no listing, no owner and no launch to do it,
    /// and re-registering a salt that already launched changes nothing that exists.
    function test_reRegisteringALaunchedSaltChangesNothingDeployed() public {
        (HedgeFunFactory.Request memory q, HedgeFunBondingCurve curve) = _launchWith(5, 60, true);
        registry.setCurveConfig(q.symbol, q.nonce, SALE, 0);
        assertEq(curve.minTokenReserve(), T_MIN);
        assertEq(curve.snipeSeconds(), 60);
    }
}
