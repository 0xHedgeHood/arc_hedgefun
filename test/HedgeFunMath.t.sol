// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HedgeFunMath, BPS} from "../src/libraries/HedgeFunMath.sol";

/// Small-input comparisons preserve the mathematical rules; full-width references check mulDiv's larger domain.
/// The old uint16 take-profit addition overflow is an intentional exception to legacy execution behavior.
contract HedgeFunMathTest is Test {
    function testFuzz_bps_isTheWrittenOutExpression(uint128 x, uint16 rate) public pure {
        assertEq(HedgeFunMath.bps(x, rate), uint256(x) * rate / 1e4);
    }

    function testFuzz_reached_matchesTheMathematicalTakeProfitThreshold(uint128 p, uint128 cost, uint16 rate) public pure {
        // Widen intentionally: this is the mathematical threshold, not the old uint16 EVM expression.
        bool notDue = uint256(p) * 1e4 < uint256(cost) * (1e4 + uint256(rate));
        assertEq(HedgeFunMath.reached(p, cost, rate), !notDue);
    }

    function testFuzz_fellTo_isTheStopAndDipComparison(uint128 p, uint128 ref, uint16 rate) public pure {
        rate = uint16(bound(rate, 0, 9999));                                              // stopBps and dipBps are < 1e4 at birth
        bool notDue = uint256(p) * 1e4 > uint256(ref) * (1e4 - uint256(rate));
        assertEq(HedgeFunMath.fellTo(p, ref, rate), !notDue);
    }

    function testFuzz_exceeds_isTheDeviationGate(uint128 gap, uint128 ref, uint16 rate) public pure {
        assertEq(HedgeFunMath.exceeds(gap, ref, rate), uint256(gap) * 1e4 > uint256(ref) * rate);
    }

    function testFuzz_shift_isTheBuybackLimit(uint160 sqrtP, uint16 rate, bool zeroForOne) public pure {
        rate = uint16(bound(rate, 0, 9000));                                              // `drift` is capped at 9000, `half` at 500
        uint256 was = zeroForOne ? uint256(sqrtP) * (1e4 - rate) / 1e4 : uint256(sqrtP) * (1e4 + rate) / 1e4;
        assertEq(HedgeFunMath.shift(sqrtP, rate, !zeroForOne), was);
    }

    function test_theEdgesAreInclusive_exactlyAsBefore() public pure {
        assertTrue(HedgeFunMath.reached(110, 100, 1000));   assertFalse(HedgeFunMath.reached(109, 100, 1000));
        assertTrue(HedgeFunMath.fellTo(90, 100, 1000));     assertFalse(HedgeFunMath.fellTo(91, 100, 1000));
        assertFalse(HedgeFunMath.exceeds(1, 100, 100));     assertTrue(HedgeFunMath.exceeds(2, 100, 100));
        assertEq(BPS, 10_000);
    }

    function test_theHooksFourNamedFlagsAreTheLiteralItUsedToCheck() public pure {
        assertEq(Hooks.ALL_HOOK_MASK, 0x3FFF);
        assertEq(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG, 0x2844);
    }

    function test_theV2HookAddsTheTwoBeforeSwapFlags() public pure {
        assertEq(0x2844 | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG, 0x28CC);
    }

    function legacyReached(uint256 p, uint256 cost, uint16 rate) external pure returns (bool) {
        // Keep the uint16 intermediate exactly as it was before PR #44.
        return !(p * 1e4 < cost * (1e4 + rate));
    }

    function reached(uint256 p, uint256 cost, uint16 rate) external pure returns (bool) {
        return HedgeFunMath.reached(p, cost, rate);
    }

    function test_reached_fixesTheLegacyUint16Overflow() public {
        assertTrue(this.legacyReached(65535, 10000, 55535));
        assertTrue(HedgeFunMath.reached(65535, 10000, 55535));
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        this.legacyReached(65536, 10000, 55536);
        assertFalse(HedgeFunMath.reached(65535, 10000, 55536));
        assertTrue(HedgeFunMath.reached(65536, 10000, 55536));
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        this.legacyReached(75535, 10000, 65535);
        assertFalse(HedgeFunMath.reached(75534, 10000, 65535));
        assertTrue(HedgeFunMath.reached(75535, 10000, 65535));
    }

    // Independent references: no Math.mulDiv, and no overflowing intermediate multiplication.
    // Callers restrict x/rate so the final result (including rounding) fits uint256.
    function _floorRatio(uint256 x, uint256 rate) internal pure returns (uint256) {
        return (x / 10000) * rate + ((x % 10000) * rate) / 10000;
    }

    function _ceilRatio(uint256 x, uint256 rate) internal pure returns (uint256) {
        return _floorRatio(x, rate) + (((x % 10000) * rate) % 10000 == 0 ? 0 : 1);
    }

    function testFuzz_fullWidthBpsAndThresholds(uint256 x, uint256 y, uint16 r) public pure {
        uint256 rate = uint256(r) % 10001;
        assertEq(HedgeFunMath.bps(x, rate), _floorRatio(x, rate));
        assertEq(HedgeFunMath.fellTo(y, x, rate), y <= _floorRatio(x, 10000 - rate));
        assertEq(HedgeFunMath.exceeds(y, x, rate), y > _floorRatio(x, rate));
        assertEq(HedgeFunMath.short(y, x, rate), y < _ceilRatio(x, rate));
        assertEq(HedgeFunMath.shift(x, rate, false), _floorRatio(x, 10000 - rate));

        // Random y is often far from the threshold; also check its adjacent integers for every fuzz input.
        uint256 floor = _floorRatio(x, rate);
        assertFalse(HedgeFunMath.exceeds(floor, x, rate));
        if (floor < type(uint256).max) assertTrue(HedgeFunMath.exceeds(floor + 1, x, rate));
        uint256 ceil = _ceilRatio(x, rate);
        assertFalse(HedgeFunMath.short(ceil, x, rate));
        if (ceil != 0) assertTrue(HedgeFunMath.short(ceil - 1, x, rate));
        uint256 stop = _floorRatio(x, 10000 - rate);
        assertTrue(HedgeFunMath.fellTo(stop, x, rate));
        if (stop < type(uint256).max) assertFalse(HedgeFunMath.fellTo(stop + 1, x, rate));
    }

    function testFuzz_reachedFullRateAndWideCost(uint256 p, uint256 cost, uint16 rate) public pure {
        cost /= 8; // Even the largest uint16 rate keeps the rounded threshold representable.
        uint256 threshold = _ceilRatio(cost, 10000 + uint256(rate));
        assertEq(HedgeFunMath.reached(p, cost, rate), p >= threshold);
        assertTrue(HedgeFunMath.reached(threshold, cost, rate));
        if (threshold != 0) assertFalse(HedgeFunMath.reached(threshold - 1, cost, rate));
    }

    function testFuzz_upwardShiftWideValues(uint256 x, uint16 r) public pure {
        x /= 2;
        uint256 rate = uint256(r) % 9001;
        assertEq(HedgeFunMath.shift(x, rate, true), _floorRatio(x, 10000 + rate));
    }

    function test_nonDivisibleThresholds_preserveInclusiveAndStrictComparisons() public pure {
        assertFalse(HedgeFunMath.reached(1, 1, 1));
        assertTrue(HedgeFunMath.reached(2, 1, 1));
        assertFalse(HedgeFunMath.fellTo(1, 1, 1));
        assertTrue(HedgeFunMath.fellTo(0, 1, 1));
        assertTrue(HedgeFunMath.short(0, 1, 1));
        assertFalse(HedgeFunMath.short(1, 1, 1));
        assertFalse(HedgeFunMath.exceeds(0, 1, 1));
        assertTrue(HedgeFunMath.exceeds(1, 1, 1));
    }

    function test_fullWidthIntermediateProductsSucceed() public pure {
        uint256 m = type(uint256).max;
        assertEq(HedgeFunMath.bps(m, 10000), m);
        assertTrue(HedgeFunMath.fellTo(m, m, 0));
        assertFalse(HedgeFunMath.short(m, m, 10000));
        assertFalse(HedgeFunMath.exceeds(m, m, 10000));
        assertTrue(HedgeFunMath.reached(m, m, 0));
    }

    function test_finalThresholdOverflowStillReverts() public {
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        this.reached(type(uint256).max, type(uint256).max, 1);
    }
}
