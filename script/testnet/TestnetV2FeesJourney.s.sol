// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HedgeFunFactory} from "../../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunBondingCurve} from "../../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter} from "../../src/v2/HedgeFunV2TradeRouter.sol";
import {CurveDeployer} from "../../src/v2/CurveDeployer.sol";
import {HedgeFunV2Hook} from "../../src/hooks/HedgeFunV2Hook.sol";
import {ILegacyV2FeeConversion} from "./ILegacyV2FeeConversion.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice One TSLA phase at a time for the new two-sided-fee core. No key is held by this script.
///         Every phase can be simulated without --broadcast and inspected again after the broadcast settles.
///         See docs/TESTNET_V2_FEE_UPGRADE.md for the exact sequence and receipt checks.
contract TestnetV2FeesJourney is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    address private constant HOOK = 0xF1b4C95B63091AE2eb68E640F6D9485982146844;
    address private constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    uint256 private constant CHAIN_ID = 46630;
    address private constant CREATOR = 0xD4f69D180a9bc36F27D307E90E365d1E012816d5;
    address private constant OPERATOR = 0x75Cee941B0eF3A83feA0397BbF903C12c1D7e96D;
    address private constant WHITELISTED = 0xdA1AEE7018a3925AA06dEEb8631Fca09E1067614;
    address private constant FACTORY = 0xACEB03aAeE5494Aa54929Ec840630ae32A9ade0A;
    address private constant ROUTER = 0xB291B34CD2D32C4a2DeFCe074107824654D427eF;
    address private constant USDG = 0x539574139BB4Ac74Fd2183ba0E38ed777E30B58d;
    address private constant TSLA = 0xcee322837F181Bd93AC2d71e4dDf334BFF565b98;
    address private constant TSLA_POOL = 0x04083643FF9E8c27f66C9dD99947743A9B777244;
    uint256 private constant DEADLINE_SECONDS = 300;

    struct Book {
        HedgeFunV2Factory factory;
        HedgeFunV2TradeRouter router;
        IERC20 usdg;
        HedgeFunV2Hook hook;
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
        q.name = "Hedgefun V2 Two-sided Fees Journey";
        q.symbol = "HFFEE1";
        q.stock = b.stock;
        q.creator = CREATOR;
        q.taxBps = 300;
        q.creatorBps = 1000;
        q.tp1Bps = 300;
        q.tp2Bps = 600;
        q.dipBps = 500;
        q.stopBps = 0;
        q.lotBps = 2000;
        q.nonce = _nonce();
        q.maxFee = d.launchFeeAmount;
        if (d.protocolBps != 2000) revert BadBook();
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

    /// @notice Anyone may deliver each fixed recipient's curve fees without redirecting them.
    function claimCurveFees() external {
        _sender(CREATOR);
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        _strategy(b, id, 2);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(b.factory.curves(id));
        if (curve.totalFees() == 0) revert BadAmount(0);
        vm.startBroadcast();
        curve.claimFees(OPERATOR);
        curve.claimFees(CREATOR);
        curve.claimFees(curve.treasury());
        vm.stopBroadcast();
        _inspect(b, id);
    }

    /// @notice Settle existing sell fees and move buy-token claims to pending inventory.
    function sweepStockFees() external {
        _sender(CREATOR);
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        _strategy(b, id, 2);
        (PoolKey memory key,) = b.factory.graduationConfig(id);
        vm.startBroadcast();
        b.hook.sweep(key.toId());
        vm.stopBroadcast();
        _inspect(b, id);
    }

    /// @notice Owner converts only this strategy's token fee claims; root supplies a reviewed nonzero minimum.
    function convertTokenFees() external {
        _sender(OPERATOR);
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        address token = _strategy(b, id, 2);
        (PoolKey memory key,) = b.factory.graduationConfig(id);
        (uint256 accrued,) = b.hook.accrued(key.toId());
        uint256 maximum = vm.envOr("CONVERSION_MAX_TOKENS", ILegacyV2FeeConversion(address(b.hook)).pendingTokenFees(key.toId()) + accrued);
        uint256 minimum = vm.envUint("MIN_CONVERSION_STOCK_OUT");
        uint256 move = vm.envOr("CONVERSION_SQRT_MOVE_BPS", uint256(50));
        if (maximum == 0 || minimum == 0 || move == 0 || move > 50) revert BadAmount(minimum);
        (uint160 spot,,,) = IPoolManager(PM).getSlot0(key.toId());
        uint160 limit = Currency.unwrap(key.currency0) == token
            ? uint160(uint256(spot) * (10_000 - move) / 10_000)
            : uint160(uint256(spot) * (10_000 + move) / 10_000);
        uint256 deadline = block.timestamp + DEADLINE_SECONDS;
        console2.log("conversion maximum tokens", maximum);
        console2.log("conversion minimum stock", minimum);
        console2.log("conversion sqrt limit", uint256(limit));
        console2.log("conversion deadline", deadline);
        vm.startBroadcast();
        (uint256 consumed, uint256 stockOut) = ILegacyV2FeeConversion(address(b.hook)).convertFees(key, maximum, minimum, limit, deadline);
        vm.stopBroadcast();
        console2.log("conversion consumed tokens", consumed);
        console2.log("conversion output stock claims", stockOut);
        _inspect(b, id);
    }

    /// @notice A separate stock sweep distributes the converted claims; repeated sweeps must pay nothing twice.
    function sweepConvertedFees() external {
        _sender(CREATOR);
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        _strategy(b, id, 2);
        (PoolKey memory key,) = b.factory.graduationConfig(id);
        vm.startBroadcast();
        b.hook.sweep(key.toId());
        vm.stopBroadcast();
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
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(b.factory.curves(id));
        if (
            curve.factory() != FACTORY || curve.taxBps() != 300 || curve.protocolBps() != 2000
                || curve.creatorBps() != 1000
        ) revert BadBook();
        uint8 stage = uint8(curve.status());
        if (stage != expectedStage) revert BadStage(stage);
    }

    function _book() private view returns (Book memory b) {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        string memory json = vm.readFile(vm.envOr("ADDRESS_BOOK", string("deploy/testnet-v2-fees.json")));
        if (
            vm.parseJsonUint(json, ".chainId") != CHAIN_ID
                || ((vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
                        || vm.isContext(VmSafe.ForgeContext.ScriptResume))
                    && !vm.parseJsonBool(json, ".broadcast")) || vm.parseJsonAddress(json, ".operator") != OPERATOR
                || keccak256(bytes(vm.parseJsonString(json, ".featureVersion")))
                    != keccak256("v2-two-sided-stock-fees-v1")
        ) revert BadBook();
        b.factory = HedgeFunV2Factory(vm.parseJsonAddress(json, ".factory"));
        b.router = HedgeFunV2TradeRouter(vm.parseJsonAddress(json, ".tradeRouter"));
        b.usdg = IERC20(vm.parseJsonAddress(json, ".usdg"));
        b.hook = HedgeFunV2Hook(vm.parseJsonAddress(json, ".hook"));
        b.stock = vm.parseJsonAddress(json, ".stocks.TSLA.token");
        b.pool = vm.parseJsonAddress(json, ".stocks.TSLA.pool");
        if (
            address(b.factory) != FACTORY || address(b.router) != ROUTER || address(b.usdg) != USDG || b.stock != TSLA
                || b.pool != TSLA_POOL || b.factory.owner() != OPERATOR || address(b.factory).code.length == 0
                || address(b.router).code.length == 0 || address(b.usdg).code.length == 0 || b.stock.code.length == 0
                || b.pool.code.length == 0 || b.factory.usdg() != address(b.usdg)
                || address(b.router.factory()) != address(b.factory) || address(b.hook) != HOOK || b.hook.version() != 2
                || b.hook.factory() != FACTORY || address(b.factory.poolManager()) != PM
                || b.factory.getDefaults().sweepTipBps != 0
        ) revert BadBook();
        (address oracle, address pool, uint256 opening, bool enabled) = b.factory.listings(b.stock);
        if (
            !enabled || oracle.code.length == 0 || pool != b.pool
                || opening != vm.parseJsonUint(json, ".stocks.TSLA.openPriceE18")
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
        console2.log("creator TSLA", IERC20(b.stock).balanceOf(CREATOR));
        console2.log("creator strategy tokens", IERC20(token).balanceOf(CREATOR));
        console2.log("curve real stock reserve", curve.realStockReserve());
        console2.log("curve unpaid stock fees", curve.totalFees());
        console2.log("curve protocol claim", curve.claimable(OPERATOR));
        console2.log("curve creator claim", curve.claimable(CREATOR));
        console2.log("curve treasury claim", curve.claimable(curve.treasury()));
        if (uint8(curve.status()) == 2) _inspectHook(b, id);
    }

    function _inspectHook(Book memory b, uint256 id) private view {
        (PoolKey memory key,) = b.factory.graduationConfig(id);
        PoolId pid = key.toId();
        (uint256 tokenClaims, uint256 stockClaims) = b.hook.accrued(pid);
        console2.log("hook accrued token claims", tokenClaims);
        console2.log("hook accrued stock claims", stockClaims);
        console2.log("hook pending token fees", ILegacyV2FeeConversion(address(b.hook)).pendingTokenFees(pid));
        console2.log("hook owed protocol", b.hook.owedProtocol(pid));
        console2.log("hook owed creator", b.hook.owedCreator(pid));
        console2.log("hook owed treasury", b.hook.owedTreasury(pid));
        console2.log("hook shared-stock total owed", b.hook.totalOwed(b.stock));
    }

    function _strategyAny(Book memory b, uint256 id) private view returns (address token) {
        if (id >= b.factory.strategyCount()) revert BadBook();
        address stock;
        address creator;
        (token,,, stock, creator) = b.factory.strategies(id);
        if (creator != CREATOR) revert WrongCreator(creator);
        if (stock != b.stock || token.code.length == 0) revert BadBook();
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(b.factory.curves(id));
        if (
            curve.factory() != FACTORY || curve.taxBps() != 300 || curve.protocolBps() != 2000
                || curve.creatorBps() != 1000
        ) revert BadBook();
    }
}
