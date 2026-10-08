// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LotReserveScheduler} from "../src/v2/strategy/LotReserveScheduler.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";
import {HedgeFunV2Hook} from "../src/hooks/HedgeFunV2Hook.sol";
import {HedgeFunBondingCurve as Curve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {CurveDeployer} from "../src/v2/CurveDeployer.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {V2TreasuryUpgradeController} from "../src/v2/V2TreasuryUpgradeController.sol";
import {V2LiquidityVault} from "../src/v2/V2LiquidityVault.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunV2UpgradeableTreasury} from "../src/v2/HedgeFunV2UpgradeableTreasury.sol";
import {HedgeFunV2BuybackTreasury} from "../src/v2/HedgeFunV2BuybackTreasury.sol";
import {HedgeFunV2EngineTreasuryCore} from "../src/v2/HedgeFunV2EngineTreasury.sol";
import {HedgeFunV2TradablePercentEngineTreasuryCore} from "../src/v2/HedgeFunV2TradablePercentEngineTreasury.sol";
import {HedgeFunV2PercentBuybackTreasuryLogic} from "../src/v2/HedgeFunV2PercentBuybackTreasury.sol";
import {HedgeFunV2UpgradeableCycleTreasuryLogic} from "../src/v2/HedgeFunV2UpgradeableCycleTreasury.sol";
import {HedgeFunV2TradeRouter as Router} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {EngineConfig, StrategyAction} from "../src/v2/strategy/IStrategyPolicy.sol";
import {V2RebalancePolicy} from "../src/v2/strategy/V2RebalancePolicy.sol";
import {V2MainnetCore} from "../script/mainnet/V2MainnetCore.sol";
import {V2MainnetDefaults} from "../script/mainnet/V2MainnetDefaults.sol";
import {DeployV2MainnetCore} from "../script/mainnet/DeployV2MainnetCore.s.sol";
import {RegisterV2UpgradeableKinds} from "../script/RegisterV2UpgradeableKinds.s.sol";
import {RegisterV2TradablePercent} from "../script/RegisterV2TradablePercent.s.sol";
import {RegisterV2LotReserve} from "../script/RegisterV2LotReserve.s.sol";
import {HedgeFunV2UpgradeableReserveTreasuryLogic} from "../src/v2/HedgeFunV2ReserveTreasury.sol";
import {LotReserveConfig} from "../src/v2/strategy/V2LotReservePolicy.sol";
import {RegisterV2PercentBuyback} from "../script/RegisterV2PercentBuyback.s.sol";
import {RegisterV2UpgradeableCycle} from "../script/RegisterV2UpgradeableCycle.s.sol";

/// @notice "The market": swaps on the real stock/USDG V3 pool until the pool's price is the one asked for.
/// @dev An exact-input swap with a price limit and no amount limit, paid from this contract's own balance in the
///      pool's callback. A rise is paid for in USDG; the stock it buys is what a later fall is paid for with.
contract V3PriceMover {
    using SafeERC20 for IERC20;

    IUniswapV3Pool public immutable pool;
    IERC20 private immutable token0;
    IERC20 private immutable token1;
    address private immutable owner;

    constructor(IUniswapV3Pool pool_) {
        pool = pool_;
        token0 = IERC20(pool_.token0());
        token1 = IERC20(pool_.token1());
        owner = msg.sender;
    }

    function moveTo(uint160 sqrtPriceX96) external {
        require(msg.sender == owner, "owner");
        (uint160 current,,,,,,) = pool.slot0();
        if (current == sqrtPriceX96) return;
        pool.swap(address(this), sqrtPriceX96 < current, type(int256).max, sqrtPriceX96, "");
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == address(pool), "pool");
        if (amount0Delta > 0) token0.safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) token1.safeTransfer(msg.sender, uint256(amount1Delta));
    }
}

/// What the two engine kinds share, read through one type.
interface IEngineView {
    function preview() external view returns (bool due, StrategyAction action, uint256 amountIn);
    function avgCost() external view returns (uint256);
    function strategyNonce() external view returns (uint64);
    function turnoverInEpoch() external view returns (uint256);
    function turnoverEpoch() external view returns (uint64);
    function payoutBps() external view returns (uint16);
}

