// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {console2} from "forge-std/console2.sol";
import {HedgeFunBondingCurve as Curve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter as Router} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

/// @dev Four independent funded wallets; EVM transactions in one block are ordered, never simultaneous.
///      The fixture uses the production factory, curve and V4 PoolManager, and a mocked stock oracle/venue.
contract V2MarketBuyScenariosTest is V2FactoryFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address[4] private buyers = [address(0xB001), address(0xB002), address(0xB003), address(0xB004)];
    Curve private curve;
    IERC20 private token;
    Router private router;
    uint256 private id;
    PoolKey private key;

    struct Wave {
        uint256[4] outputByWallet;
        uint256 totalSpent;
        uint256 totalOut;
        uint256 totalBurned;
        uint256 endPrice;
        uint256 endReserve;
    }

    struct FinalBuyState {
        uint256 expectedSpent;
        uint256 expectedOut;
        uint256 lastBurn;
        uint256 stockBefore;
        uint256 tokenBefore;
        uint256 reserveBefore;
        uint256 supplyBefore;
    }

    struct Step {
        uint256 spent;
        uint256 out;
        uint256 burn;
        uint256 price;
    }

    function setUp() public {
        _setUpV2(18);
        (id, curve, key) = _launchV2(true);
        vm.warp(curve.launchedAt() + curve.snipeSeconds()); // ordinary trading after the opening window
        token = IERC20(curve.token());
        router = new Router(factory);
        for (uint256 i; i < buyers.length; ++i) {
            stock.mint(buyers[i], 1200 ether);
            vm.startPrank(buyers[i]);
            stock.approve(address(curve), type(uint256).max);
            stock.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _spot() private view returns (uint256) {
        return Math.mulDiv(curve.virtualStock() + curve.realStockReserve(), 1e18, curve.tokenReserve());
    }

    function _buyWaveStep(
        uint256 walletIndex,
        uint256 i,
        uint256 previousOutput,
        uint256 previousPrice,
        uint256 launchTime
    ) private returns (Step memory s) {
        address buyer = buyers[walletIndex];
        (s.spent, s.out, s.burn) = curve.quoteBuy(10 ether);
        uint256 stockBefore = stock.balanceOf(buyer);
        uint256 tokenBefore = token.balanceOf(buyer);
        vm.prank(buyer);
        (uint256 actualSpent, uint256 actualOut) = curve.buy(10 ether, s.out, buyer, launchTime);
        assertEq(actualSpent, s.spent, "quote/settlement spent");
        assertEq(actualOut, s.out, "quote/settlement output");
        assertEq(stockBefore - stock.balanceOf(buyer), s.spent, "wallet charged exactly once");
        assertEq(token.balanceOf(buyer) - tokenBefore, s.out, "wallet credited exactly once");
        assertLe(s.spent, 10 ether, "buy cannot exceed budget");
        assertLt(s.out, previousOutput, "later equal-budget buyer gets fewer tokens");
        s.price = _spot();
        assertGt(s.price, previousPrice, "buy raises spot price");
        assertEq(block.timestamp, launchTime, "all buys share a timestamp");
        console2.log("Scenario buy-wave step raw index spent out", i, s.spent, s.out);
        console2.log("Scenario buy-wave step raw walletIndex burn spot", walletIndex, s.burn, s.price);
    }

    function _wave(bool reverse) private returns (Wave memory result) {
        uint256 launchTime = block.timestamp;
        uint256 previousOutput = type(uint256).max;
        uint256 previousPrice = _spot();
        uint256 startSupply = token.totalSupply();
        for (uint256 i; i < buyers.length; ++i) {
            uint256 walletIndex = reverse ? buyers.length - 1 - i : i;
            Step memory s = _buyWaveStep(walletIndex, i, previousOutput, previousPrice, launchTime);
            result.outputByWallet[walletIndex] = s.out;
            result.totalSpent += s.spent;
            result.totalOut += s.out;
            result.totalBurned += s.burn;
            previousOutput = s.out;
            previousPrice = s.price;
        }
        result.endPrice = previousPrice;
        result.endReserve = curve.realStockReserve();
        assertEq(result.endReserve + curve.totalFees(), result.totalSpent, "gross payments fund principal and fees");
        assertEq(stock.balanceOf(address(curve)), result.totalSpent, "curve stock balance backs principal and fees");
        assertEq(startSupply - token.totalSupply(), result.totalBurned, "curve buy tax is burned");
        assertEq(
            curve.tokenReserve() + result.totalOut + result.totalBurned, curve.initialSupply(), "token conservation"
        );
        assertEq(uint256(curve.status()), uint256(Curve.Status.Active), "small wave does not graduate");
    }

    function testFourWalletBuyWaveOrderChangesWalletOutcomeNotAggregate() public {
        uint256 snapshot = vm.snapshotState();
        Wave memory forward = _wave(false);
        assertTrue(vm.revertToState(snapshot));
        Wave memory reverse = _wave(true);

        assertEq(forward.totalSpent, reverse.totalSpent, "same aggregate spend");
        assertEq(forward.totalOut, reverse.totalOut, "same aggregate output");
        assertEq(forward.totalBurned, reverse.totalBurned, "same aggregate burn");
        assertEq(forward.endReserve, reverse.endReserve, "same final reserve");
        assertEq(forward.endPrice, reverse.endPrice, "same terminal price");
        assertGt(forward.outputByWallet[0], reverse.outputByWallet[0], "first buyer advantage");
        assertLt(forward.outputByWallet[3], reverse.outputByWallet[3], "last buyer disadvantage");
        console2.log(
            "Scenario buy-wave order raw firstWalletAdvantage", forward.outputByWallet[0] - reverse.outputByWallet[0]
        );
        console2.log(
            "Scenario buy-wave order raw aggregateSpent aggregateBurn", forward.totalSpent, forward.totalBurned
        );
    }

    function _threeInitialBuys() private returns (uint256 cumulativeCurveBurn) {
        uint256 startSupply = token.totalSupply();
        for (uint256 i; i < 3; ++i) {
            (uint256 quoteSpent, uint256 quoteOut, uint256 burn) = curve.quoteBuy(10 ether);
            vm.prank(buyers[i]);
            (uint256 spent, uint256 out) = curve.buy(10 ether, quoteOut, buyers[i], block.timestamp);
            assertEq(spent, quoteSpent);
            assertEq(out, quoteOut);
            cumulativeCurveBurn += burn;
            console2.log("Scenario buy-wave pregraduation raw index spent out", i, spent, out);
        }
        assertEq(startSupply - token.totalSupply(), cumulativeCurveBurn, "pre-graduation taxes burned");
    }

    function _finalBuyerGraduates() private {
        address finalBuyer = buyers[3];
        uint256 budget = 1000 ether;
        FinalBuyState memory s;
        (s.expectedSpent, s.expectedOut, s.lastBurn) = curve.quoteBuy(budget);
        assertGt(s.expectedSpent, 0);
        assertLt(s.expectedSpent, budget, "oversized graduation order must be partial");
        Router.TradeParams memory p =
            Router.TradeParams(id, address(stock), budget, budget, 1, block.timestamp, 0, false);
        Router.Hop[] memory noPath = new Router.Hop[](0);
        s.stockBefore = stock.balanceOf(finalBuyer);
        s.tokenBefore = token.balanceOf(finalBuyer);
        s.reserveBefore = curve.realStockReserve();
        s.supplyBefore = token.totalSupply();
        vm.prank(finalBuyer);
        vm.expectPartialRevert(Router.PartialFill.selector);
        router.buy(p, noPath);
        assertEq(stock.balanceOf(finalBuyer), s.stockBefore, "rejected partial fill preserves wallet");
        assertEq(token.balanceOf(finalBuyer), s.tokenBefore, "rejected partial fill mints nothing");
        assertEq(curve.realStockReserve(), s.reserveBefore, "failed graduation rolls back curve");
        assertEq(uint256(curve.status()), uint256(Curve.Status.Active), "failed graduation rolls back V4 seed");

        p.allowPartialFill = true;
        vm.prank(finalBuyer);
        (uint256 received, uint256 refund) = router.buy(p, noPath);
        assertEq(received, s.expectedOut, "graduation buyer receives quoted tokens");
        assertEq(refund, budget - s.expectedSpent, "unused stock refunded exactly");
        assertEq(s.stockBefore - stock.balanceOf(finalBuyer), s.expectedSpent, "buyer only spends filled amount");
        assertEq(token.balanceOf(finalBuyer) - s.tokenBefore, received, "buyer receives exact output");
        assertEq(uint256(curve.status()), uint256(Curve.Status.Graduated));
        assertGt(pm.getLiquidity(key.toId()), 0, "graduation seeds real V4 liquidity");
        assertEq(stock.balanceOf(address(router)), 0, "router keeps no stock refund");
        assertEq(token.balanceOf(address(router)), 0, "router keeps no strategy tokens");
        assertEq(stock.allowance(address(router), address(curve)), 0, "router clears curve allowance");
        assertGe(s.supplyBefore - token.totalSupply(), s.lastBurn, "at least final curve tax is burned");
        console2.log("Scenario buy-wave graduation raw budget spent refund", budget, s.expectedSpent, refund);
        console2.log(
            "Scenario buy-wave graduation raw out curveTax lpLiquidity",
            received,
            s.lastBurn,
            pm.getLiquidity(key.toId())
        );
    }

    function testFourWalletBuyWaveGraduationRefundAndAtomicFailure() public {
        _threeInitialBuys();
        _finalBuyerGraduates();
    }
}
