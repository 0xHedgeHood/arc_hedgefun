// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {HedgeFunBondingCurve as Curve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunV2TradeRouter as Router} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {V2LiquidityVault} from "../src/v2/V2LiquidityVault.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

/// Red-team local simulations: actual V2 factory, token, curve, treasury, hook and PoolManager.
/// No deal() for strategy tokens, no mocked curve pricing, and no alteration of production storage.
contract V2AdversarialTradingTest is V2FactoryFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address private constant ALICE = address(0x1001);
    address private constant BOB = address(0x1002);
    address private constant MALLORY = address(0x1003);
    address[3] private actors = [ALICE, BOB, MALLORY];
    Curve private curve;
    IERC20 private token;
    Router private router;
    PoolKey private key;
    uint256 private id;
    uint256 private unit;
    uint256 private initialStockSupply;
    uint256 private initialTokenSupply;
    uint256 private expectedBurn;
    uint256 private stockDonatedToCurve;
    uint256 private tokenDonatedToCurve;
    uint256 private stockDonatedToFactory;
    uint256 private tokenDonatedToFactory;

    function setUp() public { _setUpV2(18); }

    function _start(bool tokenIs0, bool sixDecimals) private {
        if (sixDecimals) _setUpV2(6);
        unit = 10 ** stock.decimals();
        (id, curve, key) = _launchV2(tokenIs0);
        token = IERC20(curve.token());
        router = new Router(factory);
        initialTokenSupply = token.totalSupply();
        for (uint256 i; i < actors.length; ++i) {
            stock.mint(actors[i], 1000 * unit);
            vm.startPrank(actors[i]);
            stock.approve(address(curve), type(uint256).max);
            stock.approve(address(router), type(uint256).max);
            token.approve(address(curve), type(uint256).max);
            token.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
        initialStockSupply = stock.totalSupply();
        _assertConservation();
    }

    function _params(uint256 amount, uint8 stage) private view returns (Router.TradeParams memory) {
        return Router.TradeParams(id, address(stock), amount, amount, 1, block.timestamp, stage, true);
    }

    function _empty() private pure returns (Router.Hop[] memory path) { path = new Router.Hop[](0); }

    function _holders() private view returns (address[] memory who) {
        who = new address[](13);
        who[0] = address(this); who[1] = ALICE; who[2] = BOB; who[3] = MALLORY;
        who[4] = address(curve); who[5] = address(factory); who[6] = address(pm);
        who[7] = address(hook); who[8] = curve.treasury(); who[9] = protocol;
        who[10] = address(router); who[11] = address(stockPool);
        who[12] = hook.liquidityVaultOf(key.toId());
    }

    function _sumBalances(IERC20 asset) private view returns (uint256 total) {
        address[] memory who = _holders();
        for (uint256 i; i < who.length; ++i) total += asset.balanceOf(who[i]);
    }

    function _assertConservation() private view {
        assertEq(stock.totalSupply(), initialStockSupply, "stock cannot be minted/burned by trading");
        assertEq(_sumBalances(IERC20(address(stock))), initialStockSupply, "all stock across users, fees, LP and donations");
        assertEq(token.totalSupply() + expectedBurn, initialTokenSupply, "only accounted curve/LP/hook burns");
        assertEq(_sumBalances(token), token.totalSupply(), "all live tokens accounted for exactly once");
        assertEq(stock.balanceOf(address(curve)), curve.realStockReserve() + curve.totalFees() + stockDonatedToCurve);
        assertEq(token.balanceOf(address(curve)), curve.tokenReserve() + tokenDonatedToCurve);
        assertEq(stock.balanceOf(address(factory)), stockDonatedToFactory, "factory cannot use donations to settle");
        assertEq(token.balanceOf(address(factory)), tokenDonatedToFactory);
        assertEq(curve.totalFees(), curve.claimable(protocol) + curve.claimable(address(this)) + curve.claimable(curve.treasury()));
        assertEq(stock.balanceOf(address(router)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(stock.allowance(address(router), address(curve)), 0);
        assertEq(token.allowance(address(router), address(curve)), 0);
        if (curve.status() == Curve.Status.Active) {
            assertEq(curve.virtualStock() + curve.realStockReserve(), Math.ceilDiv(curve.invariant(), curve.tokenReserve()));
            assertGe(curve.tokenReserve(), curve.minTokenReserve());
        } else {
            assertEq(uint256(curve.status()), uint256(Curve.Status.Graduated), "Ready must never persist");
            assertEq(curve.realStockReserve(), 0); assertEq(curve.tokenReserve(), 0);
            assertTrue(hook.isRegistered(key.toId()));
        }
        // The actor coalition starts with no free tokens and earns no role fees/sweep tips in this harness.
        assertLe(stock.balanceOf(ALICE) + stock.balanceOf(BOB) + stock.balanceOf(MALLORY), 3000 * unit,
            "actor coalition cannot extract unbacked stock");
    }

    function _digest() private view returns (bytes32) {
        address[] memory who = _holders();
        bytes32 balances;
        for (uint256 i; i < who.length; ++i) {
            balances = keccak256(abi.encode(balances, stock.balanceOf(who[i]), token.balanceOf(who[i])));
        }
        bytes32 curveState = keccak256(abi.encode(curve.status(), curve.realStockReserve(), curve.tokenReserve(),
            curve.totalFees(), curve.claimable(protocol), curve.claimable(address(this)), curve.claimable(curve.treasury())));
        (uint160 price, int24 tick,,) = pm.getSlot0(key.toId());
        (uint256 pendingToken, uint256 pendingStock) = hook.accrued(key.toId());
        return keccak256(abi.encode(balances, curveState, token.totalSupply(), price, tick,
            pm.getLiquidity(key.toId()), pendingToken, pendingStock, hook.isRegistered(key.toId())));
    }

    function _curveBuy(address who, uint256 amount) private returns (uint256 received) {
        (uint256 quotedCost, uint256 quotedTokens, uint256 burned) = curve.quoteBuy(amount);
        if (quotedCost == 0 || quotedTokens == 0) return 0;
        uint256 beforeStock = stock.balanceOf(who);
        uint256 beforeToken = token.balanceOf(who);
        vm.recordLogs();
        vm.prank(who);
        (uint256 spent, uint256 out) = curve.buy(amount, quotedTokens, who, block.timestamp);
        received = out;
        expectedBurn += burned;
        assertEq(spent, quotedCost); assertEq(out, quotedTokens);
        assertEq(beforeStock - stock.balanceOf(who), spent);
        assertEq(token.balanceOf(who) - beforeToken, out);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] ==
                keccak256("Graduated(uint256,uint160,uint128,uint256,uint256,uint256)")) {
                (,,,, uint256 excessBurn) = abi.decode(logs[i].data, (uint160, uint128, uint256, uint256, uint256));
                expectedBurn += excessBurn;
            }
        }
        _assertConservation();
    }

    function _curveSell(address who, uint256 amount) private returns (uint256 received) {
        if (amount == 0) return 0;
        (uint256 quote, uint256 fee) = curve.quoteSell(amount);
        if (quote == 0) return 0;
        uint256 beforeStock = stock.balanceOf(who);
        uint256 beforeToken = token.balanceOf(who);
        uint256 beforeFees = curve.totalFees();
        vm.prank(who); received = curve.sell(amount, quote, who, block.timestamp);
        assertEq(received, quote); assertEq(stock.balanceOf(who) - beforeStock, quote);
        assertEq(beforeToken - token.balanceOf(who), amount);
        assertEq(curve.totalFees() - beforeFees, fee);
        _assertConservation();
    }

    function _v4Buy(address who, uint256 amount) private returns (uint256 received) {
        uint256 beforeToken = token.balanceOf(who);
        vm.prank(who); (received,) = router.buy(_params(amount, 2), _empty());
        assertEq(token.balanceOf(who) - beforeToken, received);
        _assertConservation();
    }

    function _v4Sell(address who, uint256 amount) private returns (uint256 received) {
        if (amount == 0) return 0;
        vm.prank(who); (received,) = router.sell(_params(amount, 2), _empty());
        _assertConservation();
    }

    function _claim(address caller, address recipient) private {
        uint256 owed = curve.claimable(recipient);
        uint256 beforeBalance = stock.balanceOf(recipient);
        vm.prank(caller); curve.claimFees(recipient);
        assertEq(stock.balanceOf(recipient) - beforeBalance, owed);
        assertEq(curve.claimable(recipient), 0);
        _assertConservation();
    }

    function _donate(address who, bool donateToken, bool toFactory, uint256 amount) private {
        address recipient = toFactory ? address(factory) : address(curve);
        if (donateToken) {
            amount = bound(amount, 0, token.balanceOf(who));
            vm.prank(who); token.transfer(recipient, amount);
            if (toFactory) tokenDonatedToFactory += amount; else tokenDonatedToCurve += amount;
        } else {
            amount = bound(amount, 0, stock.balanceOf(who));
            vm.prank(who); stock.transfer(recipient, amount);
            if (toFactory) stockDonatedToFactory += amount; else stockDonatedToCurve += amount;
        }
        _assertConservation();
    }

    function _sweep() private {
        (uint256 taxTokens,) = hook.accrued(key.toId());
        assertEq(taxTokens, 0, "a V2 pool takes every fee in stock");
        uint256 supplyBefore = token.totalSupply();
        hook.sweep(key.toId());
        assertEq(token.totalSupply(), supplyBefore, "a V2 sweep cannot burn the basic buy fee");
        _assertConservation();
    }

    function _collectLpFees() private {
        if (curve.status() != Curve.Status.Graduated) return;
        V2LiquidityVault vault = V2LiquidityVault(hook.liquidityVaultOf(key.toId()));
        uint128 liquidityBefore = pm.getLiquidity(key.toId());
        (, uint256 burned) = vault.collectFees();
        expectedBurn += burned;
        assertEq(pm.getLiquidity(key.toId()), liquidityBefore, "collect cannot withdraw LP principal");
        _assertConservation();
    }

    function _failedMinOut(address who, bool buy) private {
        bytes32 beforeState = _digest();
        vm.startPrank(who);
        if (curve.status() == Curve.Status.Active) {
            if (buy) {
                vm.expectRevert(Curve.Slippage.selector);
                curve.buy(unit, type(uint256).max, who, block.timestamp);
            } else if (token.balanceOf(who) != 0) {
                uint256 amount = token.balanceOf(who);
                vm.expectRevert(Curve.Slippage.selector);
                curve.sell(amount, type(uint256).max, who, block.timestamp);
            }
        } else {
            Router.TradeParams memory p = _params(buy ? unit : token.balanceOf(who), 2);
            p.minFinalOut = type(uint256).max;
            if (p.amountIn != 0) {
                vm.expectPartialRevert(Router.TooLittle.selector);
                if (buy) router.buy(p, _empty()); else router.sell(p, _empty());
            }
        }
        vm.stopPrank();
        assertEq(_digest(), beforeState, "failed min-out must roll back users, tax, price and all reserves");
    }

    /// Every fuzz case is a sequence of 48 adversarial actions, with forced atomic graduation halfway through.
    function testFuzz_threeActorSequencesConserveBeforeAndAfterGraduation(uint256 seed, bool tokenIs0, bool sixDecimals) public {
        _start(tokenIs0, sixDecimals);
        _curveBuy(ALICE, 10 * unit); _curveBuy(BOB, 5 * unit); _curveBuy(MALLORY, 3 * unit);
        for (uint256 i; i < 48; ++i) {
            if (i == 24) _curveBuy(actors[(seed >> 24) % 3], 1000 * unit);
            seed = uint256(keccak256(abi.encode(seed, i)));
            address who = actors[seed % 3];
            uint256 action = (seed >> 8) % 9;
            if (action == 0) {
                uint256 amount = bound(seed >> 32, unit / 1000, 2 * unit);
                if (curve.status() == Curve.Status.Active) _curveBuy(who, amount); else _v4Buy(who, amount);
            } else if (action == 1) {
                uint256 amount = token.balanceOf(who) / (2 + (seed >> 32) % 5);
                if (curve.status() == Curve.Status.Active) _curveSell(who, amount); else _v4Sell(who, amount);
            } else if (action == 2) {
                address[4] memory roles = [protocol, address(this), curve.treasury(), MALLORY];
                _claim(who, roles[(seed >> 32) % 4]);
            } else if (action == 3) {
                _donate(who, false, (seed >> 32) % 2 == 0, unit / 1000);
            } else if (action == 4) {
                _donate(who, true, (seed >> 32) % 2 == 0, token.balanceOf(who) / 1000);
            } else if (action == 5) {
                _failedMinOut(who, (seed >> 32) % 2 == 0);
            } else if (action == 6) {
                uint256 amount = token.balanceOf(who) / 7;
                vm.prank(who); token.transfer(actors[(seed >> 32) % 3], amount);
            } else if (action == 7 && curve.status() == Curve.Status.Graduated) {
                _sweep();
            } else if (action == 8 && curve.status() == Curve.Status.Graduated) {
                _collectLpFees();
            } else {
                bytes32 beforeState = _digest();
                vm.prank(who); vm.expectRevert(HedgeFunV2Factory.NotReady.selector); factory.graduate(id);
                assertEq(_digest(), beforeState);
            }
            _assertConservation();
        }
        _claim(MALLORY, protocol); _claim(MALLORY, address(this)); _claim(MALLORY, curve.treasury());
        _sweep();
        _collectLpFees();
        for (uint256 i; i < actors.length; ++i) _v4Sell(actors[i], token.balanceOf(actors[i]));
        _sweep();
        _collectLpFees();
        _assertConservation();
    }

    function testFuzz_sameBlockRoundTripCannotExtractStockWithoutAnExternalTrade(uint96 amount, bool tokenIs0, bool graduateFirst) public {
        _start(tokenIs0, false);
        if (graduateFirst) _curveBuy(ALICE, 1000 * unit);
        else { _curveBuy(ALICE, 10 * unit); _curveBuy(BOB, 15 * unit); }
        uint256 input = bound(uint256(amount), unit / 1000, 25 * unit);
        uint256 beforeStock = stock.balanceOf(MALLORY);
        uint256 bought = graduateFirst ? _v4Buy(MALLORY, input) : _curveBuy(MALLORY, input);
        if (graduateFirst) _v4Sell(MALLORY, bought); else _curveSell(MALLORY, bought);
        if (graduateFirst) _collectLpFees();
        assertLt(stock.balanceOf(MALLORY), beforeStock, "taxed self round trip cannot make stock");
        assertEq(token.balanceOf(MALLORY), 0);
        _assertConservation();
    }

    function _graduationRace(bool tokenIs0) private {
        _start(tokenIs0, false);
        _curveBuy(ALICE, 180 * unit);
        (, uint256 bobQuote,) = curve.quoteBuy(100 * unit);
        Router.TradeParams memory stale = _params(100 * unit, 0);
        stale.minFinalOut = bobQuote;
        _curveBuy(MALLORY, 100 * unit);
        assertEq(uint256(curve.status()), 2);
        bytes32 state = _digest();
        vm.prank(BOB); vm.expectRevert(abi.encodeWithSelector(Router.StageChanged.selector, 2));
        router.buy(stale, _empty());
        assertEq(_digest(), state);
        vm.prank(BOB); vm.expectRevert(Curve.Closed.selector); curve.buy(100 * unit, bobQuote, BOB, block.timestamp);
        assertEq(_digest(), state);
        uint256 mallorySpent = 1000 * unit - stock.balanceOf(MALLORY);
        uint256 malloryBefore = stock.balanceOf(MALLORY);
        _v4Sell(MALLORY, token.balanceOf(MALLORY));
        assertLt(stock.balanceOf(MALLORY) - malloryBefore, mallorySpent, "graduation itself is not a profitable price jump");
        _v4Buy(BOB, unit);
        _assertConservation();
    }

    function testGraduationRaceTokenCurrency0() public { _graduationRace(true); }
    function testGraduationRaceTokenCurrency1() public { _graduationRace(false); }

    function testAttackerCannotPreinitializeGraduationPoolOrReleaseAnotherUsersReserve() public {
        _start(true, false);
        _curveBuy(ALICE, 20 * unit);
        bytes32 state = _digest();
        vm.prank(MALLORY); vm.expectRevert(); pm.initialize(key, uint160(1 << 96));
        assertEq(_digest(), state, "pre-initialization attack must not reserve a wrong pool price");
        vm.prank(MALLORY); vm.expectRevert(Curve.NotFactory.selector); curve.release();
        vm.prank(MALLORY); vm.expectRevert(HedgeFunV2Factory.NotReady.selector); factory.graduateCurve();
        assertEq(_digest(), state);
        _curveBuy(BOB, 1000 * unit);
        _assertConservation();
    }

    function testTightVictimMinOutDefeatsCurveSandwichAndAttackerLosesUnwind() public {
        _start(true, false);
        (, uint256 aliceQuote,) = curve.quoteBuy(140 * unit);
        uint256 malloryStart = stock.balanceOf(MALLORY);
        uint256 attackTokens = _curveBuy(MALLORY, 20 * unit);
        bytes32 state = _digest();
        vm.prank(ALICE); vm.expectRevert(Curve.Slippage.selector);
        curve.buy(140 * unit, aliceQuote * 99 / 100, ALICE, block.timestamp);
        assertEq(_digest(), state);
        _curveSell(MALLORY, attackTokens);
        assertLt(stock.balanceOf(MALLORY), malloryStart);
        assertEq(stock.balanceOf(ALICE), 1000 * unit);
        _assertConservation();
    }

    /// This is expected price-discovery MEV: a victim explicitly accepting a very wide min-out can subsidize
    /// a profitable sandwich. The attacker does not steal fee liabilities, donations or unbacked reserves.
    function testPermissiveVictimSlippageAllowsEconomicMevButConservationHolds() public {
        _start(false, false);
        vm.warp(curve.launchedAt() + curve.snipeSeconds());
        (, uint256 cleanQuote,) = curve.quoteBuy(140 * unit);
        uint256 malloryStart = stock.balanceOf(MALLORY);
        uint256 attackTokens = _curveBuy(MALLORY, 20 * unit);
        uint256 victimTokens = _curveBuy(ALICE, 140 * unit);
        assertLt(victimTokens, cleanQuote, "front-run worsens victim price");
        _curveSell(MALLORY, attackTokens);
        assertGt(stock.balanceOf(MALLORY), malloryStart, "normal AMM sandwich under accepted loose slippage");
        _claim(MALLORY, MALLORY);
        _assertConservation();
    }

    function _failedGraduationWithMultipleOwners(bool tokenIs0) private {
        _start(tokenIs0, false);
        _curveBuy(ALICE, 15 * unit); _curveBuy(BOB, 20 * unit); _curveBuy(MALLORY, 10 * unit);
        _curveSell(BOB, token.balanceOf(BOB) / 3);
        _donate(ALICE, false, false, unit);
        _donate(BOB, true, false, token.balanceOf(BOB) / 100);
        _donate(MALLORY, false, true, unit);
        _donate(ALICE, true, true, token.balanceOf(ALICE) / 100);
        _claim(MALLORY, protocol);
        bytes32 state = _digest();
        stock.blockRecipient(address(pm));
        vm.prank(MALLORY); vm.expectRevert(bytes("blocked recipient"));
        curve.buy(1000 * unit, 1, MALLORY, block.timestamp);
        assertEq(_digest(), state, "failed graduation must undo final buy and all burns for every owner");
        assertEq(uint256(curve.status()), 0);
        _curveSell(ALICE, token.balanceOf(ALICE) / 2);
        _claim(MALLORY, curve.treasury());
        stock.blockRecipient(address(0));
        _curveBuy(BOB, 1000 * unit);
        _assertConservation();
    }

    function testRejectedGraduationPreservesAllActorsTokenCurrency0() public { _failedGraduationWithMultipleOwners(true); }
    function testRejectedGraduationPreservesAllActorsTokenCurrency1() public { _failedGraduationWithMultipleOwners(false); }
}
