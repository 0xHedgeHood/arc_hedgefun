// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {HedgeFunFactory, TreasuryDeployer, TokenDeployer} from "../../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {CurveDeployer} from "../../src/v2/CurveDeployer.sol";
import {V2TreasuryDeployer} from "../../src/v2/V2TreasuryDeployer.sol";
import {HedgeFunBondingCurve} from "../../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunHook} from "../../src/hooks/HedgeFunHook.sol";
import {HedgeFunV2Hook} from "../../src/hooks/HedgeFunV2Hook.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {HedgeFunTreasuryBase} from "../../src/HedgeFunTreasuryBase.sol";
import {MockToken, MockFeed, MockV3Factory, MockLpPool, AlwaysOpen} from "../mocks/Mocks.sol";
import {HookMiner} from "./HookMiner.sol";

contract GraduationStock is MockToken {
    address public blockedRecipient;
    address public taxedSender;
    constructor(uint8 decimals_) MockToken("STOCK", decimals_) {}
    function blockRecipient(address recipient) external { blockedRecipient = recipient; }
    function taxSender(address sender) external { taxedSender = sender; }
    function _update(address from, address to, uint256 amount) internal virtual override {
        require(to != blockedRecipient || to == address(0), "blocked recipient");
        super._update(from, to, amount);
        if (from == taxedSender && from != address(0)) super._update(from, address(0), 1);
    }
}

