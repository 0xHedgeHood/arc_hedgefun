// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {
    HedgeFunV2StrategyIncomeTreasury, HedgeFunV2StrategyDividend25Treasury, HedgeFunV2StrategyDividend50Treasury
} from "../src/v2/HedgeFunV2StrategyIncomeTreasury.sol";
import {V2StakingIncome} from "../src/v2/V2StakingIncome.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {MockToken, MockFeed, AlwaysOpen, SwitchableCalendar} from "./mocks/Mocks.sol";
import {MirrorV3Pool, NoopHook} from "./InteractVenueParity.t.sol";

/// The ordinary stock strategy with a staking dividend, against the same real concentrated-liquidity stock venue
/// as the V2 scheduler suite. This test contract plays the factory: it wires the exact graduation transfer
/// before optional booking. Other arrivals are income, independent of caller or claim timing.
abstract contract V2StrategyIncomeBase is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 constant SCALE = 1e18 * 1e18 / 1e6;
    uint24 constant FEE = 3000;
    int24 constant SPACING = 60;
    address internal constant KEEPER = address(0xB07);
    address internal constant ALICE = address(0xA71CE);
    IPoolManager pm;
    MockToken usdg;
    MockToken stock;
    HedgeFunToken token;
    MockFeed stockFeed;
    MockFeed usdgFeed;
    PriceOracle oracle;
    PoolSwapTest swapRouter;
    PoolKey stockKey;
    MirrorV3Pool mirror;
    HedgeFunV2StrategyIncomeTreasury internal t;
    V2StakingIncome internal staking;

    function stockIsCurrency0() internal pure virtual returns (bool);

    function setUp() public {
        vm.warp(1_700_000_000);
        pm = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(pm);
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(pm);
        usdg = new MockToken("USDG", 6);
        stock = _mineStock();
        token = new HedgeFunToken("Strategy", "STR", 1_000_000_000e18, address(this), address(0));
        stockFeed = new MockFeed(8);
        usdgFeed = new MockFeed(8);
        usdgFeed.set(1e8);
        stockFeed.set(100e8);
        oracle = new PriceOracle(address(stock), address(stockFeed), address(usdgFeed), address(new AlwaysOpen()), 26 hours, 26 hours);
        (Currency s0, Currency s1) = stockIsCurrency0()
            ? (Currency.wrap(address(stock)), Currency.wrap(address(usdg)))
            : (Currency.wrap(address(usdg)), Currency.wrap(address(stock)));
        stockKey = PoolKey(s0, s1, FEE, SPACING, IHooks(address(0)));
        pm.initialize(stockKey, _sqrtFor(100e18));
        usdg.mint(address(this), 1e18 * 1e6);
        stock.mint(address(this), 1e12 ether);
        usdg.approve(address(lpRouter), type(uint256).max);
        stock.approve(address(lpRouter), type(uint256).max);
        usdg.approve(address(swapRouter), type(uint256).max);
        stock.approve(address(swapRouter), type(uint256).max);
        (, int24 tick,,) = pm.getSlot0(stockKey.toId());
        int24 lo = ((tick - 1800) / SPACING) * SPACING;
        int24 hi = ((tick + 1800) / SPACING) * SPACING;
        lpRouter.modifyLiquidity(stockKey, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: 1e18, salt: 0}), "");
        mirror = new MirrorV3Pool(pm, stockKey);
        // A nonzero hook address is the V2 activation marker. No token-pool swap is made here.
        vm.etch(address(0x40), address(new NoopHook()).code);
        pm.initialize(_tokenKey(), uint160(1 << 96));
        t = _deploy25(address(oracle));
    }

    function _tokenKey() internal view returns (PoolKey memory) {
        (Currency c0, Currency c1) = address(stock) < address(token)
            ? (Currency.wrap(address(stock)), Currency.wrap(address(token)))
            : (Currency.wrap(address(token)), Currency.wrap(address(stock)));
        return PoolKey(c0, c1, FEE, SPACING, IHooks(address(0x40)));
    }

    function _mineStock() internal returns (MockToken) {
        bytes32 h = keccak256(abi.encodePacked(type(MockToken).creationCode, abi.encode("STK", uint8(18))));
        for (uint256 i; i < 1000; ++i) {
            if ((vm.computeCreate2Address(bytes32(i), h, address(this)) < address(usdg)) == stockIsCurrency0()) {
                return new MockToken{salt: bytes32(i)}("STK", 18);
            }
        }
        revert("stock address");
    }

    function _params() internal pure returns (HedgeFunTreasuryBase.Params memory p) {
        p.tp1Bps = 500; p.tp2Bps = 1000; p.dipBps = 500; p.stopBps = 0;
        p.lotBps = 2000; p.bountyBps = 50; p.maxSlippageBps = 100;
        p.maxDeviationBps = 50; p.maxBuybackImpactBps = 300;
        p.buybackCooldown = 60; p.minLotUsdg = 5e6;
        p.buybackChunkUsdg = 500e6; p.sellChunkUsdg = type(uint128).max;
    }

    function _sqrtFor(uint256 p) internal pure returns (uint160) {
        return uint160(Math.sqrt(stockIsCurrency0() ? Math.mulDiv(p, 1 << 192, SCALE) : Math.mulDiv(SCALE, 1 << 192, p)));
    }

    function _px(uint256 p) internal {
        uint160 target = _sqrtFor(p);
        (uint160 cur,,,) = pm.getSlot0(stockKey.toId());
        if (target != cur) {
            swapRouter.swap(stockKey, SwapParams({zeroForOne: target < cur, amountSpecified: -int256(1e30), sqrtPriceLimitX96: target}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        }
        stockFeed.set(int256(p / 1e10));
    }

    function _deploy25(address oracle_) internal returns (HedgeFunV2StrategyIncomeTreasury d) {
        d = new HedgeFunV2StrategyDividend25Treasury(address(usdg), address(stock), address(mirror), oracle_,
            address(token), address(pm), address(this), _params());
        staking = d.staking();
    }

    function _graduate(uint256 principal) internal {
        t.wireWithGraduation(_tokenKey(), principal);
        stock.mint(address(t), principal);
        assertTrue(t.book(), "the factory's booking opens the principal's lot");
    }

    function test_wiringAndRatios() public {
        assertEq(t.stakingBps(), 2500);
        assertEq(address(staking.stakeToken()), address(token));
        assertEq(address(staking.rewardToken()), address(stock));
        assertEq(staking.incomeSource(), address(t));
        assertEq(stock.allowance(address(t), address(staking)), type(uint256).max, "the pool pulls only inside fund()");
        HedgeFunV2StrategyIncomeTreasury half = new HedgeFunV2StrategyDividend50Treasury(address(usdg), address(stock),
            address(mirror), address(oracle), address(token), address(pm), address(this), _params());
        assertEq(half.stakingBps(), 5000);
        assertTrue(address(half.staking()) != address(staking));
    }

    function test_graduationPrincipalOpensTheStrategyLotAndIsNotIncome() public {
        _graduate(10 ether);
        assertEq(t.principalStock(), 10 ether);
        assertEq(t.lotCount(), 1);
        assertEq(t.bookedStock(), 10 ether);
        assertEq(t.totalStockReceived(), 10 ether);
        assertEq(t.buybackStock(), 0);
        assertEq(staking.totalFunded(), 0);
        (uint256 qty, uint256 cost,,) = t.lots(0);
        assertEq(qty, 10 ether);
        assertEq(cost, 100e18);
    }

    function test_taxArrivalIsIncomeNeverALot_whoeverBooksIt() public {
        _graduate(10 ether);
        stock.mint(address(t), 4 ether); // the hook's sweep or a curve claim land as a plain transfer
        vm.prank(ALICE);
        assertTrue(t.book());
        assertEq(t.lotCount(), 1, "kind 0 would have opened a second lot here");
        assertEq(t.bookedStock(), 10 ether);
        assertEq(staking.totalFunded(), 1 ether);
        assertEq(stock.balanceOf(address(staking)), 1 ether);
        assertEq(t.buybackStock(), 3 ether);
        assertEq(t.unbookedStock(), 0);
        assertEq(t.totalStockReceived(), 10 ether, "income is not strategy capital");
        assertFalse(t.book(), "nothing new");
    }

    function test_executeCannotTurnUnclassifiedIncomeIntoPrincipal() public {
        _graduate(10 ether);
        stock.mint(address(t), 4 ether);
        vm.expectRevert(); // nothing is due at the booking price, and the pending stock must not be booked on the way
        t.execute();
        assertEq(t.lotCount(), 1);
        assertEq(t.bookedStock(), 10 ether);
        assertEq(t.unbookedStock(), 4 ether);
        assertTrue(t.book());
        assertEq(staking.totalFunded(), 1 ether);
    }

    function test_realisedProfitIsSplitBetweenStakersAndBuyback() public {
        _graduate(10 ether);
        _px(106e18);
        vm.prank(KEEPER);
        (HedgeFunV2Treasury.Action a,) = t.execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        uint256 toStakers = staking.totalFunded();
        uint256 toBuyback = t.buybackStock();
        assertGt(toStakers, 0);
        assertGt(t.reserveUsdg(), 0, "the principal came back as USDG for the next dip");
        assertGt(stock.balanceOf(KEEPER), 0, "the keeper's bounty is unchanged");
        assertEq(toStakers, (toStakers + toBuyback) * 2500 / 10000, "25% of the profit kept after the bounty");
        assertEq(stock.balanceOf(address(staking)), toStakers);
        assertEq(t.bookedStock() + t.buybackStock(), stock.balanceOf(address(t)), "every unit is in a ledger");
    }

    function test_dipBuysStillOpenLots_andWaitForUnclassifiedIncome() public {
        _graduate(10 ether);
        _px(106e18);
        t.execute();                       // take profit: USDG reserve, lastSalePrice 106
        uint256 lotsBefore = t.lotCount();
        _px(100.5e18);                     // more than 5% below the sale
        stock.mint(address(t), 2 ether);   // tax arrives before the keeper comes
        vm.expectRevert();
        t.execute();
        assertEq(t.lotCount(), lotsBefore, "no dip while arrived stock is unclassified");
        assertTrue(t.book());
        (HedgeFunV2Treasury.Action a,) = t.execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.BuyDip));
        assertEq(t.lotCount(), lotsBefore + 1);
        assertEq(t.bookedStock() + t.buybackStock(), stock.balanceOf(address(t)));
    }

    function test_lpFeesAllFundTheBuyback() public {
        _graduate(10 ether);
        t.setLiquidityVault(address(this));
        stock.approve(address(t), 5 ether);
        t.creditLiquidityFee(5 ether);
        assertEq(t.buybackStock(), 5 ether);
        assertEq(staking.totalFunded(), 0);
        assertFalse(t.book(), "the fee is in the budget: nothing to classify");
        assertEq(staking.totalFunded(), 0);
    }

    function test_aRefusedStakingTransferNeverBlocksATakeProfit() public {
        _graduate(10 ether);
        _px(106e18);
        vm.mockCallRevert(address(staking), abi.encodeWithSelector(V2StakingIncome.fund.selector), "blocked");
        (HedgeFunV2Treasury.Action a,) = t.execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        vm.clearMockedCalls();
        assertEq(staking.totalFunded(), 0);
        assertGt(t.buybackStock(), 0, "the stakers' share stayed in the buy-back budget");
        assertEq(t.bookedStock() + t.buybackStock(), stock.balanceOf(address(t)));
    }

    function test_principalBookedAfterAClosure_isStillExactlyThePrincipal() public {
        SwitchableCalendar cal = new SwitchableCalendar();
        PriceOracle closedOracle = new PriceOracle(address(stock), address(stockFeed), address(usdgFeed), address(cal),
            26 hours, 26 hours);
        t = _deploy25(address(closedOracle));
        cal.setClosed(true);
        t.wireWithGraduation(_tokenKey(), 10 ether);
        stock.mint(address(t), 10 ether);
        t.book();                                       // graduation on a weekend: recorded, no price to open a lot at
        assertEq(t.principalStock(), 10 ether);
        assertEq(t.lotCount(), 0);
        stock.mint(address(t), 4 ether);                // tax keeps arriving while the market is shut
        vm.prank(ALICE);
        assertTrue(t.book());
        assertEq(staking.totalFunded(), 1 ether, "income is split without waiting for the market");
        assertEq(t.buybackStock(), 3 ether);
        assertEq(t.lotCount(), 0);
        assertEq(t.unbookedStock(), 10 ether, "only the principal is still waiting");
        cal.setClosed(false);
        vm.prank(ALICE);
        assertTrue(t.book());
        assertEq(t.lotCount(), 1);
        (uint256 qty,,,) = t.lots(0);
        assertEq(qty, 10 ether, "the lot is the principal, no income in it");
        assertEq(t.totalStockReceived(), 10 ether);
    }

    function test_stakersClaimTheirShareOfProfit() public {
        _graduate(10 ether);
        token.transfer(ALICE, 1_000e18);
        vm.startPrank(ALICE);
        IERC20(address(token)).approve(address(staking), type(uint256).max);
        staking.stake(1_000e18);
        vm.stopPrank();
        _px(106e18);
        t.execute();
        uint256 funded = staking.totalFunded();
        vm.warp(block.timestamp + 7 days);
        vm.prank(ALICE);
        assertApproxEqAbs(staking.claim(ALICE), funded, 1e6);
    }

    function testFuzz_everyUnitStaysInALedger(uint96[5] memory arrivals) public {
        _graduate(10 ether);
        uint256 income;
        for (uint256 i; i < arrivals.length; ++i) {
            uint256 amount = bound(uint256(arrivals[i]), 0, 50 ether);
            if (amount == 0) continue;
            stock.mint(address(t), amount);
            assertTrue(t.book());
            income += amount;
            assertEq(t.lotCount(), 1);
            assertEq(t.bookedStock(), 10 ether);
            assertEq(t.bookedStock() + t.buybackStock(), stock.balanceOf(address(t)));
            assertEq(staking.totalFunded() + t.buybackStock(), income);
            assertEq(stock.balanceOf(address(staking)), staking.totalFunded());
        }
    }
}

contract V2StrategyIncomeStockCurrency0Test is V2StrategyIncomeBase {
    function stockIsCurrency0() internal pure override returns (bool) { return true; }
}

contract V2StrategyIncomeUsdgCurrency0Test is V2StrategyIncomeBase {
    function stockIsCurrency0() internal pure override returns (bool) { return false; }
}
