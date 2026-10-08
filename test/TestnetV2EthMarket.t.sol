// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TestFeed} from "../script/testnet/TestnetAssets.sol";
import {IV3Factory, IV3Pool} from "../script/testnet/TestnetMarket.sol";
import {TestnetCryptoCalendar, TestnetCryptoOracle} from "../script/testnet/TestnetCryptoOracle.sol";
import {TestnetNativeMarket} from "../script/testnet/TestnetNativeMarket.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {MockToken, MockFeed} from "./mocks/Mocks.sol";

/// Unit wrapped-native fixture: balances can only be created by depositing native currency.
contract NativeMarketWrapped is ERC20 {
    constructor() ERC20("Native market fixture WETH", "WETH") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount); (bool ok,) = msg.sender.call{value: amount}(""); require(ok);
    }
}

contract CryptoOracleFactoryFixture {
    address public canonical;
    function setPool(address value) external { canonical = value; }
    function getPool(address, address, uint24) external view returns (address) { return canonical; }
}

contract CryptoOraclePoolFixture {
    address public factory; address public token0; address public token1; uint24 public fee = 500;
    uint128 public liquidity = 1000; uint16 public cardinality = 720; bool public unlocked = true;
    int56 private first; int56 private last; bool public unavailable; bool public malformed;
    constructor(address f, address a, address b) { factory=f; token0=a; token1=b; }
    function configure(uint128 l, uint16 c, bool u) external { liquidity=l; cardinality=c; unlocked=u; }
    function cumulative(int56 a, int56 b) external { first=a; last=b; }
    function badObservation(bool revertRead, bool badLength) external { unavailable=revertRead; malformed=badLength; }
    function slot0() external view returns (uint160,int24,uint16,uint16,uint16,uint8,bool) {
        return (1 << 96, 0, 0, cardinality, cardinality, 0, unlocked);
    }
    function observe(uint32[] calldata ago) external view returns (int56[] memory t, uint160[] memory l) {
        require(!unavailable && ago.length==2 && ago[0]==600 && ago[1]==0, "history unavailable");
        t=new int56[](malformed?1:2); l=new uint160[](2); t[0]=first; if(!malformed)t[1]=last;
    }
}

