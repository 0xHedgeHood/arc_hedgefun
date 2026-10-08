// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunV2ArcFactory} from "../src/v2/arc/HedgeFunV2ArcFactory.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunV2TradeRouter as Router} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {CryptoPriceOracle} from "../src/CryptoPriceOracle.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";
import {ArcCore} from "../script/arc/ArcCore.sol";
import {DeployArcCore} from "../script/arc/DeployArcCore.s.sol";
import {DeployArcOracles} from "../script/arc/DeployArcOracles.s.sol";
import {ListArcCrypto} from "../script/arc/ListArcCrypto.s.sol";
import {ArcAssets} from "../script/arc/ArcAssets.sol";
import {ArcDefaults} from "../script/arc/ArcDefaults.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {EngineConfig} from "../src/v2/strategy/IStrategyPolicy.sol";
import {V2RebalancePolicy} from "../src/v2/strategy/V2RebalancePolicy.sol";
import {LotReserveConfig} from "../src/v2/strategy/V2LotReservePolicy.sol";
import {RegisterV2UpgradeableKinds} from "../script/RegisterV2UpgradeableKinds.s.sol";
import {RegisterV2TradablePercent} from "../script/RegisterV2TradablePercent.s.sol";
import {RegisterV2PercentBuyback} from "../script/RegisterV2PercentBuyback.s.sol";
import {RegisterV2UpgradeableCycle} from "../script/RegisterV2UpgradeableCycle.s.sol";
import {RegisterV2LotReserve} from "../script/RegisterV2LotReserve.s.sol";

/// Answers the Safe probes (2 of 2) and takes native USDC. Stands in for the owner and protocol Safes.
contract ArcForkSafe {
    receive() external payable {}
    function getThreshold() external pure returns (uint256) { return 2; }
    function getOwners() external pure returns (address[] memory o) { o = new address[](2); o[0] = address(1); o[1] = address(2); }
}

/// Moves a V3 pool to a chosen price and pays for it in its callback.
contract ArcForkSwapper {
    using SafeERC20 for IERC20;
    function swapTo(IUniswapV3Pool pool, bool zeroForOne, uint160 limit) external {
        pool.swap(address(this), zeroForOne, type(int128).max, limit, "");
    }
    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        IUniswapV3Pool pool = IUniswapV3Pool(msg.sender);
        if (a0 > 0) IERC20(pool.token0()).safeTransfer(msg.sender, uint256(a0));
        if (a1 > 0) IERC20(pool.token1()).safeTransfer(msg.sender, uint256(a1));
    }
}