/// Every strategy kind of the V2 release, end to end, on a fork of Robinhood Chain mainnet (4663) at production
/// configuration: launch, graduation through the real stock pool, and the strategy selling, buying and burning.
/// Not exercised: the second take-profit rung, and the optional stop-loss on any kind but the cycle.
///
/// REAL (forked chain state, or this repository's code deployed into the fork by its own mainnet scripts):
///  * the core, from `DeployV2MainnetCore.deploy` -- the function the mainnet deployment broadcasts -- with
///    `V2MainnetDefaults.release()`, the real owner/protocol Safe and the real wrapped native token;
///  * kinds 1 to 5, from the production registration scripts in the order production will run them
///    (`RegisterV2UpgradeableKinds`, `RegisterV2TradablePercent`, `RegisterV2PercentBuyback`,
///    `RegisterV2UpgradeableCycle`), whose pinned code hashes must accept this core;
///  * the NVDA token, its `PriceOracle`, the USDG feed, the trading calendar, the NVDA/USDG Uniswap V3 pool with
///    its real liquidity, USDG, and the chain's deployed Uniswap V4 PoolManager;
///  * every launch (0.0005 ETH fee), curve buy, graduation, V4 trade, fee sweep, treasury action and buy-back.
///
/// SIMULATED, and nothing else is:
///  * accounts are funded by impersonated USDG transfers out of the WETH/USDG pool (`vm.prank`); that pool is
///    used for nothing else here. No NVDA is minted or dealt: all of it is bought from the real pool;
///  * the factory's first owner is a test address standing in for the deploying key (`DEPLOYER_SETS_UP`);
///  * time is moved with `vm.warp`;
///  * "NVDA rose/fell X%": `V3PriceMover` really swaps on the NVDA pool to the new price, AND the NVDA Chainlink
///    feed's `latestRoundData` is `vm.mockCall`ed to the same price with a fresh timestamp (the address is read
///    from the oracle). The oracle contract, the USDG feed and the calendar are not touched. A fall returns to
///    0.1% above the fork price, not to it: the mover sells back only stock it bought, less the pool's fee;
///  * `test_kind0_upgrade...` alone also re-stamps the USDG feed's last answer after its two-day wait: a fork's
///    feeds stop at the fork block, and the oracle refuses a dollar leg older than 26 hours.
///
/// There is no mainnet script that registers the spot engine's policy (`V2RebalancePolicy`, schema 1); the
/// testnet deployment scripts do it inline. Here the factory owner registers it with the same call.
///
/// Every launch: 1% tax, 10% of it to the creator, take-profits 5% and 10% over cost (one rung for the cycle
/// kind), dips 5% under the last sale, a fifth of the reserve per buy, and no stop unless the test says so. The
/// two engines' bands are 2.5% and 1.5% where the testnet suites use 5%: NVDA can only be moved up from the fork
/// price here (a fall is the mover selling back what its rise bought), and the rise that takes a 50% holding
/// over a 5% band is 22%, more than the stock this pool holds above its price is good for.
///
/// Skipped unless asked for; CI does not run it (it needs an archive RPC). Nothing is broadcast.
///   MAINNET_E2E=1 RH_RPC=<archive RPC URL> forge test --mc MainnetV2EndToEndForkTest -vv
/// MAINNET_E2E_BLOCK overrides the pinned block, which was during the US session of Monday 2026-10-05.
contract MainnetV2EndToEndForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant PINNED_BLOCK = 81_045_655;
    bool internal live;
    IPoolManager internal constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant SAFE = 0x2910117dd2cB431173Ae9Fb6eAF30726321d1693;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant NVDA_ORACLE = 0x03c77f527Aa1B0B304602e3fB9Ac994dd1c157f8;
    address internal constant NVDA_POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;
    address internal constant USDG_SOURCE = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // WETH/USDG pool, funding only
    address internal constant DEPLOYER = address(0xD3910E);
    address internal constant CREATOR = address(0xC4EA704);
    address internal constant ALICE = address(0xA11);
    address internal constant BOB = address(0xB0B);
    address internal constant KEEPER = address(0xB07);
    /// 1e18 * 10^stockDecimals / 10^usdgDecimals: a price is USDG per whole NVDA, 1e18-scaled
    uint256 internal constant SCALE = 1e30;
    uint256 internal constant BOUNTY_BPS = 10;
    uint256 internal constant MIN_LOT_USDG = 5e6;
    bytes32 internal constant DEPENDENCIES = keccak256("mainnet-e2e-fork: policy dependencies");
    bytes32 internal constant AUDIT = keccak256("mainnet-e2e-fork: policy audit manifest");

    HedgeFunV2Factory internal factory;
    V2TreasuryDeployer internal registry;
    V2TreasuryUpgradeController internal controller;
    CurveDeployer internal curveDeployer;
    HedgeFunV2Hook internal hook;
    Router internal router;
    V3PriceMover internal mover;
    address internal stockFeed;
    address internal usdgFeed;
    uint80 internal feedRound;
    uint256 internal lastTarget;

    uint8 internal buybackKind;
    uint8 internal engineKind;
    uint8 internal percentKind;
    uint8 internal cycleKind;
    RegisterV2TradablePercent.Registration internal rebalance;
    RegisterV2LotReserve.Registration internal lotReserve;
    bytes32 internal spotPolicyKey;

    /// the oracle's price at the fork block, and what the test has since moved it to
    uint256 internal forkPrice;
    uint256 internal marketPrice;
    uint256 internal openPriceE18;
    /// the stop the next launch asks for; 0, the default, never sells a lot at a loss
    uint16 internal stopBps;

    // the launch under test
    HedgeFunToken internal token;
    Curve internal curve;
    HedgeFunV2Treasury internal treasury;
    PoolKey internal key;
    uint256 internal id;

    struct Snap {
        uint256 booked;
        uint256 buyback;
        uint256 reserve;
        uint256 lots;
        uint256 held;
        uint256 keeperStock;
        uint256 keeperUsdg;
        uint256 keeperToken;
        uint256 poolStock;
        uint256 poolUsdg;
        uint256 supply;
    }

    /// one engine action, measured on the real balances
    struct Fill {
        uint256 moved;      // stock that left (a sale) or entered (a buy) the tradable inventory
        uint256 stock;      // stock that crossed the V3 pool
        uint256 usdg;       // USDG that crossed the V3 pool
        uint256 toBuyback;  // a sale's gain kept in stock for the buy-back
        uint256 reward;     // the keeper's, in the action's output asset
    }

    function setUp() public {
        vm.skip(vm.envOr("MAINNET_E2E", uint256(0)) == 0, "mainnet fork: set MAINNET_E2E=1 and RH_RPC (archive)");
        vm.makePersistent(address(LotReserveScheduler));
        live = vm.envOr("MAINNET_E2E_LIVE", uint256(0)) != 0;
        uint256 forkBlock = vm.envOr("MAINNET_E2E_BLOCK", live ? 0 : PINNED_BLOCK);
        if (forkBlock == 0) vm.createSelectFork(vm.envString("RH_RPC"));
        else vm.createSelectFork(vm.envString("RH_RPC"), forkBlock);
        forkBlock = block.number;
        assertEq(block.chainid, 4663, "Robinhood Chain mainnet only");
        emit log_named_uint("fork block", forkBlock);
        emit log_named_uint("fork time", block.timestamp);
        if (live) {
            _bindLiveRelease();
        } else {
            _deployCore();
            _registerKinds();
        }
        _listAndFund();
    }

    /// @dev MAINNET_E2E_LIVE=1: the core already on mainnet (deploy/mainnet-v2-release.json), owned by the Safe, with
    ///      its six kinds, two policies and eighteen listings. Nothing is deployed, registered or listed here; the Safe
    ///      opens public launch on the fork and every scenario runs against the live contracts. Forks the head by
    ///      default; MAINNET_E2E_BLOCK pins another block.
    function _bindLiveRelease() private {
        string memory book = vm.readFile("deploy/mainnet-v2-release.json");
        factory = HedgeFunV2Factory(vm.parseJsonAddress(book, ".factory"));
        registry = V2TreasuryDeployer(vm.parseJsonAddress(book, ".treasuryDeployer"));
        curveDeployer = CurveDeployer(vm.parseJsonAddress(book, ".curveDeployer"));
        hook = HedgeFunV2Hook(vm.parseJsonAddress(book, ".hook"));
        router = Router(vm.parseJsonAddress(book, ".tradeRouter"));
        controller = registry.upgradeController();
        (buybackKind, engineKind, percentKind, cycleKind) = (1, 2, 4, 5);
        rebalance = RegisterV2TradablePercent.Registration(3, vm.parseJsonBytes32(book, ".tradablePercentPolicyKey"), vm.parseJsonAddress(book, ".tradablePercentPolicy"));
        spotPolicyKey = vm.parseJsonBytes32(book, ".rebalancePolicyKey");
        assertEq(factory.owner(), SAFE, "the Safe owns the live factory");
        assertEq(controller.owner(), SAFE);
        assertEq(hook.version(), 3);
        assertEq(curveDeployer.DEFAULT_SALE_BPS(), 7931);
        assertGe(registry.kindCount(), 6, "the release's six kinds, and any appended since (kind 6, the lot reserve)");
        assertEq(keccak256(abi.encode(factory.getDefaults())), vm.parseJsonBytes32(book, ".defaultsHash"));
        assertFalse(factory.publicLaunch(), "live launch is still closed; the Safe opens it on this fork only");
        HedgeFunFactory.Defaults memory d = factory.getDefaults();
        assertEq(d.bountyBps, BOUNTY_BPS);
        assertEq(d.minLotUsdg, MIN_LOT_USDG);
    }

    // ---------------------------------------------------------------------------------- production deployment
    /// @dev `DeployV2MainnetCore.deploy`, not the rehearsal: it runs on chain 4663 as it stands and leaves the
    ///      registry with kind 0 only, which is what the registration scripts will find on mainnet.
    function _deployCore() private {
        bytes32 defaultsHash = keccak256(abi.encode(V2MainnetDefaults.release()));
        emit log_named_bytes32("defaults hash", defaultsHash);
        V2MainnetCore.Deployed memory x = new DeployV2MainnetCore().deploy(
            DEPLOYER, V2MainnetCore.Roles(SAFE, SAFE, WETH), true, defaultsHash, 7931, 0
        );
        factory = x.factory;
        registry = x.treasury;
        curveDeployer = x.curve;
        hook = x.hook;
        router = x.router;
        controller = registry.upgradeController();

        assertEq(factory.owner(), DEPLOYER);
        assertEq(controller.owner(), DEPLOYER);
        assertEq(hook.version(), 3);
        assertEq(curveDeployer.DEFAULT_SALE_BPS(), 7931);
        assertEq(registry.DEFAULT_LP_BPS(), 7000);
        assertEq(registry.lpBps(NVDA), 7000, "an unset stock takes the 70% default");
        assertEq(registry.kindCount(), 1, "the core is born with kind 0 only");
        assertFalse(factory.publicLaunch());
        HedgeFunFactory.Defaults memory d = factory.getDefaults();
        assertEq(d.bountyBps, BOUNTY_BPS);
        assertEq(d.minLotUsdg, MIN_LOT_USDG);
        assertEq(d.launchFeeAmount, 0.0005 ether);
    }

    /// @dev The scripts' own `register`, which reverts unless the factory, curve deployer, registry and upgrade
    ///      controller are the runtimes their pinned hashes describe, and reads back what it registered.
    function _registerKinds() private {
        RegisterV2UpgradeableKinds.Kinds memory k = new RegisterV2UpgradeableKinds().register(DEPLOYER, factory);
        (buybackKind, engineKind) = (k.buyback, k.engine);
        rebalance = new RegisterV2TradablePercent().register(DEPLOYER, factory, DEPENDENCIES, AUDIT);
        percentKind = new RegisterV2PercentBuyback().register(DEPLOYER, factory);
        cycleKind = new RegisterV2UpgradeableCycle().register(DEPLOYER, factory);
        // the ids of the testnet release (deploy/testnet-v2-release.json)
        assertEq(buybackKind, 1);
        assertEq(engineKind, 2);
        assertEq(rebalance.kind, 3);
        assertEq(percentKind, 4);
        assertEq(cycleKind, 5);
        assertEq(registry.kindCount(), 6);

        // No mainnet script registers the schema-1 policy; the owner's call, as the testnet deployments make it.
        V2RebalancePolicy policy = new V2RebalancePolicy();
        vm.prank(DEPLOYER);
        spotPolicyKey = registry.registerPolicy(address(policy), 150_000, 160, DEPENDENCIES, AUDIT);
    }

    function _listAndFund() private {
        address owner = factory.owner();
        PriceOracle oracle = PriceOracle(NVDA_ORACLE);
        stockFeed = address(oracle.stockFeed());
        usdgFeed = address(oracle.usdgFeed());
        (feedRound,,,,) = IAggregatorV3(stockFeed).latestRoundData();
        bool ok;
        (ok, forkPrice) = oracle.tryPrice();
        assertTrue(ok, "the live NVDA oracle must be healthy at the fork block");
        marketPrice = forkPrice;
        // the reference opening: a $50,000 fully diluted value at graduation with 79.31% sold
        uint256 openingFdv = Math.mulDiv(50_000e18, uint256(2069) * 2069, 1e8);
        openPriceE18 = Math.mulDiv(openingFdv, 1e18, forkPrice * 1_000_000_000);
        vm.startPrank(owner);
        if (live) {
            (address o, address pool, uint256 listed, bool enabled) = factory.listings(NVDA);
            assertTrue(enabled && o == NVDA_ORACLE && pool == NVDA_POOL, "NVDA is listed on the live factory");
            openPriceE18 = listed;   // listed at the reference price when the plan ran; the oracle has moved since
        } else {
            factory.list(NVDA, NVDA_ORACLE, NVDA_POOL, openPriceE18, true);
        }
        factory.setPublicLaunch(true);
        vm.stopPrank();
        emit log_named_decimal_uint("NVDA oracle price at the fork block, USDG", forkPrice, 18);

        address[2] memory traders = [ALICE, BOB];
        for (uint256 i; i < traders.length; ++i) {
            vm.prank(USDG_SOURCE);
            IERC20(USDG).transfer(traders[i], 20_000e6);
            vm.prank(traders[i]);
            IERC20(USDG).approve(address(router), type(uint256).max);
        }
        mover = new V3PriceMover(IUniswapV3Pool(NVDA_POOL));
        vm.prank(USDG_SOURCE);
        IERC20(USDG).transfer(address(mover), 1_500_000e6);
    }

    // ---------------------------------------------------------------------------------- the market
    /// @dev NVDA is now worth `targetE18`: the feed reports it, the real pool is swapped to it, the pool's
    ///      600-second mean catches up, and the feed prints again at the same price.
    function _stockMovesTo(uint256 targetE18) private {
        bool beyondTheGate = (targetE18 > marketPrice ? targetE18 - marketPrice : marketPrice - targetE18) * 100 > marketPrice;
        uint256 served = _report(targetE18);
        bool healthy;
        if (beyondTheGate) {
            (healthy,) = treasury.health();
            assertFalse(healthy, "a feed the real pool does not agree with opens nothing");
        }
        uint160 sqrtTarget = _sqrtPriceX96(served);
        mover.moveTo(sqrtTarget);
        (uint160 reached,,,,,,) = IUniswapV3Pool(NVDA_POOL).slot0();
        assertEq(reached, sqrtTarget, "the real pool was swapped to the reported price");
        if (beyondTheGate) {
            (healthy,) = treasury.health();
            assertFalse(healthy, "nor does a pool that only just got there: its 600-second mean has to agree too");
        }
        vm.warp(block.timestamp + 660);
        marketPrice = _report(targetE18);
        lastTarget = targetE18;
        uint256 p;
        (healthy, p) = treasury.health();
        assertTrue(healthy, "oracle, pool spot and pool mean agree at the new price");
        assertEq(p, marketPrice);
    }

    /// @dev `PriceOracle`: price = stockAnswer * 1e18 * 10^usdgDecimals / (usdgAnswer * 10^stockDecimals)
    function _report(uint256 targetE18) private returns (uint256 served) {
        (, int256 dollar,,,) = IAggregatorV3(usdgFeed).latestRoundData();
        uint256 answer = Math.mulDiv(
            targetE18,
            uint256(dollar) * 10 ** IAggregatorV3(stockFeed).decimals(),
            1e18 * 10 ** IAggregatorV3(usdgFeed).decimals()
        );
        ++feedRound;
        vm.mockCall(
            stockFeed,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(feedRound, int256(answer), block.timestamp, block.timestamp, feedRound)
        );
        bool ok;
        (ok, served) = PriceOracle(NVDA_ORACLE).tryPrice();
        assertTrue(ok, "the real oracle serves the reported price");
    }

    /// @dev Only after the two-day upgrade notice. A fork's feeds stop at the fork block and the oracle refuses a
    ///      dollar leg older than 26 hours, so the USDG feed's own last answer is given the current time, and the
    ///      stock feed reports its unchanged price again.
    function _feedsPrintAgainAfterTheWait() private {
        (uint80 round, int256 dollar,,,) = IAggregatorV3(usdgFeed).latestRoundData();
        vm.mockCall(
            usdgFeed,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(round, dollar, block.timestamp, block.timestamp, round)
        );
        uint256 served = _report(lastTarget);
        assertEq(served, marketPrice, "the same price, reported now");
        (bool healthy,) = treasury.health();
        assertTrue(healthy);
    }

    function _sqrtPriceX96(uint256 p) private view returns (uint160) {
        bool stockIsToken0 = IUniswapV3Pool(NVDA_POOL).token0() == NVDA;
        return uint160(Math.sqrt(stockIsToken0 ? Math.mulDiv(p, 1 << 192, SCALE) : Math.mulDiv(SCALE, 1 << 192, p)));
    }

    /// @dev where a fall ends: the mover holds only the stock its rise bought, and the pool keeps 0.05% of it
    function _afterTheFall() private view returns (uint256) {
        return forkPrice * 1001 / 1000;
    }

    function _usd(uint256 stockAmount) private view returns (uint256) {
        return stockAmount * marketPrice / 1e18;
    }

    // ---------------------------------------------------------------------------------- launch and graduation
    function _request(string memory symbol, uint8 kind, uint32 tp2Bps) private view returns (HedgeFunFactory.Request memory q) {
        q.name = "Mainnet fork end to end";
        q.symbol = symbol;
        q.stock = NVDA;
        q.creator = CREATOR;
        q.taxBps = 100;
        q.creatorBps = 1000;
        q.tp1Bps = 500;
        q.tp2Bps = tp2Bps;
        q.dipBps = 500;
        q.stopBps = stopBps;
        q.lotBps = 2000;
        q.nonce = uint96(kind) + 1;
        q.maxFee = factory.getDefaults().launchFeeAmount;
        q.expectedOpenPriceE18 = openPriceE18;
    }

    function _launch(string memory symbol, uint8 kind, uint32 tp2Bps) private {
        HedgeFunFactory.Request memory q = _request(symbol, kind, tp2Bps);
        if (kind != 0) {
            vm.prank(CREATOR);
            registry.setStrategyKind(symbol, q.nonce, kind);
        }
        _open(q, kind);
    }

    function _launchEngine(string memory symbol, uint8 kind, EngineConfig memory config) private {
        HedgeFunFactory.Request memory q = _request(symbol, kind, 1000);
        vm.prank(CREATOR);
        registry.setEngineConfig(symbol, q.nonce, kind, config);
        _open(q, kind);
    }

    function _open(HedgeFunFactory.Request memory q, uint8 kind) private {
        // The sale share is not the creator's to choose.
        vm.prank(CREATOR);
        vm.expectRevert(CurveDeployer.BadCurveConfig.selector);
        curveDeployer.setCurveConfig(q.symbol, q.nonce, 6000, 3);

        (address predictedToken, address predictedTreasury, bytes32 terms) = factory.predict(q);
        uint256 safeEth = SAFE.balance;
        vm.deal(CREATOR, q.maxFee);
        vm.prank(CREATOR);
        id = factory.launch{value: q.maxFee}(q, terms);
        assertEq(SAFE.balance - safeEth, 0.0005 ether, "the launch fee reaches the protocol Safe in ETH");
        assertEq(CREATOR.balance, 0);

        curve = Curve(factory.curves(id));
        token = HedgeFunToken(curve.token());
        treasury = HedgeFunV2Treasury(curve.treasury());
        (key,) = factory.graduationConfig(id);
        assertEq(address(token), predictedToken);
        assertEq(address(treasury), predictedTreasury);
        assertEq(registry.strategyKindOf(keccak256(abi.encode(q.symbol, CREATOR, q.nonce))), kind);
        HedgeFunV2UpgradeableTreasury proxy = HedgeFunV2UpgradeableTreasury(payable(address(treasury)));
        assertEq(address(proxy.treasuryUpgradeController()), address(controller), "every release kind is upgradeable");
        assertEq(proxy.implementation(), proxy.initialImplementation());

        assertEq(curve.minTokenReserve(), 206_900_000e18, "79.31% of one billion is sold on the curve");
        assertEq(registry.lpBpsOfTreasury(address(treasury)), 7000, "the launch froze seventy to thirty");
        uint256 raiseUsd = (curve.terminalStock() - curve.virtualStock()) * forkPrice / 1e18;
        // $8,204.6 at the price the listing was computed from; a live listing was priced when the plan ran, so the raise
        // in dollars follows the stock since then by the ratio of the reference opening price to the listed one
        uint256 referenceOpen = Math.mulDiv(Math.mulDiv(50_000e18, uint256(2069) * 2069, 1e8), 1e18, forkPrice * 1_000_000_000);
        assertApproxEqRel(raiseUsd, Math.mulDiv(8_204.6e18, openPriceE18, referenceOpen), 0.001e18, "net raise to graduate");
        assertEq(address(treasury.pool()), NVDA_POOL, "the treasury trades on the real NVDA pool");
        assertEq(address(treasury.oracle()), NVDA_ORACLE, "and is priced by the real NVDA oracle");
        HedgeFunTreasuryBase.Params memory p = treasury.params();
        assertEq(p.bountyBps, BOUNTY_BPS);
        assertEq(p.maxSlippageBps, 100);
        assertEq(p.maxDeviationBps, 50);
        assertEq(p.buybackCooldown, 10);
        assertEq(key.fee, 2000, "the graduated pool charges the release's 0.20% LP fee");
        assertEq(curve.protocolBps(), 3000, "the curve freezes the release's 30% protocol share");
        assertEq(p.maxBuybackImpactBps, 300);
        assertEq(p.minLotUsdg, MIN_LOT_USDG);

        address[2] memory traders = [ALICE, BOB];
        for (uint256 i; i < traders.length; ++i) {
            vm.prank(traders[i]);
            token.approve(address(router), type(uint256).max);
        }
        vm.warp(block.timestamp + 30); // past the 3-second opening window
    }

    function _path(bool buying) private pure returns (Router.Hop[] memory path) {
        path = new Router.Hop[](1);
        path[0] = Router.Hop(NVDA_POOL, buying ? NVDA : USDG);
    }

    /// Buy with USDG through the real V3 pool. Returns tokens received, stock refunded, stock that left the V3 pool.
    function _buy(address user, uint256 usdgIn, uint8 stage) private returns (uint256 got, uint256 refund, uint256 stockBought) {
        Router.TradeParams memory p = Router.TradeParams(id, USDG, usdgIn, 0, 1, block.timestamp, stage, true);
        uint256 poolStock = IERC20(NVDA).balanceOf(NVDA_POOL);
        uint256 userTokens = token.balanceOf(user);
        vm.prank(user);
        (got, refund) = router.buy(p, _path(true));
        stockBought = poolStock - IERC20(NVDA).balanceOf(NVDA_POOL);
        assertEq(token.balanceOf(user) - userTokens, got);
        assertEq(IERC20(NVDA).balanceOf(address(router)), 0);
        assertEq(token.balanceOf(address(router)), 0);
    }

    function _sell(address user, uint256 amount, uint8 stage) private returns (uint256 proceeds, uint256 stockSold) {
        Router.TradeParams memory p = Router.TradeParams(id, USDG, amount, 0, 1, block.timestamp, stage, true);
        uint256 poolStock = IERC20(NVDA).balanceOf(NVDA_POOL);
        uint256 refund;
        vm.prank(user);
        (proceeds, refund) = router.sell(p, _path(false));
        assertEq(refund, 0);
        stockSold = IERC20(NVDA).balanceOf(NVDA_POOL) - poolStock;
    }

    /// @dev Two buyers on the curve through the real V3 route; the second crosses and graduates.
    function _graduate() private returns (uint256 lpStock, uint256 treasuryStock) {
        (uint256 aliceTokens,,) = _buy(ALICE, 300e6, 0);
        assertGt(aliceTokens, 0);
        assertEq(uint256(curve.status()), uint256(Curve.Status.Active));
        uint256 pmStock = IERC20(NVDA).balanceOf(address(PM));
        uint256 held = IERC20(NVDA).balanceOf(address(treasury));
        uint256 supply = token.totalSupply();
        (, uint256 refund,) = _buy(BOB, 9_500e6, 0);
        assertEq(uint256(curve.status()), uint256(Curve.Status.Graduated), "the crossing buy graduates in the same transaction");
        assertGt(refund, 0, "the stock beyond the terminal reserve comes back");
        assertEq(token.totalSupply(), supply, "graduation burns nothing");
        lpStock = IERC20(NVDA).balanceOf(address(PM)) - pmStock;
        treasuryStock = IERC20(NVDA).balanceOf(address(treasury)) - held;
        assertGt(PM.getLiquidity(key.toId()), 0, "the deployed V4 manager holds the graduated position");
        _assertTheVaultOwnsTheLiquidity();

        uint256 raise = curve.terminalStock() - curve.virtualStock();
        assertApproxEqRel(lpStock + treasuryStock, raise, 0.0001e18, "the raise is split between pool and treasury");
        uint256 lpBudget = Math.mulDiv(lpStock + treasuryStock, 7000, 10_000);
        assertLe(lpStock, lpBudget);
        assertLe(lpBudget - lpStock, 1e12, "the pool gets its 70% within dust");
        assertApproxEqRel(_fdvUsd(), 50_000e18, 0.01e18, "FDV at the graduated pool's price");
        assertEq(hook.buyRateBps(key.toId()), 100);
        assertEq(hook.sellRateBps(key.toId()), 100);
        emit log_named_decimal_uint("graduation: stock to the V4 pool, USD", _usd(lpStock), 18);
        emit log_named_decimal_uint("graduation: stock to the treasury, USD", _usd(treasuryStock), 18);
        emit log_named_decimal_uint("graduation: FDV at the pool price, USD", _fdvUsd(), 18);
    }

    /// @dev the locked positions belong to the launch's vault, which has no way to withdraw them
    function _assertTheVaultOwnsTheLiquidity() private view {
        V2LiquidityVault vault = V2LiquidityVault(treasury.liquidityVault());
        assertGt(address(vault).code.length, 0);
        assertEq(hook.liquidityVaultOf(key.toId()), address(vault));
        (uint128 base,,) = PM.getPositionInfo(
            key.toId(),
            address(vault),
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            bytes32(0)
        );
        (uint128 extra,,) = PM.getPositionInfo(
            key.toId(), address(vault), vault.surplusTickLower(), vault.surplusTickUpper(), bytes32(uint256(1))
        );
        assertGt(base, 0, "the vault owns the base position");
        assertGt(extra, 0, "the vault owns the surplus position");
        assertEq(extra, vault.surplusLiquidity());
    }

    function _fdvUsd() private view returns (uint256) {
        (uint160 sqrtP,,,) = PM.getSlot0(key.toId());
        uint256 p = Math.mulDiv(Math.mulDiv(sqrtP, sqrtP, 1 << 96), 1e18, 1 << 96); // currency1 per currency0, e18
        uint256 stockPerToken = address(token) < NVDA ? p : 1e36 / p;
        return stockPerToken * 1_000_000_000 * forkPrice / 1e18;
    }

    // ---------------------------------------------------------------------------------- measuring an action
    function _snap() private view returns (Snap memory s) {
        s.booked = treasury.bookedStock();
        s.buyback = treasury.buybackStock();
        s.reserve = treasury.reserveUsdg();
        s.lots = treasury.lotCount();
        s.held = IERC20(NVDA).balanceOf(address(treasury));
        s.keeperStock = IERC20(NVDA).balanceOf(KEEPER);
        s.keeperUsdg = IERC20(USDG).balanceOf(KEEPER);
        s.keeperToken = token.balanceOf(KEEPER);
        s.poolStock = IERC20(NVDA).balanceOf(NVDA_POOL);
        s.poolUsdg = IERC20(USDG).balanceOf(NVDA_POOL);
        s.supply = token.totalSupply();
    }

    function _execute() private returns (HedgeFunV2Treasury.Action action, uint256 ref) {
        vm.prank(KEEPER);
        (action, ref) = treasury.execute();
    }

    /// @dev what `execute()` would do now, without doing it
    function _due() private returns (bool due, HedgeFunV2Treasury.Action action) {
        uint256 snapshot = vm.snapshotState();
        vm.prank(KEEPER);
        try treasury.execute() returns (HedgeFunV2Treasury.Action a, uint256) {
            (due, action) = (true, a);
        } catch {}
        vm.revertToState(snapshot);
    }

    function _assertNothingDue() private {
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        _execute();
    }

    function _assertLedgerCoversBalance() private view {
        assertEq(
            IERC20(NVDA).balanceOf(address(treasury)),
            treasury.bookedStock() + treasury.buybackStock() + treasury.unbookedStock(),
            "every NVDA the treasury holds is in its ledger"
        );
    }

    /// @dev the floor `PoolTrader._swapBounded` holds a sale to: the oracle value less slippage and pool fee
    function _assertSoldNearOracle(uint256 stockSold, uint256 usdgGot) private view {
        assertGe(usdgGot, Math.mulDiv(Math.mulDiv(stockSold, marketPrice, SCALE), 10_000 - 100 - 5, 10_000));
        assertLe(usdgGot, Math.mulDiv(stockSold, marketPrice, SCALE), "nobody pays the treasury over the oracle");
    }

    function _assertBoughtNearOracle(uint256 usdgSpent, uint256 stockGot) private view {
        assertGe(Math.mulDiv(stockGot, marketPrice, SCALE), Math.mulDiv(usdgSpent, 10_000 - 100 - 5, 10_000));
        assertLe(Math.mulDiv(stockGot, marketPrice, SCALE), usdgSpent);
    }

    // ---------------------------------------------------------------------------------- the lot rule (kinds 0, 4, 5)
    function _assertGraduationLot(uint256 treasuryStock) private view {
        assertEq(treasury.lotCount(), 1, "the graduation stock is a lot");
        (uint256 qty, uint256 cost, bool half, uint256 tp1Left) = treasury.lots(0);
        assertEq(qty, treasuryStock);
        assertEq(cost, forkPrice, "booked at the live oracle price");
        assertFalse(half);
        assertEq(tp1Left, 0);
        assertEq(treasury.bookedStock(), treasuryStock);
        assertEq(treasury.buybackStock(), 0);
        assertEq(treasury.reserveUsdg(), 0);
        assertEq(treasury.lastSalePrice(), forkPrice);
    }

    /// @dev One `execute()` that must be a take-profit on a lot of this cost. The principal is sold for USDG on
    ///      the real pool; the profit stays in NVDA for the buy-back, less the keeper's 0.1% of it.
    function _takeProfit(uint256 cost) private returns (uint256 gaveUp, uint256 profit) {
        treasury.book(); // anything that arrived is booked (or too small to be) before the measurement
        Snap memory a = _snap();
        (HedgeFunV2Treasury.Action action,) = _execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        Snap memory b = _snap();
        gaveUp = a.booked - b.booked;
        uint256 principal = b.poolStock - a.poolStock;
        uint256 got = a.poolUsdg - b.poolUsdg;
        uint256 reward = b.keeperStock - a.keeperStock;
        profit = gaveUp - principal;
        assertGt(principal, 0, "NVDA really entered the V3 pool");
        assertApproxEqAbs(principal, Math.mulDiv(gaveUp, cost, marketPrice), 1, "principal = quantity x cost / price");
        assertEq(b.reserve - a.reserve, got, "the principal's USDG is the reserve");
        _assertSoldNearOracle(principal, got);
        assertEq(reward, profit * BOUNTY_BPS / 10_000, "keeper: 0.1% of the profit, in NVDA");
        assertGt(reward, 0);
        assertEq(b.buyback - a.buyback, profit - reward, "the rest of the profit waits for the buy-back");
        assertEq(a.held - b.held, principal + reward);
        assertEq(b.keeperUsdg, a.keeperUsdg);
        assertEq(b.supply, a.supply, "a take-profit burns nothing by itself");
        assertEq(treasury.lastSalePrice(), marketPrice);
        _assertLedgerCoversBalance();
        emit log_named_decimal_uint("take-profit: NVDA sold, USD", _usd(principal), 18);
        emit log_named_decimal_uint("take-profit: USDG received", got, 6);
        emit log_named_decimal_uint("take-profit: profit kept in NVDA, USD", _usd(profit - reward), 18);
        emit log_named_decimal_uint("take-profit: keeper reward, USD", _usd(reward), 18);
    }

    /// @dev One `execute()` that must be this buy: `lotBps` of the USDG reserve, capped at `maxSpend`, on the real
    ///      pool, into a new lot at what it cost. The keeper's 0.1% is of the USDG spent.
    function _buyLot(HedgeFunV2Treasury.Action expected, uint256 maxSpend) private returns (uint256 spent, uint256 bought) {
        treasury.book();
        Snap memory a = _snap();
        (HedgeFunV2Treasury.Action action, uint256 lot) = _execute();
        assertEq(uint256(action), uint256(expected));
        Snap memory b = _snap();
        spent = b.poolUsdg - a.poolUsdg;
        bought = a.poolStock - b.poolStock;
        uint256 reward = b.keeperUsdg - a.keeperUsdg;
        uint256 offer = Math.min(a.reserve * 2000 / 10_000, maxSpend);
        assertEq(spent, offer - offer * BOUNTY_BPS / 10_000, "a fifth of the reserve, less the keeper's share of the ask");
        assertEq(reward, spent * BOUNTY_BPS / 10_000, "keeper: 0.1% of the USDG spent");
        assertEq(a.reserve - b.reserve, spent + reward);
        _assertBoughtNearOracle(spent, bought);
        assertEq(b.booked - a.booked, bought, "what the pool delivered is the new lot");
        assertEq(b.lots, a.lots + 1);
        assertEq(lot, b.lots - 1);
        (uint256 qty, uint256 cost,,) = treasury.lots(lot);
        assertEq(qty, bought);
        assertEq(cost, Math.mulDiv(spent, SCALE, bought), "the lot costs what was paid for it");
        assertEq(b.buyback, a.buyback);
        assertEq(b.keeperStock, a.keeperStock);
        assertEq(treasury.lastSalePrice(), marketPrice);
        _assertLedgerCoversBalance();
        emit log_named_decimal_uint("buy: USDG spent", spent, 6);
        emit log_named_decimal_uint("buy: NVDA bought, USD", _usd(bought), 18);
        emit log_named_decimal_uint("buy: keeper reward, USDG", reward, 6);
    }

    /// @dev One `execute()` that must stop this lot out: all of it sold on the real pool under its cost. Nothing is
    ///      burned, and the keeper's 0.1% comes out of the USDG proceeds because a stop has no profit to pay from.
    function _stopOut(uint256 lot) private returns (uint256 sold, uint256 got) {
        treasury.book();
        (uint256 qty, uint256 cost,,) = treasury.lots(lot);
        Snap memory a = _snap();
        (HedgeFunV2Treasury.Action action, uint256 ref) = _execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.Stop));
        assertEq(ref, lot);
        Snap memory b = _snap();
        sold = b.poolStock - a.poolStock;
        got = a.poolUsdg - b.poolUsdg;
        uint256 reward = b.keeperUsdg - a.keeperUsdg;
        assertEq(sold, qty, "the whole lot fits one chunk");
        assertEq(a.booked - b.booked, sold);
        assertEq(a.held - b.held, sold);
        assertEq(b.lots, a.lots - 1);
        _assertSoldNearOracle(sold, got);
        assertLt(got, Math.mulDiv(sold, cost, SCALE), "sold for less than it cost");
        assertEq(reward, got * BOUNTY_BPS / 10_000, "keeper: 0.1% of the proceeds, in USDG");
        assertGt(reward, 0);
        assertEq(b.reserve - a.reserve, got - reward);
        assertEq(b.buyback, a.buyback, "a stop has no profit for the buy-back");
        assertEq(b.keeperStock, a.keeperStock);
        assertEq(b.supply, a.supply);
        assertEq(treasury.lastStopPrice(), marketPrice);
        assertEq(treasury.lastStopAt(), block.timestamp);
        assertEq(treasury.lastSalePrice(), marketPrice);
        _assertLedgerCoversBalance();
        emit log_named_decimal_uint("stop: NVDA sold, USD", _usd(sold), 18);
        emit log_named_decimal_uint("stop: USDG received", got, 6);
        emit log_named_decimal_uint("stop: loss against the lot's cost, USDG", Math.mulDiv(sold, cost, SCALE) - got, 6);
        emit log_named_decimal_uint("stop: keeper reward, USDG", reward, 6);
    }

    // ---------------------------------------------------------------------------------- buy back and burn (all kinds)
    function _fixedChunk() private view returns (uint256) {
        return Math.mulDiv(treasury.params().buybackChunkUsdg, SCALE, marketPrice);
    }

    /// @dev a tenth of the budget, raised to the minimum lot
    function _tenthOrALot() private view returns (uint256) {
        return Math.max(treasury.buybackStock() / 10, Math.mulDiv(MIN_LOT_USDG, SCALE, marketPrice));
    }

    /// @dev One `buyback()`: NVDA from the budget into the launch's own V4 pool, through the hook and untaxed, and
    ///      the strategy token it buys is burned, less the keeper's 0.1% of it.
    function _buybackOnce(uint256 chunk) private returns (uint256 spent, uint256 burned) {
        Snap memory a = _snap();
        uint256 offer = Math.min(a.buyback, chunk);
        uint256 fees = _accruedStock();
        uint256 managerStock = IERC20(NVDA).balanceOf(address(PM));
        uint256 totalBurned = treasury.totalBurned();
        vm.prank(KEEPER);
        (spent, burned) = treasury.buyback();
        Snap memory b = _snap();
        uint256 reward = b.keeperToken - a.keeperToken;
        assertGt(spent, 0, "a real swap on the deployed V4 manager");
        assertLe(spent, offer, "never more than this kind's chunk of the budget");
        assertGt(burned, 0);
        assertEq(a.buyback - b.buyback, spent);
        assertEq(a.held - b.held, spent);
        assertEq(IERC20(NVDA).balanceOf(address(PM)) - managerStock, spent, "the NVDA is in the V4 pool");
        assertEq(a.supply - b.supply, burned, "the strategy token's supply fell by what was burned");
        assertEq(treasury.totalBurned() - totalBurned, burned);
        assertEq(reward, (burned + reward) * BOUNTY_BPS / 10_000, "keeper: 0.1% of the tokens bought");
        assertEq(_accruedStock(), fees, "the treasury's own buy pays no fee");
        assertEq(b.booked, a.booked);
        assertEq(b.reserve, a.reserve);
        _assertLedgerCoversBalance();
        emit log_named_decimal_uint("buy-back: NVDA spent, USD", _usd(spent), 18);
        emit log_named_decimal_uint("buy-back: strategy tokens burned", burned, 18);
    }

    /// Stock the hook has accrued for this pool; nothing may ever accrue in the strategy token.
    function _accruedStock() private view returns (uint256 stock) {
        uint256 inToken;
        (inToken, stock) = hook.accrued(key.toId());
        assertEq(inToken, 0, "no fee is held in the strategy token");
        assertEq(PM.balanceOf(address(hook), uint256(uint160(address(token)))), 0, "no token claim inventory");
    }

    // ---------------------------------------------------------------------------------- the engines (kinds 2, 3)
    function _engine() private view returns (IEngineView) {
        return IEngineView(address(treasury));
    }

    function _stockShareBps() private view returns (uint256) {
        uint256 value = Math.mulDiv(treasury.bookedStock(), marketPrice, SCALE);
        return value * 10_000 / (value + treasury.reserveUsdg());
    }

    /// @dev One `execute()` that must sell: the pool pays USDG, the keeper gets 0.1% of it, and whatever part of
    ///      the gain the config pays out stays in NVDA for the buy-back.
    function _engineSell() private returns (Fill memory f) {
        (bool due, StrategyAction proposed, uint256 amount) = _engine().preview();
        assertTrue(due, "the policy proposes an action");
        assertEq(uint256(proposed), uint256(StrategyAction.SellStock));
        uint64 nonce = _engine().strategyNonce();
        uint256 used = _engine().turnoverInEpoch();
        uint64 epoch = _engine().turnoverEpoch();
        Snap memory a = _snap();
        (HedgeFunV2Treasury.Action action, uint256 ref) = _execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.RebalanceSell));
        assertEq(ref, uint256(nonce) + 1);
        assertEq(_engine().strategyNonce(), nonce + 1);
        Snap memory b = _snap();
        f.moved = a.booked - b.booked;
        f.stock = b.poolStock - a.poolStock;
        f.usdg = a.poolUsdg - b.poolUsdg;
        f.toBuyback = b.buyback - a.buyback;
        f.reward = b.keeperUsdg - a.keeperUsdg;
        assertGt(f.stock, 0, "NVDA really entered the V3 pool");
        assertLe(f.moved, amount, "never more than the preview offered");
        assertEq(f.moved, f.stock + f.toBuyback, "inventory left as stock sold plus stock kept for the buy-back");
        assertEq(a.held - b.held, f.stock);
        _assertSoldNearOracle(f.stock, f.usdg);
        assertEq(f.reward, f.usdg * BOUNTY_BPS / 10_000, "keeper: 0.1% of the USDG the sale produced");
        assertGt(f.reward, 0);
        assertEq(b.reserve - a.reserve, f.usdg - f.reward);
        assertEq(b.keeperStock, a.keeperStock);
        if (_engine().turnoverEpoch() != epoch) used = 0;   // a new trading date (20:00 New York) restarts the budget
        assertEq(_engine().turnoverInEpoch() - used, Math.mulDiv(f.moved, marketPrice, SCALE), "charged to the daily budget");
        assertEq(b.held, b.booked + b.buyback, "nothing is left unbooked");
        emit log_named_decimal_uint("engine sale: NVDA sold, USD", _usd(f.stock), 18);
        emit log_named_decimal_uint("engine sale: USDG received", f.usdg, 6);
        emit log_named_decimal_uint("engine sale: gain kept for the buy-back, USD", _usd(f.toBuyback), 18);
        emit log_named_decimal_uint("engine sale: keeper reward, USDG", f.reward, 6);
    }

    /// @dev One `execute()` that must buy: USDG to the pool, the keeper gets 0.1% of the NVDA it delivers, and the
    ///      rest joins the inventory at what the whole spend cost.
    function _engineBuy() private returns (Fill memory f) {
        (bool due, StrategyAction proposed, uint256 amount) = _engine().preview();
        assertTrue(due, "the policy proposes an action");
        assertEq(uint256(proposed), uint256(StrategyAction.BuyStock));
        uint64 nonce = _engine().strategyNonce();
        uint256 used = _engine().turnoverInEpoch();
        uint64 epoch = _engine().turnoverEpoch();
        uint256 cost = _engine().avgCost();
        Snap memory a = _snap();
        (HedgeFunV2Treasury.Action action,) = _execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.RebalanceBuy));
        assertEq(_engine().strategyNonce(), nonce + 1);
        Snap memory b = _snap();
        f.usdg = b.poolUsdg - a.poolUsdg;
        f.stock = a.poolStock - b.poolStock;
        f.reward = b.keeperStock - a.keeperStock;
        f.moved = b.booked - a.booked;
        assertGt(f.usdg, 0, "USDG really entered the V3 pool");
        assertLe(f.usdg, amount, "never more than the preview offered");
        assertEq(a.reserve - b.reserve, f.usdg);
        _assertBoughtNearOracle(f.usdg, f.stock);
        assertEq(f.reward, f.stock * BOUNTY_BPS / 10_000, "keeper: 0.1% of the NVDA the buy delivered");
        assertGt(f.reward, 0);
        assertEq(f.moved, f.stock - f.reward, "the inventory grows by what the treasury kept");
        assertEq(b.buyback, a.buyback);
        assertEq(b.keeperUsdg, a.keeperUsdg);
        assertEq(
            _engine().avgCost(),
            Math.ceilDiv(a.booked * cost + f.usdg * SCALE, a.booked + f.moved),
            "the average cost carries the whole spend"
        );
        if (_engine().turnoverEpoch() != epoch) used = 0;
        assertEq(_engine().turnoverInEpoch() - used, f.usdg, "charged to the daily budget");
        assertEq(b.held, b.booked + b.buyback, "nothing is left unbooked");
        emit log_named_decimal_uint("engine buy: USDG spent", f.usdg, 6);
        emit log_named_decimal_uint("engine buy: NVDA bought, USD", _usd(f.stock), 18);
        emit log_named_decimal_uint("engine buy: keeper reward, USD", _usd(f.reward), 18);
    }

    /// @dev schema 1: 50% stock, a 2.5% band (the floor here is 2.3%: twice slippage + pool fee + keeper reward),
    ///      ten minutes between actions, half of a sale's gain to the buy-back; one action at most the listing's
    ///      chunk, a day at most five of them.
    function _spotConfig() private view returns (EngineConfig memory c) {
        c.schema = 1;
        c.engineVersion = 1;
        c.policyKey = spotPolicyKey;
        c.words[0] = bytes32(uint256(5000) | uint256(250) << 16 | uint256(600) << 32 | uint256(5000) << 64);
        c.words[1] = bytes32(uint256(2_000e6));
        c.words[2] = bytes32(uint256(10_000e6));
    }

    /// @dev schema 3: 50% stock, a 1.5% band, ten minutes between actions, half of a sale's net gain to the
    ///      buy-back; one action at most 20% of the cash or of the stock, a day at most 50% of the capital bought
    ///      and 90% sold.
    function _rebalanceConfig() private view returns (EngineConfig memory c) {
        c.schema = 3;
        c.engineVersion = 1;
        c.policyKey = rebalance.policyKey;
        c.words[0] = bytes32(uint256(5000) | uint256(150) << 16 | uint256(600) << 32 | uint256(5000) << 64);
        c.words[1] = bytes32(uint256(2000) | uint256(2000) << 16);
        c.words[2] = bytes32(uint256(5000) | uint256(9000) << 16);
    }

    // ================================================================================== registration
    function test_productionScriptsRegisterKindsOneToFive_andTheirReadbacksPass() public {
        vm.skip(live, "live mode: the kinds were registered on mainnet and verified by tools/verify_mainnet_release.py");
        new RegisterV2UpgradeableKinds().check(registry, RegisterV2UpgradeableKinds.Kinds(buybackKind, engineKind));
        new RegisterV2TradablePercent().check(factory, rebalance, DEPENDENCIES, AUDIT);
        new RegisterV2PercentBuyback().check(factory, percentKind);
        new RegisterV2UpgradeableCycle().check(factory, cycleKind);
        (uint32 version, uint32 schema,, uint256 capabilities) = registry.kindManifest(engineKind);
        assertEq(version, 1);
        assertEq(schema, 1);
        assertEq(capabilities, 3);
        (version, schema,, capabilities) = registry.kindManifest(rebalance.kind);
        assertEq(version, 1);
        assertEq(schema, 3);
        assertEq(capabilities, 3);
        assertTrue(registry.policy(spotPolicyKey).enabledForNewLaunches);
        assertTrue(registry.policy(rebalance.policyKey).enabledForNewLaunches);
        assertEq(controller.UPGRADE_DELAY(), 2 days);
    }

    // ================================================================================== kind 0, the ordinary lot strategy
    /// Launch, graduation, V4 trading with the 1% fee taken in NVDA on both sides, the fee split; then NVDA rises
    /// 6% and half the lot is sold, the profit is burned, NVDA falls back and the reserve buys the dip.
    function test_kind0_ordinaryLots_graduateTradeAndSplitFees_thenTakeProfitBurnAndBuyTheDip() public {
        _launch("E2EZERO", 0, 1000);
        (, uint256 treasuryStock) = _graduate();
        _assertGraduationLot(treasuryStock);
        emit log_named_decimal_uint("tokens burned on the curve by the opening window", 1_000_000_000e18 - token.totalSupply(), 18);

        _tradeOnV4();
        _sweepAndCheckSplit();

        _stockMovesTo(forkPrice * 106 / 100);
        (uint256 gaveUp,) = _takeProfit(forkPrice);
        assertEq(gaveUp, treasuryStock / 2, "the first rung sells half the lot");
        (uint256 qty,, bool half, uint256 tp1Left) = treasury.lots(0);
        assertEq(qty, treasuryStock - gaveUp);
        assertTrue(half, "the lot waits for its second rung");
        assertEq(tp1Left, 0);
        (bool due,) = _due();
        assertFalse(due, "the second rung is 10% over cost");

        _buybackOnce(_fixedChunk());

        _stockMovesTo(_afterTheFall());
        _buyLot(HedgeFunV2Treasury.Action.BuyDip, type(uint256).max);
        (due,) = _due();
        assertFalse(due, "the next rung is another 5% down");
    }

    function _tradeOnV4() private {
        // ---- V4 buys: the 1% is taken in NVDA, before the swap
        uint256 s0 = _accruedStock();
        assertEq(s0, 0);
        (uint256 aGot, uint256 aRefund, uint256 aStock) = _buy(ALICE, 200e6, 2);
        uint256 s1 = _accruedStock();
        assertEq(aRefund, 0);
        assertGt(aGot, 0);
        assertEq(s1 - s0, Math.mulDiv(aStock, 100, 10_000), "buy fee: exactly 1% of the NVDA paid");
        (uint256 bGot,, uint256 bStock) = _buy(BOB, 150e6, 2);
        uint256 s2 = _accruedStock();
        assertEq(s2 - s1, Math.mulDiv(bStock, 100, 10_000));
        assertEq(PM.balanceOf(address(hook), uint256(uint160(NVDA))), s2, "the hook's NVDA claim equals what it accrued");

        // ---- V4 sells: 1% of the NVDA received
        (uint256 proceeds, uint256 soldStock) = _sell(ALICE, aGot / 2, 2);
        uint256 sellTax = _accruedStock() - s2;
        assertGt(proceeds, 0);
        assertEq(sellTax, Math.mulDiv(soldStock + sellTax, 100, 10_000), "sell fee: 1% of the NVDA the sale produced");
        _sell(BOB, bGot, 2);
        emit log_named_decimal_uint("V4 buy: NVDA paid, USD", _usd(aStock), 18);
        emit log_named_decimal_uint("V4 buy: fee accrued, USD", _usd(s1 - s0), 18);
        emit log_named_decimal_uint("V4 sell: fee accrued, USD", _usd(sellTax), 18);
    }

    function _sweepAndCheckSplit() private {
        // ---- anyone sweeps: protocol 30%, creator 10%, treasury 60%, nothing to the sweeper
        uint256 total = _accruedStock();
        uint256[4] memory b = [
            IERC20(NVDA).balanceOf(SAFE),
            IERC20(NVDA).balanceOf(CREATOR),
            IERC20(NVDA).balanceOf(address(treasury)),
            IERC20(NVDA).balanceOf(KEEPER)
        ];
        uint256 supply = token.totalSupply();
        vm.prank(KEEPER);
        hook.sweep(key.toId());
        uint256 protocolCut = Math.mulDiv(total, 3000, 10_000);
        uint256 creatorCut = Math.mulDiv(total, 1000, 10_000);
        assertEq(IERC20(NVDA).balanceOf(SAFE) - b[0], protocolCut, "protocol Safe: 30% of the fees, in real NVDA");
        assertEq(IERC20(NVDA).balanceOf(CREATOR) - b[1], creatorCut, "creator: 10%");
        assertEq(IERC20(NVDA).balanceOf(address(treasury)) - b[2], total - protocolCut - creatorCut, "treasury: the rest");
        assertEq(IERC20(NVDA).balanceOf(KEEPER), b[3], "no sweep tip");
        assertEq(token.totalSupply(), supply, "a sweep burns nothing");
        assertEq(_accruedStock(), 0);
        assertEq(PM.balanceOf(address(hook), uint256(uint160(NVDA))), 0);
        emit log_named_decimal_uint("V4 fees swept, USD", _usd(total), 18);
    }

    // ================================================================================== kind 1, buy-back
    /// No stock strategy: the graduation stock is protected principal, and only what the treasury earns -- curve
    /// fees, V4 trading fees, the vault's LP fees -- buys the token back, untaxed, and burns it.
    function test_kind1_buyback_protectsThePrincipal_booksEarnedFees_andBurnsUntaxedThroughTheHook() public {
        _launch("E2EONE", buybackKind, 1000);
        (, uint256 treasuryStock) = _graduate();
        HedgeFunV2BuybackTreasury t = HedgeFunV2BuybackTreasury(address(treasury));
        assertEq(t.protectedGraduationStock(), treasuryStock, "the graduation stock is principal");
        assertEq(t.bookedStock(), treasuryStock);
        assertEq(IERC20(NVDA).balanceOf(address(t)), treasuryStock);
        assertEq(t.buybackStock(), 0);
        assertEq(t.lotCount(), 0);
        vm.expectRevert(HedgeFunV2BuybackTreasury.UseBuyback.selector);
        _execute();
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        vm.prank(KEEPER);
        t.buyback();

        // Fees: the curve's (claimed), V4 trading's (swept), the vault's own (collected).
        (uint256 aGot,,) = _buy(ALICE, 400e6, 2);
        _sell(ALICE, aGot, 2);
        (uint256 bGot,,) = _buy(BOB, 200e6, 2);
        _sell(BOB, bGot, 2);
        uint256 held = IERC20(NVDA).balanceOf(address(t));
        vm.prank(KEEPER);
        curve.claimFees(address(t));
        uint256 curveFees = IERC20(NVDA).balanceOf(address(t)) - held;
        vm.prank(KEEPER);
        hook.sweep(key.toId());
        uint256 tradingFees = IERC20(NVDA).balanceOf(address(t)) - held - curveFees;
        (uint256 lpFees,) = V2LiquidityVault(hook.liquidityVaultOf(key.toId())).collectFees();
        assertGt(curveFees, 0);
        assertGt(tradingFees, 0);
        assertGt(lpFees, 0);
        assertEq(t.buybackStock(), lpFees, "LP fees are credited straight to the budget");
        assertTrue(t.book(), "earned fees are booked as income");
        uint256 budget = t.buybackStock();
        assertEq(budget, curveFees + tradingFees + lpFees, "the budget is exactly what was earned");
        assertEq(t.bookedStock(), treasuryStock);
        emit log_named_decimal_uint("buy-back budget from fees, USD", _usd(budget), 18);

        vm.warp(block.timestamp + 61);
        (uint256 spent,) = _buybackOnce(_fixedChunk());
        assertEq(spent, budget, "the whole budget fits one chunk");
        assertEq(t.bookedStock(), treasuryStock, "the principal is untouched");
        assertEq(t.protectedGraduationStock(), treasuryStock);
        assertEq(IERC20(NVDA).balanceOf(address(t)), treasuryStock + t.buybackStock());
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        vm.prank(KEEPER);
        t.buyback();
    }

    // ================================================================================== kind 2, spot engine (schema 1)
    /// Sells from all-stock to its 50% target at the fork's own feed and pool; sells again when NVDA rises 13%,
    /// paying half the gain to the buy-back, which burns; buys when NVDA falls back.
    function test_kind2_spotEngine_sellsToTarget_sellsTheRise_burnsTheGain_andBuysTheFall() public {
        _launchEngine("E2ESPOT", engineKind, _spotConfig());
        (, uint256 treasuryStock) = _graduate();
        HedgeFunV2EngineTreasuryCore e = HedgeFunV2EngineTreasuryCore(address(treasury));
        assertEq(e.bookedStock(), treasuryStock, "the graduation stock is inventory");
        assertEq(e.avgCost(), forkPrice, "booked at the live oracle price");
        assertEq(e.buybackStock(), 0);
        assertEq(e.payoutBps(), 5000);
        assertEq(e.lotCount(), 0);

        // ---- all stock -> 50%, in one action under the listing's chunk
        Fill memory f = _engineSell();
        assertEq(f.toBuyback, 0, "a sale at cost has no gain to pay out");
        assertApproxEqAbs(_stockShareBps(), 5000, 20, "at target");
        assertEq(e.avgCost(), forkPrice, "a sale leaves the average cost alone");
        _assertNothingDue();

        // ---- NVDA +13%: over the band, sold back to target; half the gain stays in NVDA
        _stockMovesTo(forkPrice * 113 / 100);
        assertGt(_stockShareBps(), 5250, "the rise took the stock share over the band");
        f = _engineSell();
        uint256 gain = f.moved - Math.mulDiv(f.moved, forkPrice, marketPrice);
        assertApproxEqAbs(f.toBuyback, gain / 2, 2, "half of the gain over the average cost");
        assertGt(f.toBuyback, 0);
        assertApproxEqAbs(_stockShareBps(), 5000, 20, "at target");
        _buybackOnce(_fixedChunk());
        assertEq(e.buybackStock(), 0, "the whole gain was spent and burned");

        // ---- NVDA falls back: under the band, bought back to target
        _stockMovesTo(_afterTheFall());
        assertLt(_stockShareBps(), 4750, "the fall took the stock share under the band");
        _engineBuy();
        assertApproxEqAbs(_stockShareBps(), 5000, 20, "at target");
        assertEq(e.strategyNonce(), 3);
        _assertNothingDue();
    }

    // ================================================================================== kind 3, rebalance (schema 3)
    /// Percentage caps: each action sells at most 20% of the stock, so all-stock reaches the 50% band in three
    /// paced sales; a 12% rise is sold with half the net gain to the buy-back; the fall back is bought.
    function test_kind3_rebalance_sellsInCappedSteps_sellsTheRise_burnsTheGain_andBuysTheFall() public {
        _launchEngine("E2EREBAL", rebalance.kind, _rebalanceConfig());
        (, uint256 treasuryStock) = _graduate();
        HedgeFunV2TradablePercentEngineTreasuryCore e = HedgeFunV2TradablePercentEngineTreasuryCore(address(treasury));
        assertEq(e.bookedStock(), treasuryStock, "the graduation stock is inventory");
        assertEq(e.avgCost(), forkPrice);
        assertEq(e.buybackStock(), 0);
        _assertRebalanceLimitsAtGraduation(e);

        // ---- 100% -> 80% -> 64% -> 51.2%, one capped sale per cooldown
        for (uint256 i; i < 3; ++i) {
            _cappedSale(e);
            (bool due,,) = e.preview();
            assertFalse(due, "nothing inside the cooldown");
            _assertNothingDue();
            vm.warp(block.timestamp + 600);
        }
        assertApproxEqAbs(_stockShareBps(), 5120, 20);
        (bool again,,) = e.preview();
        assertFalse(again, "inside the 1.5% band");
        assertGt(e.unrecoveredLossUsdg(), 0, "selling at cost realises the trade's own cost as a loss");
        assertEq(e.buybackStock(), 0, "and pays nothing to the buy-back");

        // ---- NVDA +12%: sold back to target; the gain first recovers that loss, then half of it is kept in NVDA
        _stockMovesTo(forkPrice * 112 / 100);
        assertGt(_stockShareBps(), 5150, "the rise took the stock share over the band");
        Fill memory f = _cappedSale(e);
        assertGt(f.toBuyback, 0, "a net gain funds the buy-back");
        assertLe(f.toBuyback, (f.moved - Math.mulDiv(f.moved, forkPrice, marketPrice)) / 2, "never over half the marked gain");
        assertEq(e.unrecoveredLossUsdg(), 0, "the earlier loss was recovered first");
        assertApproxEqAbs(_stockShareBps(), 5000, 20, "at target");
        _buybackOnce(_fixedChunk());
        assertEq(e.buybackStock(), 0);

        // ---- NVDA falls back: bought to target, inside 20% of the cash and the day's buy budget
        _stockMovesTo(_afterTheFall());
        assertLt(_stockShareBps(), 4850, "the fall took the stock share under the band");
        (,, uint256 maxBuy,,,,,) = e.riskLimits();
        assertEq(maxBuy, e.reserveUsdg() / 5);
        f = _engineBuy();
        assertLe(f.usdg, maxBuy);
        (,, uint256 buyCap,, uint256 bought,) = e.dailyRiskLimits();
        assertEq(bought, f.usdg, "the day's buy budget is charged the spend");
        assertLe(bought, buyCap);
        assertApproxEqAbs(_stockShareBps(), 5000, 20, "at target");
        assertEq(e.strategyNonce(), 5);
    }

    function _assertRebalanceLimitsAtGraduation(HedgeFunV2TradablePercentEngineTreasuryCore e) private view {
        (bool healthy, uint256 capital, uint256 maxBuy, uint256 maxSell, uint256 daily,,,) = e.riskLimits();
        assertTrue(healthy);
        assertEq(capital, Math.mulDiv(e.bookedStock(), forkPrice, SCALE), "only tradable stock, not locked LP, funds limits");
        assertEq(maxBuy, 0, "no cash yet");
        assertEq(maxSell, e.bookedStock() / 5);
        assertEq(daily, capital * 5000 / 10_000 + capital * 9000 / 10_000);
    }

    /// @dev a sale that respects the per-action cap and what is left of the day's sell budget
    function _cappedSale(HedgeFunV2TradablePercentEngineTreasuryCore e) private returns (Fill memory f) {
        (,,, uint256 maxSell,,,,) = e.riskLimits();
        (,,, uint256 sellCap,, uint256 sold) = e.dailyRiskLimits();
        (,, uint256 proposed) = e.preview();
        assertLe(proposed, maxSell, "the preview is already inside the cap");
        f = _engineSell();
        assertLe(f.moved, maxSell, "at most 20% of the stock in one action");
        assertLe(Math.mulDiv(f.moved, marketPrice, SCALE), sellCap - sold, "inside the remaining daily budget");
        (,,,,, uint256 soldAfter) = e.dailyRiskLimits();
        assertEq(soldAfter - sold, Math.mulDiv(f.moved, marketPrice, SCALE));
    }

    // ================================================================================== kind 4, percentage buy-back
    /// The lot rule of kind 0; a buy-back offers a tenth of the waiting budget, never under a lot.
    function test_kind4_percentageBuyback_takesProfit_burnsATenthPerCall_andBuysTheDip() public {
        _launch("E2ETENTH", percentKind, 1000);
        (, uint256 treasuryStock) = _graduate();
        _assertGraduationLot(treasuryStock);
        assertEq(HedgeFunV2PercentBuybackTreasuryLogic(address(treasury)).BUYBACK_BPS(), 1000);

        _stockMovesTo(forkPrice * 106 / 100);
        (uint256 gaveUp,) = _takeProfit(forkPrice);
        assertEq(gaveUp, treasuryStock / 2, "the first rung sells half the lot");
        (bool due,) = _due();
        assertFalse(due);

        uint256 supply = token.totalSupply();
        for (uint256 i; i < 3; ++i) {
            uint256 budget = treasury.buybackStock();
            assertGt(budget, 0);
            (uint256 spent,) = _buybackOnce(_tenthOrALot());
            assertLt(spent, budget, "a share of the budget, not all of it");
            vm.expectRevert(HedgeFunTreasuryBase.Cooldown.selector);
            vm.prank(KEEPER);
            treasury.buyback();
            vm.warp(block.timestamp + treasury.params().buybackCooldown);
        }
        assertLt(token.totalSupply(), supply);

        _stockMovesTo(_afterTheFall());
        _buyLot(HedgeFunV2Treasury.Action.BuyDip, type(uint256).max);
    }

    // ================================================================================== kind 6, lot with a reserve
    /// Appended after the release by `RegisterV2LotReserve`, as the factory owner will do on mainnet: kinds 0 to 5
    /// and their launches are untouched.
    function _registerLotReserve() private {
        if (live && vm.envOr("LOT_RESERVE_KIND", uint256(0)) != 0) {
            // the kind the Safe registered on mainnet: its code chunks embed the deployed scheduler's address
            lotReserve = RegisterV2LotReserve.Registration(
                uint8(vm.envUint("LOT_RESERVE_KIND")), vm.envBytes32("LOT_RESERVE_POLICY_KEY"), vm.envAddress("LOT_RESERVE_POLICY")
            );
            (uint32 version, uint32 schema,,) = registry.kindManifest(lotReserve.kind);
            assertEq(version, LotReserveConfig.ENGINE_VERSION);
            assertEq(schema, LotReserveConfig.SCHEMA);
            assertEq(registry.policy(lotReserve.policyKey).implementation, lotReserve.policy);
            return;
        }
        uint256 before = registry.kindCount();
        lotReserve = new RegisterV2LotReserve().register(factory.owner(), factory, DEPENDENCIES, AUDIT);
        assertEq(lotReserve.kind, before, "appended as the next kind");
        assertEq(registry.kindCount(), before + 1);
    }

    function _reserveConfig(uint256 reserveBps) private view returns (EngineConfig memory c) {
        c.schema = LotReserveConfig.SCHEMA;
        c.engineVersion = LotReserveConfig.ENGINE_VERSION;
        c.policyKey = lotReserve.policyKey;
        c.words[0] = bytes32(reserveBps);
    }

    /// The problem the kind solves: graduation books the whole treasury in stock, so a lot strategy has no USDG for
    /// its first dip. With a 30% reserve the first calls after graduation sell that share of the graduation lot for
    /// USDG, in chunks, paying the keeper; then a 5% fall from that sale buys the dip with a fifth of the reserve.
    /// (NVDA rises 7% first, under the 8% take-profit, so the fall can be shown without pushing the real pool under
    /// the fork price: the price mover only holds what it bought on the way up.)
    function test_kind6_lotReserve_sellsItsReserveAfterGraduation_thenBuysTheFall() public {
        _registerLotReserve();
        HedgeFunFactory.Request memory q = _request("E2ERESERVE", lotReserve.kind, 1200);
        q.tp1Bps = 800;
        EngineConfig memory c = _reserveConfig(3000);
        c.words[1] = bytes32(uint256(1000) | uint256(2000) << 16 | uint256(4) << 32);
        vm.prank(CREATOR);
        registry.setEngineConfig(q.symbol, q.nonce, lotReserve.kind, c);
        _open(q, lotReserve.kind);
        (, uint256 treasuryStock) = _graduate();
        _stockMovesTo(forkPrice * 107 / 100);
        HedgeFunV2UpgradeableReserveTreasuryLogic t = HedgeFunV2UpgradeableReserveTreasuryLogic(address(treasury));
        assertEq(t.reserveBps(), 3000);
        assertEq(t.strategyId(), lotReserve.policyKey);
        assertEq(t.engineVersion(), LotReserveConfig.ENGINE_VERSION);
        assertEq(treasury.reserveUsdg(), 0, "graduation books the whole treasury in stock");
        assertTrue(t.reserveArmed(), "graduation fixed the target");
        assertEq(t.reserveStockLeft(), treasuryStock * 3000 / 10_000, "30% of the exact principal graduation transferred");

        uint256 sold;
        uint256 received;
        for (uint256 calls; ; ++calls) {
            assertLt(calls, 10, "the reserve is sold in a few chunks");
            treasury.book();
            (bool due, HedgeFunV2Treasury.Action next) = _due();
            if (!due || next != HedgeFunV2Treasury.Action.RebalanceSell) break;
            Snap memory a = _snap();
            (HedgeFunV2Treasury.Action action,) = _execute();
            assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.RebalanceSell));
            Snap memory b = _snap();
            uint256 stock = b.poolStock - a.poolStock;
            uint256 usdg = a.poolUsdg - b.poolUsdg;
            uint256 reward = b.keeperUsdg - a.keeperUsdg;
            assertEq(a.booked - b.booked, stock, "sold out of the graduation lot");
            _assertSoldNearOracle(stock, usdg);
            assertEq(reward, usdg * BOUNTY_BPS / 10_000, "keeper: 0.1% of the USDG the sale produced");
            assertEq(b.reserve - a.reserve, usdg - reward, "the rest joins the reserve");
            assertEq(b.buyback, a.buyback, "a reserve sale is not a profit");
            (sold, received) = (sold + stock, received + usdg - reward);
        }
        assertEq(t.reserveStockLeft(), 0);
        assertTrue(t.reserveArmed());
        assertApproxEqRel(sold, treasuryStock * 3000 / 10_000, 0.001e18, "30% of the graduation stock");
        assertEq(treasury.reserveUsdg(), received);
        assertEq(treasury.bookedStock(), treasuryStock - sold);
        assertEq(treasury.lastSalePrice(), marketPrice, "the first dip is measured from the reserve sale");
        emit log_named_decimal_uint("opening reserve, USDG", received, 6);

        _stockMovesTo(forkPrice * 1015 / 1000);
        uint256 cashBefore = treasury.reserveUsdg();
        _buyLot(HedgeFunV2Treasury.Action.BuyDip, type(uint256).max);
        (, uint256 count, bool frozen, uint256 principal, uint256 basis, uint256 spent) = t.dipLimits();
        assertTrue(frozen);
        assertEq(principal, treasuryStock);
        assertEq(count, 1);
        assertEq(spent, cashBefore - treasury.reserveUsdg());
        assertLe(spent, basis * 2000 / 10000);
        assertGe(treasury.reserveUsdg(), Math.mulDiv(basis,1000,10000,Math.Rounding.Ceil));
        assertEq(treasury.lotCount(), 2, "the graduation lot and the dip");
    }

    /// At 0% the kind is the plain lot rule: nothing is sold for a reserve, so the treasury holds no USDG.
    /// Over 50% the launch itself refuses.
    function test_kind6_lotReserve_zeroIsThePlainLotRule_andOverHalfIsRefused() public {
        _registerLotReserve();
        HedgeFunFactory.Request memory q = _request("E2EOVER", lotReserve.kind, 1000);
        vm.prank(CREATOR);
        registry.setEngineConfig(q.symbol, q.nonce, lotReserve.kind, _reserveConfig(5001));
        (,, bytes32 terms) = factory.predict(q);
        vm.deal(CREATOR, q.maxFee);
        vm.prank(CREATOR);
        vm.expectRevert();
        factory.launch{value: q.maxFee}(q, terms);

        _launchEngine("E2ENORESERVE", lotReserve.kind, _reserveConfig(0));
        _graduate();
        treasury.book();
        (bool due,) = _due();
        assertFalse(due, "nothing to sell for a reserve, and no USDG for a dip");
        assertEq(treasury.reserveUsdg(), 0);
    }

    // ================================================================================== kind 5, cycle
    /// The lot rule plus the recovery entry: the whole lot is sold 6% up; a further 5.5% rise over that sale buys
    /// back in, once; a later fall buys the ordinary dip.
    function test_kind5_cycle_sellsTheLot_buysBackInAfterAFurtherRise_burns_andBuysTheDip() public {
        HedgeFunV2UpgradeableCycleTreasuryLogic t = _cycleSellsTheLotAndBuysBackIn("E2ECYCLE");

        uint256 budget = t.buybackStock();
        (uint256 spent,) = _buybackOnce(_tenthOrALot());
        assertLt(spent, budget, "this kind also burns a tenth per call");

        // The ordinary rung still works: 5% under the recovery buy, the reserve buys again.
        _stockMovesTo(_afterTheFall());
        _buyLot(HedgeFunV2Treasury.Action.BuyDip, type(uint256).max);
        assertEq(t.lotCount(), 2);
    }

    /// The same launch with an 8% stop, which is off by default: the lot the recovery bought is sold at a loss
    /// when NVDA falls back, nothing is bought under the stop, and a 5.5% recovery over the stop buys back in.
    function test_kind5_cycle_withAStop_sellsTheRecoveryLotAtALoss_thenBuysBackInOnTheRecovery() public {
        stopBps = 800;
        HedgeFunV2UpgradeableCycleTreasuryLogic t = _cycleSellsTheLotAndBuysBackIn("E2ESTOP");
        assertEq(t.params().stopBps, 800);

        _stockMovesTo(_afterTheFall());
        _stopOut(0);
        assertEq(t.lotCount(), 0);
        assertEq(t.bookedStock(), 0);
        assertEq(t.reentrySalePrice(), marketPrice, "the stop is a live sale: it arms the recovery entry");
        _assertNothingDue();

        uint256 stop = marketPrice;
        _stockMovesTo(stop * 103 / 100);
        _assertNothingDue();
        _stockMovesTo(stop * 1055 / 1000);
        _buyLot(HedgeFunV2Treasury.Action.BuyRecovery, t.params().sellChunkUsdg);
        assertEq(t.reentrySaleAt(), 0, "the entry is consumed");
        assertEq(t.lastStopAt(), 0, "and the stop's own gate is cleared by the buy");
        assertEq(t.lotCount(), 1);
    }

    /// @dev Graduate, sell the whole lot at the first rung, refuse at +3% over the sale, buy back in at +5.5%.
    function _cycleSellsTheLotAndBuysBackIn(string memory symbol)
        private
        returns (HedgeFunV2UpgradeableCycleTreasuryLogic t)
    {
        _launch(symbol, cycleKind, 0);
        (, uint256 treasuryStock) = _graduate();
        _assertGraduationLot(treasuryStock);
        t = HedgeFunV2UpgradeableCycleTreasuryLogic(address(treasury));
        assertEq(t.reentrySaleAt(), 0);

        // The whole lot goes at the first rung, one listing chunk per call; each sale re-arms the entry.
        _stockMovesTo(forkPrice * 106 / 100);
        (uint256 gaveUp,) = _takeProfit(forkPrice);
        assertLt(gaveUp, treasuryStock, "one chunk of the lot");
        assertEq(t.reentrySaleAt(), block.timestamp, "a live sale of a lot or more arms the recovery entry");
        (bool due, HedgeFunV2Treasury.Action next) = _due();
        while (due && next == HedgeFunV2Treasury.Action.TakeProfit) {
            (uint256 more,) = _takeProfit(forkPrice);
            gaveUp += more;
            (due, next) = _due();
        }
        assertEq(gaveUp, treasuryStock, "the whole lot was sold");
        assertEq(t.lotCount(), 0, "in cash: without the recovery entry the next buy needs a 5% fall");
        assertEq(t.bookedStock(), 0);
        uint256 sale = t.reentrySalePrice();
        assertEq(sale, marketPrice);

        // Under the rise the entry asks for, nothing is due.
        _stockMovesTo(sale * 103 / 100);
        _assertNothingDue();

        _stockMovesTo(sale * 1055 / 1000);
        _buyLot(HedgeFunV2Treasury.Action.BuyRecovery, t.params().sellChunkUsdg);
        assertEq(t.reentrySaleAt(), 0, "the entry is consumed");
        assertEq(t.reentrySalePrice(), 0);
        assertEq(t.lotCount(), 1);
    }

    // ================================================================================== an upgrade, kind 0
    /// The factory owner moves a live kind-0 treasury to the percentage buy-back through the controller: two days'
    /// notice, nothing moved, and the same treasury then burns a tenth per call and still buys the dip.
    function test_kind0_upgradeThroughTheTwoDayController_movesNothing_thenBurnsATenthAndBuysTheDip() public {
        _launch("E2EUPGRADE", 0, 1000);
        (, uint256 treasuryStock) = _graduate();
        _assertGraduationLot(treasuryStock);
        _stockMovesTo(forkPrice * 106 / 100);
        _takeProfit(forkPrice);

        HedgeFunV2UpgradeableTreasury proxy = HedgeFunV2UpgradeableTreasury(payable(address(treasury)));
        HedgeFunV2PercentBuybackTreasuryLogic next = new HedgeFunV2PercentBuybackTreasuryLogic(
            USDG, NVDA, NVDA_POOL, NVDA_ORACLE, address(token), address(PM), address(factory), treasury.params()
        );
        assertEq(next.upgradeConfigHash(), proxy.upgradeConfigHash(), "kind 0's own identity");
        bytes32 before = _ledger();
        vm.expectRevert(V2TreasuryUpgradeController.NotOwner.selector);
        vm.prank(CREATOR);
        controller.schedule(address(proxy), address(next), "");
        vm.prank(controller.owner());
        controller.schedule(address(proxy), address(next), "");
        vm.warp(block.timestamp + 2 days - 1);
        vm.expectRevert(V2TreasuryUpgradeController.NotReady.selector);
        controller.execute(address(proxy), "");
        assertEq(proxy.implementation(), proxy.initialImplementation());
        vm.warp(block.timestamp + 1);
        controller.execute(address(proxy), "");
        assertEq(proxy.implementation(), address(next));
        assertEq(_ledger(), before, "the upgrade moved nothing");

        _feedsPrintAgainAfterTheWait();
        uint256 budget = treasury.buybackStock();
        (uint256 spent,) = _buybackOnce(_tenthOrALot());
        assertLt(spent, budget, "the same treasury now offers a tenth of its budget");
        assertLt(spent, _fixedChunk(), "where kind 0 would have offered it all");

        _stockMovesTo(_afterTheFall());
        _buyLot(HedgeFunV2Treasury.Action.BuyDip, type(uint256).max);
    }

    function _ledger() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                treasury.bookedStock(), treasury.buybackStock(), treasury.lotCount(), treasury.lastSalePrice(),
                treasury.totalBurned(), treasury.totalStockReceived(), treasury.params(),
                IERC20(NVDA).balanceOf(address(treasury)), IERC20(USDG).balanceOf(address(treasury)),
                token.totalSupply(), treasury.liquidityVault()
            )
        );
    }
}

