// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {HedgeFunFactory} from "../../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunV2Treasury} from "../../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunV2AllInTreasury} from "../../src/v2/HedgeFunV2AllInTreasury.sol";
import {HedgeFunBondingCurve} from "../../src/v2/HedgeFunBondingCurve.sol";
import {V2TreasuryDeployer, V2InitCodeChunk} from "../../src/v2/V2TreasuryDeployer.sol";
import {V2CreatorParams} from "../../src/v2/strategy/V2CreatorParams.sol";

/// @notice Optional ordinary strategy append on the existing testnet fee core, with creator-selected TP/dip.
/// @dev No keys or password paths. Forge is a simulation unless an operator supplies --broadcast.
///      Old core, kinds and strategies stay immutable. Console output is candidate data, not receipt proof.
///      The old registry still restricts stop. Full TP/dip/stop freedom requires a fresh core.
contract TestnetV2AllInFloor is Script {
    address public constant OPERATOR = 0x75Cee941B0eF3A83feA0397BbF903C12c1D7e96D;
    address public constant CREATOR = 0xD4f69D180a9bc36F27D307E90E365d1E012816d5;
    address public constant FACTORY = 0xACEB03aAeE5494Aa54929Ec840630ae32A9ade0A;
    address public constant REGISTRY = 0xe874fE425e14f3CBa3aDBA2Dd10B50E153Ac6064;
    address private constant HOOK = 0xF1b4C95B63091AE2eb68E640F6D9485982146844;
    address private constant CURVE_DEPLOYER = 0x0D73f6bd43D3937e4b07c70bfFC53A8c25d3C1CA;
    address private constant USDG = 0x539574139BB4Ac74Fd2183ba0E38ed777E30B58d;
    address private constant TSLA = 0xcee322837F181Bd93AC2d71e4dDf334BFF565b98;
    address private constant ORACLE = 0x5001C9C8b278425129C36C8099520aBAA70aa4ae;
    address private constant POOL = 0x04083643FF9E8c27f66C9dD99947743A9B777244;
    uint8 public constant ALL_IN_KIND = 4;
    uint96 public constant NONCE = 202609300310;
    uint256 public constant STRATEGY_ID = 3;
    uint256 public constant CURVE_OFFER = 24e18;

    error WrongChain(uint256 actual);
    error WrongSender(address actual);
    error BadBinding();
    error BadStage();
    error BadAccounting();

    function appendPlain() external {
        _sender(OPERATOR);
        (, V2TreasuryDeployer r) = _core();
        if (r.kindCount() != ALL_IN_KIND) revert BadStage();
        string memory revision = _revision();
        bytes memory code = type(HedgeFunV2AllInTreasury).creationCode;
        uint256 half = code.length / 2;
        vm.startBroadcast(OPERATOR);
        address a = address(new V2InitCodeChunk(_slice(code, 0, half)));
        address b = address(new V2InitCodeChunk(_slice(code, half, code.length - half)));
        uint8 kind = r.registerKind(a, b);
        vm.stopBroadcast();
        if (kind != ALL_IN_KIND) revert BadBinding();
        _plainKind(r);
        console2.log("ALL_IN_FLOOR_CANDIDATE broadcast=false verified=false source", revision);
        console2.log("kind", kind);
        console2.log("chunkA", a);
        console2.log("chunkB", b);
        console2.log("creationCodeHash", vm.toString(keccak256(code)));
    }

    function launchPlain() external returns (uint256 id) {
        _sender(CREATOR);
        (HedgeFunV2Factory f, V2TreasuryDeployer r) = _core();
        _plainKind(r);
        if (f.strategyCount() != STRATEGY_ID) revert BadStage();
        HedgeFunFactory.Request memory q = _request(f);
        if (IERC20(USDG).balanceOf(CREATOR) < q.maxFee) revert BadStage();
        checkParameters(q.tp1Bps, q.tp2Bps, q.dipBps, q.stopBps);
        vm.startBroadcast(CREATOR);
        r.setStrategyKind(q.symbol, q.nonce, ALL_IN_KIND);
        f.curveDeployer().setCurveConfig(q.symbol, q.nonce, 4400, 0);
        vm.stopBroadcast();
        (address token, address treasury, bytes32 terms) = f.predict(q);
        if (token.code.length != 0 || treasury.code.length != 0) revert BadStage();
        uint256 beforeCash = IERC20(USDG).balanceOf(CREATOR);
        uint256 beforeProtocol = IERC20(USDG).balanceOf(OPERATOR);
        vm.recordLogs();
        vm.startBroadcast(CREATOR);
        if (IERC20(USDG).allowance(CREATOR, FACTORY) < q.maxFee && !IERC20(USDG).approve(FACTORY, q.maxFee)) revert BadAccounting();
        id = f.launch(q, terms);
        vm.stopBroadcast();
        if (id != STRATEGY_ID || beforeCash - IERC20(USDG).balanceOf(CREATOR) != q.maxFee
            || IERC20(USDG).balanceOf(OPERATOR) - beforeProtocol != q.maxFee) revert BadAccounting();
        (address actualToken, address actualTreasury,,,) = f.strategies(id);
        if (actualToken != token || actualTreasury != treasury) revert BadBinding();
        _bound(vm.getRecordedLogs(), treasury);
        console2.log("strategy id", id);
        console2.log("treasury", treasury);
        console2.log("token", token);
        console2.log("curve", f.curves(id));
    }

    function graduatePlain() external {
        _sender(CREATOR);
        (HedgeFunV2Factory f, V2TreasuryDeployer r) = _core();
        _plainKind(r);
        if (f.strategyCount() != STRATEGY_ID + 1) revert BadStage();
        (address token,address treasury,,address stock,address creator) = f.strategies(STRATEGY_ID);
        HedgeFunFactory.Request memory q = _request(f);
        (address predictedToken, address predictedTreasury,) = f.predict(q);
        if (token != predictedToken || treasury != predictedTreasury || f.curves(STRATEGY_ID) != f.predictCurve(q)) revert BadBinding();
        if (stock != TSLA || creator != CREATOR || keccak256(bytes(IERC20Metadata(token).symbol())) != keccak256("HFSTEADY")
            || HedgeFunV2Treasury(treasury).params().tp1Bps != 1 || HedgeFunV2Treasury(treasury).params().dipBps != 1) revert BadBinding();
        HedgeFunBondingCurve c = HedgeFunBondingCurve(f.curves(STRATEGY_ID));
        if (uint8(c.status()) != 0 || c.realStockReserve() != 0 || IERC20(TSLA).balanceOf(CREATOR) < CURVE_OFFER) revert BadStage();
        (uint256 spent, uint256 output, uint256 burned) = c.quoteBuyFor(CURVE_OFFER, CREATOR);
        if (spent == 0 || spent > CURVE_OFFER || output != f.getDefaults().supply * 4400 / 10000 || burned != 0) revert BadAccounting();
        vm.startBroadcast(CREATOR);
        if (IERC20(TSLA).allowance(CREATOR,address(c)) < CURVE_OFFER && !IERC20(TSLA).approve(address(c), CURVE_OFFER)) revert BadAccounting();
        c.buy(CURVE_OFFER, output, CREATOR, block.timestamp + 300);
        vm.stopBroadcast();
        HedgeFunV2Treasury t = HedgeFunV2Treasury(treasury);
        if (uint8(c.status()) != 2 || t.bookedStock() == 0 || t.bookedStock() + t.buybackStock() != IERC20(TSLA).balanceOf(treasury)) revert BadAccounting();
        console2.log("graduated principal stock", t.bookedStock());
    }

    function checkParameters(uint256 tp1, uint256 tp2, uint256 dip, uint256 stop) public pure {
        V2CreatorParams.validate(tp1, tp2, dip, stop);
    }

    function _bound(Vm.Log[] memory logs, address treasury) private view {
        uint256 matches;
        bytes32 topic = keccak256("TreasuryCodeBound(address,uint8,bytes32,bytes32,bytes32)");
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != REGISTRY || l.topics.length == 0 || l.topics[0] != topic) continue;
            if (l.topics.length != 3 || address(uint160(uint256(l.topics[1]))) != treasury || uint256(l.topics[2]) != ALL_IN_KIND) revert BadBinding();
            (bytes32 initHash, bytes32 runtimeHash, bytes32 configHash) = abi.decode(l.data,(bytes32,bytes32,bytes32));
            if (initHash == bytes32(0) || runtimeHash != treasury.codehash || configHash != bytes32(0)) revert BadBinding();
            ++matches;
        }
        if (matches != 1) revert BadBinding();
    }

    function _core() private view returns (HedgeFunV2Factory f, V2TreasuryDeployer r) {
        if (block.chainid != 46630) revert WrongChain(block.chainid);
        if (FACTORY.codehash != 0xfcd24dc65ea80198523d9b598a03f674f6827376764ee4752dd305cabfaff3c9
            || REGISTRY.codehash != 0xeee8d529ac295493cb7b872513cb84f7edfdbfb71f69a364a9ed921a93f52b56
            || HOOK.codehash != 0x8652526ce215d12e16ff5e523ec2fcb45a295b3cb2ce3fbbe7d4cc30c039e6c1
            || CURVE_DEPLOYER.codehash != 0x4b359a6e47faa6e674c4dd691e327ebec10d34d874036be4fdd32c179a2bd74b) revert BadBinding();
        f = HedgeFunV2Factory(FACTORY); r = V2TreasuryDeployer(REGISTRY);
        if (f.owner() != OPERATOR || f.protocol() != OPERATOR || address(f.treasuryDeployer()) != REGISTRY
            || address(f.curveDeployer()) != CURVE_DEPLOYER || address(f.hook()) != HOOK
            || r.factory() != FACTORY || f.usdg() != USDG || !f.publicLaunch()) revert BadBinding();
        bytes32[4] memory old = [bytes32(0xaec5bc5cdaeef801f738c564cc0aca2f1d4405a38e218d4cad9ad66ccc810b93),
            bytes32(0x20d84b868ef45cf6a4fa3f11d90432fa8b6e8d375edcfd668856770b12199720),
            bytes32(0x67d0657c52fdd7fbe540435539f44a46caa159e82b2c74a91cb7c8b1a3db151f),
            bytes32(0x21db9a11b19dfe73eb5e372972f0dc7057595360c989d92012ba4b638e0d271f)];
        for (uint8 i; i < 4; ++i) {
            (uint32 version, uint32 schema, bytes32 hash, uint256 caps) = r.kindManifest(i);
            (address a, address b) = r.kinds(i);
            if (hash != old[i] || keccak256(bytes.concat(a.code,b.code)) != hash
                || version != (i < 2 ? 0 : 1) || schema != (i < 2 ? 0 : 1) || caps != (i < 2 ? 0 : 3)) revert BadBinding();
        }
        (address oracle, address pool, uint256 opening, bool listed) = f.listings(TSLA);
        (,uint16 slip,) = f.listingGates(TSLA);
        HedgeFunFactory.Defaults memory d = f.getDefaults();
        if (!listed || oracle != ORACLE || pool != POOL || opening != 26500000000 || slip != 100 || d.bountyBps != 50 || d.supply != 1e27
            || d.launchFeeCurrency != HedgeFunFactory.FeeCurrency.Usdg || d.launchFeeAmount != 25e6) revert BadBinding();
    }

    function _plainKind(V2TreasuryDeployer r) private view {
        if (r.kindCount() != ALL_IN_KIND + 1) revert BadStage();
        (uint32 version, uint32 schema, bytes32 hash, uint256 caps) = r.kindManifest(ALL_IN_KIND);
        (address a, address b) = r.kinds(ALL_IN_KIND);
        if (version != 0 || schema != 0 || caps != 0 || hash != keccak256(type(HedgeFunV2AllInTreasury).creationCode)
            || keccak256(bytes.concat(a.code,b.code)) != hash) revert BadBinding();
    }

    function _request(HedgeFunV2Factory f) private view returns (HedgeFunFactory.Request memory q) {
        q.name = "TSLA Steady"; q.symbol = "HFSTEADY"; q.stock = TSLA; q.creator = CREATOR;
        q.taxBps = 300; q.creatorBps = 1000; q.tp1Bps = 1; q.tp2Bps = 2; q.dipBps = 1;
        q.lotBps = 2000; q.nonce = NONCE; q.maxFee = 25e6; (,,q.expectedOpenPriceE18,) = f.listings(TSLA);
    }
    function _slice(bytes memory code, uint256 offset, uint256 length) private pure returns (bytes memory part) {
        part = new bytes(length);
        assembly ("memory-safe") { mcopy(add(part,0x20), add(add(code,0x20),offset), length) }
    }
    function _sender(address expected) private view { if (msg.sender != expected) revert WrongSender(msg.sender); }
    function _revision() private view returns (string memory revision) {
        revision = vm.envString("GIT_COMMIT"); bytes memory v = bytes(revision);
        if (v.length != 40) revert BadBinding();
        for (uint256 i; i < v.length; ++i) if (!((v[i] >= 0x30 && v[i] <= 0x39) || (v[i] >= 0x61 && v[i] <= 0x66))) revert BadBinding();
    }
}