/// The whole Arc path on a fork of Arc mainnet: the six-contract core from the deployment script, the cirBTC oracle,
/// the listing, a launch paid in native USDC, curve buys paid in USDC through the real cirBTC/USDC Uniswap V3 pool,
/// graduation into V4, a V4 round trip, and a treasury take-profit sold into the real pool.
///
/// Opt-in, and only under Circle's arc-forge: Arc's USDC moves balances through a native precompile that stock
/// Foundry does not have. `ARC_FORK=true arc-forge test --network arc --match-contract ArcForkTest`; ARC_FORK_BLOCK
/// pins a block. `vm.deal` funds native USDC here, which Arc's ERC-20 view reads as the same balance.
contract ArcForkTest is Test {
    address private constant DEPLOYER = address(0xA11CE);
    address private constant CREATOR = address(0xC0FFEE);
    address private constant BUYER = address(0xB0B);
    address private constant KEEPER = address(0x4EE9E4);
    IERC20 private constant USDC = IERC20(0x3600000000000000000000000000000000000000);

    bool private enabled;
    ArcCore.Deployed private core;
    CryptoPriceOracle private oracle;
    ArcAssets.Asset private btc;
    address private owner;
    address private protocol;

    function setUp() public {
        enabled = vm.envOr("ARC_FORK", false);
        if (!enabled) return;
        uint256 pinned = vm.envOr("ARC_FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork("arc");
        else vm.createSelectFork("arc", pinned);
        btc = ArcAssets.get("cirBTC");
        owner = address(new ArcForkSafe());
        protocol = address(new ArcForkSafe());

        DeployArcCore deployer = new DeployArcCore();
        core = deployer.deploy(DEPLOYER, ArcCore.Roles(owner, protocol), true,
            keccak256(abi.encode(ArcDefaults.release())), ArcDefaults.SALE_BPS, 0);

        string[] memory symbols = new string[](1);
        symbols[0] = "cirBTC";
        DeployArcOracles.Deployed memory o = new DeployArcOracles().deploy(DEPLOYER, owner, address(0), symbols);
        oracle = o.oracles[0];

        ListArcCrypto lister = new ListArcCrypto();
        address[] memory oracles = new address[](1);
        oracles[0] = address(oracle);
        lister.list(core.factory, DEPLOYER, lister.planFor(core.factory, symbols, oracles));
        vm.prank(DEPLOYER);
        core.factory.setPublicLaunch(true);
    }

    function test_listingPricesCirBtcAtTheReferenceOpening() public {
        if (!enabled) { vm.skip(true); return; }
        (address o, address pool, uint256 open, bool live) = core.factory.listings(btc.token);
        assertTrue(live); assertEq(o, address(oracle)); assertEq(pool, btc.pool);
        (bool ok, uint256 p) = oracle.tryPrice();
        assertTrue(ok);
        // 50,000 * 0.2069^2 = $2,140 of opening FDV, in satoshi: within a satoshi of the formula
        uint256 virtualStock = open * 1_000_000_000e18 / 1e36;
        assertApproxEqRel(virtualStock * p / 1e8, 2_140.38e18, 1e15);
        assertGt(open, 1e14, "the 1e36 scale leaves the opening price at least 1e14 units of resolution");
    }

    function test_launchBuyGraduateAndTakeProfitOnArc() public {
        if (!enabled) { vm.skip(true); return; }
        (uint256 id, HedgeFunBondingCurve curve) = _launch();
        vm.warp(block.timestamp + 10);   // past the opening snipe window

        Router router = core.router;
        Router.Hop[] memory usdcToBtc = new Router.Hop[](1);
        usdcToBtc[0] = Router.Hop(btc.pool, btc.token);
        vm.deal(BUYER, 200_000e18);      // native USDC; the ERC-20 view is the same balance
        assertEq(USDC.balanceOf(BUYER), 200_000e6);
        vm.prank(BUYER); USDC.approve(address(router), type(uint256).max);

        // a small buy that stays on the curve
        Router.TradeParams memory p = Router.TradeParams(id, address(USDC), 100e6, 1, 1, block.timestamp + 300, 0, false);
        vm.prank(BUYER); (uint256 got, uint256 refund) = router.buy(p, usdcToBtc);
        assertGt(got, 0); assertEq(refund, 0); assertEq(uint8(curve.status()), 0);

        // a buy larger than what is left: the curve fills to its end, graduates in the same call, refunds cirBTC
        p.amountIn = 20_000e6; p.allowPartialFill = true;
        vm.prank(BUYER); (got, refund) = router.buy(p, usdcToBtc);
        assertGt(got, 0); assertGt(refund, 0); assertEq(uint8(curve.status()), 2, "graduated");
        assertEq(IERC20(btc.token).balanceOf(BUYER), refund);

        HedgeFunV2Treasury t = _treasury(id);
        (bool healthy, uint256 price) = t.health();
        assertTrue(healthy, "the oracle and the real cirBTC pool agree");
        assertApproxEqRel(price, t.spotPrice(), 0.01e18);
        assertGt(t.bookedStock(), 0);

        // graduated: a V4 round trip in USDC through the V3 pool on both ends
        address token = curve.token();
        p = Router.TradeParams(id, address(USDC), 50e6, 1, 1, block.timestamp + 300, 2, false);
        vm.prank(BUYER); (uint256 more,) = router.buy(p, usdcToBtc);
        assertGt(more, 0);
        Router.Hop[] memory btcToUsdc = new Router.Hop[](1);
        btcToUsdc[0] = Router.Hop(btc.pool, address(USDC));
        uint256 usdcBefore = USDC.balanceOf(BUYER);
        vm.prank(BUYER); IERC20(token).approve(address(router), more);
        p.amountIn = more; vm.prank(BUYER); (uint256 proceeds,) = router.sell(p, btcToUsdc);
        assertGt(proceeds, 0); assertEq(USDC.balanceOf(BUYER), usdcBefore + proceeds);

        _takeProfit(t);
    }

    /// Kinds 1 to 6 from the production registration scripts, whose runtime pins accept the Arc factory and curve
    /// deployer on chain 5042; then one launch of every kind on cirBTC, each bought through to graduation in USDC.
    function test_everyKindRegistersOnArcAndGraduatesOnCirBtc() public {
        if (!enabled) { vm.skip(true); return; }
        V2TreasuryDeployer registry = core.treasury;
        HedgeFunV2Factory asV2 = HedgeFunV2Factory(address(core.factory));
        bytes32 deps = keccak256("arc-fork: policy dependencies");
        bytes32 audit = keccak256("arc-fork: policy audit manifest");
        RegisterV2UpgradeableKinds.Kinds memory k = new RegisterV2UpgradeableKinds().register(DEPLOYER, asV2);
        RegisterV2TradablePercent.Registration memory rebalance = new RegisterV2TradablePercent().register(DEPLOYER, asV2, deps, audit);
        uint8 percent = new RegisterV2PercentBuyback().register(DEPLOYER, asV2);
        uint8 cycle = new RegisterV2UpgradeableCycle().register(DEPLOYER, asV2);
        RegisterV2LotReserve.Registration memory reserve = new RegisterV2LotReserve().register(DEPLOYER, asV2, deps, audit);
        assertEq(k.buyback, 1); assertEq(k.engine, 2); assertEq(rebalance.kind, 3); assertEq(percent, 4);
        assertEq(cycle, 5); assertEq(reserve.kind, 6); assertEq(registry.kindCount(), 7);
        address spotPolicy = address(new V2RebalancePolicy());
        vm.prank(DEPLOYER);
        bytes32 spotKey = registry.registerPolicy(spotPolicy, 150_000, 160, deps, audit);

        vm.deal(BUYER, 1_000_000e18);
        vm.prank(BUYER); USDC.approve(address(core.router), type(uint256).max);
        for (uint8 kind; kind < 7; ++kind) {
            HedgeFunFactory.Request memory q = _request(string.concat("HFKIND", vm.toString(kind)), uint96(100 + kind));
            vm.startPrank(CREATOR);
            if (kind == 2) registry.setEngineConfig(q.symbol, q.nonce, kind, _spotConfig(spotKey));
            else if (kind == 3) registry.setEngineConfig(q.symbol, q.nonce, kind, _rebalanceConfig(rebalance.policyKey));
            else if (kind == 6) registry.setEngineConfig(q.symbol, q.nonce, kind, _reserveConfig(reserve.policyKey));
            else if (kind != 0) registry.setStrategyKind(q.symbol, q.nonce, kind);
            vm.stopPrank();
            (uint256 id, HedgeFunBondingCurve curve) = _launch(q);
            assertEq(registry.strategyKindOf(keccak256(abi.encode(q.symbol, CREATOR, q.nonce))), kind);
            vm.warp(block.timestamp + 10);
            Router.Hop[] memory path = new Router.Hop[](1);
            path[0] = Router.Hop(btc.pool, btc.token);
            Router.TradeParams memory p = Router.TradeParams(id, address(USDC), 20_000e6, 1, 1, block.timestamp + 300, 0, true);
            vm.prank(BUYER); _routerBuy(p, path);
            assertEq(uint8(curve.status()), 2, string.concat("kind graduated: ", vm.toString(kind)));
            (, address treasury,,,) = core.factory.strategies(id);
            assertGt(IERC20(btc.token).balanceOf(treasury), 0, "the treasury holds cirBTC after graduation");
        }
    }

    function _routerBuy(Router.TradeParams memory p, Router.Hop[] memory path) private {
        (uint256 got,) = core.router.buy(p, path);
        assertGt(got, 0);
    }

    /// @dev the engines' bands sit above twice the execution friction: 2 * (150 slippage + 1 pool fee + 10 bounty)
    ///      = 322 bps on Arc's cirBTC listing, against 2 * (100 + 5 + 10) = 230 on 4663. 4% here.
    function _spotConfig(bytes32 key) private pure returns (EngineConfig memory c) {
        c.schema = 1; c.engineVersion = 1; c.policyKey = key;
        c.words[0] = bytes32(uint256(5000) | uint256(400) << 16 | uint256(600) << 32 | uint256(5000) << 64);
        c.words[1] = bytes32(uint256(2_000e6));
        c.words[2] = bytes32(uint256(10_000e6));
    }

    function _rebalanceConfig(bytes32 key) private pure returns (EngineConfig memory c) {
        c.schema = 3; c.engineVersion = 1; c.policyKey = key;
        c.words[0] = bytes32(uint256(5000) | uint256(400) << 16 | uint256(600) << 32 | uint256(5000) << 64);
        c.words[1] = bytes32(uint256(2000) | uint256(2000) << 16);
        c.words[2] = bytes32(uint256(5000) | uint256(9000) << 16);
    }

    function _reserveConfig(bytes32 key) private pure returns (EngineConfig memory c) {
        c.schema = LotReserveConfig.SCHEMA; c.engineVersion = LotReserveConfig.ENGINE_VERSION; c.policyKey = key;
        c.words[0] = bytes32(uint256(3000));
    }

    /// BTC up 6% on the real pool and on Chainlink; the 5% take-profit sells a lot into the real pool. (A rung must
    /// clear twice slippage-plus-fee: 2 * (150 + 1) bps here, so 3.02% is the lowest a creator may choose.)
    function _takeProfit(HedgeFunV2Treasury t) private {
        IUniswapV3Pool pool = IUniswapV3Pool(btc.pool);
        bool btcIs0 = pool.token0() == btc.token;
        (uint160 sqrtP,,,,,,) = pool.slot0();
        // +6% in BTC's USDC price is sqrt(1.06) on the sqrt price, inverted when BTC is token1
        uint160 target = btcIs0 ? uint160(uint256(sqrtP) * 102_956 / 100_000) : uint160(uint256(sqrtP) * 100_000 / 102_956);
        ArcForkSwapper swapper = new ArcForkSwapper();
        vm.deal(address(swapper), 50_000_000e18);
        swapper.swapTo(pool, !btcIs0, target);
        vm.warp(block.timestamp + 700);  // the pool's 600-second mean catches up; nothing else trades on the fork
        vm.roll(block.number + 700);
        _printFeed(t.spotPrice());

        (bool healthy,) = t.health();
        assertTrue(healthy, "pool spot, pool mean and the feed agree after the move");
        uint256 usdcBefore = USDC.balanceOf(address(t));
        uint256 bookedBefore = t.bookedStock();
        vm.prank(KEEPER); (HedgeFunV2Treasury.Action action,) = t.execute();
        assertEq(uint8(action), uint8(HedgeFunV2Treasury.Action.TakeProfit));
        assertGt(USDC.balanceOf(address(t)), usdcBefore, "the lot sold for USDC in the real pool");
        assertLt(t.bookedStock(), bookedBefore);
        assertGt(IERC20(btc.token).balanceOf(KEEPER), 0, "keeper bounty in cirBTC");
    }

    /// Chainlink prints the pool's new price now: answer = BTC/USD with the USDC/USD leg multiplied back in.
    function _printFeed(uint256 spotE18) private {
        (, int256 usdc,,,) = CryptoPriceOracle(address(oracle)).usdgFeed().latestRoundData();
        int256 answer = int256(spotE18 * uint256(usdc) / 1e18);
        vm.mockCall(btc.feed, abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), answer, block.timestamp, block.timestamp, uint80(1)));
    }

    function _launch() private returns (uint256 id, HedgeFunBondingCurve curve) {
        return _launch(_request("HFBTCFX", 1));
    }

    function _request(string memory symbol, uint96 nonce) private view returns (HedgeFunFactory.Request memory q) {
        HedgeFunV2ArcFactory f = core.factory;
        (,, uint256 open,) = f.listings(btc.token);
        q.name = "Arc fork rehearsal"; q.symbol = symbol; q.stock = btc.token; q.creator = CREATOR;
        q.taxBps = 100; q.creatorBps = 1000; q.tp1Bps = 500; q.tp2Bps = 1000; q.dipBps = 500; q.stopBps = 0;
        q.lotBps = 2000; q.nonce = nonce; q.maxFee = f.getDefaults().launchFeeAmount; q.expectedOpenPriceE18 = open;
    }

    function _launch(HedgeFunFactory.Request memory q) private returns (uint256 id, HedgeFunBondingCurve curve) {
        HedgeFunV2ArcFactory f = core.factory;
        (,, bytes32 terms) = f.predict(q);
        uint256 protocolBefore = protocol.balance;
        vm.deal(CREATOR, 10e18);
        vm.prank(CREATOR); id = f.launch{value: 1e18}(q, terms);
        assertEq(protocol.balance, protocolBefore + 1e18, "launch fee: one native USDC to the protocol Safe");
        curve = HedgeFunBondingCurve(f.curves(id));
        assertEq(curve.stock(), btc.token);
    }

    function _treasury(uint256 id) private view returns (HedgeFunV2Treasury) {
        (, address treasury,,,) = core.factory.strategies(id);
        return HedgeFunV2Treasury(treasury);
    }
}
