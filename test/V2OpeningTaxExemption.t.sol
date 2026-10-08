// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunBondingCurve as Curve} from "../src/v2/HedgeFunBondingCurve.sol";
import {CurveDeployer} from "../src/v2/CurveDeployer.sol";
import {HedgeFunHook} from "../src/hooks/HedgeFunHook.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

contract V2OpeningTaxExemptionTest is V2FactoryFixture {
    using PoolIdLibrary for PoolKey;

    address internal constant WHITELISTED = address(0xBEEF);
    address internal constant OTHER = address(0xCAFE);
    address internal constant STRANGER = address(0xBAD);

    function setUp() public {
        _setUpV2(18);
        creatorSnipeSeconds = 60;
    }

    function _requestForLaunch() private view returns (HedgeFunFactory.Request memory q) {
        q = _request();
        while (factory.predictToken(q) >= address(stock)) q.nonce++;
    }

    function _list(address who) private pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = who;
    }

    function _launch(address[] memory list)
        private returns (HedgeFunFactory.Request memory q, Curve curve, PoolKey memory key)
    {
        q = _requestForLaunch();
        CurveDeployer registry = factory.curveDeployer();
        registry.setCurveConfig(q.symbol, q.nonce, 8000, 60);
        registry.setOpeningTaxExemptions(q.symbol, q.nonce, list);
        address predicted = factory.predictCurve(q);
        (,, bytes32 terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        curve = Curve(factory.curves(id));
        assertEq(address(curve), predicted);
        (key,) = factory.graduationConfig(id);
        stock.approve(address(curve), type(uint256).max);
    }

    function testWhitelistIsCreatorScopedValidatedAndFrozenAtLaunch() public {
        CurveDeployer registry = factory.curveDeployer();
        HedgeFunFactory.Request memory q = _requestForLaunch();
        bytes32 salt = keccak256(abi.encode(q.symbol, q.creator, q.nonce));
        address[] memory list = new address[](41);
        for (uint256 i; i < list.length; ++i) list[i] = address(uint160(i + 1));
        vm.expectRevert(CurveDeployer.BadOpeningTaxExemptions.selector);
        registry.setOpeningTaxExemptions(q.symbol, q.nonce, list);
        list = new address[](2);
        list[0] = WHITELISTED;
        list[1] = WHITELISTED;
        vm.expectRevert(CurveDeployer.BadOpeningTaxExemptions.selector);
        registry.setOpeningTaxExemptions(q.symbol, q.nonce, list);
        list[1] = address(0);
        vm.expectRevert(CurveDeployer.BadOpeningTaxExemptions.selector);
        registry.setOpeningTaxExemptions(q.symbol, q.nonce, list);
        list[1] = q.creator;
        vm.expectRevert(CurveDeployer.BadOpeningTaxExemptions.selector);
        registry.setOpeningTaxExemptions(q.symbol, q.nonce, list);

        registry.setCurveConfig(q.symbol, q.nonce, 8000, 60);
        address originalPrediction = factory.predictCurve(q);
        (,, bytes32 originalTerms) = factory.predict(q);
        registry.setOpeningTaxExemptions(q.symbol, q.nonce, _list(WHITELISTED));
        address newPrediction = factory.predictCurve(q);
        (,, bytes32 newTerms) = factory.predict(q);
        assertTrue(originalPrediction != newPrediction);
        assertTrue(originalTerms != newTerms);
        vm.prank(STRANGER);
        registry.setOpeningTaxExemptions(q.symbol, q.nonce, _list(OTHER));
        assertEq(registry.openingTaxExemptions(salt), _list(WHITELISTED));
        assertEq(factory.predictCurve(q), newPrediction);
        vm.expectRevert(HedgeFunFactory.Restated.selector);
        factory.launch(q, originalTerms);
        uint256 id = factory.launch(q, newTerms);
        Curve curve = Curve(factory.curves(id));
        assertEq(address(curve), newPrediction);
        assertEq(curve.openingTaxExemptions(0), WHITELISTED);
        assertTrue(curve.isOpeningTaxExempt(WHITELISTED));
        assertTrue(curve.isOpeningTaxExempt(q.creator));
        assertFalse(curve.isOpeningTaxExempt(OTHER));
        registry.setOpeningTaxExemptions(q.symbol, q.nonce, _list(OTHER));
        assertTrue(curve.isOpeningTaxExempt(WHITELISTED));
        assertFalse(curve.isOpeningTaxExempt(OTHER));
    }

    function testWhitelistedRecipientPaysOnlyFlatTaxAndQuoteMatchesExecution() public {
        (, Curve curve,) = _launch(_list(WHITELISTED));
        HedgeFunToken token = HedgeFunToken(curve.token());
        uint256 budget = 10 ether;
        assertEq(curve.buyRateBps(), 9900);
        assertEq(curve.buyRateBpsFor(WHITELISTED), 1000);
        assertEq(curve.buyRateBpsFor(curve.creator()), 1000);
        assertEq(curve.buyRateBpsFor(OTHER), 9900);
        (uint256 spent, uint256 out, uint256 burned) = curve.quoteBuyFor(budget, WHITELISTED);
        (, uint256 normalOut, uint256 normalBurn) = curve.quoteBuyFor(budget, OTHER);
        assertGt(out, normalOut);
        assertLt(burned, normalBurn);
        assertEq(burned, 0, "exemption removes the extra burn, base fee remains in stock");
        stock.mint(WHITELISTED, budget);
        vm.startPrank(WHITELISTED);
        stock.approve(address(curve), budget);
        vm.stopPrank();
        uint256 supplyBefore = token.totalSupply();
        vm.prank(WHITELISTED);
        (uint256 actualSpent, uint256 actualOut) = curve.buy(budget, out, WHITELISTED, block.timestamp);
        assertEq(actualSpent, spent);
        assertEq(actualOut, out);
        assertEq(token.balanceOf(WHITELISTED), out);
        assertEq(supplyBefore - token.totalSupply(), burned);
        assertEq(curve.tokenReserve() + out + burned, curve.initialSupply());
        assertEq(curve.realStockReserve(), spent - spent * 1000 / 10_000);
        assertEq(curve.totalFees(), spent * 1000 / 10_000);

        (spent, out, burned) = curve.quoteBuyFor(budget, OTHER);
        stock.mint(OTHER, budget);
        vm.prank(OTHER); stock.approve(address(curve), budget);
        supplyBefore = token.totalSupply();
        vm.prank(OTHER); (actualSpent, actualOut) = curve.buy(budget, out, OTHER, block.timestamp);
        assertEq(actualSpent, spent);
        assertEq(actualOut, out);
        assertEq(supplyBefore - token.totalSupply(), burned);
        assertEq(burned, (out + burned) * (9900 - 1000) / (10_000 - 1000));
    }

    function testExactlyFortyAdditionalRecipientsCanLaunch() public {
        address[] memory list = new address[](40);
        for (uint256 i; i < list.length; ++i) list[i] = address(uint160(i + 1));
        (, Curve curve,) = _launch(list);
        assertEq(curve.openingTaxExemptions(39), list[39]);
        assertTrue(curve.isOpeningTaxExempt(list[0]));
        assertTrue(curve.isOpeningTaxExempt(list[39]));
        assertTrue(curve.isOpeningTaxExempt(curve.creator()));
        assertFalse(curve.isOpeningTaxExempt(STRANGER));
    }

    function testExemptionExpiresAtWindowAndDoesNotCarryIntoV4() public {
        (, Curve curve, PoolKey memory key) = _launch(_list(WHITELISTED));
        vm.warp(curve.launchedAt() + 59);
        assertGt(curve.buyRateBpsFor(OTHER), curve.buyRateBpsFor(WHITELISTED));
        vm.warp(curve.launchedAt() + 60);
        assertEq(curve.buyRateBpsFor(OTHER), 1000);
        assertEq(curve.buyRateBpsFor(WHITELISTED), 1000);
        (, uint256 exemptOut, uint256 exemptBurn) = curve.quoteBuyFor(10 ether, WHITELISTED);
        (, uint256 regularOut, uint256 regularBurn) = curve.quoteBuyFor(10 ether, OTHER);
        assertEq(exemptOut, regularOut);
        assertEq(exemptBurn, regularBurn);
        curve.buy(type(uint256).max, 1, address(this), block.timestamp);
        assertEq(uint256(curve.status()), uint256(Curve.Status.Graduated));
        vm.expectRevert(Curve.Closed.selector);
        curve.quoteBuyFor(10 ether, WHITELISTED);
        HedgeFunHook.Rates memory rates = hook.rates(key.toId());
        assertEq(rates.snipeBps, 0);
        assertEq(rates.snipeSeconds, 0);
        assertEq(hook.buyRateBps(key.toId()), curve.taxBps());
    }
}
