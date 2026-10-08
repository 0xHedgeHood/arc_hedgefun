// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CurveDeployer} from "../src/v2/CurveDeployer.sol";
import {ArcCurveDeployer} from "../src/v2/arc/ArcCurveDeployer.sol";
import {CryptoCalendar} from "../src/CryptoCalendar.sol";
import {CryptoPriceOracle} from "../src/CryptoPriceOracle.sol";
import {ListArcCrypto} from "../script/arc/ListArcCrypto.s.sol";
import {MockFeed, MockToken} from "./mocks/Mocks.sol";

/// The Arc-only pieces, without a fork: the curve deployer's wider `sqrtPrice`, the crypto oracle and calendar, and the
/// listing's opening-price formula. The full path runs on an Arc fork in `ArcForkTest`.
contract ArcComponentsTest is Test {
    CurveDeployer private stock;
    ArcCurveDeployer private arc;

    function setUp() public {
        stock = new CurveDeployer(7931);
        arc = new ArcCurveDeployer(7931);
        vm.warp(1_790_000_000);
    }

    // ------------------------------------------------------------------------------------------- sqrtPrice
    /// Below a 2^64 ratio the Arc deployer answers exactly what the 4663 one does, in both token orders.
    function testFuzz_sqrtPriceMatchesCurveDeployerBelowTwoTo64(uint256 stockAmount, uint256 tokens, bool tokenIs0) public {
        stockAmount = bound(stockAmount, 1, type(uint128).max);
        tokens = bound(tokens, 1, type(uint128).max);
        (uint256 num, uint256 den) = tokenIs0 ? (stockAmount, tokens) : (tokens, stockAmount);
        vm.assume(num / den < 1 << 64);
        try stock.sqrtPrice(stockAmount, tokens, tokenIs0) returns (uint160 expected) {
            assertEq(arc.sqrtPrice(stockAmount, tokens, tokenIs0), expected);
        } catch (bytes memory reason) {
            vm.expectRevert(reason);
            arc.sqrtPrice(stockAmount, tokens, tokenIs0);
        }
    }

    /// At and above 2^64, where `CurveDeployer` overflows, the answer is sqrt(ratio) * 2^96 with its low 32 bits
    /// cleared: q = answer >> 32 is the integer root of ratio * 2^128, so q^2 <= ratio * 2^128 < (q + 1)^2.
    function testFuzz_sqrtPriceServesRatiosAboveTwoTo64(uint256 sats, uint256 tokens) public view {
        sats = bound(sats, 1, 1e12);                 // up to 10,000 BTC
        tokens = bound(tokens, sats << 64, type(uint128).max / 2);
        uint160 p = arc.sqrtPrice(sats, tokens, false);
        assertEq(uint256(p) & type(uint32).max, 0);
        uint256 q = uint256(p) >> 32;
        uint256 scaled = Math.mulDiv(tokens, 1 << 128, sats);
        assertLe(q * q, scaled);
        assertGt((q + 1) * (q + 1), scaled);
        assertLt(p, TickMath.MAX_SQRT_PRICE);
    }

    function test_sqrtPriceCirBtcOpeningWhereCurveDeployerOverflows() public {
        uint256 sats = 2_566_000;                   // ~$2,140 of cirBTC at $83,400
        uint256 supply = 1_000_000_000e18;
        vm.expectRevert();
        stock.sqrtPrice(sats, supply, false);
        uint160 p = arc.sqrtPrice(sats, supply, false);
        // sqrt(1e27 / 2,566,000) * 2^96 = 1.5641e39
        assertApproxEqRel(uint256(p), 1.5641e39, 1e14);
        assertEq(arc.sqrtPrice(sats, supply, true), stock.sqrtPrice(sats, supply, true), "token as currency0 was always fine");
    }

    // ------------------------------------------------------------------------------------------- the oracle
    function _oracle() private returns (CryptoPriceOracle o, CryptoCalendar c, MockFeed btc, MockFeed usdc) {
        MockToken cirBtc = new MockToken("cirBTC", 8);
        btc = new MockFeed(8); usdc = new MockFeed(8);
        btc.set(83_400e8); usdc.set(0.9998e8);
        c = new CryptoCalendar(address(this));
        o = new CryptoPriceOracle(address(cirBtc), address(btc), address(usdc), address(c), 25 hours, 25 hours);
    }

    function test_oraclePricesTheAssetInUsdcEveryDayOfTheWeek() public {
        (CryptoPriceOracle o,, MockFeed btc, MockFeed usdc) = _oracle();
        uint256 start = block.timestamp;
        for (uint256 d; d < 7; ++d) {
            vm.warp(start + d * 1 days);
            btc.set(83_400e8); usdc.set(0.9998e8);   // a print a day, as the 24h heartbeat guarantees
            (bool ok, uint256 p) = o.tryPrice();
            assertTrue(ok, "no weekend closure");
            assertEq(p, Math.mulDiv(83_400e8, 1e18 * 1e8, 0.9998e8 * 1e8));
            assertEq(o.calendar().tradingDate(block.timestamp), block.timestamp / 1 days);
            assertFalse(o.calendar().isScheduledClosure(block.timestamp));
        }
    }

    function test_oracleFailsClosedOnHaltStalenessAndBadRounds() public {
        (CryptoPriceOracle o, CryptoCalendar c, MockFeed btc, MockFeed usdc) = _oracle();
        c.setHalted(true);
        (bool ok,) = o.tryPrice(); assertFalse(ok, "halted");
        vm.expectRevert(CryptoPriceOracle.Unhealthy.selector); o.price();
        c.setHalted(false);
        btc.setAt(83_400e8, block.timestamp - 25 hours - 1);
        (ok,) = o.tryPrice(); assertFalse(ok, "asset leg older than 25 hours");
        btc.setAt(83_400e8, block.timestamp - 25 hours);
        (ok,) = o.tryPrice(); assertTrue(ok, "exactly 25 hours is still served");
        btc.setAt(83_400e8, block.timestamp + 1);
        (ok,) = o.tryPrice(); assertFalse(ok, "a round from the future");
        btc.set(0);
        (ok,) = o.tryPrice(); assertFalse(ok, "zero answer");
        btc.set(83_400e8); usdc.setAt(1e8, block.timestamp - 26 hours);
        (ok,) = o.tryPrice(); assertFalse(ok, "stale USDC leg");
        (bool last,,) = o.lastPriceAt(); assertFalse(last, "the dollar leg never gets to be stale");
    }

    function test_oracleRefusesAgesOverOneHeartbeatPlusGrace() public {
        MockToken t = new MockToken("cirBTC", 8);
        MockFeed f = new MockFeed(8);
        CryptoCalendar c = new CryptoCalendar(address(this));
        vm.expectRevert(bytes("age"));
        new CryptoPriceOracle(address(t), address(f), address(f), address(c), 26 hours + 1, 1 hours);
        vm.expectRevert(bytes("code"));
        new CryptoPriceOracle(address(0xdead), address(f), address(f), address(c), 1 hours, 1 hours);
    }

    function test_onlyTheOwnerHaltsTheCalendar() public {
        CryptoCalendar c = new CryptoCalendar(address(this));
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        c.setHalted(true);
        assertFalse(c.isClosed(block.timestamp));
    }

    // ------------------------------------------------------------------------------------------- the opening price
    /// $50,000 graduation FDV with 79.31% sold is $2,140.38 of opening FDV, whatever the asset's decimals: the
    /// virtual reserve the Arc factory derives from the listed price is worth that, in cirBTC and in WETH.
    function test_referenceOpeningIsTheSameDollarsForEightAndEighteenDecimals() public {
        ListArcCrypto l = new ListArcCrypto();
        uint256 scale = 1e36;   // HedgeFunV2ArcFactory.OPEN_PRICE_SCALE
        uint256 btcOpen = l.referenceOpenPrice(83_400e18, 8);
        uint256 btcVirtual = Math.mulDiv(btcOpen, 1_000_000_000e18, scale, Math.Rounding.Ceil);
        assertApproxEqRel(btcVirtual * 83_400e18 / 1e8, 2_140.38e18, 1e12);
        uint256 ethOpen = l.referenceOpenPrice(2_573e18, 18);
        uint256 ethVirtual = Math.mulDiv(ethOpen, 1_000_000_000e18, scale, Math.Rounding.Ceil);
        assertApproxEqRel(ethVirtual * 2_573e18 / 1e18, 2_140.38e18, 1e12);
        // what the 4663 factory's 1e18 scale would have listed for cirBTC: nothing
        assertEq(Math.mulDiv(btcVirtual, 1e18, 1_000_000_000e18), 0);
    }
}
