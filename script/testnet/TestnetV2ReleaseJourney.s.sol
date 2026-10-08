// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {HedgeFunFactory} from "../../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunBondingCurve} from "../../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter} from "../../src/v2/HedgeFunV2TradeRouter.sol";
import {HedgeFunV2Treasury} from "../../src/v2/HedgeFunV2Treasury.sol";
import {V2TreasuryDeployer} from "../../src/v2/V2TreasuryDeployer.sol";
import {V2LiquidityVault} from "../../src/v2/V2LiquidityVault.sol";
import {CurveDeployer} from "../../src/v2/CurveDeployer.sol";
import {HedgeFunV2Hook} from "../../src/hooks/HedgeFunV2Hook.sol";
import {Drip} from "./TestnetAssets.sol";

/// @notice One TSLA phase at a time on the v2.0 release core (`deploy/testnet-v2-release.json`). No key is held
///         here: every phase simulates without `--broadcast`, and `inspect()` reads the same state back afterwards.
///         Compared with the fee-upgrade journey there is no owner conversion step: the version-3 hook takes the V4
///         buy tax in stock before the swap, so `sweep` alone pays all three recipients. See
///         docs/V2_RELEASE_RUNBOOK.md, section F.
contract TestnetV2ReleaseJourney is Script {
    using PoolIdLibrary for PoolKey;

    uint256 private constant CHAIN_ID = 46630;
    address private constant OWNER = 0x36437b878415EdA1a24186CF79AFffBc9ecEd298;
    address private constant PROTOCOL = 0x75Cee941B0eF3A83feA0397BbF903C12c1D7e96D;
    address private constant FACTORY = 0x6847318D28aB2f9343DDd2067871DC4f48609383;
    address private constant ROUTER = 0xC80B217f34B04CB039E737084c4bc29E4bC4Af66;
    address private constant HOOK = 0xb5bAbc5609de876D56662d066a0B5f63eF90a8CC;
    address private constant REGISTRY = 0x38e97783266Cd1B702569001aAb22f47dd2dDfF0;
    address private constant CURVES = 0xC92e7e717D5a4f00038D13e93c2Dc3cDcb7AE3b1;
    address private constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address private constant USDG = 0x539574139BB4Ac74Fd2183ba0E38ed777E30B58d;
    address private constant TSLA = 0xcee322837F181Bd93AC2d71e4dDf334BFF565b98;
    uint16 private constant TAX_BPS = 100;
    uint16 private constant CREATOR_BPS = 1000;
    uint16 private constant PROTOCOL_BPS = 3000;
    uint16 private constant SALE_BPS = 7931;
    uint16 private constant LP_BPS = 7000;
    uint256 private constant DEADLINE_SECONDS = 300;

    struct Book {
        HedgeFunV2Factory factory;
        HedgeFunV2TradeRouter router;
        V2TreasuryDeployer registry;
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
    error BadKind(uint8 kind);
    error WrongCreator(address actual);

    /// @dev The creator is whoever runs the journey: the deployer by default, another test wallet by `JOURNEY_CREATOR`.
    function _creator() private view returns (address) { return vm.envOr("JOURNEY_CREATOR", OWNER); }

    /// @notice 10,000 tUSDG and 15 TSLA to the creator, once a day each; enough tUSDG to graduate one launch.
    function drip() external {
        address creator = _creator();
        _sender(creator);
        Book memory b = _book();
        vm.startBroadcast();
        if (Drip(address(b.usdg)).lastDrip(creator) + Drip(address(b.usdg)).DRIP_INTERVAL() <= block.timestamp) Drip(address(b.usdg)).drip();
        if (Drip(b.stock).lastDrip(creator) + Drip(b.stock).DRIP_INTERVAL() <= block.timestamp) Drip(b.stock).drip();
        vm.stopBroadcast();
        console2.log("creator tUSDG", b.usdg.balanceOf(creator));
        console2.log("creator TSLA", IERC20(b.stock).balanceOf(creator));
    }

    /// @notice Launch on TSLA with the release's recommended terms: 1% tax, 10% of it to the creator; the sale share
    ///         is the curve deployer's and no `setCurveConfig` is sent. `KIND` (default 0) picks a treasury kind
    ///         without an engine config: 0 ordinary, 1 buy-back, 4 percentage buy-back, 5 cycle. Kinds 2 and 3 need
    ///         `setEngineConfig`; launch those from the site or the fork suites.
    function launch() external {
        address creator = _creator();
        _sender(creator);
        Book memory b = _book();
        HedgeFunFactory.Defaults memory d = b.factory.getDefaults();
        uint8 kind = uint8(vm.envOr("KIND", uint256(0)));
        if (kind != 0 && kind != 1 && kind != 4 && kind != 5) revert BadKind(kind);
        if (creator.balance < d.launchFeeAmount) revert BadAmount(d.launchFeeAmount);

        HedgeFunFactory.Request memory q;
        q.name = "Hedgefun V2 Release Journey";
        q.symbol = string.concat("HFREL", vm.toString(uint256(kind)));
        q.stock = b.stock;
        q.creator = creator;
        q.taxBps = TAX_BPS;
        q.creatorBps = CREATOR_BPS;
        q.tp1Bps = 500;
        q.tp2Bps = 1000;
        q.dipBps = 500;
        q.stopBps = 0;
        q.lotBps = 2000;
        q.nonce = _nonce();
        q.maxFee = d.launchFeeAmount;
        (,, q.expectedOpenPriceE18,) = b.factory.listings(b.stock);
        (uint16 chosenSale, uint8 chosenWindow) = CurveDeployer(CURVES).curveConfigOf(keccak256(abi.encode(q.symbol, creator, q.nonce)));
        if (chosenSale != 0 || chosenWindow != 0) revert BadBook(); // an earlier draft registered under this nonce: pick another
        (address predictedToken,, bytes32 terms) = b.factory.predict(q);
        address predictedCurve = b.factory.predictCurve(q);
        if (predictedToken.code.length != 0 || predictedCurve.code.length != 0) revert BadBook();

        uint256 expectedId = b.factory.strategyCount();
        console2.log("launch kind", kind);
        console2.log("launch predicted id", expectedId);
        console2.log("launch predicted token", predictedToken);
        console2.log("launch predicted curve", predictedCurve);
        vm.startBroadcast();
        if (kind != 0 && b.registry.strategyKindOf(keccak256(abi.encode(q.symbol, creator, q.nonce))) != kind) {
            b.registry.setStrategyKind(q.symbol, q.nonce, kind);
        }
        uint256 id = b.factory.launch{value: d.launchFeeAmount}(q, terms);
        vm.stopBroadcast();
        if (id != expectedId || b.factory.curves(id) != predictedCurve) revert BadBook();
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(predictedCurve);
        if (!_sellsTheDefaultShare(curve)) revert BadBook();
        _inspect(b, id);
    }

    function curveBuy() external {
        address creator = _creator();
        _sender(creator);
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        _strategy(b, id, 0);
        uint256 amount = _amountIn();
        if (_paysInStock() ? amount == 0 || amount > 5e18 || IERC20(b.stock).balanceOf(creator) < amount : amount == 0 || amount > 2_000e6 || b.usdg.balanceOf(creator) < amount) revert BadAmount(amount);
        _buy(b, id, amount, 0, false, creator);
        _inspect(b, id);
    }

    function curveSell() external {
        address creator = _creator();
        _sender(creator);
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        address token = _strategy(b, id, 0);
        uint256 amount = vm.envUint("TOKEN_IN");
        if (amount == 0 || amount > IERC20(token).balanceOf(creator) / 2) revert BadAmount(amount);
        _sell(b, id, token, amount, 0, creator);
        _inspect(b, id);
    }

    /// @dev The final curve buy crosses the threshold and seeds the V4 pool in the same transaction; the unused
    ///      stock is refunded untaxed. About 8,205 tUSDG of stock graduates a fresh launch; offer more and read the
    ///      refund.
    function graduate() external {
        address creator = _creator();
        _sender(creator);
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        _strategy(b, id, 0);
        uint256 amount = _amountIn();
        if (_paysInStock() ? amount < 1e18 || amount > 60e18 || IERC20(b.stock).balanceOf(creator) < amount : amount < 500e6 || amount > 25_000e6 || b.usdg.balanceOf(creator) < amount) revert BadAmount(amount);
        _buy(b, id, amount, 0, true, creator);
        if (uint8(HedgeFunBondingCurve(b.factory.curves(id)).status()) != 2) revert BadStage(0);
        _inspect(b, id);
    }

    function v4Buy() external {
        address creator = _creator();
        _sender(creator);
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        _strategy(b, id, 2);
        uint256 amount = _amountIn();
        if (_paysInStock() ? amount == 0 || amount > 2e18 || IERC20(b.stock).balanceOf(creator) < amount : amount == 0 || amount > 1_000e6 || b.usdg.balanceOf(creator) < amount) revert BadAmount(amount);
        _buy(b, id, amount, 2, false, creator);
        _inspect(b, id);
    }

    function v4Sell() external {
        address creator = _creator();
        _sender(creator);
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        address token = _strategy(b, id, 2);
        uint256 amount = vm.envUint("TOKEN_IN");
        if (amount == 0 || amount > IERC20(token).balanceOf(creator) / 4) revert BadAmount(amount);
        _sell(b, id, token, amount, 2, creator);
        _inspect(b, id);
    }

    /// @notice Anyone may deliver each fixed recipient's curve fees; nothing is redirected.
    function claimCurveFees() external {
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        _strategy(b, id, 2);
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(b.factory.curves(id));
        if (curve.totalFees() == 0) revert BadAmount(0);
        vm.startBroadcast();
        curve.claimFees(PROTOCOL);
        curve.claimFees(_creator());
        curve.claimFees(curve.treasury());
        vm.stopBroadcast();
        _inspect(b, id);
    }

    /// @notice Pay the hook's stock tax to protocol, creator and treasury (30 / 10 / rest). Buy and sell taxes are
    ///         both in stock on this core, so one sweep settles everything; a second sweep must pay nothing.
    function sweepFees() external {
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        _strategy(b, id, 2);
        (PoolKey memory key,) = b.factory.graduationConfig(id);
        (uint256 inToken, uint256 inStock) = b.hook.accrued(key.toId());
        if (inToken != 0) revert BadBook(); // version 3 books no token-side tax
        console2.log("sweeping accrued stock", inStock);
        vm.startBroadcast();
        b.hook.sweep(key.toId());
        vm.stopBroadcast();
        _inspect(b, id);
    }

    /// @notice Realize the pool's 0.20% LP fee: the stock side enters the treasury's buy-back budget, the token side
    ///         is burned. Anyone may call.
    function collectLpFees() external {
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        _strategy(b, id, 2);
        V2LiquidityVault vault = _vault(b, id);
        vm.startBroadcast();
        (uint256 stockFee, uint256 tokenBurned) = vault.collectFees();
        vm.stopBroadcast();
        console2.log("lp fee credited to treasury (stock)", stockFee);
        console2.log("lp fee burned (token)", tokenBurned);
        _inspect(b, id);
    }

    /// @notice Book the stock the treasury received since (the hook's share, LP fees): a strategy kind books it as a
    ///         lot at the oracle price, the buy-back kinds as buy-back budget. Anyone may call; `execute` books too.
    function book() external {
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        _strategy(b, id, 2);
        HedgeFunV2Treasury t = _treasury(b, id);
        console2.log("unbooked stock before", t.unbookedStock());
        vm.startBroadcast();
        bool booked = t.book();
        vm.stopBroadcast();
        console2.log("booked", booked);
        _inspect(b, id);
    }

    /// @notice Spend the treasury's buy-back budget on the pool and burn what it buys. Permissionless; at most one
    ///         every `buybackCooldown` (10 s) and only inside market hours.
    function buyback() external {
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        _strategy(b, id, 2);
        HedgeFunV2Treasury t = _treasury(b, id);
        if (t.buybackStock() == 0) revert BadAmount(0);
        vm.startBroadcast();
        (uint256 spent, uint256 burned) = t.buyback();
        vm.stopBroadcast();
        console2.log("buyback spent (stock)", spent);
        console2.log("buyback burned (token)", burned);
        _inspect(b, id);
    }

    /// @notice One strategy step, if the price allows one: a take-profit, a dip buy, a stop. The keeper reward is
    ///         0.1%; the venue owner moves the price on this testnet.
    function execute() external {
        Book memory b = _book();
        uint256 id = vm.envUint("JOURNEY_ID");
        _strategy(b, id, 2);
        HedgeFunV2Treasury t = _treasury(b, id);
        vm.startBroadcast();
        (HedgeFunV2Treasury.Action action, uint256 lot) = t.execute();
        vm.stopBroadcast();
        console2.log("executed action (0 stop, 1 take profit, 2 dip, 3/4 rebalance, 5 recovery)", uint256(action));
        console2.log("executed lot", lot);
        _inspect(b, id);
    }

    function inspect() external view {
        Book memory b = _book();
        _inspect(b, vm.envUint("JOURNEY_ID"));
    }

    /// @dev Pays tUSDG over the listed V3 pool, or the stock itself when `STOCK_IN` is set (no hop: what the site does).
    function _buy(Book memory b, uint256 id, uint256 amount, uint8 stage, bool allowPartial, address payer) private {
        uint256 minStock = vm.envUint("MIN_STOCK_RECEIVED");
        uint256 minTokens = vm.envUint("MIN_FINAL_OUT");
        if (minStock == 0 || minTokens == 0) revert BadAmount(0);
        bool inStock = _paysInStock();
        HedgeFunV2TradeRouter.Hop[] memory path = new HedgeFunV2TradeRouter.Hop[](inStock ? 0 : 1);
        if (!inStock) path[0] = HedgeFunV2TradeRouter.Hop(b.pool, b.stock);
        HedgeFunV2TradeRouter.TradeParams memory p = HedgeFunV2TradeRouter.TradeParams({
            id: id,
            asset: inStock ? b.stock : address(b.usdg),
            amountIn: amount,
            minStockReceived: minStock,
            minFinalOut: minTokens,
            deadline: block.timestamp + DEADLINE_SECONDS,
            expectedStage: stage,
            allowPartialFill: allowPartial || (inStock && stage == 0) // a stock-paid curve buy leaves rounding dust, refunded
        });
        vm.startBroadcast();
        _approveIfNeeded(inStock ? IERC20(b.stock) : b.usdg, address(b.router), amount, payer);
        b.router.buy(p, path);
        vm.stopBroadcast();
    }

    function _sell(Book memory b, uint256 id, address token, uint256 amount, uint8 stage, address payer) private {
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
        _approveIfNeeded(IERC20(token), address(b.router), amount, payer);
        b.router.sell(p, path);
        vm.stopBroadcast();
    }

    function _paysInStock() private view returns (bool) { return vm.envOr("STOCK_IN", uint256(0)) != 0; }

    function _amountIn() private view returns (uint256) {
        return _paysInStock() ? vm.envUint("STOCK_IN") : vm.envUint("USDG_IN");
    }

    function _approveIfNeeded(IERC20 asset, address spender, uint256 amount, address payer) private {
        if (asset.allowance(payer, spender) < amount) require(asset.approve(spender, amount), "approve failed");
    }

    function _strategy(Book memory b, uint256 id, uint8 expectedStage) private view returns (address token) {
        token = _strategyAny(b, id);
        uint8 stage = uint8(HedgeFunBondingCurve(b.factory.curves(id)).status());
        if (stage != expectedStage) revert BadStage(stage);
    }

    function _strategyAny(Book memory b, uint256 id) private view returns (address token) {
        if (id >= b.factory.strategyCount()) revert BadBook();
        address stock;
        address creator;
        (token,,, stock, creator) = b.factory.strategies(id);
        if (creator != _creator()) revert WrongCreator(creator);
        if (stock != b.stock || token.code.length == 0) revert BadBook();
        // the tax and the creator's share are the creator's choice (a site launch may differ from this script's
        // 1% / 10%); the protocol share and the sale share are the core's
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(b.factory.curves(id));
        if (curve.factory() != FACTORY || curve.protocolBps() != PROTOCOL_BPS || !_sellsTheDefaultShare(curve)) revert BadBook();
    }

    /// @dev The curve keeps no `saleBps`; its minimum token reserve is the unsold share of the supply.
    function _sellsTheDefaultShare(HedgeFunBondingCurve curve) private view returns (bool) {
        return curve.minTokenReserve() == curve.initialSupply() * (10_000 - SALE_BPS) / 10_000;
    }

    function _treasury(Book memory b, uint256 id) private view returns (HedgeFunV2Treasury) {
        return HedgeFunV2Treasury(HedgeFunBondingCurve(b.factory.curves(id)).treasury());
    }

    function _vault(Book memory b, uint256 id) private view returns (V2LiquidityVault vault) {
        vault = V2LiquidityVault(_treasury(b, id).liquidityVault());
        if (address(vault).code.length == 0) revert BadBook();
    }

    /// @dev Every phase re-checks the book against the chain: the release core, its version-3 hook, the contract's
    ///      sale share, the 70% LP share and the release defaults. A broadcast or resume needs `broadcast == true`.
    function _book() private view returns (Book memory b) {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        string memory json = vm.readFile(vm.envOr("ADDRESS_BOOK", string("deploy/testnet-v2-release.json")));
        if (
            vm.parseJsonUint(json, ".chainId") != CHAIN_ID
                || ((vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume))
                    && !vm.parseJsonBool(json, ".broadcast"))
                || vm.parseJsonAddress(json, ".owner") != OWNER || vm.parseJsonAddress(json, ".protocol") != PROTOCOL
                || keccak256(bytes(vm.parseJsonString(json, ".featureVersion"))) != keccak256("v2-release-candidate-v2")
        ) revert BadBook();
        b.factory = HedgeFunV2Factory(vm.parseJsonAddress(json, ".factory"));
        b.router = HedgeFunV2TradeRouter(vm.parseJsonAddress(json, ".tradeRouter"));
        b.registry = V2TreasuryDeployer(vm.parseJsonAddress(json, ".treasuryDeployer"));
        b.usdg = IERC20(vm.parseJsonAddress(json, ".usdg"));
        b.hook = HedgeFunV2Hook(vm.parseJsonAddress(json, ".hook"));
        b.stock = vm.parseJsonAddress(json, ".stocks.TSLA.token");
        b.pool = vm.parseJsonAddress(json, ".stocks.TSLA.pool");
        if (
            address(b.factory) != FACTORY || address(b.router) != ROUTER || address(b.registry) != REGISTRY
                || address(b.usdg) != USDG || address(b.hook) != HOOK || b.stock != TSLA || b.pool.code.length == 0
                || b.factory.owner() != OWNER || b.factory.protocol() != PROTOCOL || !b.factory.publicLaunch()
                || b.factory.usdg() != address(b.usdg) || address(b.router.factory()) != address(b.factory)
                || address(b.factory.treasuryDeployer()) != REGISTRY || address(b.factory.curveDeployer()) != CURVES
                || address(b.factory.poolManager()) != PM || b.hook.version() != 3 || b.hook.factory() != FACTORY
                || CurveDeployer(CURVES).DEFAULT_SALE_BPS() != SALE_BPS || b.registry.DEFAULT_LP_BPS() != LP_BPS
                || b.registry.lpBps(b.stock) != LP_BPS
        ) revert BadBook();
        HedgeFunFactory.Defaults memory d = b.factory.getDefaults();
        if (
            d.lpFee != 2000 || d.protocolBps != PROTOCOL_BPS || d.maxCreatorBps != CREATOR_BPS || d.bountyBps != 10
                || d.buybackCooldown != 10 || d.sweepTipBps != 0 || d.launchFeeCurrency != HedgeFunFactory.FeeCurrency.Native
                || d.launchFeeAmount != 0.0005 ether
        ) revert BadBook();
        (address oracle, address pool, uint256 opening, bool enabled) = b.factory.listings(b.stock);
        if (!enabled || oracle.code.length == 0 || pool != b.pool || opening != vm.parseJsonUint(json, ".stocks.TSLA.openPriceE18")) {
            revert BadBook();
        }
    }

    function _sender(address expected) private view {
        if (msg.sender != expected) revert WrongSender(msg.sender);
    }

    function _nonce() private view returns (uint96) {
        uint256 value = vm.envUint("JOURNEY_NONCE");
        if (value > type(uint96).max) revert BadAmount(value);
        return uint96(value);
    }

    function _inspect(Book memory b, uint256 id) private view {
        address token = _strategyAny(b, id);
        address creator = _creator();
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(b.factory.curves(id));
        console2.log("strategy id", id);
        console2.log("strategy token", token);
        console2.log("curve", address(curve));
        console2.log("treasury", curve.treasury());
        console2.log("curve status (0 active, 2 graduated)", uint256(curve.status()));
        console2.log("curve tax bps / creator share bps", uint256(curve.taxBps()), uint256(curve.creatorBps()));
        console2.log("creator tUSDG", b.usdg.balanceOf(creator));
        console2.log("creator TSLA", IERC20(b.stock).balanceOf(creator));
        console2.log("creator strategy tokens", IERC20(token).balanceOf(creator));
        console2.log("curve real stock reserve", curve.realStockReserve());
        console2.log("curve unpaid stock fees", curve.totalFees());
        console2.log("curve protocol claim", curve.claimable(PROTOCOL));
        console2.log("curve creator claim", curve.claimable(creator));
        console2.log("curve treasury claim", curve.claimable(curve.treasury()));
        if (uint8(curve.status()) == 2) _inspectGraduated(b, id);
    }

    function _inspectGraduated(Book memory b, uint256 id) private view {
        (PoolKey memory key,) = b.factory.graduationConfig(id);
        PoolId pid = key.toId();
        (uint256 inToken, uint256 inStock) = b.hook.accrued(pid);
        console2.log("hook accrued token claims (always 0 on version 3)", inToken);
        console2.log("hook accrued stock claims", inStock);
        console2.log("hook owed protocol", b.hook.owedProtocol(pid));
        console2.log("hook owed creator", b.hook.owedCreator(pid));
        console2.log("hook owed treasury", b.hook.owedTreasury(pid));
        console2.log("hook shared-stock total owed", b.hook.totalOwed(b.stock));
        HedgeFunV2Treasury t = _treasury(b, id);
        console2.log("treasury booked stock", t.bookedStock());
        console2.log("treasury unbooked stock", t.unbookedStock());
        console2.log("treasury buy-back budget (stock)", t.buybackStock());
        console2.log("treasury strategy tokens", IERC20(_strategyAny(b, id)).balanceOf(address(t)));
        console2.log("vault", address(_vault(b, id)));
    }
}
