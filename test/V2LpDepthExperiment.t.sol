// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {HedgeFunBondingCurve as Curve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter as Router} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {V2LiquidityVault} from "../src/v2/V2LiquidityVault.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

/// What `lab/model.py` leaves out, measured on the production contracts: the LP fee and hook
/// tax that flow back to the treasury, and the early buyer's exit. One wallet buys the FIRST 5% of the curve sale
/// (the cheapest tokens), a second wallet buys the rest and graduates the curve, and the first wallet sells
/// everything into the fresh V4 pool. Numbers are logged, not asserted: this is a measurement, not a guard.
/// See docs/V2_LP_DEPTH_EXPERIMENT.md for the recorded results.
contract V2LpDepthExperimentTest is V2FactoryFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address private constant EARLY = address(0xEA51);
    address private constant REST = address(0x5E57);
    uint256 private constant EARLY_SHARE_BPS = 500;

    struct Run {
        uint16 saleBps;
        uint16 lpBps;
        uint256 raised;
        uint256 earlyCost;
        uint256 earlyTokens;
        uint160 gradPrice;
        uint256 lpStock;
        uint256 treasuryStock;
    }

    function setUp() public { _setUpV2(18); }

    function test_t0DumpAcrossLpAndSaleShares() public {
        uint16[4] memory sale = [uint16(8000), 8000, 7000, 7000];
        uint16[4] memory lp = [uint16(5000), 7500, 5000, 7500];
        for (uint256 i; i < 4; ++i) {
            uint256 snap = vm.snapshotState();
            Run memory r = _graduateWithEarlyBuyer(sale[i], lp[i]);
            (uint256 out, uint256 tax, uint256 lpFee, uint160 after_) = _dump(r, 0);
            _log("t+0 dump", r, out, tax, lpFee, after_);
            vm.revertToState(snap);
        }
    }

    function test_buybackNoticeLeavesV2SellTaxFlat() public {
        uint16[3] memory delay = [uint16(0), 60, 119];
        for (uint256 i; i < 3; ++i) {
            uint256 snap = vm.snapshotState();
            Run memory r = _graduateWithEarlyBuyer(8000, 5000);
            (, address treasury,,,) = factory.strategies(0);
            vm.prank(treasury);
            hook.noteEvent(); // a treasury buyback cannot raise V2's frozen flat sell tax
            (, PoolKey memory key) = _key();
            assertEq(hook.sellRateBps(key.toId()), 1000);
            (uint256 out, uint256 tax, uint256 lpFee, uint160 after_) = _dump(r, delay[i]);
            _log(string.concat("notice+", vm.toString(uint256(delay[i])), "s dump"), r, out, tax, lpFee, after_);
            vm.revertToState(snap);
        }
    }

    function _graduateWithEarlyBuyer(uint16 saleBps, uint16 lpBps) private returns (Run memory r) {
        // A sale share is a deployment's, fixed when its curve deployer is constructed: another share, another stack.
        if (saleBps != factory.curveDeployer().DEFAULT_SALE_BPS()) { creatorSaleBps = saleBps; _setUpV2(18); }
        V2TreasuryDeployer treasuryDeployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        vm.prank(owner);
        treasuryDeployer.setLpBps(address(stock), lpBps);
        (uint256 id, Curve curve, PoolKey memory key) = _launchV2(true);
        vm.warp(curve.launchedAt() + curve.snipeSeconds());
        r.saleBps = saleBps; r.lpBps = lpBps;
        uint256 supply = curve.initialSupply();
        uint256 tMin = curve.minTokenReserve();
        uint256 t1 = supply - (supply - tMin) * EARLY_SHARE_BPS / 10_000;
        uint256 need = Math.ceilDiv(curve.invariant(), t1) - curve.virtualStock();
        _fund(EARLY, curve); _fund(REST, curve);
        vm.prank(EARLY);
        (r.earlyCost, r.earlyTokens) = curve.buy(need, 1, EARLY, block.timestamp);
        uint256 pmBefore = stock.balanceOf(address(pm));
        (, address treasury,,,) = factory.strategies(id);
        uint256 trBefore = stock.balanceOf(treasury);
        vm.prank(REST);
        curve.buy(type(uint256).max, 1, REST, block.timestamp);
        assertEq(uint256(curve.status()), 2);
        r.raised = curve.terminalStock() - curve.virtualStock();
        r.lpStock = stock.balanceOf(address(pm)) - pmBefore;
        r.treasuryStock = stock.balanceOf(treasury) - trBefore;
        (r.gradPrice,,,) = pm.getSlot0(key.toId());
    }

    function _fund(address who, Curve curve) private {
        stock.mint(who, 100_000 ether);
        vm.startPrank(who);
        stock.approve(address(curve), type(uint256).max);
        vm.stopPrank();
    }

    function _dump(Run memory r, uint256 delay) private returns (uint256 out, uint256 tax, uint256 lpFee, uint160 after_) {
        vm.warp(block.timestamp + delay);
        Router router = new Router(factory);
        (, address treasury,,,) = factory.strategies(0);
        (, PoolKey memory key) = _key();
        vm.startPrank(EARLY);
        IERC20(curveOf().token()).approve(address(router), type(uint256).max);
        Router.Hop[] memory empty = new Router.Hop[](0);
        (, uint256 taxBefore) = hook.accrued(key.toId());
        (out,) = router.sell(Router.TradeParams(0, address(stock), r.earlyTokens, 0, 1, block.timestamp, 2, true), empty);
        vm.stopPrank();
        (, uint256 taxAfter) = hook.accrued(key.toId());
        tax = taxAfter - taxBefore;
        (after_,,,) = pm.getSlot0(key.toId());
        (lpFee,) = V2LiquidityVault(hook.liquidityVaultOf(key.toId())).collectFees();
        assertEq(HedgeFunV2Treasury(treasury).buybackStock(), lpFee, "stock-side LP fee lands in the buyback budget");
    }

    function curveOf() private view returns (Curve) { return Curve(factory.curves(0)); }
    function _key() private view returns (uint256, PoolKey memory key) { (key,) = factory.graduationConfig(0); return (0, key); }

    function _log(string memory label, Run memory r, uint256 out, uint256 tax, uint256 lpFee, uint160 after_) private pure {
        // token is currency0, so the token's stock price is sqrtP^2: the ratio of squares is the price ratio
        uint256 pricePct = Math.mulDiv(Math.mulDiv(after_, 100, r.gradPrice), after_, r.gradPrice);
        console2.log("---", label, "sale bps", r.saleBps);
        console2.log("    lp bps", r.lpBps, "raised (stock e18)", r.raised);
        console2.log("    LP stock", r.lpStock, "treasury stock", r.treasuryStock);
        console2.log("    early paid", r.earlyCost, "early got stock", out);
        console2.log("    early multiple x100", out * 100 / r.earlyCost, "price after % of graduation", pricePct);
        console2.log("    hook tax (stock)", tax, "LP fee to treasury buyback", lpFee);
    }
}
