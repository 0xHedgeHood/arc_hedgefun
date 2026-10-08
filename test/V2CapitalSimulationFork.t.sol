// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunBondingCurve as Curve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter as Router} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {HedgeFunHook} from "../src/hooks/HedgeFunHook.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";

/// In-memory testnet fork only. No signing, keys, broadcast, or public-chain mutations.
/// Forty distinct callers are sequential EVM calls at one timestamp, not a sequencer bundle.
/// Costs are actual direct-stock spends marked at the fork's stock/USDG oracle reference.
contract V2CapitalSimulationForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    HedgeFunV2Factory constant FACTORY = HedgeFunV2Factory(0x3E95976E2425e63cb2A8d48BBce8976F55627019);
    Router constant ROUTER = Router(0xf86Ee10C49d89a47Bd0E8Ec5c390631F7b454B65);
    IERC20 constant STOCK = IERC20(0xcee322837F181Bd93AC2d71e4dDf334BFF565b98);
    IERC20 constant USDG = IERC20(0x539574139BB4Ac74Fd2183ba0E38ed777E30B58d);
    IUniswapV3Pool constant FUNDING_POOL = IUniswapV3Pool(0x04083643FF9E8c27f66C9dD99947743A9B777244);
    address constant CREATOR = address(0xCA100);
    address constant SWEEPER = address(0xCA200);
    uint256 constant N = 40;
    uint256 constant TARGET_FDV = 2_000_000e18;
    Curve internal curve;
    IERC20 internal token;
    PoolKey internal key;
    uint256 internal id;
    uint256 internal stockPrice;
    uint256 internal initialSupply;
    uint256 internal launchFee;
    uint256 internal spent;
    uint256 internal forkBlock;
    uint256 internal forkTimestamp;
    bytes32 internal forkHash;

    struct Measurement {
        uint256 spend;
        uint256 supply;
        uint256 held;
        uint256 fdv;
        uint256 fdvBeforeSweep;
        uint256 supplyBeforeSweep;
    }

    function setUp() public virtual {
        vm.skip(vm.envOr("V2_CAPITAL_FORK", uint256(0)) == 0, "opt-in in-memory fork only");
        uint256 pinned = vm.envOr("V2_CAPITAL_BLOCK", uint256(0));
        string memory rpc = "https://rpc.testnet.chain.robinhood.com";
        if (pinned == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pinned);
        forkBlock = block.number;
        forkTimestamp = block.timestamp;
        forkHash = blockhash(block.number - 1);
        assertEq(block.chainid, 46630);
        assertEq(address(ROUTER.factory()), address(FACTORY));
        assertGt(address(FACTORY).code.length, 0);
    }

    function _wallet(uint256 i) internal pure returns (address) {
        return address(uint160(0xCA000 + i));
    }

    function _launch(uint16 sale, uint256 whitelistCount, uint16 baseTax) internal {
        HedgeFunFactory.Defaults memory d = FACTORY.getDefaults();
        initialSupply = d.supply;
        launchFee = d.launchFeeAmount;
        assertEq(uint256(d.launchFeeCurrency), uint256(HedgeFunFactory.FeeCurrency.Usdg));
        (address oracle,, uint256 opening, bool enabled) = FACTORY.listings(address(STOCK));
        assertTrue(enabled);
        stockPrice = PriceOracle(oracle).price();
        assertEq(stockPrice, 358e18, "snapshot changed: update report assumptions");
        assertEq(V2TreasuryDeployer(address(FACTORY.treasuryDeployer())).lpBps(address(STOCK)), 5000);
        HedgeFunFactory.Request memory q;
        q.name = "Local capital simulation only";
        q.symbol = "CAPFORK";
        q.creator = CREATOR;
        q.stock = address(STOCK);
        q.nonce = 987654321;
        q.taxBps = baseTax;
        q.creatorBps = 1000;
        q.tp1Bps = 500;
        q.tp2Bps = 1000;
        q.dipBps = 500;
        q.stopBps = 500;
        q.lotBps = 2000;
        q.maxFee = launchFee;
        q.expectedOpenPriceE18 = opening;
        q = _ruleRequest(q);
        address[] memory exemptions = new address[](whitelistCount);
        for (uint256 i; i < whitelistCount; ++i) {
            exemptions[i] = _wallet(i);
        }
        deal(FACTORY.usdg(), CREATOR, launchFee);
        vm.startPrank(CREATOR);
        FACTORY.curveDeployer().setCurveConfig(q.symbol, q.nonce, sale, 180);
        FACTORY.curveDeployer().setOpeningTaxExemptions(q.symbol, q.nonce, exemptions);
        IERC20(FACTORY.usdg()).approve(address(FACTORY), launchFee);
        (,, bytes32 terms) = FACTORY.predict(q);
        id = FACTORY.launch(q, terms);
        vm.stopPrank();
        curve = Curve(FACTORY.curves(id));
        token = IERC20(curve.token());
        (key,) = FACTORY.graduationConfig(id);
        assertEq(curve.virtualStock(), 26.5e18);
        for (uint256 i; i < N; ++i) {
            assertEq(token.balanceOf(_wallet(i)), 0, "fresh holder required");
            // Local storage funding; this deliberately does not simulate acquiring TSLA on V3.
            deal(address(STOCK), _wallet(i), 1_000_000e18);
            vm.prank(_wallet(i));
            STOCK.approve(address(ROUTER), type(uint256).max);
        }
    }

    function _ruleRequest(HedgeFunFactory.Request memory q)
        internal
        view
        virtual
        returns (HedgeFunFactory.Request memory)
    {
        return q;
    }

    function _buy(uint256 i, uint256 amount, uint8 stage) internal {
        uint256 beforeBalance = STOCK.balanceOf(_wallet(i));
        Router.TradeParams memory p =
            Router.TradeParams(id, address(STOCK), amount, amount, 1, block.timestamp, stage, false);
        vm.prank(_wallet(i));
        (, uint256 refund) = ROUTER.buy(p, new Router.Hop[](0));
        assertEq(refund, 0, "strict direct-stock buy must fully fill");
        spent += beforeBalance - STOCK.balanceOf(_wallet(i));
        assertEq(STOCK.balanceOf(address(ROUTER)), 0);
        assertEq(token.balanceOf(address(ROUTER)), 0);
    }

    function _held() internal view returns (uint256 h) {
        for (uint256 i; i < N; ++i) {
            h += token.balanceOf(_wallet(i));
        }
    }

    function _fdv() internal view returns (uint256 value) {
        (uint160 sqrt,,,) = FACTORY.poolManager().getSlot0(key.toId());
        uint256 ratioQ96 = Math.mulDiv(sqrt, sqrt, 1 << 96);
        uint256 stockFdv = address(token) < address(STOCK)
            ? Math.mulDiv(token.totalSupply(), ratioQ96, 1 << 96)
            : Math.mulDiv(token.totalSupply(), 1 << 96, ratioQ96);
        value = Math.mulDiv(stockFdv, stockPrice, 1e18);
    }

    function _measure() internal virtual returns (Measurement memory m) {
        m.spend = spent;
        m.fdvBeforeSweep = _fdv();
        m.supplyBeforeSweep = token.totalSupply();
        HedgeFunHook hook = FACTORY.hook();
        vm.prank(SWEEPER);
        hook.sweep(key.toId());
        (uint256 tokenTax,) = hook.accrued(key.toId());
        assertEq(tokenTax, 0, "token tax settlement must succeed");
        m.supply = token.totalSupply();
        m.held = _held();
        m.fdv = _fdv();
        assertEq(
            m.supply,
            m.held + token.balanceOf(address(FACTORY.poolManager())) + token.balanceOf(SWEEPER),
            "group, V4 inventory and independent sweep tips conserve surviving supply"
        );
    }

    function _meets(bool fdvTarget) private returns (bool) {
        Measurement memory m = _measure();
        return fdvTarget ? m.fdv >= TARGET_FDV : m.held * 100 >= m.supply * 80;
    }

    /// Snapshot probes find the minimum one additional stock order, then execute only the winning order.
    /// Searches use raw 18-decimal stock units, actual hooked V4 swaps and settled burns, not an AMM formula.
    function _reach(bool fdvTarget) private returns (Measurement memory) {
        if (_meets(fdvTarget)) return _measure();
        uint256 checkpoint = vm.snapshotState();
        uint256 lo;
        uint256 hi = 1e18;
        while (true) {
            _buy(0, hi, 2);
            bool enough = _meets(fdvTarget);
            assertTrue(vm.revertToState(checkpoint));
            if (enough) break;
            hi *= 2;
            require(hi <= 100_000e18, "target not bracketed");
        }
        while (hi - lo > 1e10) {
            // 0.00000001 TSLA, below $0.000004 at this snapshot
            uint256 mid = (hi + lo) / 2;
            _buy(0, mid, 2);
            bool enough = _meets(fdvTarget);
            assertTrue(vm.revertToState(checkpoint));
            if (enough) hi = mid;
            else lo = mid;
        }
        vm.deleteStateSnapshot(checkpoint);
        _buy(0, hi, 2);
        Measurement memory result = _measure();
        assertTrue(fdvTarget ? result.fdv >= TARGET_FDV : result.held * 100 >= result.supply * 80);
        return result;
    }

    function _serialize(string memory name, Measurement memory m) private returns (string memory json) {
        vm.serializeUint(name, "stockSpentRaw", m.spend);
        vm.serializeUint(name, "usdReferenceE18", Math.mulDiv(m.spend, stockPrice, 1e18));
        vm.serializeUint(name, "totalSupplyRaw", m.supply);
        vm.serializeUint(name, "heldRaw", m.held);
        vm.serializeUint(name, "ownershipBps", m.held * 10_000 / m.supply);
        vm.serializeUint(name, "fdvBeforeLastSweepE18", m.fdvBeforeSweep);
        vm.serializeUint(name, "supplyBeforeLastSweepRaw", m.supplyBeforeSweep);
        vm.serializeUint(name, "upfrontV3FundingUsdgRaw", _fundingCost(m.spend));
        json = vm.serializeUint(name, "fdvAfterSweepE18", m.fdv);
    }

    /// Independent initial-V3-state exact-output funding quote for the cumulative stock budget.
    /// Acquire all stock up front, then hold it during launch; not a sequence of per-wallet routing quotes.
    function _fundingCost(uint256 amount) internal virtual returns (uint256 usdSpent) {
        uint256 checkpoint = vm.snapshotState();
        deal(address(USDG), address(this), 100_000_000e6);
        uint256 beforeStock = STOCK.balanceOf(address(this));
        uint256 beforeUsd = USDG.balanceOf(address(this));
        bool zeroForOne = FUNDING_POOL.token0() == address(USDG);
        assertEq(FACTORY.v3Factory().getPool(address(STOCK), address(USDG), FUNDING_POOL.fee()), address(FUNDING_POOL));
        FUNDING_POOL.swap(
            address(this),
            zeroForOne,
            -int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            abi.encode(amount)
        );
        assertEq(STOCK.balanceOf(address(this)) - beforeStock, amount, "funding route must deliver full stock budget");
        usdSpent = beforeUsd - USDG.balanceOf(address(this));
        assertTrue(vm.revertToStateAndDelete(checkpoint));
    }

    function uniswapV3SwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        require(msg.sender == address(FUNDING_POOL), "only canonical funding pool");
        bool usdIs0 = FUNDING_POOL.token0() == address(USDG);
        int256 payment = usdIs0 ? amount0 : amount1;
        require(payment > 0 && (usdIs0 ? amount1 : amount0) < 0, "funding deltas");
        assertTrue(USDG.transfer(msg.sender, uint256(payment)));
    }

    function _run(string memory name, uint16 sale, uint256 exemptions, bool wait, uint16 baseTax) private {
        _launch(sale, exemptions, baseTax);
        if (wait) vm.warp(block.timestamp + curve.snipeSeconds());
        uint256 raise = curve.terminalStock() - curve.virtualStock();
        uint256 each = raise / N;
        for (uint256 i; i < N; ++i) {
            uint256 amount = i + 1 == N ? curve.terminalStock() - curve.virtualStock() - curve.realStockReserve() : each;
            _buy(i, amount, 0);
        }
        assertEq(uint256(curve.status()), 2);
        assertEq(spent, raise);
        Measurement memory graduation = _measure();
        Measurement memory eighty = _reach(false);
        Measurement memory twoMillion = _reach(true);
        assertGe(twoMillion.fdv, TARGET_FDV);
        assertLt(twoMillion.fdv, TARGET_FDV + 1e15, "target cost should be tight to one tenth of a cent");
        vm.serializeUint(name, "forkBlock", forkBlock);
        vm.serializeString(name, "scenario", name);
        vm.serializeUint(name, "forkTimestamp", forkTimestamp);
        vm.serializeBytes32(name, "forkParentHash", forkHash);
        vm.serializeUint(name, "scenarioTimestamp", block.timestamp);
        vm.serializeUint(name, "saleBps", sale);
        vm.serializeUint(name, "walletCount", N);
        vm.serializeUint(name, "openingExemptWallets", exemptions);
        vm.serializeBool(name, "waitedForWindow", wait);
        vm.serializeUint(name, "baseTaxBps", baseTax);
        vm.serializeUint(name, "stockPriceE18", stockPrice);
        vm.serializeUint(name, "launchFeeUsdgRaw", launchFee);
        vm.serializeUint(name, "initialSupplyRaw", initialSupply);
        vm.serializeString(name, "graduation", _serialize(string.concat(name, "_graduation"), graduation));
        vm.serializeString(name, "ownership80", _serialize(string.concat(name, "_eighty"), eighty));
        string memory json =
            vm.serializeString(name, "fdv2m", _serialize(string.concat(name, "_twoMillion"), twoMillion));
        console2.log("CAPITAL_RESULT", json);
    }

    function testFork_Default44_32Exempt_Opening() public {
        _run("default44_32exempt_opening", 4400, 32, false, 300);
    }

    function testFork_Default44_NoExempt_Opening() public {
        _run("default44_noexempt_opening", 4400, 0, false, 300);
    }

    function testFork_Default44_AfterWindow() public {
        _run("default44_after_window", 4400, 0, true, 300);
    }

    function testFork_Sale80_32Exempt_Opening() public {
        _run("sale80_32exempt_opening", 8000, 32, false, 300);
    }

    function testFork_Sale80_AfterWindow() public {
        _run("sale80_after_window", 8000, 0, true, 300);
    }

    function testFork_Default44_Base10_AfterWindow() public {
        _run("default44_tax10_after_window", 4400, 0, true, 1000);
    }
}
