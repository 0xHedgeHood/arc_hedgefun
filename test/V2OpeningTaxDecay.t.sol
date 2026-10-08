// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";
import {HedgeFunBondingCurve as Curve} from "../src/v2/HedgeFunBondingCurve.sol";
import {MockToken} from "./mocks/Mocks.sol";

/// The curve's opening buy tax falls linearly from `snipeBps` to the flat `taxBps` over the whole `snipeSeconds`,
/// rounded up. It used to fall to ZERO and floor at the tax, which ended the window at
/// `snipeSeconds * (1 - taxBps / snipeBps)`: at 9900 / 60 s / 1000 the rate was already the flat 10% from second 54.
/// The deployed V1 hook keeps that old formula; these tests are about the V2 curve only.
contract V2OpeningTaxDecayTest is Test {
    uint256 internal constant SUPPLY = 1_000_000e18;
    MockToken internal stock;
    address internal protocol = address(uint160(uint256(keccak256("opening tax protocol"))));
    address internal creator = address(uint160(uint256(keccak256("opening tax creator"))));
    address internal treasury = address(uint160(uint256(keccak256("opening tax treasury"))));
    address internal buyer = address(uint160(uint256(keccak256("opening tax buyer"))));

    function setUp() public {
        vm.warp(1_700_000_000);
        stock = new MockToken("STOCK", 18);
        stock.mint(address(this), 1_000_000e18);
    }

    /// The reporter's table. Every value inside the window is strictly above the 10% flat tax.
    function test_sixtySecondWindowLastsSixtySeconds() public {
        Curve c = _curve(9900, 60, 1000);
        assertEq(_rateAt(c, 0), 9900);
        assertEq(_rateAt(c, 30), 5450); // 1000 + 8900 * 30 / 60, exact
        assertEq(_rateAt(c, 53), 2039); // 1000 + ceil(62,300 / 60 = 1038.33)
        assertEq(_rateAt(c, 54), 1890); // 1000 + 53,400 / 60, exact; the old formula already read the flat 1000 here
        assertEq(_rateAt(c, 59), 1149); // 1000 + ceil(8,900 / 60 = 148.33)
        assertEq(_rateAt(c, 60), 1000);
        assertEq(_rateAt(c, 61), 1000);
        assertEq(_rateAt(c, 10_000 days), 1000);
    }

    /// The shipped defaults: 9900 over 3 seconds, here with a 10% tax (was 9900 / 6600 / 3300 / 1000), and with the
    /// factory's 15% maximum tax (was 9900 / 6600 / 3300 / 1500).
    function test_shippedThreeSecondSchedule() public {
        Curve c = _curve(9900, 3, 1000);
        assertEq(_rateAt(c, 0), 9900);
        assertEq(_rateAt(c, 1), 6934); // 1000 + ceil(8900 * 2 / 3 = 5933.33)
        assertEq(_rateAt(c, 2), 3967); // 1000 + ceil(8900 / 3 = 2966.67)
        assertEq(_rateAt(c, 3), 1000);

        c = _curve(9900, 3, 1500);
        assertEq(_rateAt(c, 0), 9900);
        assertEq(_rateAt(c, 1), 7100); // 1500 + 8400 * 2 / 3, exact
        assertEq(_rateAt(c, 2), 4300); // 1500 + 8400 / 3, exact
        assertEq(_rateAt(c, 3), 1500);
    }

    /// `snipeBps` 0 is the legitimate "off" setting; at or below the tax the window has nothing to add. Neither may
    /// underflow: that would revert every buy for the whole window.
    function test_openingRateAtOrBelowTheTaxIsTheFlatTaxAndBuysSucceed() public {
        uint16[4] memory tops = [uint16(0), 1, 500, 1000];
        for (uint256 i; i < tops.length; ++i) {
            Curve c = _curve(tops[i], 60, 1000);
            uint256[5] memory at = [uint256(0), 1, 30, 59, 60];
            for (uint256 j; j < at.length; ++j) assertEq(_rateAt(c, at[j]), 1000);
            _assertBuyBurnsWhatWasQuoted(c, 0, 1e18, 1000);
        }
        Curve untaxed = _curve(0, 60, 0);
        assertEq(_rateAt(untaxed, 0), 0);
        _assertBuyBurnsWhatWasQuoted(untaxed, 0, 1e18, 0);
    }

    /// Over the curve's whole reachable range (its constructor admits any tax below 100% and an opening rate up to
    /// 99%; the factory narrows the tax to at most 15%).
    function testFuzz_openingRateStaysAboveTheTaxUntilTheWindowEnds(
        uint16 taxBps,
        uint16 snipeBps,
        uint8 secs,
        uint256 lateBy
    ) public {
        taxBps = uint16(bound(taxBps, 0, 9899));
        snipeBps = uint16(bound(snipeBps, uint256(taxBps) + 1, 9900));
        secs = uint8(bound(secs, 1, 255));
        Curve c = _curve(snipeBps, secs, taxBps);
        uint256 previous = type(uint256).max;
        for (uint256 e; e < secs; ++e) {
            uint256 rate = _rateAt(c, e);
            assertGt(rate, taxBps, "inside the window the rate is above the flat tax");
            assertLe(rate, snipeBps, "never above the opening rate");
            assertLe(rate, previous, "non-increasing");
            assertEq(rate, taxBps + Math.ceilDiv((uint256(snipeBps) - taxBps) * (secs - e), secs), "linear, rounded up");
            previous = rate;
        }
        assertEq(_rateAt(c, 0), snipeBps);
        assertEq(_rateAt(c, secs), taxBps);
        assertEq(_rateAt(c, uint256(secs) + bound(lateBy, 0, 3650 days)), taxBps);
    }

    /// `quoteBuy` and the executed buy read the same rate: the burn is exactly what was quoted, anywhere in or after
    /// the window.
    function testFuzz_quoteBuyAgreesWithTheExecutedBuysBurn(uint16 taxBps, uint8 secs, uint256 elapsed, uint256 amount)
        public
    {
        taxBps = uint16(bound(taxBps, 0, 1500));
        secs = uint8(bound(secs, 1, 255));
        elapsed = bound(elapsed, 0, uint256(secs) + 5);
        amount = bound(amount, 1e12, 100e18);
        Curve c = _curve(9900, secs, taxBps);
        uint256 expectedRate = elapsed >= secs ? taxBps : taxBps + Math.ceilDiv((9900 - uint256(taxBps)) * (secs - elapsed), secs);
        _assertBuyBurnsWhatWasQuoted(c, elapsed, amount, expectedRate);
    }

    function _assertBuyBurnsWhatWasQuoted(Curve c, uint256 elapsed, uint256 amount, uint256 expectedRate) private {
        vm.warp(uint256(c.launchedAt()) + elapsed);
        assertEq(c.buyRateBps(), expectedRate);
        (uint256 spent, uint256 out, uint256 taxTokens) = c.quoteBuy(amount);
        assertEq(taxTokens, Math.mulDiv(out + taxTokens, expectedRate - c.taxBps(), 10000 - c.taxBps()),
            "quote burns only the normalized opening excess");
        HedgeFunToken token = HedgeFunToken(c.token());
        uint256 supplyBefore = token.totalSupply();
        uint256 buyerBefore = token.balanceOf(buyer);
        _expectBuyFee(c, spent);
        vm.expectEmit(true, true, false, true, address(c));
        emit Curve.Bought(address(this), buyer, spent, out, taxTokens);
        (uint256 actualSpent, uint256 actualOut) = c.buy(amount, out, buyer, block.timestamp);
        assertEq(actualSpent, spent);
        assertEq(actualOut, out);
        assertEq(supplyBefore - token.totalSupply(), taxTokens, "burned exactly what was quoted");
        assertEq(token.balanceOf(buyer) - buyerBefore, out);
        assertEq(c.realStockReserve(), spent - Math.mulDiv(spent, c.taxBps(), 10000));
        assertEq(c.totalFees(), Math.mulDiv(spent, c.taxBps(), 10000));
    }

    function _expectBuyFee(Curve c, uint256 spent) private {
        uint256 fee = Math.mulDiv(spent, c.taxBps(), 10000);
        vm.expectEmit(true, false, false, true, address(c));
        emit Curve.TradeFeesAccrued(true, fee, fee * 2000 / 10000, fee * 1000 / 10000,
            fee - fee * 2000 / 10000 - fee * 1000 / 10000);
    }

    function _curve(uint16 snipeBps, uint8 secs, uint16 taxBps) private returns (Curve c) {
        HedgeFunToken token = new HedgeFunToken("Meme", "MEME", SUPPLY, address(this), creator);
        c = new Curve(Curve.Init(address(this), address(token), address(stock), treasury, protocol, creator,
            SUPPLY, 100e18, 8000, taxBps, 2000, 1000, snipeBps, secs, new address[](0)));
        token.transfer(address(c), SUPPLY);
        stock.approve(address(c), type(uint256).max);
    }

    function _rateAt(Curve c, uint256 elapsed) private returns (uint256) {
        vm.warp(uint256(c.launchedAt()) + elapsed);
        return c.buyRateBps();
    }
}