contract TestnetCryptoOracleTest is Test {
    NativeMarketWrapped private wrapped; MockToken private usd;
    TestnetCryptoCalendar private calendar; TestnetCryptoOracle private oracle;
    CryptoOraclePoolFixture private pool; CryptoOracleFactoryFixture private factory;

    function setUp() public {
        vm.warp(1_790_820_000);
        vm.etch(address(0x1111),address(new NativeMarketWrapped()).code); wrapped=NativeMarketWrapped(address(0x1111));
        vm.etch(address(0x2222),address(new MockToken("tUSDG",6)).code); usd=MockToken(address(0x2222));
        calendar=new TestnetCryptoCalendar(address(this)); factory=new CryptoOracleFactoryFixture();
        pool=new CryptoOraclePoolFixture(address(factory),address(wrapped),address(usd)); factory.setPool(address(pool));
        oracle=new TestnetCryptoOracle(address(wrapped),address(usd),address(pool),address(calendar),500);
        pool.cumulative(0,int56(int256(_initialTick())*600));
    }

    function _initialTick() private pure returns(int24) {
        return TickMath.getTickAtSqrtPrice(uint160(Math.sqrt(Math.mulDiv(3000e18,1<<192,1e30))));
    }

    function test_priceUsesCanonicalTickWindowWithoutWrappedEquityPauseInterface() public {
        (bool ok,uint256 p)=oracle.tryPrice(); assertTrue(ok); assertApproxEqRel(p,3000e18,1e14);
        assertEq(oracle.version(),2); assertEq(oracle.twapSeconds(),600); assertEq(oracle.minLiquidity(),500);
        assertEq(oracle.stock(),address(wrapped)); assertEq(oracle.usdg(),address(usd)); assertEq(oracle.v3Factory(),address(factory));
        uint256 at; (ok,p,at)=oracle.lastPriceAt(); assertTrue(ok); assertEq(at,block.timestamp); assertEq(p,oracle.price());
    }

    function test_negativeCumulativeMeanRoundsDownRatherThanTowardZero() public {
        pool.cumulative(0,-1);
        uint256 sqrt=TickMath.getSqrtPriceAtTick(-1);
        uint256 expected=Math.mulDiv(sqrt*sqrt,1e30,1<<192);
        assertEq(oracle.price(),expected); assertLt(expected,1e30);
        pool.cumulative(0,-600); assertEq(oracle.price(),expected);
        pool.cumulative(0,-601); assertLt(oracle.price(),expected);
    }

    function test_reciprocalPairPreserves18StockAnd6QuoteScale() public {
        CryptoOraclePoolFixture reverse=new CryptoOraclePoolFixture(address(factory),address(usd),address(wrapped));
        factory.setPool(address(reverse));
        TestnetCryptoOracle inverted=new TestnetCryptoOracle(address(wrapped),address(usd),address(reverse),address(calendar),500);
        int24 tick=TickMath.getTickAtSqrtPrice(uint160(Math.sqrt(Math.mulDiv(1e30,1<<192,3000e18))));
        reverse.cumulative(0,int56(int256(tick)*600)); assertApproxEqRel(inverted.price(),3000e18,1e14);
        assertFalse(inverted.stockIsToken0());
    }

    function test_missingHistoryMalformedReadsLockedOrShallowPoolFailClosed() public {
        pool.badObservation(true,false); _unhealthy(); pool.badObservation(false,true); _unhealthy(); pool.badObservation(false,false);
        pool.configure(499,720,true); _unhealthy(); pool.configure(1000,719,true); _unhealthy(); pool.configure(1000,720,false); _unhealthy();
        pool.configure(1000,720,true); assertGt(oracle.price(),0);
        vm.mockCallRevert(address(pool),abi.encodeWithSelector(pool.liquidity.selector),"unavailable"); _unhealthy(); vm.clearMockedCalls();
        vm.mockCallRevert(address(pool),abi.encodeWithSelector(pool.slot0.selector),"unavailable"); _unhealthy(); vm.clearMockedCalls();
        vm.mockCallRevert(address(calendar),abi.encodeWithSelector(calendar.isClosed.selector,block.timestamp),"unavailable"); _unhealthy();
    }

    function test_cryptoCalendarWeekendUtcRollAndHaltAppliesToEveryPriceRead() public {
        for(uint256 d;d<14;++d){assertFalse(calendar.isClosed(d*1 days));assertFalse(calendar.isScheduledClosure(d*1 days));}
        assertEq(calendar.tradingDate(3 days-1),2); assertEq(calendar.tradingDate(3 days),3);
        vm.prank(address(0xBAD));vm.expectRevert();calendar.setHalted(true);
        calendar.setHalted(true);_unhealthy();calendar.setHalted(false);assertGt(oracle.price(),0);
    }

    function test_extremeTicksCannotOverflowAndOutOfRangeCumulativeFailsClosed() public {
        pool.cumulative(0,int56(int256(TickMath.MAX_TICK)*600)); (bool ok,uint256 p)=oracle.tryPrice();assertTrue(ok);assertGt(p,0);
        pool.cumulative(0,int56(int256(TickMath.MIN_TICK)*600)); _unhealthy(); // positive raw price truncates to zero; no fallback.
        pool.cumulative(0,int56((int256(TickMath.MAX_TICK)+1)*600));_unhealthy();
        pool.cumulative(type(int56).min,type(int56).max);_unhealthy();
    }

    function test_constructorRejectsNoncanonicalPoolMissingCodeWrongDecimalsAndZeroLiquidityFloor() public {
        vm.expectRevert(TestnetCryptoOracle.BadConfig.selector);new TestnetCryptoOracle(address(0xBAD),address(usd),address(pool),address(calendar),500);
        vm.expectRevert(TestnetCryptoOracle.BadConfig.selector);new TestnetCryptoOracle(address(wrapped),address(usd),address(pool),address(calendar),0);
        MockToken wrong=new MockToken("wrong",18);vm.expectRevert(TestnetCryptoOracle.BadConfig.selector);
        new TestnetCryptoOracle(address(wrapped),address(wrong),address(pool),address(calendar),500);
        factory.setPool(address(0xBAD));vm.expectRevert(TestnetCryptoOracle.BadConfig.selector);
        new TestnetCryptoOracle(address(wrapped),address(usd),address(pool),address(calendar),500);
    }

    function _unhealthy() private {
        (bool ok,uint256 p)=oracle.tryPrice();assertFalse(ok);assertEq(p,0);
        (bool lastOk,uint256 last,uint256 at)=oracle.lastPriceAt();assertFalse(lastOk);assertEq(last,0);assertEq(at,0);
        vm.expectRevert(TestnetCryptoOracle.Unhealthy.selector);oracle.price();
    }
}

