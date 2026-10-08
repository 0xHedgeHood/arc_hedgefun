// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {V2OriginalSupplyParticipationForkTest} from "./V2OriginalSupplyParticipationFork.t.sol";

/// Fixed 40,000 test USDG total, 32 buyers, isolated initial-state V3 funding.
contract V2Budget32ForkTest is V2OriginalSupplyParticipationForkTest {
    uint256 constant TOTAL_BUDGET = 40_000e6;

    function _measure() internal override returns (Measurement memory m) {
        if (uint256(curve.status()) == 2) return super._measure();
        assertEq(uint256(curve.status()), 0, "remaining curve must be active");
        m.spend = spent;
        m.supply = token.totalSupply();
        m.held = _held();
        assertEq(token.balanceOf(address(curve)), curve.tokenReserve());
        assertEq(m.supply, m.held + curve.tokenReserve(), "curve inventory and buyers conserve supply");
        // Constant-product marginal price y/x, including virtual stock, before graduation.
        uint256 stockFdv = Math.mulDiv(m.supply, curve.virtualStock() + curve.realStockReserve(), curve.tokenReserve());
        m.fdv = Math.mulDiv(stockFdv, stockPrice, 1e18);
    }

    function _stockForBudget() private returns (uint256 stockAmount) {
        uint256 available = TOTAL_BUDGET - launchFee;
        uint256 lo;
        uint256 hi = available * 1e30 / stockPrice + 1e18;
        assertGt(_fundingCost(hi), available, "upper stock budget must exceed USDG limit");
        while (hi - lo > 1e10) {
            uint256 mid = (lo + hi) / 2;
            if (_fundingCost(mid) <= available) lo = mid;
            else hi = mid;
        }
        return lo;
    }

    function _budgetRow(string memory name, uint16 sale, bool exemptions, bool wait, bool cycle) private {
        onePercentRule = cycle;
        if (cycle) {
            address owner = FACTORY.owner();
            vm.prank(owner);
            FACTORY.setListingGates(address(STOCK), 5, 10, 0);
        }
        _launch(sale, exemptions ? 32 : 0, 300);
        treasury = HedgeFunV2Treasury(curve.treasury());
        uint256 stockBudget = _stockForBudget();
        if (wait) vm.warp(block.timestamp + curve.snipeSeconds());
        uint256 cap = curve.terminalStock() - curve.virtualStock();
        uint256 toCurve = stockBudget < cap ? stockBudget : cap;
        for (uint256 i; i < 32; ++i) {
            uint256 offered = i == 31 ? toCurve - spent : toCurve / 32;
            (uint256 canonical,,) = curve.quoteBuyFor(offered, _wallet(i));
            _buy(i, canonical, 0);
        }
        uint256 curveInput = spent;
        if (cycle) {
            assertEq(uint256(curve.status()), 2, "strategy requires graduation");
            _cycle();
        }
        if (uint256(curve.status()) == 2 && stockBudget > spent) _buy(0, stockBudget - spent, 2);
        Measurement memory m = _measure();
        uint256 actualUsd = _fundingCost(spent) + launchFee;
        assertLe(actualUsd, TOTAL_BUDGET);
        assertLt(TOTAL_BUDGET - actualUsd, 100, "budget remainder below0.0001 test USDG");
        for (uint256 i = 32; i < N; ++i) {
            assertEq(token.balanceOf(_wallet(i)), 0, "only32 wallets hold tokens");
        }
        vm.serializeString(name, "scenario", name);
        vm.serializeUint(name, "forkBlock", forkBlock);
        vm.serializeUint(name, "forkTimestamp", forkTimestamp);
        vm.serializeBytes32(name, "forkParentHash", forkHash);
        vm.serializeUint(name, "buyerCount", 32);
        vm.serializeUint(name, "saleBps", sale);
        vm.serializeUint(name, "openingExemptions", exemptions ? 32 : 0);
        vm.serializeBool(name, "waited180Seconds", wait);
        vm.serializeUint(name, "cycles", cycle ? 1 : 0);
        vm.serializeUint(name, "totalBudgetUsdgRaw", TOTAL_BUDGET);
        vm.serializeUint(name, "actualUsdgRaw", actualUsd);
        vm.serializeUint(name, "launchFeeUsdgRaw", launchFee);
        vm.serializeUint(name, "stockBudgetRaw", stockBudget);
        vm.serializeUint(name, "stockSpentRaw", spent);
        vm.serializeUint(name, "curveCapStockRaw", cap);
        vm.serializeUint(name, "curveInputStockRaw", curveInput);
        vm.serializeUint(name, "curveCurrentStockReserveRaw", curve.realStockReserve());
        vm.serializeUint(name, "curveStatus", uint256(curve.status()));
        vm.serializeUint(name, "heldRaw", m.held);
        vm.serializeUint(name, "initialSupplyRaw", initialSupply);
        vm.serializeUint(name, "survivingSupplyRaw", m.supply);
        vm.serializeBool(name, "original80Reached", m.held * 100 >= initialSupply * 80);
        vm.serializeUint(name, "fdvSurvivingE18", m.fdv);
        vm.serializeUint(name, "fdvOriginalE18", Math.mulDiv(m.fdv, initialSupply, m.supply));
        vm.serializeUint(name, "strategyBurnedRaw", strategyBurned);
        string memory json = vm.serializeUint(name, "finalStockPriceE18", stockPrice);
        console2.log("BUDGET32_RESULT", json);
    }

    function testBudget32_Default44Opening() public {
        _budgetRow("default44_opening32_budget40k", 4400, true, false, false);
    }

    function testBudget32_Sale80Opening() public {
        _budgetRow("sale80_opening32_budget40k", 8000, true, false, false);
    }

    function testBudget32_Sale80OpeningCycle() public {
        _budgetRow("sale80_opening32_cycle1_budget40k", 8000, true, false, true);
    }

    function testBudget32_Sale80AfterWindow() public {
        _budgetRow("sale80_afterwindow_budget40k", 8000, false, true, false);
    }

    function testBudget32_Sale80NoExemptions() public {
        _budgetRow("sale80_noexempt_opening_budget40k", 8000, false, false, false);
    }

    function testBudget32_Sale90Opening() public {
        _budgetRow("sale90_opening32_budget40k", 9000, true, false, false);
    }

    function _targetRow(string memory name, uint256 buyers, bool cycle, uint256 goal) private {
        onePercentRule = cycle;
        if (cycle) {
            address owner = FACTORY.owner();
            vm.prank(owner);
            FACTORY.setListingGates(address(STOCK), 5, 10, 0);
        }
        _launch(4400, buyers, 300);
        treasury = HedgeFunV2Treasury(curve.treasury());
        uint256 cap = curve.terminalStock() - curve.virtualStock();
        for (uint256 i; i < buyers; ++i) {
            uint256 offered = i + 1 == buyers ? cap - spent : cap / buyers;
            (uint256 canonical,,) = curve.quoteBuyFor(offered, _wallet(i));
            _buy(i, canonical, 0);
        }
        assertEq(uint256(curve.status()), 2);
        if (cycle) _cycle();
        Measurement memory m = _reachOriginal(false, goal);
        assertGe(m.fdv, goal);
        assertLt(m.fdv - goal, 1e15, "tight target below0.001 test USDG");
        for (uint256 i = buyers; i < N; ++i) {
            assertEq(token.balanceOf(_wallet(i)), 0);
        }
        vm.serializeString(name, "scenario", name);
        vm.serializeUint(name, "forkBlock", forkBlock);
        vm.serializeUint(name, "forkTimestamp", forkTimestamp);
        vm.serializeBytes32(name, "forkParentHash", forkHash);
        vm.serializeUint(name, "buyerCount", buyers);
        vm.serializeUint(name, "openingExemptions", buyers);
        vm.serializeUint(name, "saleBps", 4400);
        vm.serializeUint(name, "cycles", cycle ? 1 : 0);
        vm.serializeUint(name, "targetFdvE18", goal);
        vm.serializeUint(name, "actualFdvE18", m.fdv);
        vm.serializeUint(name, "heldRaw", m.held);
        vm.serializeUint(name, "initialSupplyRaw", initialSupply);
        vm.serializeUint(name, "survivingSupplyRaw", m.supply);
        vm.serializeUint(name, "stockSpentRaw", spent);
        vm.serializeUint(name, "launchFeeUsdgRaw", launchFee);
        vm.serializeUint(name, "strategyBurnedRaw", strategyBurned);
        vm.serializeUint(name, "finalStockPriceE18", stockPrice);
        string memory json = vm.serializeUint(name, "actualUsdgRaw", _fundingCost(spent) + launchFee);
        console2.log("WALLET_TARGET_RESULT", json);
    }

    function testWalletTargets_OneBuyer1m() public {
        _targetRow("default44_wallet1_fdv1m", 1, false, 1_000_000e18);
    }

    function testWalletTargets_OneBuyer2m() public {
        _targetRow("default44_wallet1_fdv2m", 1, false, 2_000_000e18);
    }

    function testWalletTargets_32Buyers1m() public {
        _targetRow("default44_wallet32_fdv1m", 32, false, 1_000_000e18);
    }

    function testWalletTargets_32Buyers2m() public {
        _targetRow("default44_wallet32_fdv2m", 32, false, 2_000_000e18);
    }

    function testWalletTargets_32BuyersCycle1m() public {
        _targetRow("default44_wallet32_cycle1_fdv1m", 32, true, 1_000_000e18);
    }

    function testWalletTargets_32BuyersCycle2m() public {
        _targetRow("default44_wallet32_cycle1_fdv2m", 32, true, 2_000_000e18);
    }
}
