// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HedgeFunFactory} from "../../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunBondingCurve} from "../../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter} from "../../src/v2/HedgeFunV2TradeRouter.sol";
import {CurveDeployer} from "../../src/v2/CurveDeployer.sol";

/// @notice One phase at a time for a dedicated, valueless Robinhood testnet wallet. No key is held by this script.
///         Every phase can be simulated without --broadcast and inspected again after the broadcast settles.
///         See docs/TESTNET_V2_JOURNEY.md for the exact sequence and receipt checks.
contract TestnetV2Journey is Script {
    uint256 private constant CHAIN_ID = 46630;
    address private constant CREATOR = 0xD4f69D180a9bc36F27D307E90E365d1E012816d5;
    address private constant OPERATOR = 0x75Cee941B0eF3A83feA0397BbF903C12c1D7e96D;
    address private constant WHITELISTED = 0xdA1AEE7018a3925AA06dEEb8631Fca09E1067614;
    address private constant FACTORY = 0x3E95976E2425e63cb2A8d48BBce8976F55627019;
    address private constant ROUTER = 0xf86Ee10C49d89a47Bd0E8Ec5c390631F7b454B65;
    address private constant USDG = 0x539574139BB4Ac74Fd2183ba0E38ed777E30B58d;
    address private constant GME = 0xDD301669340232F283b1e91a7c4571591d86bd85;
    address private constant GME_POOL = 0x9f978fa32e3dc5D61D92Be85644c867DCee692c0;
    uint256 private constant DEADLINE_SECONDS = 300;

    struct Book {
        HedgeFunV2Factory factory;
        HedgeFunV2TradeRouter router;
        IERC20 usdg;
        address stock;
        address pool;
    }

    error WrongChain(uint256 actual);
    error WrongSender(address actual);
    error BadBook();
    error BadStage(uint8 actual);
    error BadAmount(uint256 amount);
    error WrongCreator(address actual);

    function launch() external {
        _sender(CREATOR);
        Book memory b = _book();
        HedgeFunFactory.Defaults memory d = b.factory.getDefaults();
        if (
            !b.factory.publicLaunch() || d.launchFeeCurrency != HedgeFunFactory.FeeCurrency.Usdg
                || d.launchFeeAmount > 50e6
        ) revert BadBook();

        HedgeFunFactory.Request memory q;
        q.name = "Hedgefun V2 Whitelist Journey";
        q.symbol = "HFTWL1";
        q.stock = b.stock;
        q.creator = CREATOR;
        q.taxBps = 300;
        q.creatorBps = 1000;
        q.tp1Bps = 500;
        q.tp2Bps = 1000;
        q.dipBps = 500;
        q.stopBps = 500;
        q.lotBps = 2000;
        q.nonce = _nonce();
        q.maxFee = d.launchFeeAmount;
        (,, q.expectedOpenPriceE18,) = b.factory.listings(b.stock);
        address[] memory recipients = new address[](1);
        recipients[0] = WHITELISTED;
        vm.startBroadcast();
        CurveDeployer registry = b.factory.curveDeployer();
        registry.setCurveConfig(q.symbol, q.nonce, 4400, 180);
        registry.setOpeningTaxExemptions(q.symbol, q.nonce, recipients);
        vm.stopBroadcast();
        (address predictedToken,, bytes32 terms) = b.factory.predict(q);
        address predictedCurve = b.factory.predictCurve(q);
        if (predictedToken.code.length != 0 || predictedCurve.code.length != 0) revert BadBook();
        if (b.usdg.balanceOf(CREATOR) < d.launchFeeAmount) revert BadAmount(d.launchFeeAmount);

        uint256 expectedId = b.factory.strategyCount();
        console2.log("launch predicted id", expectedId);
        console2.log("launch predicted token", predictedToken);
        console2.log("launch predicted curve", predictedCurve);
        vm.startBroadcast();
        _approveIfNeeded(b.usdg, address(b.factory), d.launchFeeAmount, CREATOR);
        uint256 id = b.factory.launch(q, terms);
        vm.stopBroadcast();
        if (id != expectedId || b.factory.curves(id) != predictedCurve) revert BadBook();
        _inspect(b, id);
    }

    function curveBuy() external {
        _sender(CREATOR);
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        _strategy(b, id, 0);
        uint256 amount = vm.envUint("USDG_IN");
        if (amount == 0 || amount > 500e6 || b.usdg.balanceOf(CREATOR) < amount) revert BadAmount(amount);
        _buy(b, id, amount, 0, false, CREATOR);
        _inspect(b, id);
    }

    function ordinaryBuy() external {
        _sender(OPERATOR);
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        _strategy(b, id, 0);
        _openingTaxWindow(b, id);
        uint256 amount = vm.envUint("USDG_IN");
        if (amount == 0 || amount > 500e6 || b.usdg.balanceOf(OPERATOR) < amount) revert BadAmount(amount);
        _buy(b, id, amount, 0, false, OPERATOR);
        _inspect(b, id);
    }

    function whitelistBuy() external {
        _sender(WHITELISTED);
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        _strategy(b, id, 0);
        _openingTaxWindow(b, id);
        uint256 amount = vm.envUint("USDG_IN");
        if (amount == 0 || amount > 500e6 || b.usdg.balanceOf(WHITELISTED) < amount) revert BadAmount(amount);
        _buy(b, id, amount, 0, false, WHITELISTED);
        _inspect(b, id);
    }

    function curveSell() external {
        _sender(CREATOR);
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        address token = _strategy(b, id, 0);
        uint256 amount = vm.envUint("TOKEN_IN");
        if (amount == 0 || amount > IERC20(token).balanceOf(CREATOR) / 2) revert BadAmount(amount);
        _sell(b, id, token, amount, 0);
        _inspect(b, id);
    }

    /// @dev A final curve buy crosses the threshold and atomically creates the V4 pool. The unused stock is refunded.
    function graduate() external {
        _sender(CREATOR);
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        _strategy(b, id, 0);
        uint256 amount = vm.envUint("USDG_IN");
        if (amount < 8_000e6 || amount > 25_000e6 || b.usdg.balanceOf(CREATOR) < amount) revert BadAmount(amount);
        _buy(b, id, amount, 0, true, CREATOR);
        if (uint8(HedgeFunBondingCurve(b.factory.curves(id)).status()) != 2) revert BadStage(0);
        _inspect(b, id);
    }

    function v4Buy() external {
        _sender(CREATOR);
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        _strategy(b, id, 2);
        uint256 amount = vm.envUint("USDG_IN");
        if (amount == 0 || amount > 1_000e6 || b.usdg.balanceOf(CREATOR) < amount) revert BadAmount(amount);
        _buy(b, id, amount, 2, false, CREATOR);
        _inspect(b, id);
    }

    function v4Sell() external {
        _sender(CREATOR);
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        address token = _strategy(b, id, 2);
        uint256 amount = vm.envUint("TOKEN_IN");
        if (amount == 0 || amount > IERC20(token).balanceOf(CREATOR) / 4) revert BadAmount(amount);
        _sell(b, id, token, amount, 2);
        _inspect(b, id);
    }

    function inspect() external view {
        Book memory b = _book();
        _inspect(b, vm.envUint("JOURNEY_ID"));
    }

    function _buy(Book memory b, uint256 id, uint256 amount, uint8 stage, bool allowPartial, address payer) private {
        uint256 minStock = vm.envUint("MIN_STOCK_RECEIVED");
        uint256 minTokens = vm.envUint("MIN_FINAL_OUT");
        if (minStock == 0 || minTokens == 0) revert BadAmount(0);
        HedgeFunV2TradeRouter.Hop[] memory path = new HedgeFunV2TradeRouter.Hop[](1);
        path[0] = HedgeFunV2TradeRouter.Hop(b.pool, b.stock);
        HedgeFunV2TradeRouter.TradeParams memory p = HedgeFunV2TradeRouter.TradeParams({
            id: id,
            asset: address(b.usdg),
            amountIn: amount,
            minStockReceived: minStock,
            minFinalOut: minTokens,
            deadline: block.timestamp + DEADLINE_SECONDS,
            expectedStage: stage,
            allowPartialFill: allowPartial
        });
        vm.startBroadcast();
        _approveIfNeeded(b.usdg, address(b.router), amount, payer);
        b.router.buy(p, path);
        vm.stopBroadcast();
    }

    function _sell(Book memory b, uint256 id, address token, uint256 amount, uint8 stage) private {
        uint256 minUsdg = vm.envUint("MIN_FINAL_OUT");
        if (minUsdg == 0) revert BadAmount(0);
        HedgeFunV2TradeRouter.Hop[] memory path = new HedgeFunV2TradeRouter.Hop[](1);
        path[0] = HedgeFunV2TradeRouter.Hop(b.pool, address(b.usdg));
        HedgeFunV2TradeRouter.TradeParams memory p = HedgeFunV2TradeRouter.TradeParams({
            id: id,
            asset: address(b.usdg),
            amountIn: amount,
            minStockReceived: 0,
            minFinalOut: minUsdg,
            deadline: block.timestamp + DEADLINE_SECONDS,
            expectedStage: stage,
            allowPartialFill: false
        });
        vm.startBroadcast();
        _approveIfNeeded(IERC20(token), address(b.router), amount, CREATOR);
        b.router.sell(p, path);
        vm.stopBroadcast();
    }

    function _approveIfNeeded(IERC20 asset, address spender, uint256 amount, address payer) private {
        if (asset.allowance(payer, spender) < amount) {
            require(asset.approve(spender, amount), "approve failed");
        }
    }

    function _strategy(Book memory b, uint256 id, uint8 expectedStage) private view returns (address token) {
        if (id >= b.factory.strategyCount()) revert BadBook();
        address creator;
        address stock;
        (token,,, stock, creator) = b.factory.strategies(id);
        if (creator != CREATOR) revert WrongCreator(creator);
        if (stock != b.stock || token.code.length == 0) revert BadBook();
        uint8 stage = uint8(HedgeFunBondingCurve(b.factory.curves(id)).status());
        if (stage != expectedStage) revert BadStage(stage);
    }

    function _book() private view returns (Book memory b) {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        string memory json = vm.readFile(vm.envOr("ADDRESS_BOOK", string("deploy/testnet-v2-whitelist.json")));
        if (
            vm.parseJsonUint(json, ".chainId") != CHAIN_ID || !vm.parseJsonBool(json, ".broadcast")
                || vm.parseJsonAddress(json, ".operator") != OPERATOR
        ) revert BadBook();
        b.factory = HedgeFunV2Factory(vm.parseJsonAddress(json, ".factory"));
        b.router = HedgeFunV2TradeRouter(vm.parseJsonAddress(json, ".tradeRouter"));
        b.usdg = IERC20(vm.parseJsonAddress(json, ".usdg"));
        b.stock = vm.parseJsonAddress(json, ".stocks.GME.token");
        b.pool = vm.parseJsonAddress(json, ".stocks.GME.pool");
        if (
            address(b.factory) != FACTORY || address(b.router) != ROUTER || address(b.usdg) != USDG || b.stock != GME
                || b.pool != GME_POOL || b.factory.owner() != OPERATOR || address(b.factory).code.length == 0
                || address(b.router).code.length == 0 || address(b.usdg).code.length == 0 || b.stock.code.length == 0
                || b.pool.code.length == 0 || b.factory.usdg() != address(b.usdg)
                || address(b.router.factory()) != address(b.factory)
        ) revert BadBook();
        (address oracle, address pool, uint256 opening, bool enabled) = b.factory.listings(b.stock);
        if (
            !enabled || oracle.code.length == 0 || pool != b.pool
                || opening != vm.parseJsonUint(json, ".stocks.GME.openPriceE18")
        ) revert BadBook();
    }

    function _sender(address expected) private view {
        if (msg.sender != expected) revert WrongSender(msg.sender);
    }

    function _openingTaxWindow(Book memory b, uint256 id) private view {
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(b.factory.curves(id));
        if (block.timestamp >= curve.launchedAt() + curve.snipeSeconds()) revert BadBook();
        console2.log("ordinary buy rate", curve.buyRateBpsFor(OPERATOR));
        console2.log("whitelist buy rate", curve.buyRateBpsFor(WHITELISTED));
        console2.log("creator buy rate", curve.buyRateBpsFor(CREATOR));
    }

    function _nonce() private view returns (uint96) {
        uint256 value = vm.envUint("JOURNEY_NONCE");
        if (value > type(uint96).max) revert BadAmount(value);
        return uint96(value);
    }

    function _inspect(Book memory b, uint256 id) private view {
        address token = _strategyAny(b, id);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(b.factory.curves(id));
        console2.log("strategy id", id);
        console2.log("strategy token", token);
        console2.log("curve", address(curve));
        console2.log("curve status (0 active, 2 graduated)", uint256(curve.status()));
        console2.log("creator tUSDG", b.usdg.balanceOf(CREATOR));
        console2.log("creator GME", IERC20(b.stock).balanceOf(CREATOR));
        console2.log("creator strategy tokens", IERC20(token).balanceOf(CREATOR));
        console2.log("curve real stock reserve", curve.realStockReserve());
    }

    function _strategyAny(Book memory b, uint256 id) private view returns (address token) {
        if (id >= b.factory.strategyCount()) revert BadBook();
        address stock;
        address creator;
        (token,,, stock, creator) = b.factory.strategies(id);
        if (creator != CREATOR) revert WrongCreator(creator);
        if (stock != b.stock || token.code.length == 0) revert BadBook();
    }
}
