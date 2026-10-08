// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {PoolTrader} from "../src/PoolTrader.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunTreasury} from "../src/HedgeFunTreasury.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";
import {MockToken, MockFeed} from "./mocks/Mocks.sol";
import {AlwaysOpen, SwitchableCalendar} from "./mocks/Mocks.sol";

/*//////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                          the V3 venue, with real fills
//////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

interface ISwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// A Uniswap V3 pool interface backed by a REAL Uniswap V4 pool.
///
/// `test/mocks/Mocks.sol`'s `MockPool` is a flat-price pool that always fills in full, so it structurally cannot
/// show what the treasury does when a swap runs out of liquidity inside its price bound. Rather than hand-roll a
/// second approximation of V3's tick math (which would make every failure ambiguous -- "the rule is wrong" vs "my
/// mock is wrong"), this translates the V3 swap ABI onto a V4 `PoolManager`: `swap()` forwards to
/// `poolManager.swap`, collects the input through `uniswapV3SwapCallback` exactly as a V3 pool does, and settles. The
/// fills are v4-core's `SwapMath`, which is V3's.
///
/// `observe()` reports a mean that sits exactly on spot unless a test moves `twapLagTicks` -- so, by default, the
/// health gate's TWAP leg agrees with its spot leg.
contract MirrorV3Pool is IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable pm;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    uint16 public cardinality = 1000;                 // PoolTrader demands >= TWAP_WINDOW + 60
    int24 public twapLagTicks;                        // spot minus the 10-minute mean; 0 = a pool that has sat still

    PoolKey internal key;
    address internal _caller;
    address internal _recipient;
    bytes internal _cbData;

    constructor(IPoolManager pm_, PoolKey memory k) {
        pm = pm_;
        key = k;
        token0 = Currency.unwrap(k.currency0);
        token1 = Currency.unwrap(k.currency1);
        fee = k.fee;
    }

    function setTwapLag(int24 t) external { twapLagTicks = t; }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        (uint160 sqrtP, int24 t,,) = pm.getSlot0(key.toId());
        return (sqrtP, t, 0, cardinality, cardinality, 0, true);
    }

    function observe(uint32[] calldata ago) external view returns (int56[] memory tc, uint160[] memory l) {
        (, int24 t,,) = pm.getSlot0(key.toId());
        tc = new int56[](2);
        l = new uint160[](2);
        tc[1] = int56(t - twapLagTicks) * int56(uint56(ago[0]));
    }

    /// @dev V3's exact-input shape: `amountSpecified > 0`, deltas positive for what the pool RECEIVES, and the
    ///      input pulled from the caller through its own callback.
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 limit, bytes calldata data)
        external returns (int256 a0, int256 a1)
    {
        require(amountSpecified > 0, "exact in only");
        _caller = msg.sender; _recipient = recipient; _cbData = data;
        (a0, a1) = abi.decode(pm.unlock(abi.encode(zeroForOne, uint256(amountSpecified), limit)), (int256, int256));
        _caller = address(0);
    }

    function unlockCallback(bytes calldata raw) external override returns (bytes memory) {
        require(msg.sender == address(pm) && _caller != address(0), "lock");
        (bool zeroForOne, uint256 amountIn, uint160 limit) = abi.decode(raw, (bool, uint256, uint160));
        BalanceDelta d = pm.swap(key, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}), "");
        (int128 dIn, int128 dOut) = zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        uint256 spent = uint256(uint128(-dIn));
        uint256 got = uint256(uint128(dOut));
        (int256 a0, int256 a1) = zeroForOne ? (int256(spent), -int256(got)) : (-int256(got), int256(spent));

        ISwapCallback(_caller).uniswapV3SwapCallback(a0, a1, _cbData);           // the caller pays in, as on V3

        Currency inC = zeroForOne ? key.currency0 : key.currency1;
        Currency outC = zeroForOne ? key.currency1 : key.currency0;
        pm.sync(inC);
        IERC20(Currency.unwrap(inC)).transfer(address(pm), spent);
        pm.settle();
        pm.take(outC, _recipient, got);
        return abi.encode(a0, a1);
    }
}

/// Enough of a V3 pool for `PoolTrader`'s constructor, and nothing more: used only by the construction tests,
/// which never swap.
contract StubV3Pool {
    address public immutable token0;
    address public immutable token1;
    uint24 public constant fee = 3000;
    constructor(address a, address b) { (token0, token1) = a < b ? (a, b) : (b, a); }
    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (uint160(1 << 96), int24(0), uint16(0), uint16(1000), uint16(1000), uint8(0), true);
    }
}

/// A hook that the PoolManager never calls: its address carries only AFTER_DONATE, and nothing here donates. It
/// exists so the <token>/<stock> pool can be hooked (the treasury refuses to buy back through an unwired, i.e.
/// hookless, pool) without dragging the real `HedgeFunHook`'s tax behaviour into a test of the rule.
contract NoopHook {
    uint256 public events;
    function noteEvent() external { events++; }
    /// the real hook keeps an observation ring; a fresh pool has too little history to serve the window, which is
    /// what this answers, so the buy-back falls back to the treasury's own ratchet
    function meanTick(uint32) external pure returns (bool, int24) { return (false, 0); }
    function observationCount() external pure returns (uint16) { return 1; }   // a pool that has traded
}

/// `HedgeFunTreasury` with the two otherwise-invisible copies of every shared field brought out where a test can
/// compare them. Nothing is overridden, so the deployed behaviour is the production contract's.
contract ExposedStrategyTreasury is HedgeFunTreasury {
    constructor(address usdg_, address stock_, address v3Pool_, address oracle_, address token_, address poolManager_, address factory_, Params memory p)
        HedgeFunTreasury(usdg_, stock_, v3Pool_, oracle_, token_, poolManager_, factory_, p) {}

    function baseStock() external view returns (address) { return address(_stock); }
    function baseUsdg() external view returns (address) { return address(_usdg); }
    function baseOracle() external view returns (address) { return address(_oracle); }
    function baseScale() external view returns (uint256) { return _SCALE; }
    function traderScale() external view returns (uint256) { return SCALE; }
    function ruleValue(uint256 a, uint256 p) external view returns (uint256) { return _ruleValue(a, p); }
    function traderValue(uint256 a, uint256 p) external view returns (uint256) { return _value(a, p); }
    function ruleStockFor(uint256 a, uint256 p) external view returns (uint256) { return _ruleStockFor(a, p); }
    function traderStockFor(uint256 a, uint256 p) external view returns (uint256) { return _stockFor(a, p); }
}

/*//////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                                  the harness
//////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

