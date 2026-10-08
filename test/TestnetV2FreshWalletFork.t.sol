// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter} from "../src/v2/HedgeFunV2TradeRouter.sol";

interface IFreshWalletDrip {
    function drip() external;
}

/// @notice Fork-only proof that one public drip funds the existing fee-core lifecycle.
/// No ERC20 deal/mint privilege, oracle changes, clock changes, signer, or broadcast.
contract TestnetV2FreshWalletForkTest is Test {
    address constant CREATOR = 0xCeCAd0eBB0CAb4fbB2fe6213E3cd6dE82e4D164B;
    HedgeFunV2Factory constant FACTORY = HedgeFunV2Factory(0xACEB03aAeE5494Aa54929Ec840630ae32A9ade0A);
    HedgeFunV2TradeRouter constant ROUTER = HedgeFunV2TradeRouter(0xB291B34CD2D32C4a2DeFCe074107824654D427eF);
    IERC20 constant USDG = IERC20(0x539574139BB4Ac74Fd2183ba0E38ed777E30B58d);
    IERC20 constant STOCK = IERC20(0xcee322837F181Bd93AC2d71e4dDf334BFF565b98);
    address constant POOL = 0x04083643FF9E8c27f66C9dD99947743A9B777244;

    function test_publicDripsFundLaunchCurveRoundTripGraduationAndV4RoundTrip() public {
        if (!vm.envOr("FRESH_WALLET_FORK", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("https://rpc.testnet.chain.robinhood.com", vm.envUint("FRESH_WALLET_FORK_BLOCK"));
        assertEq(block.chainid, 46630);
        emit log_named_uint("fork block", block.number);
        assertEq(USDG.balanceOf(CREATOR), 0, "pin a block before this wallet is funded");
        assertEq(STOCK.balanceOf(CREATOR), 0);
        vm.startPrank(CREATOR);
        IFreshWalletDrip(address(USDG)).drip();
        IFreshWalletDrip(address(STOCK)).drip();
        assertEq(USDG.balanceOf(CREATOR), 10_000e6);
        assertEq(STOCK.balanceOf(CREATOR), 15e18);

        uint256 id = _launch();
        (address token, address treasury,,,) = FACTORY.strategies(id);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(FACTORY.curves(id));
        assertEq(uint8(curve.status()), 0);
        assertTrue(USDG.approve(address(ROUTER), 9_200e6));
        _buy(id, token, 100e6, 2e17, 1_000_000e18, 0, false);
        assertEq(uint8(curve.status()), 0);
        _sell(id, token, 1_000_000e18, 1e6, 0);
        assertEq(uint8(curve.status()), 0);

        uint256 refund = _buy(id, token, 9_000e6, 23e18, 350_000_000e18, 0, true);
        assertEq(uint8(curve.status()), 2);
        assertGt(refund, 0, "crossing buy refunds the unused stock");
        assertGt(STOCK.balanceOf(treasury), 0);
        HedgeFunV2Treasury t = HedgeFunV2Treasury(treasury);
        assertEq(t.bookedStock() + t.buybackStock() + t.unbookedStock(), STOCK.balanceOf(treasury));

        _buy(id, token, 100e6, 2e17, 1_000_000e18, 2, false);
        _sell(id, token, 1_000_000e18, 1e6, 2);
        assertEq(uint8(curve.status()), 2);
        assertEq(USDG.allowance(CREATOR, address(ROUTER)), 0);
        assertEq(IERC20(token).allowance(CREATOR, address(ROUTER)), 0);
        assertEq(USDG.balanceOf(address(ROUTER)), 0);
        assertEq(STOCK.balanceOf(address(ROUTER)), 0);
        assertEq(IERC20(token).balanceOf(address(ROUTER)), 0);
        emit log_named_uint("final tUSDG", USDG.balanceOf(CREATOR));
        emit log_named_uint("final TSLA", STOCK.balanceOf(CREATOR));
        emit log_named_uint("final FUN", IERC20(token).balanceOf(CREATOR));
        emit log_named_uint("treasury booked stock", t.bookedStock());
        emit log_named_uint("treasury unbooked stock", t.unbookedStock());
        vm.stopPrank();
    }

    function _launch() private returns (uint256 id) {
        HedgeFunFactory.Defaults memory d = FACTORY.getDefaults();
        assertTrue(FACTORY.publicLaunch());
        assertEq(uint8(d.launchFeeCurrency), uint8(HedgeFunFactory.FeeCurrency.Usdg));
        assertEq(d.launchFeeAmount, 25e6);
        HedgeFunFactory.Request memory q;
        q.name = "Hedgefun Fresh Wallet Fork Rehearsal";
        q.symbol = "HFFRESH";
        q.stock = address(STOCK);
        q.creator = CREATOR;
        q.taxBps = 300;
        q.creatorBps = 1000;
        q.tp1Bps = 300;
        q.tp2Bps = 600;
        q.dipBps = 500;
        q.lotBps = 2000;
        q.nonce = 2026100301;
        q.maxFee = d.launchFeeAmount;
        (,, q.expectedOpenPriceE18,) = FACTORY.listings(address(STOCK));
        FACTORY.curveDeployer().setCurveConfig(q.symbol, q.nonce, 4400, 180);
        (address predictedToken,, bytes32 terms) = FACTORY.predict(q);
        assertTrue(USDG.approve(address(FACTORY), q.maxFee));
        uint256 beforeBalance = USDG.balanceOf(CREATOR);
        id = FACTORY.launch(q, terms);
        (address token,,,, address creator) = FACTORY.strategies(id);
        assertEq(token, predictedToken);
        assertEq(creator, CREATOR);
        assertEq(beforeBalance - USDG.balanceOf(CREATOR), q.maxFee);
    }

    function _buy(
        uint256 id,
        address token,
        uint256 amount,
        uint256 minStock,
        uint256 minTokens,
        uint8 stage,
        bool allowPartial
    ) private returns (uint256 refund) {
        return _buyWithParams(
            token,
            HedgeFunV2TradeRouter.TradeParams(
                id, address(USDG), amount, minStock, minTokens, block.timestamp + 300, stage, allowPartial
            )
        );
    }

    function _buyWithParams(address token, HedgeFunV2TradeRouter.TradeParams memory p)
        private
        returns (uint256 refund)
    {
        HedgeFunV2TradeRouter.Hop[] memory path = new HedgeFunV2TradeRouter.Hop[](1);
        path[0] = HedgeFunV2TradeRouter.Hop(POOL, address(STOCK));
        uint256 beforeUsd = USDG.balanceOf(CREATOR);
        uint256 beforeToken = IERC20(token).balanceOf(CREATOR);
        uint256 beforeStock = STOCK.balanceOf(CREATOR);
        (uint256 bought, uint256 stockRefund) = ROUTER.buy(p, path);
        assertEq(beforeUsd - USDG.balanceOf(CREATOR), p.amountIn);
        assertEq(IERC20(token).balanceOf(CREATOR) - beforeToken, bought);
        assertEq(STOCK.balanceOf(CREATOR) - beforeStock, stockRefund);
        assertGe(bought, p.minFinalOut);
        return stockRefund;
    }

    function _sell(uint256 id, address token, uint256 amount, uint256 minimum, uint8 stage) private {
        HedgeFunV2TradeRouter.Hop[] memory path = new HedgeFunV2TradeRouter.Hop[](1);
        path[0] = HedgeFunV2TradeRouter.Hop(POOL, address(USDG));
        assertTrue(IERC20(token).approve(address(ROUTER), amount));
        uint256 beforeUsd = USDG.balanceOf(CREATOR);
        uint256 beforeToken = IERC20(token).balanceOf(CREATOR);
        (uint256 received, uint256 refund) = ROUTER.sell(
            HedgeFunV2TradeRouter.TradeParams(
                id, address(USDG), amount, 0, minimum, block.timestamp + 300, stage, false
            ),
            path
        );
        assertEq(refund, 0);
        assertEq(USDG.balanceOf(CREATOR) - beforeUsd, received);
        assertEq(beforeToken - IERC20(token).balanceOf(CREATOR), amount);
        assertGe(received, minimum);
    }
}
