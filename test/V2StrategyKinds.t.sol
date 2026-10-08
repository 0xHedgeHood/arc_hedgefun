// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

/// A second strategy for the tests: the shipped one plus a marker. What matters is that its code differs.
contract KindOneTreasury is HedgeFunV2Treasury {
    constructor(address usdg_, address stock_, address v3Pool_, address oracle_, address token_,
        address poolManager_, address factory_, Params memory p)
        HedgeFunV2Treasury(usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p) {}
    function strategyKind() external pure returns (uint8) { return 1; }
}

/// The per-launch strategy choice lives in the deployer, not the factory: the factory is bytes from EIP-170 and
/// its `Request` is the deployed V1 ABI. These tests pin that a kind is the creator's to choose, only for their
/// own salt, only among registered kinds, and that the choice is part of the terms the launch commits to.
contract V2StrategyKindsTest is V2FactoryFixture {
    V2TreasuryDeployer internal deployer;

    function setUp() public {
        _setUpV2(18);
        deployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
    }

    function _registerKindOne() internal returns (uint8 kind) {
        (address a, address b) = deployer.makeChunks(type(KindOneTreasury).creationCode);
        vm.prank(owner);
        kind = deployer.registerKind(a, b);
        assertEq(kind, 1);
        assertEq(deployer.kindCount(), 2);
    }

    function test_shippedTreasuryIsKindZeroAndNeedsNoCall() public {
        assertEq(deployer.kindCount(), 1);
        (address a, address b) = deployer.kinds(0);
        assertEq(a, deployer.chunkA());
        assertEq(b, deployer.chunkB());
        (uint256 id,,) = _launchV2(true);
        (, address treasury,,,) = factory.strategies(id);
        assertEq(HedgeFunTreasuryBase(treasury).factory(), address(factory));
        assertEq(deployer.strategyKindOf(keccak256(abi.encode("V2", address(this), uint96(0)))), 0);
    }

    function test_onlyFactoryOwnerRegistersAKindAndKindsAreWriteOnce() public {
        (address a, address b) = deployer.makeChunks(type(KindOneTreasury).creationCode);
        vm.expectRevert(V2TreasuryDeployer.NotOwner.selector);
        deployer.registerKind(a, b);
        vm.prank(owner);
        vm.expectRevert(V2TreasuryDeployer.BadKind.selector);
        deployer.registerKind(a, address(0xdead)); // no code
        _registerKindOne();
        (address a0,) = deployer.kinds(0);
        assertEq(a0, deployer.chunkA(), "kind 0 is untouched by a registration");
        vm.expectRevert(V2TreasuryDeployer.BadKind.selector);
        deployer.kinds(2);
    }

    function test_creatorCannotChooseAnUnregisteredKind() public {
        vm.expectRevert(V2TreasuryDeployer.BadKind.selector);
        deployer.setStrategyKind("V2", 0, 1);
    }

    function test_kindOneLaunchDeploysKindOneCodeAndGraduates() public {
        _registerKindOne();
        HedgeFunFactory.Request memory q = _request();
        (, address treasuryZero,) = factory.predict(q);
        deployer.setStrategyKind(q.symbol, q.nonce, 1);
        (, address treasuryOne, bytes32 terms) = factory.predict(q);
        assertTrue(treasuryOne != treasuryZero, "the kind is in the treasury address, so in the terms");
        uint256 id = factory.launch(q, terms);
        (, address treasury,,,) = factory.strategies(id);
        assertEq(treasury, treasuryOne);
        assertEq(KindOneTreasury(treasury).strategyKind(), 1);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        stock.approve(address(curve), type(uint256).max);
        _graduateV2(curve);
        assertTrue(HedgeFunTreasuryBase(treasury).hook() != address(0), "a kind-1 treasury is wired like any other");
    }

    function test_kindIsPerCreatorSalt() public {
        _registerKindOne();
        HedgeFunFactory.Request memory q = _request();
        (, address mine,) = factory.predict(q);
        vm.prank(address(0xBAD));
        deployer.setStrategyKind(q.symbol, q.nonce, 1); // someone else's salt: (symbol, THEM, nonce)
        (, address still,) = factory.predict(q);
        assertEq(still, mine, "another address cannot pick a kind for my launch");
    }

    function test_changingKindAfterQuoteRestatesTheLaunch() public {
        _registerKindOne();
        HedgeFunFactory.Request memory q = _request();
        (,, bytes32 terms) = factory.predict(q);
        deployer.setStrategyKind(q.symbol, q.nonce, 1);
        vm.expectRevert(HedgeFunFactory.Restated.selector);
        factory.launch(q, terms);
    }
}

/// The LP share of a graduating curve lives in `CurveDeployer`, per stock, for the same reason the strategy kind
/// lives in the treasury deployer. It is in the terms and frozen at launch: what the owner changes afterwards
/// applies to the next launch, never to a curve already selling.
contract V2LpShareTest is V2FactoryFixture {
    V2TreasuryDeployer internal deployer;

    function setUp() public {
        _setUpV2(18);
        deployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
    }

    function test_defaultIsSeventyPercentAndOnlyTheOwnerMovesItWithinBounds() public {
        assertEq(deployer.DEFAULT_LP_BPS(), 7000);
        assertEq(deployer.lpBps(address(stock)), 7000);
        vm.expectRevert(V2TreasuryDeployer.NotOwner.selector);
        deployer.setLpBps(address(stock), 7500);
        vm.startPrank(owner);
        vm.expectRevert(V2TreasuryDeployer.BadLpBps.selector);
        deployer.setLpBps(address(stock), 999);
        vm.expectRevert(V2TreasuryDeployer.BadLpBps.selector);
        deployer.setLpBps(address(stock), 10001);
        deployer.setLpBps(address(stock), 7500);
        vm.stopPrank();
        assertEq(deployer.lpBps(address(stock)), 7500);
    }

    function test_lpShareIsInTheTermsAndFrozenAtLaunch() public {
        HedgeFunFactory.Request memory q = _request();
        (,, bytes32 terms) = factory.predict(q);
        vm.prank(owner);
        deployer.setLpBps(address(stock), 7500);
        vm.expectRevert(HedgeFunFactory.Restated.selector);
        factory.launch(q, terms);
        (,, terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(factory.curves(id));
        (, address treasury,,,) = factory.strategies(id);
        assertEq(deployer.lpBpsOfTreasury(treasury), 7500);
        vm.prank(owner);
        deployer.setLpBps(address(stock), 2000); // after launch: the next launch's business, not this curve's
        assertEq(deployer.lpBpsOfTreasury(treasury), 7500);
        stock.approve(address(curve), type(uint256).max);
        uint256 treasuryBefore = stock.balanceOf(treasury);
        vm.recordLogs();
        _graduateV2(curve);
        uint256 toTreasury = stock.balanceOf(treasury) - treasuryBefore;
        // 75% to LP within seeding dust: the treasury got the other quarter of the real reserve
        uint256 realReserve = toTreasury * 4; // the LP got ~3x what the treasury got
        assertApproxEqRel(realReserve / 4, toTreasury, 1e15);
        uint256 lpStock = stock.balanceOf(address(pm));
        assertApproxEqRel(lpStock, toTreasury * 3, 1e12, "LP seed is three quarters, treasury one quarter");
    }
}