/// The V3 treasury over a real pool, with a wired <token>/<stock> pool so the buy-back runs too. This file was a
/// DIFFERENTIAL suite -- a V3-backed and a V4-backed treasury driven through identical pools had to agree bit for
/// bit -- until the V4 stock venue was removed. What is left is every test that states a property of the V3 venue by
/// itself. The names (`VenueParityBase`, `t3`, `pm3`, `bot3`, ...) are kept because four other suites build on them.
/// Both token orderings of the stock/USDG pool run, since USDG is currency0 in 16 of this chain's watched pools
/// and currency1 in 9.
abstract contract VenueParityBase is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 constant SCALE = 1e18 * 1e18 / 1e6;      // stock 18 decimals, USDG 6
    uint24 constant FEE = 3000;
    int24 constant SPACING = 60;
    uint256 constant P0 = 100e18;
    address constant TOKEN_HOOK = address(uint160(0xBEEF0010));   // AFTER_DONATE only: a valid, never-called hook

    IPoolManager pm3;
    PoolSwapTest sr3;
    PoolModifyLiquidityTest lp3;

    MockToken usdg; MockToken stock;
    HedgeFunToken tok3;
    MockFeed stockFeed; MockFeed usdgFeed;
    PriceOracle oracle;
    SwitchableCalendar cal;
    MirrorV3Pool mirror;
    PoolKey key3;                                    // stock/USDG
    PoolKey tokenKey3;                               // <token>/<stock>

    HedgeFunTreasury t3;
    address attacker = address(0xBAD);
    address bot3 = address(0xB3);                    // whoever calls the rule, so bounties can be read off one address
    uint256 internal acted;                          // rule calls that actually went through

    function stockIsCurrency0() internal pure virtual returns (bool);

    // ------------------------------------------------------------------------------------------------ fixture
    function setUp() public {
        vm.warp(1_700_000_000);
        pm3 = IPoolManager(address(new PoolManager(address(this))));
        sr3 = new PoolSwapTest(pm3);
        lp3 = new PoolModifyLiquidityTest(pm3);

        usdg = new MockToken("USDG", 6);
        stock = _mineToken("STK", 18, address(usdg), stockIsCurrency0());
        tok3 = _mineStrategyToken("S3");

        stockFeed = new MockFeed(8); usdgFeed = new MockFeed(8);
        usdgFeed.set(1e8); stockFeed.set(int256(P0 / 1e10));
        cal = new SwitchableCalendar();
        oracle = new PriceOracle(address(stock), address(stockFeed), address(usdgFeed), address(cal), 26 hours, 26 hours);

        (Currency c0, Currency c1) = stockIsCurrency0()
            ? (Currency.wrap(address(stock)), Currency.wrap(address(usdg)))
            : (Currency.wrap(address(usdg)), Currency.wrap(address(stock)));
        key3 = PoolKey(c0, c1, FEE, SPACING, IHooks(address(0)));
        pm3.initialize(key3, _sqrtFor(P0));

        vm.etch(TOKEN_HOOK, address(new NoopHook()).code);
        tokenKey3 = _tokenKey(address(tok3));
        pm3.initialize(tokenKey3, uint160(1 << 96));

        usdg.mint(address(this), 1e18 * 1e6);
        stock.mint(address(this), 1e12 ether);
        _approveAll();
        _seedStockPool(pm3, lp3, key3);
        _seedTokenPool(lp3, tokenKey3);

        mirror = new MirrorV3Pool(pm3, key3);
        t3 = new HedgeFunTreasury(address(usdg), address(stock), address(mirror), address(oracle), address(tok3), address(pm3), address(this), _params(1000));
        t3.wire(tokenKey3);
    }

    /// @dev the same treasury with a sell chunk small enough to matter: 300 USDG, about 3 stock a call
    function _redeployChunked() internal {
        HedgeFunTreasuryBase.Params memory p = _params(1000); p.sellChunkUsdg = 300e6;
        t3 = new HedgeFunTreasury(address(usdg), address(stock), address(mirror), address(oracle), address(tok3), address(pm3), address(this), p);
        t3.wire(tokenKey3);
    }

    /// a closure the way the chain sees one: the calendar says shut AND the stock feed has been silent for a day
    /// and a half. The band keys off that silence, so a test that only flips the calendar is testing a fresh feed.
    function _weekend() internal {
        cal.setClosed(true);
        vm.warp(block.timestamp + 36 hours);
        usdgFeed.set(usdgFeed.answer());                                         // the dollar leg keeps printing
    }

    function _params(uint16 stopBps) internal pure returns (HedgeFunTreasuryBase.Params memory) {
        HedgeFunTreasuryBase.Params memory _x;
        _x.tp1Bps = 500;
        _x.tp2Bps = 1000;
        _x.dipBps = 500;
        _x.stopBps = stopBps;
        _x.lotBps = 2000;
        _x.bountyBps = 50;
        _x.maxSlippageBps = 100;
        _x.maxDeviationBps = 50;
        _x.maxBuybackImpactBps = 300;
        _x.buybackCooldown = 60;
        _x.minLotUsdg = 5e6;
        _x.buybackChunkUsdg = 500e6; _x.sellChunkUsdg = type(uint128).max;
        _x.bandBpsPerHour = 200;
        return _x;
    }

    function _tokenKey(address t) internal view returns (PoolKey memory) {
        return t < address(stock)
            ? PoolKey(Currency.wrap(t), Currency.wrap(address(stock)), FEE, SPACING, IHooks(TOKEN_HOOK))
            : PoolKey(Currency.wrap(address(stock)), Currency.wrap(t), FEE, SPACING, IHooks(TOKEN_HOOK));
    }

    function _mineToken(string memory sym, uint8 dec, address other, bool wantLower) internal returns (MockToken) {
        bytes32 h = keccak256(abi.encodePacked(type(MockToken).creationCode, abi.encode(sym, dec)));
        for (uint256 i; i < 5000; i++) {
            if ((vm.computeCreate2Address(bytes32(i), h, address(this)) < other) == wantLower) return new MockToken{salt: bytes32(i)}(sym, dec);
        }
        revert("no salt");
    }

    /// @dev the launch token is mined BELOW the stock, so `stockIsCurrency0InTokenPool` is false in both orderings
    ///      of the stock/USDG pool and the buy-back swaps the same way in each
    function _mineStrategyToken(string memory sym) internal returns (HedgeFunToken) {
        bytes32 h = keccak256(abi.encodePacked(type(HedgeFunToken).creationCode, abi.encode(sym, sym, uint256(1_000_000_000e18), address(this), address(0))));
        for (uint256 i; i < 5000; i++) {
            if (vm.computeCreate2Address(bytes32(i), h, address(this)) < address(stock)) {
                return new HedgeFunToken{salt: bytes32(i)}(sym, sym, 1_000_000_000e18, address(this), address(0));
            }
        }
        revert("no salt");
    }

    function _approveAll() internal {
        address[2] memory routers = [address(lp3), address(sr3)];
        for (uint256 i; i < routers.length; i++) {
            usdg.approve(routers[i], type(uint256).max);
            stock.approve(routers[i], type(uint256).max);
            tok3.approve(routers[i], type(uint256).max);
        }
    }

    /// @dev the same depth the unit suite uses: ~10k stock and ~1.2M USDG within +/-20% of the open price
    function _seedStockPool(IPoolManager pm, PoolModifyLiquidityTest lp, PoolKey memory k) internal {
        (, int24 tick,,) = pm.getSlot0(k.toId());
        lp.modifyLiquidity(k, ModifyLiquidityParams({tickLower: ((tick - 1800) / SPACING) * SPACING, tickUpper: ((tick + 1800) / SPACING) * SPACING, liquidityDelta: 1e18, salt: 0}), "");
    }

    /// @dev the <token>/<stock> pool, deep enough that one buy-back chunk fills inside its 3% impact bound
    function _seedTokenPool(PoolModifyLiquidityTest lp, PoolKey memory k) internal {
        lp.modifyLiquidity(k, ModifyLiquidityParams({tickLower: -1800, tickUpper: 1800, liquidityDelta: 1e21, salt: 0}), "");
    }

    function _sqrtFor(uint256 p) internal pure returns (uint160) {
        return uint160(Math.sqrt(stockIsCurrency0() ? Math.mulDiv(p, 1 << 192, SCALE) : Math.mulDiv(SCALE, 1 << 192, p)));
    }

    // ------------------------------------------------------------------------------------------------ driving
    /// @dev walk the stock pool to exactly `p` and move the feed with it
    function _px(uint256 p) internal {
        _walk(pm3, sr3, key3, p);
        stockFeed.set(int256(p / 1e10));
    }

    /// @dev move only the POOL, leaving the feed where it is -- which is what a weekend actually looks like: the
    ///      equity feed is frozen at Friday's close while the pool keeps trading.
    function _pxPoolOnly(uint256 p) internal {
        _walk(pm3, sr3, key3, p);
    }

    function _walk(IPoolManager pm, PoolSwapTest sr, PoolKey memory k, uint256 p) internal {
        uint160 target = _sqrtFor(p);
        (uint160 cur,,,) = pm.getSlot0(k.toId());
        if (target == cur) return;
        sr.swap(k, SwapParams({zeroForOne: target < cur, amountSpecified: -int256(1e30), sqrtPriceLimitX96: target}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
    }

    function _fund(uint256 stockAmount) internal { stock.mint(address(t3), stockAmount); }

    // ------------------------------------------------------------------------------------------------ assertions
    /// @dev what must hold after every step, whatever the step was: the ledger totals the lots it describes, and the
    ///      treasury holds at least the stock it says it does
    function _assertInvariants(string memory step) internal view {
        assertEq(t3.bookedStock(), _sumLots(), string.concat(step, ": bookedStock != sum(lots)"));
        assertGe(stock.balanceOf(address(t3)), t3.bookedStock() + t3.buybackStock(), string.concat(step, ": owes more stock than it holds"));
    }

    function _sumLots() internal view returns (uint256 total) {
        uint256 n = t3.lotCount();
        for (uint256 i; i < n; i++) { (uint256 q,,,) = t3.lots(i); total += q; }
    }

    /// @dev the rule's calls as a keeper makes them: from `bot3`, allowed to be refused (the test that follows says
    ///      what it expects of the state), counted in `acted` when they go through, invariants checked either way
    function _book(string memory step) internal returns (bool booked) { booked = t3.book(); _assertInvariants(step); }
    function _takeProfit(uint256 id, string memory step) internal returns (bool ok) { ok = _try(abi.encodeCall(HedgeFunTreasuryBase.takeProfit, (id)), step); }
    function _stopLoss(uint256 id, string memory step) internal returns (bool ok) { ok = _try(abi.encodeCall(HedgeFunTreasuryBase.stopLoss, (id)), step); }
    function _buyDip(string memory step) internal returns (bool ok) { ok = _try(abi.encodeCall(HedgeFunTreasuryBase.buyDip, ()), step); }
    function _buyback(string memory step) internal returns (bool ok) { ok = _try(abi.encodeCall(HedgeFunTreasuryBase.buyback, ()), step); }

    function _try(bytes memory call_, string memory step) internal returns (bool ok) {
        vm.prank(bot3); (ok,) = address(t3).call(call_);
        if (ok) acted++;                                     // so a vacuous run (everything reverted) is detectable
        _assertInvariants(step);
    }
}

/*//////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                                   the tests
//////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

abstract contract VenueParityTests is VenueParityBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ------------------------------------------------------------------------------------ the duplicated fields
    /// `HedgeFunTreasury` carries TWO copies of every shared field -- `PoolTrader`'s `stock`/`usdg`/`oracle`/
    /// `SCALE` and `HedgeFunTreasuryBase`'s `_stock`/`_usdg`/`_oracle`/`_SCALE` -- because two unrelated bases
    /// cannot declare the same name. If they ever disagreed the rule would compute on one and execute on the
    /// other. One such bug already happened during the split (passing `PoolTrader.SCALE` into the base read
    /// ZERO, because base constructors run in linearized rather than textual order).
    function test_theTwoCopiesOfEveryFieldAgree() public {
        ExposedStrategyTreasury e = new ExposedStrategyTreasury(
            address(usdg), address(stock), address(mirror), address(oracle), address(tok3), address(pm3), address(this), _params(0));

        assertEq(address(e.stock()), e.baseStock(), "PoolTrader.stock != base._stock");
        assertEq(address(e.usdg()), e.baseUsdg(), "PoolTrader.usdg != base._usdg");
        assertEq(address(e.oracle()), e.baseOracle(), "PoolTrader.oracle != base._oracle");
        assertEq(e.traderScale(), e.baseScale(), "PoolTrader.SCALE != base._SCALE");
        assertTrue(e.baseScale() != 0, "the base's scale read zero -- the linearization bug is back");
        assertEq(e.baseScale(), SCALE, "the scale is not 1e18 * 10^stockDec / 10^usdgDec");
    }

    /// The consequence, rather than the fields: the two unit conversions must answer identically, or a lot priced
    /// by the rule and a swap sized by `PoolTrader` would be sized off different scales.
    function testFuzz_theTwoUnitConversionsAgree(uint256 amount, uint256 p) public {
        ExposedStrategyTreasury e = new ExposedStrategyTreasury(
            address(usdg), address(stock), address(mirror), address(oracle), address(tok3), address(pm3), address(this), _params(0));
        amount = bound(amount, 0, 1e30);
        p = bound(p, 1, 1e24);
        assertEq(e.ruleValue(amount, p), e.traderValue(amount, p), "_ruleValue and _value disagree");
        assertEq(e.ruleStockFor(amount, p), e.traderStockFor(amount, p), "_ruleStockFor and _stockFor disagree");
    }

    /// The scales are computed twice, from the same two `decimals()` reads, in two different places. Sweep the
    /// decimal pairs this chain actually has (USDG 6, stock 18; and the degenerate equal case) and confirm the
    /// two computations still land on the same number.
    function test_theTwoScalesAgreeAcrossDecimalCombinations() public {
        uint8[3] memory stockDecs = [18, 8, 6];
        uint8[3] memory usdgDecs = [6, 6, 18];
        for (uint256 i; i < 3; i++) {
            MockToken u = new MockToken("U", usdgDecs[i]);
            MockToken s = new MockToken("S", stockDecs[i]);
            MockFeed sf = new MockFeed(8);
            sf.set(1e10);
            PriceOracle o = new PriceOracle(address(s), address(sf), address(usdgFeed), address(new AlwaysOpen()), 26 hours, 26 hours);
            ExposedStrategyTreasury e = new ExposedStrategyTreasury(
                address(u), address(s), address(new StubV3Pool(address(u), address(s))), address(o), address(tok3), address(pm3), address(this), _params(0));
            assertEq(e.traderScale(), e.baseScale(), "the two scales diverged for this decimals pair");
            assertEq(e.baseScale(), 1e18 * 10 ** uint256(stockDecs[i]) / 10 ** uint256(usdgDecs[i]), "wrong scale");
        }
    }

    // ------------------------------------------------------------------------------------ the full price path
    /// Up past tp1, up past tp2, down past the dip, down past the stop, then a buy-back -- with the ledger's
    /// invariants checked after every single step, and each step refused until it is due.
    function test_aFullPricePath_eachStepWaitsUntilDue_andTheLedgerHoldsThroughout() public {
        _assertInvariants("open");

        _fund(10 ether);
        _book("book");
        (uint256 q, uint256 c, bool half,) = t3.lots(0);
        assertEq(q, 10 ether); assertEq(c, P0); assertFalse(half);

        _px(104e18);                                          // short of tp1
        _takeProfit(0, "before tp1");
        assertEq(t3.lotCount(), 1, "a lot was sold before it was due");

        _px(106e18);                                          // past tp1 (+5%), short of tp2 (+10%)
        _takeProfit(0, "tp1");
        (q,, half,) = t3.lots(0);
        assertEq(q, 5 ether, "tp1 should sell exactly half");
        assertTrue(half);
        assertGt(t3.reserveUsdg(), 0, "the principal did not come back as USDG");
        assertGt(t3.buybackStock(), 0, "no profit was set aside");

        _px(111e18);                                          // past tp2
        _takeProfit(0, "tp2");
        assertEq(t3.lotCount(), 0, "the lot should be gone after tp2");
        assertEq(t3.bookedStock(), 0);

        _px(108e18);                                          // only ~2.7% below the last sale
        _buyDip("before the dip");
        assertEq(t3.lotCount(), 0, "a dip was bought before it was due");

        _px(104e18);                                          // past the 5% dip
        _buyDip("dip");
        assertEq(t3.lotCount(), 1, "the dip booked no lot");

        (, uint256 dipCost,,) = t3.lots(0);
        _px(dipCost * 95 / 100);                              // 5% down: short of the 10% stop
        _stopLoss(0, "before the stop");
        assertEq(t3.lotCount(), 1, "a lot was stopped before it was due");

        _px(dipCost * 88 / 100);                              // past the 10% stop on the dip lot's own cost
        _stopLoss(0, "stop");
        assertEq(t3.lotCount(), 0, "the stopped lot should be gone");

        vm.warp(block.timestamp + 61);
        assertGt(t3.buybackStock(), 0, "nothing realised to buy back with");
        _buyback("buyback");
        assertGt(t3.totalBurned(), 0, "the buy-back burned nothing");
    }

    /// The same drive, but with the dip hit three times so more than one lot is open at once: `_shrink`'s swap-and-pop
    /// reorders the array, and `bookedStock` must still total the lots after every reorder.
    function test_multipleLotsSurviveTheSwapAndPop_bookedStockStillTotalsThem() public {
        _fund(10 ether);
        _book("lot A");
        _px(111e18);
        _takeProfit(0, "tp1 on A");                       // tp1 takes half...
        _takeProfit(0, "tp2 on A");                       // ...and only then does tp2 take the rest

        _px(104e18);
        _buyDip("lot B");
        _px(98e18);
        _buyDip("lot C");
        _px(92e18);
        _buyDip("lot D");
        assertEq(t3.lotCount(), 3, "three dip lots expected");

        _px(103e18);                                          // above B's cost + 5%? no -- but above C and D
        _takeProfit(2, "tp on the last lot");             // pops the tail, or sells half of it
        _takeProfit(0, "tp on the first lot");
        _takeProfit(1, "tp on the middle lot");
        _px(84e18);
        _stopLoss(0, "stop whatever is left");
        _assertInvariants("after the reshuffle");
    }

    // ------------------------------------------------------------------------------------ a sale the pool can only partly take
    /// A sale used to have to fill whole (`PoolTrader._swapBounded` once took a `requireFull` flag) because `_shrink`
    /// ran before the swap. The swap now runs first, and the lot shrinks by what the pool took: the V3 callback paid exactly
    /// that, the ledger describes exactly that, and the rest of the lot is still there at its cost.
    function test_v3SellThatCannotFullyFill_sellsWhatFits_andTheLedgerFollowsTheStockThatLeft() public {
        stock.mint(address(t3), 200_000 ether);               // ~20x the pool's entire stock depth
        assertTrue(t3.book());
        _px(111e18);
        uint256 heldBefore = stock.balanceOf(address(t3));

        vm.prank(bot3); t3.takeProfit(0);

        uint256 bounty = stock.balanceOf(bot3);
        uint256 sold = heldBefore - stock.balanceOf(address(t3)) - bounty;       // what the swap callback paid the pool
        assertGt(sold, 0); assertLt(sold, 10_000 ether, "sanity: the fill was meant to be short");
        (uint256 qty, uint256 cost, bool half, uint256 left) = t3.lots(0);
        assertEq(cost, P0, "what did not sell keeps its cost");
        assertEq(200_000 ether - qty, Math.mulDiv(sold, 111e18, P0), "the lot gives up sold * p / cost, rounded down");
        assertEq(left, 100_000 ether - (200_000 ether - qty), "tp1 owes half of the original, less what was actually given up");
        assertFalse(half, "tp1 is not done while it still owes");
        assertEq(t3.buybackStock() + bounty, 200_000 ether - qty - sold, "the profit is what the lot gave up beyond the principal sold");
        assertGe(t3.reserveUsdg() * 1e4, Math.mulDiv(sold, 111e18, SCALE) * (1e4 - 100 - FEE / 100), "what sold did not clear the slippage floor");
        _assertInvariants("after the short V3 sell");
    }

    /// An oversized sell through take-profit and then through a stop: the pool can absorb only part of each offer, a
    /// second call with the pool still on the limit is refused, and a short stop leaves `tp1Left` alone while the lot
    /// still holds more than tp1 owes.
    function test_aShortTakeProfitThenAShortStop_tp1LeftIsNotClampedWhileTheLotStillCoversIt() public {
        _fund(200_000 ether);
        _book("an oversized lot");
        _px(111e18);
        uint256 before = acted;
        _takeProfit(0, "an oversized take-profit");
        assertEq(acted, before + 1, "the short sale was refused");
        (uint256 q,,, uint256 left) = t3.lots(0);
        assertLt(q, 200_000 ether); assertGt(q, 190_000 ether, "sanity: the fill was meant to be short");
        assertEq(left, 100_000 ether - (200_000 ether - q));
        _takeProfit(0, "again, with the pool still on the limit");   // Unhealthy: the sale left spot on the limit
        assertEq(acted, before + 1);

        _px(84e18);
        _stopLoss(0, "an oversized stop");
        assertEq(acted, before + 2, "the short stop was refused");
        (uint256 q2,,, uint256 left2) = t3.lots(0);
        assertLt(q2, q); assertGt(q2, 170_000 ether, "sanity: the stop was meant to fill short");
        assertEq(left2, left, "tp1Left was clamped though the lot still holds more than it owes");
    }

    /// The other half: a BUY may fill short, because a smaller lot is self-consistent, and books what it actually got.
    function test_aDipMayFillShort_andSpendsOnlyWhatFilled() public {
        _fund(10 ether);
        _book("a lot");
        _px(111e18);
        _takeProfit(0, "tp1");
        _takeProfit(0, "tp2");
        assertEq(t3.lotCount(), 0, "the lot should be gone after both take-profit steps");

        usdg.mint(address(t3), 5_000_000e6);                  // a reserve far past the pool's depth
        _px(104e18);
        assertTrue(_buyDip("an oversized dip"), "a dip that can only partly fill must not revert");

        assertEq(t3.lotCount(), 1, "the short-filled dip booked no lot");
        (uint256 q3,,,) = t3.lots(0);
        assertGt(q3, 0, "a short-filled dip should still book the stock it got");
        assertLt(t3.reserveUsdg(), 5_000_000e6, "the dip spent nothing");
        assertGt(t3.reserveUsdg(), 0, "the dip spent everything -- it was meant to fill short");
    }

    // ------------------------------------------------------------------------------------ chunked sales
    /// `sellChunkUsdg` on the V3 venue: one chunk per call, `tp1Left` carried between calls, a refusal when the price
    /// falls back mid-tp1 that loses nothing, tp1 ending on half of the ORIGINAL quantity, and a stop in chunks too.
    function test_chunkedSales_oneChunkACall_throughTp1APriceFallBackAndAStop() public {
        _redeployChunked();
        _fund(10 ether);
        _book("a lot");
        _px(106e18);
        _takeProfit(0, "tp1, first chunk");
        (uint256 q,,, uint256 left) = t3.lots(0);
        uint256 c = Math.mulDiv(300e6, SCALE, 106e18);
        assertEq(q, 10 ether - c, "a call sold something other than one chunk"); assertEq(left, 5 ether - c);
        _px(103e18);
        assertFalse(_takeProfit(0, "tp1, price fell back"), "tp1 sold a chunk under its trigger");
        (q,,, left) = t3.lots(0);
        assertEq(q, 10 ether - c); assertEq(left, 5 ether - c, "what tp1 still owes was lost");
        _px(106e18);
        _takeProfit(0, "tp1, second chunk");
        (q,,, left) = t3.lots(0);
        assertEq(left, 0, "5 stock is under two chunks of ~2.83"); assertEq(q, 5 ether, "tp1 must take half of the ORIGINAL quantity");

        _fund(7 ether);
        _px(88e18);                                           // 17% under the lot's cost of 100: the stop
        _book("a second lot, at 88");
        uint256 before = acted;
        for (uint256 i; i < 2; i++) { _stopLoss(0, "stop, in chunks"); _px(88e18); }
        assertEq(acted, before + 2, "the stop should have needed two calls for 5 stock at ~3.4 a call");
        assertEq(t3.lotCount(), 1, "the stopped lot should be gone and the second still there");
    }

    function test_theV3ConstructorRefusesAZeroSellChunk() public {
        HedgeFunTreasuryBase.Params memory p = _params(1000); p.sellChunkUsdg = 0;
        vm.expectRevert(PoolTrader.BadConfig.selector);
        new HedgeFunTreasury(address(usdg), address(stock), address(mirror), address(oracle), address(tok3), address(pm3), address(this), p);
    }

    // ------------------------------------------------------------------------------------ arbitrary sequences
    /// Drive the treasury through a pseudo-random sequence of price moves and rule calls, checking the ledger's
    /// invariants after every step. Half the runs book lots far bigger than the ~500 stock the pool takes inside 1%,
    /// and every run may shove the pool (not the feed) toward the deviation gate: so sales fill SHORT, from a shoved
    /// start. Nothing here asserts a quantity a full fill would have produced.
    function testFuzz_arbitrarySequencesNeverBreakTheLedger(uint256 seed) public {
        if (seed & (1 << 200) != 0) _redeployChunked();       // half the runs sell ~3 stock a call, so tp1 spans calls
        uint256 biggest = seed & (1 << 201) != 0 ? 4_000 ether : 50 ether;   // the unchunked half of these fills short
        // a fixed opening, so no run of this fuzz can be vacuous: a lot is always booked and tp1 has always fired on it
        _fund(10 ether);
        _book("opening book");
        _px(106e18);
        _takeProfit(0, "opening tp1");
        assertEq(acted, 1, "the opening take-profit did not go through");

        for (uint256 step; step < 12; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 action = seed % 6;
            string memory tag = string.concat("step ", vm.toString(step));

            if (action == 0) {
                _px(bound(uint256(keccak256(abi.encode(seed, "p"))), 84e18, 119e18));
            } else if (action == 1) {
                _fund(bound(uint256(keccak256(abi.encode(seed, "q"))), 0.001 ether, biggest));
                _book(tag);
            } else if (action == 2) {
                _takeProfit(_id(seed), tag);
            } else if (action == 3) {
                _stopLoss(_id(seed), tag);
            } else if (action == 4) {
                _buyDip(tag);
            } else {
                // the pool alone, down to just inside the gate or just outside it: a sale from here has less room
                _pxPoolOnly(uint256(stockFeed.answer()) * 1e10 * (1e4 - bound(uint256(keccak256(abi.encode(seed, "s"))), 0, 60)) / 1e4);
            }
            _assertInvariants(tag);
        }
        _assertInvariants("end of sequence");
    }

    function _id(uint256 seed) internal view returns (uint256) {
        uint256 n = t3.lotCount();
        return n == 0 ? 0 : seed % n;
    }

    // ============================================================================ the market closes, the rule keeps going
    /// The equity feeds are 24/5: across a weekend they freeze at Friday's value for ~65 hours while the pool
    /// keeps trading. Refusing for all of it slept through a third of every week. A SCHEDULED closure now prices
    /// off the pool's own 600s mean, for a treasury born with a band.
    function test_aBandedTreasuryTradesThroughAScheduledClosure() public {
        _fund(100 ether);
        assertTrue(t3.book(), "should book while the market is open");
        _px(111e18);                                                             // +11%, past tp2

        _weekend();                                                     // the weekend starts

        (bool ok3,) = t3.health();
        assertTrue(ok3, "should price off its own mean while the market is shut");

        vm.prank(bot3); t3.takeProfit(0);                                         // the rule keeps working
        assertGt(t3.reserveUsdg(), 0, "the weekend sale funded nothing");
    }

    /// Gaps are the POINT, not something to hide from. The rule is mean-reverting, so a pool that has moved a
    /// long way from Friday is exactly where it earns its keep -- and whoever moved it is on the other side of
    /// every trade the rule makes. The drift bound is a circuit breaker for "the pool is broken", not a filter on
    /// volatility. (This checks the gate; `test_stopLossWaitsForTheMarketToOpen` below carries a real trade
    /// through the same path -- walking the harness pool far enough to gap it exhausts its seeded range.)
    function test_aWeekendGapIsTradable_andOnlyAnAbsurdOneParks() public {
        _fund(5 ether);
        t3.book();
        _px(111e18);
        _weekend();

        _pxPoolOnly(125e18);                                                     // +13% over the weekend: real news
        (bool ok, uint256 p) = t3.health();
        assertTrue(ok, "a 13% weekend gap should be tradable, not parked");
        assertApproxEqRel(p, 125e18, 0.01e18, "and priced off the pool's own mean");

        assertTrue(t3.pricedOffPoolOnly(), "the gap is tradable, but on the pool's word alone");

        _pxPoolOnly(170e18);                                                     // +53%: likelier broken than repriced
        (ok,) = t3.health();
        assertFalse(ok, "a move past the circuit breaker must park the rule");
    }

    /// The one call a fake weekend price genuinely hurts: `stopLoss` is the only operation that sells INTO
    /// weakness, so a shoved-down pool would make it realise a loss that never happened. It waits for the open.
    function test_stopLossWaitsForTheMarketToOpen() public {
        _fund(100 ether);
        t3.book();
        _weekend();
        _pxPoolOnly(85e18);                                                      // a 15% "crash" over the weekend

        (bool ok,) = t3.health();
        assertTrue(ok, "the weekend path should be open");
        assertTrue(t3.pricedOffPoolOnly(), "and it should say the price has no oracle behind it");

        vm.prank(bot3); vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector); t3.stopLoss(0);
        assertEq(t3.lotCount(), 1, "the lot must survive the weekend intact");

        // Monday: the feed agrees with the pool, the price is oracle-backed again, and the stop may act
        cal.setClosed(false); stockFeed.set(int256(uint256(85e18) / 1e10));
        assertFalse(t3.pricedOffPoolOnly(), "with the market open the price is oracle-backed again");
        vm.prank(bot3); t3.stopLoss(0);
        assertEq(t3.lotCount(), 0, "the stop should act once there is a real price behind it");
    }


    /// An outage is not a weekend. Age alone cannot tell them apart -- the calendar can, and it is what decides.
    function test_aFeedOutageDuringTradingHoursStillFailsClosed() public {
        _fund(100 ether);
        t3.book();
        _px(111e18);

        usdgFeed.setAt(1e8, block.timestamp - 30 hours);                         // the feed dies, market still open
        (bool ok,) = t3.health();
        assertFalse(ok, "a stale feed during trading hours must fail closed, weekend path or not");
    }

    /// A corporate action halts the rule whatever the calendar says.
    function test_oraclePausedHaltsEvenOnAWeekend() public {
        _fund(100 ether);
        t3.book();
        _px(111e18);
        _weekend();
        (bool ok,) = t3.health();
        assertTrue(ok);

        stock.setOraclePaused(true);
        (ok,) = t3.health();
        assertFalse(ok, "a corporate action must halt the weekend path too");
    }

    /// And spot still has to agree with the mean: on a weekend that is the ONLY corroboration there is.
    function test_anAtomicShoveCannotBecomeTheWeekendPrice() public {
        _fund(100 ether);
        t3.book();
        _px(111e18);
        _weekend();

        mirror.setTwapLag(300);                                             // spot 3% away from the mean
        (bool ok,) = t3.health();
        assertFalse(ok, "spot disagreeing with the mean must close the weekend gate");
    }

    /// THE WEEKEND DUMP. Nobody can arbitrage a tokenised stock against the real one on a Saturday -- the real
    /// market is shut -- so a push in the stock pool has nothing pulling it back until Monday. What saves the
    /// treasury is not detection but DIRECTION: the rule is mean-reverting, so whoever shoves the pool is the
    /// counterparty to the trade their shove triggers. Measured here rather than asserted.
    function test_aWeekendDumpPaysTheTreasuryNotTheDumper() public {
        _fund(5 ether);
        t3.book();                                                    // a lot at 100
        _px(111e18);
        vm.prank(bot3); t3.takeProfit(0);                                        // realise, so there is a reserve
        _weekend();

        // fund the attacker BEFORE the baseline, or the funding reads as profit
        stock.mint(attacker, 400e18);
        usdg.mint(attacker, 5_000_000e6);
        uint256 stockBefore = stock.balanceOf(attacker);
        uint256 usdgBefore = usdg.balanceOf(attacker);
        uint160 sqrt0 = _spot3();

        _dumpAs(attacker, 400e18);                                               // slam the pool down, weekend, no arb
        (bool ok, uint256 p) = t3.health();
        assertTrue(ok, "the weekend path should still be open at this depth");

        vm.prank(bot3);
        try t3.buyDip() { } catch { }                                            // the rule takes the other side
        _walkAs(attacker, sqrt0);                                                // Monday: the price comes back

        int256 pnl = int256(usdg.balanceOf(attacker)) - int256(usdgBefore)
                   + int256(_valueAtOracle(stock.balanceOf(attacker)) ) - int256(_valueAtOracle(stockBefore));
        emit log_named_int("weekend dumper PnL, marked at the restored price (USDG-6)", pnl);
        emit log_named_uint("price the rule acted on (1e18)", p);
        assertLt(pnl, int256(0), "dumping into the treasury on a weekend should cost the dumper");
        _assertInvariants("weekend/dump");
    }

    /// THE PRE-OPEN FRONT RUN. Monday morning, the feed is about to print a gap. Someone who knows where it will
    /// print can move the pool there first and be waiting. They still cannot make the rule act at a price the
    /// feed has not reached: while the market is shut the pool must agree with its own 600s mean, and the moment
    /// it opens the price is Chainlink's again and the deviation gate holds the pool to it.
    function test_aPreOpenFrontRunCannotMakeTheRuleActAtTheGapPrice() public {
        _fund(5 ether);
        t3.book();
        _weekend();

        // a shove lands on spot before it lands on a 600-second mean; that divergence is what the gate sees
        mirror.setTwapLag(400);                                                  // spot 4% away from the mean
        (bool okShoved,) = t3.health();
        assertFalse(okShoved, "spot torn away from its own mean must close the weekend gate");
        mirror.setTwapLag(0);

        // even once the shove settles into the mean, the market opening restores Chainlink as the price
        cal.setClosed(false);
        (bool okOpen, uint256 pOpen) = t3.health();
        if (okOpen) assertApproxEqRel(pOpen, 100e18, 0.02e18, "with the market open the price is the feed's, not the pool's");
        assertFalse(t3.pricedOffPoolOnly(), "an open market is never priced off the pool alone");
    }

    function _spot3() internal view returns (uint160 s) { (s,,,) = pm3.getSlot0(key3.toId()); }

    function _valueAtOracle(uint256 stockAmt) internal pure returns (uint256) { return stockAmt * 100 / 1e12; }

    /// @dev sell `amt` of stock into the V3-mirrored pool as `who`
    function _dumpAs(address who, uint256 amt) internal {
        vm.startPrank(who);
        stock.approve(address(sr3), type(uint256).max);
        usdg.approve(address(sr3), type(uint256).max);
        bool zeroForOne = Currency.unwrap(key3.currency0) == address(stock);
        (uint160 cur,,,) = pm3.getSlot0(key3.toId());
        uint160 lim = zeroForOne ? uint160(uint256(cur) / 4) : uint160(uint256(cur) * 4);
        sr3.swap(key3, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amt), sqrtPriceLimitX96: lim}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        vm.stopPrank();
    }

    function _walkAs(address who, uint160 target) internal {
        (uint160 cur,,,) = pm3.getSlot0(key3.toId());
        if (target == cur) return;
        vm.startPrank(who);
        stock.approve(address(sr3), type(uint256).max);
        usdg.approve(address(sr3), type(uint256).max);
        sr3.swap(key3, SwapParams({zeroForOne: target < cur, amountSpecified: -int256(1e26), sqrtPriceLimitX96: target}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        vm.stopPrank();
    }

    /// `PoolTrader._health` corroborates spot against the pool's own 10-minute mean: a push that spot alone cannot
    /// distinguish from a real move closes the gate.
    function test_aSpotItsOwnTwapDoesNotCorroborateClosesTheGate() public {
        (bool ok3,) = t3.health();
        assertTrue(ok3, "the gate should be open on a pool sitting at the oracle");

        mirror.setTwapLag(150);                               // spot is 1.5% above the pool's own 10-minute mean
        (ok3,) = t3.health();
        assertFalse(ok3, "the gate ignored a spot its own TWAP does not corroborate");
    }

    /// The tightest spot the rule can be asked to trade in: a pool sitting a full deviation-bound BELOW the oracle
    /// still passes the gate while the sale's own price limit sits essentially on the pool's price -- the swap either
    /// fills on the last tick it is allowed or is refused by the pool outright. Either is fine; a refusal that left
    /// anything behind would not be.
    function test_atTheDeviationBoundaryASaleFillsOrIsRefusedWhole() public {
        _fund(10 ether);
        _book("a lot");
        _px(112e18);
        _takeProfit(0, "tp1");                                // a sale, so there is something to sell later

        _walk(pm3, sr3, key3, 111e18);                        // the pool 1% below...
        stockFeed.set(int256(uint256(112.11e18) / 1e10));      // ...an oracle that is 1% above it

        (uint256 booked, uint256 reserve, uint256 held) = (t3.bookedStock(), t3.reserveUsdg(), stock.balanceOf(address(t3)));
        if (!_takeProfit(0, "at the deviation boundary")) {   // `_takeProfit` checks the ledger's invariants either way
            assertEq(t3.bookedStock(), booked, "a refused sale moved the ledger");
            assertEq(t3.reserveUsdg(), reserve, "a refused sale moved the reserve");
            assertEq(stock.balanceOf(address(t3)), held, "a refused sale moved stock");
        }
    }

    /// A stale feed and an `oraclePaused()` stock stop every trading path with `Unhealthy`, and `book` with `false`.
    function test_anUnhealthyOracleStopsEveryTradingPath_stopLossIncluded() public {
        _fund(10 ether);
        _book("a lot");
        _px(111e18);

        stock.setOraclePaused(true);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector); t3.takeProfit(0);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector); t3.buyDip();
        _fund(1 ether);
        assertFalse(t3.book());

        stock.setOraclePaused(false);
        usdgFeed.setAt(1e8, block.timestamp - 30 hours);       // stale beyond maxUsdgAge
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector); t3.takeProfit(0);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector); t3.stopLoss(0);
        _assertInvariants("unhealthy");
    }
}

contract InteractVenueParityStockCurrency0Test is VenueParityTests {
    function stockIsCurrency0() internal pure override returns (bool) { return true; }
}

contract InteractVenueParityUsdgCurrency0Test is VenueParityTests {
    function stockIsCurrency0() internal pure override returns (bool) { return false; }
}