/// @dev Genuine PoolManager, production hook and factory; only the external stock/USDG venue and feeds are mocked.
abstract contract V2FactoryFixture is Test, HookMiner {
    IPoolManager internal pm;
    MockToken internal usdg;
    GraduationStock internal stock;
    MockV3Factory internal v3f;
    MockLpPool internal stockPool;
    MockFeed internal stockFeed;
    MockFeed internal usdgFeed;
    PriceOracle internal oracle;
    HedgeFunV2Hook internal hook;
    HedgeFunV2Factory internal factory;
    address internal owner = address(0xA11CE);
    address internal protocol = address(0x5AFE);
    uint256 internal openPrice;
    /// The sale share this fixture's `CurveDeployer` is constructed with, and the window `_launchV2` registers as
    /// the fixture's creator for the salt it launches under (`CurveDeployer.setCurveConfig`). The suites built on
    /// this fixture were written against an 80% sale and a 3-second window; a release deploys 7931. Set
    /// `creatorSaleBps` to 0 BEFORE `_setUpV2` to deploy 7931 and register nothing (the window is `d.snipeSeconds`).
    uint16 internal creatorSaleBps = 8000;
    uint8 internal creatorSnipeSeconds = 3;
    /// the nonce of the last `_launchV2`, whose salt is (`_request().symbol`, this contract, `lastNonce`)
    uint96 internal lastNonce;

    function _setUpV2(uint8 decimals_) internal {
        vm.warp(1_700_000_000);
        pm = IPoolManager(address(new PoolManager(address(this))));
        usdg = new MockToken("USDG", 6);
        stock = new GraduationStock(decimals_);
        stockFeed = new MockFeed(8);
        usdgFeed = new MockFeed(8);
        stockFeed.set(100e8);
        usdgFeed.set(1e8);
        oracle = new PriceOracle(address(stock), address(stockFeed), address(usdgFeed), address(new AlwaysOpen()), 26 hours, 26 hours);
        v3f = new MockV3Factory();
        stockPool = new MockLpPool(address(stock), address(usdg), 3000);
        uint256 scale = 1e18 * 10 ** decimals_ / 1e6;
        stockPool.setSqrt(uint160(Math.sqrt(Math.mulDiv(100e18, 1 << 192, scale))));
        v3f.set(address(stock), address(usdg), 3000, address(stockPool));
        hook = _deployV2Hook(pm);
        factory = new HedgeFunV2Factory(owner, address(pm), address(v3f), address(usdg), protocol,
            address(new V2TreasuryDeployer()), address(new TokenDeployer()), address(hook), address(new CurveDeployer(creatorSaleBps == 0 ? 7931 : creatorSaleBps)), _defaults());
        // CurveDeployer creates its curve-code chunk in its own constructor: every curve address below hashes these bytes.
        assertEq(keccak256(factory.curveDeployer().curveChunk().code), keccak256(type(HedgeFunBondingCurve).creationCode));
        openPrice = 50 * 10 ** decimals_ / 1_000_000;
        vm.startPrank(owner);
        factory.list(address(stock), address(oracle), address(stockPool), openPrice, true);
        factory.setPublicLaunch(true);
        vm.stopPrank();
        stock.mint(address(this), 10_000 * 10 ** decimals_);
    }

    function _defaults() internal pure returns (HedgeFunFactory.Defaults memory d) {
        d.supply = 1_000_000e18;
        d.lpFee = 3000; // 0.30% static V4 fee, collected by the locked V2 liquidity vault.
        d.tickSpacing = 60;
        d.minTaxBps = 100;
        d.maxTaxBps = 1500;
        d.protocolBps = 2000;
        d.maxCreatorBps = 3000;
        d.spikeBps = 9000;
        d.spikeSeconds = 120;
        d.snipeBps = 9900;
        d.snipeSeconds = 3;
        d.sweepTipBps = 0;
        d.bountyBps = 50;
        d.maxSlippageBps = 100;
        d.maxDeviationBps = 50;
        d.maxBuybackImpactBps = 300;
        d.buybackCooldown = 60;
        d.minLotUsdg = 5e6;
        d.buybackChunkUsdg = 500e6;
        d.sellChunkUsdg = type(uint128).max;
    }

    function _request() internal view virtual returns (HedgeFunFactory.Request memory q) {
        q.name = "V2 strategy";
        q.symbol = "V2";
        q.stock = address(stock);
        q.creator = address(this);
        q.taxBps = 1000;
        q.creatorBps = 1000;
        q.tp1Bps = 500;
        q.tp2Bps = 1000;
        q.dipBps = 500;
        q.stopBps = 500;
        q.lotBps = 2000;
        q.maxFee = type(uint256).max;
        q.expectedOpenPriceE18 = openPrice;
    }

    function _launchV2(bool tokenIs0) internal returns (uint256 id, HedgeFunBondingCurve curve, PoolKey memory key) {
        HedgeFunFactory.Request memory q = _request();
        while ((factory.predictToken(q) < address(stock)) != tokenIs0) q.nonce++;
        lastNonce = q.nonce;
        _registerCurve(q);
        address predictedCurve = factory.predictCurve(q);
        (,, bytes32 terms) = factory.predict(q);
        id = factory.launch(q, terms);
        curve = HedgeFunBondingCurve(factory.curves(id));
        assertEq(address(curve), predictedCurve);
        (key,) = factory.graduationConfig(id);
        stock.approve(address(curve), type(uint256).max);
        IERC20(curve.token()).approve(address(curve), type(uint256).max);
        assertEq(uint256(curve.status()), uint256(HedgeFunBondingCurve.Status.Active));
        assertEq(HedgeFunTreasuryBase(curve.treasury()).hook(), address(0));
    }

    /// the creator's curve choices for `q`'s salt; call it after the final nonce is chosen and before `predict`
    function _registerCurve(HedgeFunFactory.Request memory q) internal {
        if (creatorSaleBps != 0) {
            factory.curveDeployer().setCurveConfig(q.symbol, q.nonce, creatorSaleBps, creatorSnipeSeconds);
        }
    }

    function _graduateV2(HedgeFunBondingCurve curve) internal {
        curve.buy(type(uint256).max, 1, address(this), block.timestamp);
        assertEq(uint256(curve.status()), uint256(HedgeFunBondingCurve.Status.Graduated));
    }
}