contract TestnetNativeMarketTest is Test {
    NativeMarketWrapped private wrapped;
    MockToken private usd;
    TestFeed private feed;
    IV3Factory private factory;
    IV3Pool private pool;
    TestnetNativeMarket private market;
    bool private stock0;
    uint128 private liquidity;

    receive() external payable {}

    function _fixture(bool wrappedIs0) private {
        vm.warp(1_790_820_000); vm.deal(address(this), 2 ether);
        address w = wrappedIs0 ? address(0x1111) : address(0x8888);
        address u = wrappedIs0 ? address(0x9999) : address(0x2222);
        vm.etch(w, address(new NativeMarketWrapped()).code); wrapped = NativeMarketWrapped(w);
        vm.etch(u, address(new MockToken("tUSDG", 6)).code); usd = MockToken(u);
        bytes memory code = vm.readFileBinary("lib/v4-core/test/bin/v3Factory.bytecode"); address deployed;
        assembly ("memory-safe") { deployed := create(0, add(code, 32), mload(code)) }
        factory = IV3Factory(deployed); pool = IV3Pool(factory.createPool(w, u, 500)); stock0 = wrappedIs0;
        uint160 sqrtP = uint160(Math.sqrt(stock0 ? Math.mulDiv(3000e18, 1 << 192, 1e30) : Math.mulDiv(1e30, 1 << 192, 3000e18)));
        pool.initialize(sqrtP); pool.increaseObservationCardinalityNext(720);
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP); int24 centre = tick / 10 * 10; if (tick < 0 && tick % 10 != 0) centre -= 10;
        int24 lo = centre - 6000; int24 hi = centre + 6000;
        uint256 l = stock0
            ? Math.mulDiv(Math.mulDiv(0.9 ether, sqrtP, TickMath.getSqrtPriceAtTick(hi) - sqrtP), TickMath.getSqrtPriceAtTick(hi), 1 << 96)
            : Math.mulDiv(0.9 ether, 1 << 96, uint256(sqrtP) - TickMath.getSqrtPriceAtTick(lo));
        liquidity = uint128(l); feed = new TestFeed("ETH / USD (testnet, operator-set)", 3000e8, address(this));
        market = new TestnetNativeMarket(address(this), deployed, u, w, address(pool), feed, lo, hi);
        feed.setOperator(address(market), true);
        wrapped.deposit{value: 1 ether}(); wrapped.transfer(address(market), 1 ether); usd.mint(address(market), 3100e6);
    }

    function _provide() private returns (uint256 a0, uint256 a1) {
        return market.provide(liquidity, stock0 ? 0.9 ether : 3100e6, stock0 ? 3100e6 : 0.9 ether, block.timestamp);
    }
    function _poke() private { market.poke(stock0 ? 0.01 ether : 20e6, stock0 ? 20e6 : 0.01 ether, block.timestamp); }

    function test_prefundingAndOneSecondPokeMakeRealV3RingLiveBothOrderings() public {
        for (uint256 i; i < 2; ++i) {
            _fixture(i == 0); uint256 supply = wrapped.totalSupply(); (uint256 a0, uint256 a1) = _provide();
            assertGt(a0, 0); assertGt(a1, 0); assertEq(pool.liquidity(), liquidity);
            assertEq(wrapped.totalSupply(), supply); assertEq(address(wrapped).balance, supply);
            assertGt(wrapped.balanceOf(address(market)), 0.09 ether);
            (uint160 before,,,,,,) = pool.slot0(); vm.warp(block.timestamp + 1); _poke();
            (uint160 after_,,, uint16 cardinality, uint16 next,,) = pool.slot0();
            assertEq(before, after_); assertEq(cardinality, 720); assertEq(next, 720); assertEq(feed.answer(), 3000e8);
        }
    }

    function test_capsAndInsufficientPrefundingRevertWithoutFabricatingWeth() public {
        _fixture(false); uint256 wethBefore = wrapped.balanceOf(address(market)); uint256 usdBefore = usd.balanceOf(address(market));
        vm.expectRevert(TestnetNativeMarket.InputLimit.selector); market.provide(liquidity, 1, 1, block.timestamp);
        assertEq(wrapped.balanceOf(address(market)), wethBefore); assertEq(usd.balanceOf(address(market)), usdBefore); assertEq(pool.liquidity(), 0);
        vm.prank(address(market)); wrapped.transfer(address(this), wethBefore);
        vm.expectRevert(); _provide(); assertEq(wrapped.totalSupply(), 1 ether); assertEq(pool.liquidity(), 0);
    }

    function test_callbackAndOperatorBoundariesCannotSpendPrefundedBalances() public {
        _fixture(false);
        vm.expectRevert(TestnetNativeMarket.BadCallback.selector); market.uniswapV3MintCallback(1, 1, "");
        vm.prank(address(pool)); vm.expectRevert(TestnetNativeMarket.BadCallback.selector); market.uniswapV3SwapCallback(1, -1, "");
        vm.prank(address(0xBAD)); vm.expectRevert(); market.provide(liquidity, 3100e6, 0.9 ether, block.timestamp);
        vm.expectRevert(TestnetNativeMarket.Expired.selector); market.provide(liquidity, 3100e6, 0.9 ether, block.timestamp - 1);
        assertEq(wrapped.balanceOf(address(market)), 1 ether); assertEq(usd.balanceOf(address(market)), 3100e6);
    }

    function test_priceMovesAreBudgetedAndPoolAndSyntheticFeedMoveAtomically() public {
        _fixture(false); _provide(); uint256 supply = wrapped.totalSupply();
        vm.expectRevert(TestnetNativeMarket.PriceNotReached.selector); market.setPrice(3060e18, 1, 1, block.timestamp);
        assertEq(feed.answer(), 3000e8);
        market.setPrice(3060e18, 300e6, 0.1 ether, block.timestamp);
        assertEq(feed.answer(), 3060e8); assertApproxEqRel(market.priceAt(_sqrt()), 3060e18, 1e12);
        assertEq(wrapped.totalSupply(), supply); assertEq(address(wrapped).balance, supply);
        vm.expectRevert(TestnetNativeMarket.OutsideRange.selector); market.setPrice(100000e18, 300e6, 0.1 ether, block.timestamp);
    }

    function test_realPoolRequiresFullWindowAndInstantSpotMoveDoesNotRewriteTwap() public {
        _fixture(false); _provide();
        TestnetCryptoCalendar cal=new TestnetCryptoCalendar(address(this));
        TestnetCryptoOracle o=new TestnetCryptoOracle(address(wrapped),address(usd),address(pool),address(cal),liquidity/2);
        (bool ok,)=o.tryPrice(); assertFalse(ok);
        vm.warp(block.timestamp+1); _poke(); (ok,)=o.tryPrice();assertFalse(ok,"ring expansion is not 600 seconds of history");
        vm.warp(block.timestamp+600); uint256 before=o.price();assertApproxEqRel(before,3000e18,1e14);
        market.setPrice(3120e18,300e6,0.1 ether,block.timestamp);
        assertApproxEqRel(market.priceAt(_sqrt()),3120e18,1e12); assertEq(o.price(),before,"an instantaneous spot move has zero TWAP weight");
        vm.warp(block.timestamp+300);uint256 halfway=o.price();assertGt(halfway,before);assertLt(halfway,3120e18);
        vm.warp(block.timestamp+300);assertApproxEqRel(o.price(),3120e18,1e14);
        cal.setHalted(true);(ok,)=o.tryPrice();assertFalse(ok);
    }

    function _sqrt() private view returns (uint160 p) { (p,,,,,,) = pool.slot0(); }
}
