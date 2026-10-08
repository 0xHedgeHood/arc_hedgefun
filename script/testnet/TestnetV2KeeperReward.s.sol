// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunFactory} from "../../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunV2Treasury} from "../../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunV2EngineTreasury, HedgeFunV2EngineTreasuryCore} from "../../src/v2/HedgeFunV2EngineTreasury.sol";
import {HedgeFunBondingCurve} from "../../src/v2/HedgeFunBondingCurve.sol";
import {V2TreasuryDeployer, V2InitCodeChunk} from "../../src/v2/V2TreasuryDeployer.sol";
import {EngineConfig, PolicyManifest, StrategyAction} from "../../src/v2/strategy/IStrategyPolicy.sol";

/// @notice Append one immutable Engine to the already deployed fee core, then exercise two independent strategies.
///         Contains no keys. A phase is simulated unless the human operator explicitly supplies --broadcast.
///         Console candidates and local checks are NOT canonical published proof; audit actual receipts separately.
contract TestnetV2KeeperReward is Script {
    address public constant OPERATOR = 0x75Cee941B0eF3A83feA0397BbF903C12c1D7e96D;
    address public constant CREATOR = 0xD4f69D180a9bc36F27D307E90E365d1E012816d5;
    address public constant SECOND = 0xdA1AEE7018a3925AA06dEEb8631Fca09E1067614;
    address public constant FACTORY = 0xACEB03aAeE5494Aa54929Ec840630ae32A9ade0A;
    address public constant REGISTRY = 0xe874fE425e14f3CBa3aDBA2Dd10B50E153Ac6064;
    address private constant HOOK = 0xF1b4C95B63091AE2eb68E640F6D9485982146844;
    address private constant CURVE_DEPLOYER = 0x0D73f6bd43D3937e4b07c70bfFC53A8c25d3C1CA;
    address private constant USDG = 0x539574139BB4Ac74Fd2183ba0E38ed777E30B58d;
    address private constant TSLA = 0xcee322837F181Bd93AC2d71e4dDf334BFF565b98;
    address private constant POOL = 0x04083643FF9E8c27f66C9dD99947743A9B777244;
    address private constant ORACLE = 0x5001C9C8b278425129C36C8099520aBAA70aa4ae;
    address private constant POLICY = 0xdc50b270563e59bf419A8114f8bDD41d91002FD7;
    address private constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    bytes32 public constant OLD_ENGINE_HASH = 0x67d0657c52fdd7fbe540435539f44a46caa159e82b2c74a91cb7c8b1a3db151f;
    bytes32 private constant POLICY_KEY = 0x6df0736dd5b12a748f565df86c35d2a8f8be75af863d1fec939d39e68b4dc083;
    string public constant CORE_SOURCE = "698e577048fde8681d9263f32a653d5176f888e5";
    uint8 public constant REWARD_KIND = 3;
    uint96 public constant SELL_NONCE = 202609300108;
    uint96 public constant BUY_NONCE = 202609300109;
    uint256 public constant CURVE_OFFER = 24e18;
    uint256 public constant BUY_SEED = 10_000e6;
    bytes32 private constant EXECUTED = keccak256("StrategyExecuted(uint64,uint8,uint256,uint256,uint256,uint256,uint256,bytes32)");
    bytes32 private constant REWARD = keccak256("KeeperRewardPaid(uint64,address,address,uint256)");

    struct Snapshot {
        uint256 stock;
        uint256 usdg;
        uint256 keeperStock;
        uint256 keeperUsdg;
        uint256 booked;
        uint256 buyback;
        uint256 avgCost;
        uint64 nonce;
        uint256 turnover;
        uint256 last;
        bytes32 state;
    }
    struct Execution {
        uint256 input;
        uint256 grossOutput;
        uint256 price;
        uint256 turnover;
        uint256 reward;
        bytes32 state;
    }

    error WrongChain(uint256 actual);
    error WrongSender(address actual);
    error BadBinding();
    error BadStage();
    error BadAccounting();
    error BadFriction();

    function appendEngine() external {
        _sender(OPERATOR);
        (HedgeFunV2Factory f, V2TreasuryDeployer r) = _core();
        if (r.kindCount() != 3 || f.strategyCount() != 1) revert BadStage();
        string memory revision = _revision();
        bytes memory creation = type(HedgeFunV2EngineTreasury).creationCode;
        if (keccak256(creation) == OLD_ENGINE_HASH) revert BadBinding();
        uint256 start = block.number;
        vm.startBroadcast(OPERATOR);
        // CREATE originates from the fixed owner EOA, whose nonce third parties cannot consume.
        // Public registry.makeChunks is unsuitable for precomputed register calldata: anyone can race its nonce.
        uint256 half = creation.length / 2;
        address a = address(new V2InitCodeChunk(_slice(creation, 0, half)));
        address b = address(new V2InitCodeChunk(_slice(creation, half, creation.length - half)));
        uint8 kind = r.registerEngineKind(a, b, 1, 1, 3);
        vm.stopBroadcast();
        if (kind != REWARD_KIND) revert BadBinding();
        _rewardKind(r);
        _candidate(a, b, start, revision);
    }

    function _slice(bytes memory src, uint256 offset, uint256 len) private pure returns (bytes memory part) {
        part = new bytes(len);
        assembly ("memory-safe") { mcopy(add(part, 0x20), add(add(src, 0x20), offset), len) }
    }

    function _candidate(address a, address b, uint256 start, string memory revision) private view {
        // Always a candidate, including when a subsequent operator chooses --broadcast.
        string memory candidate = string.concat(
            "KEEPER_REWARD_CANDIDATE {\"schema\":\"v2-execute-keeper-reward-candidate-v1\",\"chainId\":46630,\"broadcast\":false,\"verified\":false,\"coreSourceCommit\":\"", CORE_SOURCE,
            "\",\"rewardSourceCommit\":\"", revision, "\",\"factory\":\"", vm.toString(FACTORY));
        candidate = string.concat(candidate,
            "\",\"registry\":\"", vm.toString(REGISTRY), "\",\"operator\":\"", vm.toString(OPERATOR),
            "\",\"kind\":3,\"engineVersion\":1,\"configSchema\":1,\"capabilities\":\"3\",\"previousEngineCreationHash\":\"", vm.toString(OLD_ENGINE_HASH));
        candidate = string.concat(candidate,
            "\",\"creationCodeHash\":\"", vm.toString(keccak256(type(HedgeFunV2EngineTreasury).creationCode)), "\",\"chunkA\":\"", vm.toString(a),
            "\",\"chunkB\":\"", vm.toString(b), "\",\"policyKey\":\"", vm.toString(POLICY_KEY));
        candidate = string.concat(candidate,
            "\",\"blockNumber\":", vm.toString(start), ",\"sellSymbol\":\"HFKSELL\",\"sellNonce\":\"202609300108\",\"buySymbol\":\"HFKBUY\",\"buyNonce\":\"202609300109\"}"
        );
        console2.log(candidate);
    }

    function launchSell() external returns (uint256) { return _launch(false); }
    function launchBuy() external returns (uint256) { return _launch(true); }
    function graduateSell() external { _graduate(false); }
    function graduateBuy() external { _graduate(true); }
    function executeSell() external { _execute(false, SECOND); }
    function executeBuy() external { _execute(true, OPERATOR); }

    function _launch(bool buy) private returns (uint256 id) {
        _sender(CREATOR);
        (HedgeFunV2Factory f, V2TreasuryDeployer r) = _core();
        _rewardKind(r);
        if (f.strategyCount() != (buy ? 2 : 1)) revert BadStage();
        HedgeFunFactory.Request memory q = _request(buy, f);
        if (IERC20(USDG).balanceOf(CREATOR) < q.maxFee + (buy ? BUY_SEED : 0)) revert BadStage();
        vm.startBroadcast(CREATOR);
        r.setEngineConfig(q.symbol, q.nonce, REWARD_KIND, _config());
        f.curveDeployer().setCurveConfig(q.symbol, q.nonce, 4400, 180);
        vm.stopBroadcast();
        (address token, address treasury, bytes32 terms) = f.predict(q);
        if (token.code.length != 0 || treasury.code.length != 0) revert BadStage();
        vm.startBroadcast(CREATOR);
        _approve(IERC20(USDG), FACTORY, q.maxFee);
        id = f.launch(q, terms);
        if (buy && !IERC20(USDG).transfer(treasury, BUY_SEED)) revert BadAccounting();
        vm.stopBroadcast();
        if (id != (buy ? 2 : 1)) revert BadBinding();
        (address actualToken, address actualTreasury,,,) = f.strategies(id);
        if (actualToken != token || actualTreasury != treasury) revert BadBinding();
        _strategy(buy);
        console2.log("keeper strategy id", id);
        console2.log("keeper strategy treasury", treasury);
        console2.log("keeper strategy curve", f.curves(id));
        console2.log("seed USDG", buy ? BUY_SEED : 0);
    }

    function _graduate(bool buy) private {
        _sender(CREATOR);
        (HedgeFunV2Factory f,) = _core();
        _strategy(buy);
        uint256 id = buy ? 2 : 1;
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(f.curves(id));
        if (uint8(curve.status()) != 0 || curve.realStockReserve() != 0 || IERC20(TSLA).balanceOf(CREATOR) < CURVE_OFFER) revert BadStage();
        (uint256 spent, uint256 output, uint256 burned) = curve.quoteBuyFor(CURVE_OFFER, CREATOR);
        if (spent == 0 || spent > CURVE_OFFER || output != f.getDefaults().supply * 4400 / 10000 || burned != 0) revert BadAccounting();
        vm.startBroadcast(CREATOR);
        _approve(IERC20(TSLA), address(curve), CURVE_OFFER);
        curve.buy(CURVE_OFFER, output, CREATOR, block.timestamp + 300);
        vm.stopBroadcast();
        if (uint8(curve.status()) != 2) revert BadStage();
        HedgeFunV2EngineTreasury t = _strategy(buy);
        (bool due, StrategyAction action,) = t.preview();
        if (!due || action != (buy ? StrategyAction.BuyStock : StrategyAction.SellStock)) revert BadStage();
        console2.log("graduation gross stock paid", spent);
        console2.log("graduation funded engine stock", t.bookedStock());
        console2.log("engine reserve USDG", t.reserveUsdg());
    }

    function _execute(bool buy, address keeper) private {
        _sender(keeper);
        HedgeFunV2EngineTreasury t = _strategy(buy);
        if (uint8(HedgeFunBondingCurve(HedgeFunV2Factory(FACTORY).curves(buy ? 2 : 1)).status()) != 2 || t.strategyNonce() != 0 || t.unbookedStock() != 0) revert BadStage();
        (bool due, StrategyAction proposed,) = t.preview();
        if (!due || proposed != (buy ? StrategyAction.BuyStock : StrategyAction.SellStock)) revert BadStage();
        Snapshot memory before = _snapshot(t, keeper);
        vm.recordLogs();
        vm.startBroadcast(keeper);
        (HedgeFunV2Treasury.Action action, uint256 nonce) = t.execute();
        vm.stopBroadcast();
        Execution memory e = _execution(vm.getRecordedLogs(), address(t), keeper, buy);
        Snapshot memory after_ = _snapshot(t, keeper);
        if (action != (buy ? HedgeFunV2Treasury.Action.RebalanceBuy : HedgeFunV2Treasury.Action.RebalanceSell) || nonce != 1 || after_.nonce != 1 || after_.last != block.timestamp || after_.state != e.state || e.reward == 0 || e.reward != e.grossOutput * 50 / 10000 || e.turnover < 5e6 || e.turnover > 100e6 || after_.turnover != e.turnover) revert BadAccounting();
        if (buy) {
            uint256 retained = e.grossOutput - e.reward;
            if (after_.stock - before.stock != retained || after_.booked - before.booked != retained || after_.keeperStock - before.keeperStock != e.reward || after_.keeperUsdg != before.keeperUsdg || before.usdg - after_.usdg != e.input || after_.buyback != before.buyback || e.turnover != e.input) revert BadAccounting();
            if (after_.avgCost != Math.ceilDiv(before.booked * before.avgCost + e.input * 1e30, before.booked + retained)) revert BadAccounting();
        } else {
            uint256 gainToBuyback = after_.buyback - before.buyback;
            if (before.stock - after_.stock != e.input || before.booked - after_.booked != e.input + gainToBuyback || after_.usdg - before.usdg != e.grossOutput - e.reward || after_.keeperUsdg - before.keeperUsdg != e.reward || after_.keeperStock != before.keeperStock || after_.avgCost != before.avgCost || e.turnover != Math.mulDiv(e.input + gainToBuyback, e.price, 1e30)) revert BadAccounting();
        }
        if (after_.booked + after_.buyback != after_.stock || t.turnoverEpoch() != t.tradingCalendar().tradingDate(block.timestamp)) revert BadAccounting();
        // This call is local simulation after stopBroadcast: a reverted transaction is never scheduled.
        vm.prank(keeper);
        (bool ok, bytes memory reason) = address(t).call(abi.encodeCall(HedgeFunV2EngineTreasuryCore.execute, ()));
        bytes4 selector;
        if (reason.length >= 4) assembly ("memory-safe") { selector := mload(add(reason, 32)) }
        // The fixed policy returns Hold during cooldown, yielding NotDue; the core also enforces Cooldown.
        if (ok || (selector != HedgeFunTreasuryBase.NotDue.selector && selector != HedgeFunTreasuryBase.Cooldown.selector) || keccak256(abi.encode(_snapshot(t, keeper))) != keccak256(abi.encode(after_))) revert BadAccounting();
        console2.log("keeper reward executor", keeper);
        console2.log("keeper reward asset", buy ? TSLA : USDG);
        console2.log("gross swap output", e.grossOutput);
        console2.log("keeper actual reward", e.reward);
        console2.log("net treasury output", e.grossOutput - e.reward);
        console2.log("actual input", e.input);
        console2.log("actual turnover USDG", e.turnover);
        console2.log("average cost after", after_.avgCost);
        console2.log("cooldown probe (read-only, not a failed broadcast)", vm.toString(reason));
    }

    function _execution(Vm.Log[] memory logs, address treasury, address keeper, bool buy) private pure returns (Execution memory e) {
        uint256 actions;
        uint256 rewards;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != treasury || l.topics.length == 0) continue;
            if (l.topics[0] == EXECUTED) {
                if (l.topics.length != 3 || uint256(l.topics[1]) != 1 || uint256(l.topics[2]) != uint256(buy ? StrategyAction.BuyStock : StrategyAction.SellStock)) revert BadAccounting();
                (, e.input, e.grossOutput, e.price, e.turnover, e.state) = abi.decode(l.data, (uint256, uint256, uint256, uint256, uint256, bytes32));
                ++actions;
            }
            if (l.topics[0] == REWARD) {
                if (l.topics.length != 4 || uint256(l.topics[1]) != 1 || address(uint160(uint256(l.topics[2]))) != keeper || address(uint160(uint256(l.topics[3]))) != (buy ? TSLA : USDG)) revert BadAccounting();
                e.reward = abi.decode(l.data, (uint256));
                ++rewards;
            }
        }
        if (actions != 1 || rewards != 1) revert BadAccounting();
    }

    function _snapshot(HedgeFunV2EngineTreasury t, address keeper) private view returns (Snapshot memory s) {
        s.stock = IERC20(TSLA).balanceOf(address(t)); s.usdg = IERC20(USDG).balanceOf(address(t));
        s.keeperStock = IERC20(TSLA).balanceOf(keeper); s.keeperUsdg = IERC20(USDG).balanceOf(keeper);
        s.booked = t.bookedStock(); s.buyback = t.buybackStock(); s.avgCost = t.avgCost();
        s.nonce = t.strategyNonce(); s.turnover = t.turnoverInEpoch(); s.last = t.lastStrategyAt(); s.state = t.policyState();
    }

    function _strategy(bool buy) private view returns (HedgeFunV2EngineTreasury t) {
        (HedgeFunV2Factory f, V2TreasuryDeployer r) = _core();
        _rewardKind(r);
        uint256 id = buy ? 2 : 1;
        if (f.strategyCount() <= id) revert BadStage();
        (address token, address treasury, address hook, address stock, address creator) = f.strategies(id);
        HedgeFunFactory.Request memory q = _request(buy, f);
        (address predictedToken, address predictedTreasury,) = f.predict(q);
        if (token != predictedToken || treasury != predictedTreasury || hook != HOOK || stock != TSLA || creator != CREATOR) revert BadBinding();
        t = HedgeFunV2EngineTreasury(treasury);
        EngineConfig memory c = t.engineConfig();
        if (t.engineVersion() != 1 || t.policyImplementation() != POLICY || t.strategyId() != POLICY_KEY || c.schema != 1 || c.engineVersion != 1 || c.policyKey != POLICY_KEY || keccak256(abi.encode(c.words)) != keccak256(abi.encode(_config().words)) || t.payoutBps() != 5000 || t.params().bountyBps != 50 || t.factory() != FACTORY || address(t.stock()) != TSLA || address(t.usdg()) != USDG) revert BadBinding();
    }

    function _config() private pure returns (EngineConfig memory c) {
        c.schema = 1; c.engineVersion = 1; c.policyKey = POLICY_KEY;
        c.words[0] = bytes32(uint256(5000) | uint256(500) << 16 | uint256(600) << 32 | uint256(5000) << 64);
        c.words[1] = bytes32(uint256(100e6)); c.words[2] = bytes32(uint256(500e6));
    }

    function _request(bool buy, HedgeFunV2Factory f) private view returns (HedgeFunFactory.Request memory q) {
        q.name = buy ? "Keeper reward buy proof" : "Keeper reward sell proof";
        q.symbol = buy ? "HFKBUY" : "HFKSELL"; q.nonce = buy ? BUY_NONCE : SELL_NONCE;
        q.stock = TSLA; q.creator = CREATOR; q.taxBps = 300; q.creatorBps = 1000;
        q.tp1Bps = 300; q.tp2Bps = 600; q.dipBps = 500; q.stopBps = 0; q.lotBps = 2000;
        q.maxFee = 25e6; (,, q.expectedOpenPriceE18,) = f.listings(TSLA);
    }

    /// @notice Fail before any broadcast; the old registry does not know this reward-inclusive floor.
    function checkFriction(uint256 slippage, uint256 poolFeeBps, uint256 bounty) public pure {
        if (500 < 2 * (slippage + poolFeeBps + bounty)) revert BadFriction();
    }

    function _core() private view returns (HedgeFunV2Factory f, V2TreasuryDeployer r) {
        if (block.chainid != 46630) revert WrongChain(block.chainid);
        if (FACTORY.codehash != 0xfcd24dc65ea80198523d9b598a03f674f6827376764ee4752dd305cabfaff3c9 || REGISTRY.codehash != 0xeee8d529ac295493cb7b872513cb84f7edfdbfb71f69a364a9ed921a93f52b56 || HOOK.codehash != 0x8652526ce215d12e16ff5e523ec2fcb45a295b3cb2ce3fbbe7d4cc30c039e6c1 || CURVE_DEPLOYER.codehash != 0x4b359a6e47faa6e674c4dd691e327ebec10d34d874036be4fdd32c179a2bd74b) revert BadBinding();
        f = HedgeFunV2Factory(FACTORY); r = V2TreasuryDeployer(REGISTRY);
        if (f.owner() != OPERATOR || f.protocol() != OPERATOR || address(f.treasuryDeployer()) != REGISTRY || r.factory() != FACTORY || address(f.curveDeployer()) != CURVE_DEPLOYER || address(f.hook()) != HOOK || address(f.poolManager()) != PM || f.usdg() != USDG || !f.publicLaunch()) revert BadBinding();
        (address oracle, address pool, uint256 opening, bool enabled) = f.listings(TSLA);
        if (!enabled || oracle != ORACLE || pool != POOL || opening != 26500000000) revert BadBinding();
        PolicyManifest memory m = r.policy(POLICY_KEY);
        if (m.implementation != POLICY || m.runtimeCodeHash != 0x703c92e4d169643e9b20eadf00cd53470b95699186a5ce9131feee42299c0b74 || POLICY.codehash != m.runtimeCodeHash || !m.enabledForNewLaunches || m.engineVersion != 1 || m.configSchema != 1 || m.capabilities != 3 || m.maxGas != 150000 || m.maxReturnBytes != 160) revert BadBinding();
        bytes32[3] memory hashes = [bytes32(0xaec5bc5cdaeef801f738c564cc0aca2f1d4405a38e218d4cad9ad66ccc810b93), bytes32(0x20d84b868ef45cf6a4fa3f11d90432fa8b6e8d375edcfd668856770b12199720), OLD_ENGINE_HASH];
        for (uint8 i; i < 3; ++i) {
            (uint32 v, uint32 schema, bytes32 h, uint256 caps) = r.kindManifest(i);
            (address a, address b) = r.kinds(i);
            if (h != hashes[i] || keccak256(bytes.concat(a.code, b.code)) != h || v != (i == 2 ? 1 : 0) || schema != (i == 2 ? 1 : 0) || caps != (i == 2 ? 3 : 0)) revert BadBinding();
        }
        HedgeFunFactory.Defaults memory d = f.getDefaults();
        if (d.supply != 1e9 * 1e18 || d.protocolBps != 2000 || d.bountyBps != 50 || d.sweepTipBps != 0 || d.launchFeeCurrency != HedgeFunFactory.FeeCurrency.Usdg || d.launchFeeAmount != 25e6) revert BadBinding();
        (, uint16 slip,) = f.listingGates(TSLA);
        if (slip == 0) slip = d.maxSlippageBps;
        // The pinned TSLA venue is 3000 millionths (30 basis points).
        checkFriction(slip, 30, d.bountyBps);
    }

    function _rewardKind(V2TreasuryDeployer r) private view {
        if (r.kindCount() != 4) revert BadStage();
        (uint32 version, uint32 schema, bytes32 h, uint256 caps) = r.kindManifest(REWARD_KIND);
        (address a, address b) = r.kinds(REWARD_KIND);
        if (version != 1 || schema != 1 || caps != 3 || h != keccak256(type(HedgeFunV2EngineTreasury).creationCode) || keccak256(bytes.concat(a.code, b.code)) != h) revert BadBinding();
    }

    function _approve(IERC20 asset, address spender, uint256 amount) private {
        if (asset.allowance(CREATOR, spender) < amount && !asset.approve(spender, amount)) revert BadAccounting();
    }
    function _sender(address expected) private view { if (msg.sender != expected) revert WrongSender(msg.sender); }
    function _revision() private view returns (string memory revision) {
        revision = vm.envString("GIT_COMMIT"); bytes memory value = bytes(revision);
        if (value.length != 40) revert BadBinding();
        for (uint256 i; i < value.length; ++i) if (!((value[i] >= 0x30 && value[i] <= 0x39) || (value[i] >= 0x61 && value[i] <= 0x66))) revert BadBinding();
    }
}
