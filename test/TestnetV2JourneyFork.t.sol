// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {CurveDeployer} from "../src/v2/CurveDeployer.sol";

/// @notice Read-only RPC fork rehearsal of the separately broadcast phases in TestnetV2Journey.
contract TestnetV2JourneyForkTest is Test {
    address constant CREATOR = 0xD4f69D180a9bc36F27D307E90E365d1E012816d5;
    address constant WHITELISTED = 0xdA1AEE7018a3925AA06dEEb8631Fca09E1067614;
    HedgeFunV2Factory factory;
    HedgeFunV2TradeRouter router;
    IERC20 usdg;
    IERC20 stock;
    address pool;

    function setUp() public {
        if (!vm.envOr("RUN_TESTNET_FORK", false)) vm.skip(true);
        vm.createSelectFork(vm.envOr("RPC", string("https://rpc.testnet.chain.robinhood.com")));
        string memory json = vm.readFile("deploy/testnet-v2-whitelist.json");
        assertEq(block.chainid, 46630);
        assertTrue(vm.parseJsonBool(json, ".broadcast"));
        factory = HedgeFunV2Factory(vm.parseJsonAddress(json, ".factory"));
        router = HedgeFunV2TradeRouter(vm.parseJsonAddress(json, ".tradeRouter"));
        usdg = IERC20(vm.parseJsonAddress(json, ".usdg"));
        stock = IERC20(vm.parseJsonAddress(json, ".stocks.GME.token"));
        pool = vm.parseJsonAddress(json, ".stocks.GME.pool");
    }

    function test_liveV2LaunchCurveRoundTripGraduationAndV4RoundTrip() public {
        // This advances only the local fork. No RPC transaction is signed or broadcast.
        vm.warp(block.timestamp + 11 minutes);
        uint256 id = factory.strategyCount();
        address token;
        HedgeFunBondingCurve curve;
        {
            HedgeFunFactory.Request memory q;
            q.name = "Hedgefun V2 Test Journey";
            q.symbol = "HFTWL-FORK";
            q.stock = address(stock);
            q.creator = CREATOR;
            q.taxBps = 300;
            q.creatorBps = 1000;
            q.tp1Bps = 500;
            q.tp2Bps = 1000;
            q.dipBps = 500;
            q.stopBps = 500;
            q.lotBps = 2000;
            q.nonce = uint96(factory.strategyCount() + 100); // fork-only salt also works after a real journey exists
            HedgeFunFactory.Defaults memory d = factory.getDefaults();
            assertEq(uint256(d.launchFeeCurrency), uint256(HedgeFunFactory.FeeCurrency.Usdg));
            q.maxFee = d.launchFeeAmount;
            (,, q.expectedOpenPriceE18,) = factory.listings(address(stock));
            address[] memory recipients = new address[](1);
            recipients[0] = WHITELISTED;
            CurveDeployer registry = CurveDeployer(address(factory.curveDeployer()));
            vm.startPrank(CREATOR);
            registry.setCurveConfig(q.symbol, q.nonce, 4400, 180);
            registry.setOpeningTaxExemptions(q.symbol, q.nonce, recipients);
            vm.stopPrank();
            (address predictedToken,, bytes32 terms) = factory.predict(q);
            address predictedCurve = factory.predictCurve(q);
            uint256 usdgBefore = usdg.balanceOf(CREATOR);

            vm.startPrank(CREATOR);
            usdg.approve(address(factory), d.launchFeeAmount);
            assertEq(factory.launch(q, terms), id);
            assertEq(usdgBefore - usdg.balanceOf(CREATOR), d.launchFeeAmount);
            assertEq(factory.curves(id), predictedCurve);
            address creator;
            (token,,,, creator) = factory.strategies(id);
            assertEq(token, predictedToken);
            assertEq(creator, CREATOR);
            curve = HedgeFunBondingCurve(predictedCurve);
            assertEq(uint8(curve.status()), 0);
            assertTrue(curve.isOpeningTaxExempt(CREATOR));
            assertTrue(curve.isOpeningTaxExempt(WHITELISTED));
            assertFalse(curve.isOpeningTaxExempt(address(router)));
        }

        HedgeFunV2TradeRouter.Hop[] memory buyPath = new HedgeFunV2TradeRouter.Hop[](1);
        buyPath[0] = HedgeFunV2TradeRouter.Hop(pool, address(stock));
        HedgeFunV2TradeRouter.Hop[] memory sellPath = new HedgeFunV2TradeRouter.Hop[](1);
        sellPath[0] = HedgeFunV2TradeRouter.Hop(pool, address(usdg));
        usdg.approve(address(router), 21_000e6);
        IERC20(token).approve(address(router), type(uint256).max);
        vm.warp(block.timestamp + 4);

        {
            uint256 tokensBefore = IERC20(token).balanceOf(CREATOR);
            uint256 usdBefore = usdg.balanceOf(CREATOR);
            (uint256 bought, uint256 refund) =
                router.buy(_p(id, address(usdg), 100e6, 4e18, 8_000_000e18, 0, false), buyPath);
            assertEq(refund, 0);
            assertEq(IERC20(token).balanceOf(CREATOR) - tokensBefore, bought);
            assertEq(usdBefore - usdg.balanceOf(CREATOR), 100e6);
            assertEq(uint8(curve.status()), 0);
        }
        {
            uint256 usdBefore = usdg.balanceOf(CREATOR);
            (uint256 received, uint256 refund) =
                router.sell(_p(id, address(usdg), 1_000_000e18, 0, 7e6, 0, false), sellPath);
            assertEq(refund, 0);
            assertEq(usdg.balanceOf(CREATOR) - usdBefore, received);
            assertEq(uint8(curve.status()), 0);
        }
        {
            uint256 stockBefore = stock.balanceOf(CREATOR);
            uint256 tokensBefore = IERC20(token).balanceOf(CREATOR);
            (uint256 bought, uint256 refund) =
                router.buy(_p(id, address(usdg), 20_000e6, 300e18, 350_000_000e18, 0, true), buyPath);
            assertEq(IERC20(token).balanceOf(CREATOR) - tokensBefore, bought);
            assertEq(stock.balanceOf(CREATOR) - stockBefore, refund);
            assertGt(refund, 0);
            assertEq(uint8(curve.status()), 2);
        }
        {
            uint256 tokensBefore = IERC20(token).balanceOf(CREATOR);
            (uint256 bought, uint256 refund) =
                router.buy(_p(id, address(usdg), 100e6, 4e18, 1_000_000e18, 2, false), buyPath);
            assertEq(refund, 0);
            assertEq(IERC20(token).balanceOf(CREATOR) - tokensBefore, bought);
        }
        {
            uint256 usdBefore = usdg.balanceOf(CREATOR);
            (uint256 received, uint256 refund) =
                router.sell(_p(id, address(usdg), 1_000_000e18, 0, 5e6, 2, false), sellPath);
            assertEq(refund, 0);
            assertEq(usdg.balanceOf(CREATOR) - usdBefore, received);
            assertEq(uint8(curve.status()), 2);
        }
        vm.stopPrank();
    }

    function _p(
        uint256 id,
        address asset,
        uint256 amount,
        uint256 minStock,
        uint256 minOut,
        uint8 stage,
        bool allowPartial
    ) private view returns (HedgeFunV2TradeRouter.TradeParams memory) {
        return HedgeFunV2TradeRouter.TradeParams(
            id, asset, amount, minStock, minOut, block.timestamp + 300, stage, allowPartial
        );
    }
}
