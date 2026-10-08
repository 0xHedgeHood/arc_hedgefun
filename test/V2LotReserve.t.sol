// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {RegisterV2LotReserve} from "../script/RegisterV2LotReserve.s.sol";
import {LotReserveScheduler} from "../src/v2/strategy/LotReserveScheduler.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {V2TreasuryUpgradeController} from "../src/v2/V2TreasuryUpgradeController.sol";
import {LotReserveConfig} from "../src/v2/strategy/V2LotReservePolicy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {
    HedgeFunV2UpgradeableReserveTreasury,
    HedgeFunV2UpgradeableReserveTreasuryLogic
} from "../src/v2/HedgeFunV2ReserveTreasury.sol";
import {V2LotReservePolicy} from "../src/v2/strategy/V2LotReservePolicy.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {EngineConfig} from "../src/v2/strategy/IStrategyPolicy.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";
import {ISwapCallback, MockLpPool} from "./mocks/Mocks.sol";

contract LotReserveVenue is MockLpPool {
    uint256 private immutable scale;
    uint256 public price;
    uint256 public fillBps = 10_000;

    constructor(address stock, address usdg, uint256 scale_) MockLpPool(stock, usdg, 3000) {
        scale = scale_;
    }

    function setPrice(uint256 p) external {
        price = p;
        sqrtPriceX96 = uint160(Math.sqrt(Math.mulDiv(p, 1 << 192, scale)));
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    function setFill(uint256 bps) external {
        require(bps <= 10_000);
        fillBps = bps;
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 limit, bytes calldata data)
        external
        returns (int256 a0, int256 a1)
    {
        require(amountSpecified > 0);
        require(zeroForOne ? limit < sqrtPriceX96 : limit > sqrtPriceX96);
        uint256 input = uint256(amountSpecified) * fillBps / 10_000;
        uint256 net = input * (1_000_000 - fee) / 1_000_000;
        uint256 output = zeroForOne ? Math.mulDiv(net, price, scale) : Math.mulDiv(net, scale, price);
        IERC20(zeroForOne ? token1 : token0).transfer(recipient, output);
        (a0, a1) = zeroForOne ? (int256(input), -int256(output)) : (-int256(output), int256(input));
        IERC20 inputToken = IERC20(zeroForOne ? token0 : token1);
        uint256 beforeBalance = inputToken.balanceOf(address(this));
        ISwapCallback(msg.sender).uniswapV3SwapCallback(a0, a1, data);
        require(inputToken.balanceOf(address(this)) == beforeBalance + input);
    }
}

contract LotReserveSchedulerHarness {
    HedgeFunTreasuryBase.Lot[] public lots;

    function add(uint256 qty, uint256 cost, bool half, uint256 left) external {
        lots.push(HedgeFunTreasuryBase.Lot(qty, cost, half, left));
    }

    function coalesce() external returns (bool) {
        return LotReserveScheduler.coalesce(lots);
    }

    function stops(uint256 p, uint16 bps) external view returns (bool, uint256) {
        return LotReserveScheduler.dueStop(lots, p, bps);
    }

    function profits(uint256 p, uint32 tp1, uint32 tp2) external view returns (bool, uint256) {
        return LotReserveScheduler.dueProfit(lots, p, tp1, tp2);
    }

    function count() external view returns (uint256) {
        return lots.length;
    }
}

abstract contract V2LotReserveTestBase is V2FactoryFixture {
    LotReserveVenue venue;
    V2TreasuryDeployer registry;
    uint8 reserveKind;
    bytes32 policyKey;
    uint256 launchId;
    EngineConfig launchConfig;
    function _decimals() internal pure virtual returns (uint8);

    function _unit() internal pure returns (uint256) {
        return 10 ** _decimals();
    }

    function setUp() public {
        _setUpV2(_decimals());
        venue = new LotReserveVenue(address(stock), address(usdg), 1e18 * _unit() / 1e6);
        venue.setPrice(100e18);
        v3f.set(address(stock), address(usdg), 3000, address(venue));
        vm.prank(owner);
        factory.list(address(stock), address(oracle), address(venue), openPrice, true);
        usdg.mint(address(venue), 100_000_000e6);
        stock.mint(address(venue), 1_000_000 * _unit());
        registry = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        (address a, address b) = registry.makeChunks(type(HedgeFunV2UpgradeableReserveTreasury).creationCode);
        vm.prank(owner);
        reserveKind = registry.registerEngineKind(a, b, 3, 4, 3);
        V2LotReservePolicy policy = new V2LotReservePolicy();
        vm.prank(owner);
        policyKey = registry.registerPolicy(
            address(policy), 50_000, 160, keccak256("review dependencies"), keccak256("review only")
        );
    }

    function _launchReserve()
        internal
        returns (HedgeFunV2UpgradeableReserveTreasuryLogic t, HedgeFunBondingCurve curve)
    {
        return _launchWith(3000, 0, 0, 0, 0);
    }

    function _launchWith(uint16 reserve, uint16 floor, uint16 budget, uint16 count, uint16 stop)
        internal
        returns (HedgeFunV2UpgradeableReserveTreasuryLogic t, HedgeFunBondingCurve curve)
    {
        HedgeFunFactory.Request memory q = _request();
        q.tp1Bps = 800;
        q.tp2Bps = 0;
        q.stopBps = stop;
        _registerCurve(q);
        EngineConfig memory e = EngineConfig(
            4,
            3,
            policyKey,
            [
                bytes32(uint256(reserve)),
                bytes32(uint256(floor) | uint256(budget) << 16 | uint256(count) << 32),
                bytes32(0)
            ]
        );
        launchConfig = e;
        registry.setEngineConfig(q.symbol, q.nonce, reserveKind, e);
        (,, bytes32 terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        launchId = id;
        curve = HedgeFunBondingCurve(factory.curves(id));
        t = HedgeFunV2UpgradeableReserveTreasuryLogic(curve.treasury());
        stock.approve(address(curve), type(uint256).max);
    }

    function _price(uint256 p) internal {
        vm.warp(block.timestamp + 601);
        stockFeed.set(int256(p / 1e10));
        usdgFeed.set(1e8);
        venue.setPrice(p);
    }

    function test_donationExcludedFromGraduationReserve() public {
        (HedgeFunV2UpgradeableReserveTreasuryLogic t, HedgeFunBondingCurve curve) = _launchReserve();
        uint256 donation = 5 * _unit();
        stock.mint(address(t), donation);
        _graduateV2(curve);
        uint256 beforeStock = t.bookedStock();
        uint256 actualPrincipal = beforeStock - donation;
        venue.setFill(5000);
        t.execute();
        uint256 armedTarget = t.reserveStockLeft() + beforeStock - t.bookedStock();
        assertEq(armedTarget, actualPrincipal * 3000 / 10000);
        assertLt(armedTarget, beforeStock * 3000 / 10000);
    }

    function test_takeProfitCancelsOpeningReserveBeforeNewDip() public {
        (HedgeFunV2UpgradeableReserveTreasuryLogic t, HedgeFunBondingCurve curve) = _launchReserve();
        _graduateV2(curve);
        venue.setFill(5000);
        t.execute();
        assertGt(t.reserveStockLeft(), 0);
        venue.setFill(10000);
        _price(200e18);
        (HedgeFunV2Treasury.Action a,) = t.execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.TakeProfit));
        assertEq(t.lotCount(), 0);
        _price(180e18);
        (a,) = t.execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.BuyDip));
        assertEq(t.lotCount(), 1);
        assertEq(t.reserveStockLeft(), 0);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        t.execute();
    }

    function _state(HedgeFunV2UpgradeableReserveTreasuryLogic t)
        internal
        view
        returns (uint256 buys, uint256 basis, uint256 spent)
    {
        (, buys,,, basis, spent) = t.dipLimits();
    }

    function _open(HedgeFunV2UpgradeableReserveTreasuryLogic t, HedgeFunBondingCurve curve) internal {
        _graduateV2(curve);
        (HedgeFunV2Treasury.Action a, uint256 id) = t.execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.RebalanceSell));
        assertEq(id, 0);
        assertEq(t.reserveStockLeft(), 0);
    }

    function test_linkedSelectionKeepsLegacyStopAndProfitPriority() public {
        LotReserveSchedulerHarness h = new LotReserveSchedulerHarness();
        h.add(10, 100, false, 0);
        h.add(5, 120, false, 0);
        h.add(6, 120, false, 0);
        (bool found, uint256 chosen) = h.stops(90, 1000);
        assertTrue(found);
        assertEq(chosen, 2);
        LotReserveSchedulerHarness profits = new LotReserveSchedulerHarness();
        profits.add(20, 100, false, 0);
        profits.add(10, 110, true, 0);
        profits.add(10, 105, true, 0);
        (found, chosen) = profits.profits(150, 800, 1600);
        assertTrue(found);
        assertEq(chosen, 2);
        (found, chosen) = profits.profits(150, 800, 0);
        assertTrue(found);
        assertEq(chosen, 0);
    }

    function test_linkedCoalescingPreservesCostHalfAndOutstandingRung() public {
        LotReserveSchedulerHarness h = new LotReserveSchedulerHarness();
        h.add(1, 100, false, 0);
        h.add(2, 100, true, 0);
        h.add(3, 100, false, 1);
        h.add(4, 110, false, 0);
        assertFalse(h.coalesce());
        h.add(5, 100, false, 0);
        assertTrue(h.coalesce());
        assertEq(h.count(), 4);
        (uint256 qty, uint256 cost, bool half, uint256 left) = h.lots(0);
        assertEq(qty, 6);
        assertEq(cost, 100);
        assertFalse(half);
        assertEq(left, 0);
        h.add(7, 100, false, 2);
        assertTrue(h.coalesce());
        (qty, cost, half, left) = h.lots(2);
        assertEq(qty, 10);
        assertEq(cost, 100);
        assertFalse(half);
        assertEq(left, 3);
        assertEq(h.count(), 4);
        assertFalse(h.coalesce());
    }

    function test_upgradeCannotReplenishUsedBudgetOrBuyCount() public {
        (HedgeFunV2UpgradeableReserveTreasuryLogic t, HedgeFunBondingCurve curve) = _launchWith(3000, 1000, 1000, 1, 0);
        _open(t, curve);
        _price(90e18);
        t.execute();
        (uint256 count, uint256 basis, uint256 spent) = _state(t);
        assertEq(count, 1);
        assertGt(spent, 0);
        HedgeFunV2UpgradeableReserveTreasuryLogic next = new HedgeFunV2UpgradeableReserveTreasuryLogic(
            address(usdg),
            address(stock),
            address(venue),
            address(oracle),
            curve.token(),
            address(pm),
            address(factory),
            t.params(),
            launchConfig
        );
        V2TreasuryUpgradeController controller = registry.upgradeController();
        vm.prank(owner);
        controller.schedule(address(t), address(next), "");
        vm.warp(block.timestamp + 2 days);
        controller.execute(address(t), "");
        (uint256 count2, uint256 basis2, uint256 spent2) = _state(t);
        assertEq(count2, count);
        assertEq(basis2, basis);
        assertEq(spent2, spent);
        _price(80e18);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        t.execute();
    }

    function test_registrationRejectsMissingOrSubstitutedLinkedScheduler() public {
        RegisterV2LotReserve script = new RegisterV2LotReserve();
        address scheduler = script.checkScheduler();
        assertEq(scheduler, address(LotReserveScheduler));
        bytes memory original = scheduler.code;
        vm.etch(scheduler, hex"00");
        vm.expectRevert(RegisterV2LotReserve.BadBinding.selector);
        script.checkScheduler();
        vm.etch(scheduler, original);
        assertEq(script.checkScheduler(), scheduler);
    }

    function test_runtimeAndInitcodeFitChainLimits() public {
        (HedgeFunV2UpgradeableReserveTreasuryLogic t,) = _launchReserve();
        address impl = HedgeFunV2UpgradeableReserveTreasury(payable(address(t))).initialImplementation();
        assertLe(impl.code.length, 24576, "reserve logic must fit EIP-170");
        assertLe(
            type(HedgeFunV2UpgradeableReserveTreasury).creationCode.length
                + abi.encode(
                    address(usdg),
                    address(stock),
                    address(venue),
                    address(oracle),
                    address(t.token()),
                    address(pm),
                    address(factory),
                    t.params(),
                    launchConfig
                )
                .length,
            49152,
            "proxy initcode must fit EIP-3860"
        );
    }

    function test_factoryOnlyExactPrincipalAndOneShotWiring() public {
        (HedgeFunV2UpgradeableReserveTreasuryLogic t, HedgeFunBondingCurve curve) = _launchReserve();
        (PoolKey memory key,) = factory.graduationConfig(launchId);
        vm.expectRevert(HedgeFunTreasuryBase.NotFactory.selector);
        t.wireWithGraduation(key, 100 * _unit());
        vm.expectRevert(bytes4(keccak256("GraduationPrincipalRequired()")));
        t.wire(key);
        _graduateV2(curve);
        assertTrue(t.reserveArmed());
        vm.prank(address(factory));
        vm.expectRevert(HedgeFunTreasuryBase.AlreadyWired.selector);
        t.wireWithGraduation(key, 0);
    }

    function test_zeroPrincipalIsFrozenAndDonationCannotArmIt() public {
        (HedgeFunV2UpgradeableReserveTreasuryLogic t, HedgeFunBondingCurve curve) = _launchReserve();
        _graduateV2(curve);
        (PoolKey memory key,) = factory.graduationConfig(launchId);
        HedgeFunV2UpgradeableReserveTreasuryLogic direct = new HedgeFunV2UpgradeableReserveTreasuryLogic(
            address(usdg),
            address(stock),
            address(venue),
            address(oracle),
            curve.token(),
            address(pm),
            address(this),
            t.params(),
            launchConfig
        );
        direct.wireWithGraduation(key, 0);
        stock.mint(address(direct), 5 * _unit());
        // This standalone boundary treasury is intentionally absent from the real hook registry.
        vm.mockCall(address(hook), abi.encodeWithSignature("observationCount()"), abi.encode(uint16(0)));
        direct.book();
        assertTrue(direct.reserveArmed());
        assertEq(direct.reserveStockLeft(), 0);
        (,, bool frozen, uint256 principal, uint256 basis,) = direct.dipLimits();
        assertTrue(frozen);
        assertEq(principal, 0);
        assertEq(basis, 0);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        direct.execute();
    }

    function test_plainWordZeroKeepsLegacyDipAndNoOpeningSale() public {
        (HedgeFunV2UpgradeableReserveTreasuryLogic t, HedgeFunBondingCurve curve) = _launchWith(0, 0, 0, 0, 0);
        _graduateV2(curve);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        t.execute();
        usdg.mint(address(t), 100e6);
        _price(90e18);
        (HedgeFunV2Treasury.Action a,) = t.execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.BuyDip));
    }

    function test_cashFloorClipsGrossSpendAndStopsFurtherDips() public {
        (HedgeFunV2UpgradeableReserveTreasuryLogic t, HedgeFunBondingCurve curve) = _launchWith(3000, 2000, 0, 0, 0);
        _open(t, curve);
        (, uint256 basis,) = _state(t);
        uint256 floor = Math.mulDiv(basis, 2000, 10000, Math.Rounding.Ceil);
        _price(90e18);
        t.execute();
        _price(81e18);
        t.execute();
        assertGe(t.reserveUsdg(), floor);
        assertLt(t.reserveUsdg() - floor, 5e6);
        (uint256 count,, uint256 spent) = _state(t);
        assertEq(count, 2);
        assertGt(spent, 0);
        _price(72e18);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        t.execute();
        (uint256 afterCount,, uint256 afterSpent) = _state(t);
        assertEq(afterCount, count);
        assertEq(afterSpent, spent);
    }

    function test_budgetIncludesKeeperAndCannotBeRefilledByCashOrStockDonations() public {
        (HedgeFunV2UpgradeableReserveTreasuryLogic t, HedgeFunBondingCurve curve) = _launchWith(3000, 0, 1000, 0, 0);
        _open(t, curve);
        (, uint256 basis,) = _state(t);
        uint256 cash = t.reserveUsdg();
        uint256 keeper = usdg.balanceOf(address(this));
        _price(90e18);
        t.execute();
        (uint256 count,, uint256 spent) = _state(t);
        assertEq(spent, cash - t.reserveUsdg());
        assertGt(usdg.balanceOf(address(this)), keeper);
        assertEq(count, 1);
        _price(81e18);
        t.execute();
        (count,, spent) = _state(t);
        assertLe(spent, basis / 10);
        assertLt(basis / 10 - spent, 5e6);
        usdg.mint(address(t), 10000e6);
        stock.mint(address(t), 100 * _unit());
        t.book();
        (, uint256 afterBasis,) = _state(t);
        assertEq(afterBasis, basis);
        _price(72e18);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        t.execute();
        (uint256 afterCount,, uint256 afterSpent) = _state(t);
        assertEq(afterCount, count);
        assertEq(afterSpent, spent);
    }

    function test_countCapPersistsAfterProfitsAndDonations() public {
        (HedgeFunV2UpgradeableReserveTreasuryLogic t, HedgeFunBondingCurve curve) = _launchWith(3000, 0, 0, 1, 0);
        _open(t, curve);
        _price(90e18);
        t.execute();
        (uint256 count, uint256 basis, uint256 spent) = _state(t);
        assertEq(count, 1);
        _price(200e18);
        for (uint256 i; i < 2; ++i) {
            t.execute();
        }
        usdg.mint(address(t), 1000e6);
        _price(180e18);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        t.execute();
        (uint256 count2, uint256 basis2, uint256 spent2) = _state(t);
        assertEq(count2, count);
        assertEq(basis2, basis);
        assertEq(spent2, spent);
    }

    function test_partialBuyCountsOnlyActualFillAndReward() public {
        (HedgeFunV2UpgradeableReserveTreasuryLogic t, HedgeFunBondingCurve curve) = _launchWith(3000, 0, 1000, 2, 0);
        _open(t, curve);
        uint256 cash = t.reserveUsdg();
        venue.setFill(5000);
        _price(90e18);
        t.execute();
        (uint256 count,, uint256 spent) = _state(t);
        assertEq(count, 1);
        assertEq(spent, cash - t.reserveUsdg());
        assertLt(spent, cash / 5);
    }

    function test_failedFillRollsBackAllRiskCountersAndCash() public {
        (HedgeFunV2UpgradeableReserveTreasuryLogic t, HedgeFunBondingCurve curve) = _launchWith(3000, 0, 1000, 2, 0);
        _open(t, curve);
        uint256 cash = t.reserveUsdg();
        uint256 lotsBefore = t.lotCount();
        _price(90e18);
        venue.setFill(1);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        t.execute();
        (uint256 count,, uint256 spent) = _state(t);
        assertEq(count, 0);
        assertEq(spent, 0);
        assertEq(t.reserveUsdg(), cash);
        assertEq(t.lotCount(), lotsBefore);
        venue.setFill(0);
        vm.expectRevert();
        t.execute();
        (count,, spent) = _state(t);
        assertEq(count, 0);
        assertEq(spent, 0);
    }

    function test_stopPreemptsAndCancelsPartialOpeningReserve() public {
        (HedgeFunV2UpgradeableReserveTreasuryLogic t, HedgeFunBondingCurve curve) = _launchWith(3000, 0, 1000, 1, 1000);
        _graduateV2(curve);
        venue.setFill(5000);
        t.execute();
        assertGt(t.reserveStockLeft(), 0);
        _price(80e18);
        (HedgeFunV2Treasury.Action a,) = t.execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.Stop));
        assertEq(t.reserveStockLeft(), 0);
        venue.setFill(10000); // finish the due stop before reentry
        t.execute();
        _price(70e18);
        t.execute();
        (uint256 count, uint256 basis, uint256 spent) = _state(t);
        assertEq(count, 1);
        assertGt(basis, 0);
        assertGt(spent, 0);
        _price(60e18); // stop on the new dip lot
        t.execute();
        _price(50e18);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        t.execute();
        (uint256 count2, uint256 basis2, uint256 spent2) = _state(t);
        assertEq(count2, count);
        assertEq(basis2, basis);
        assertEq(spent2, spent);
    }

    function test_smallOpeningTailCompletesWithoutBuyingOrPayingKeeper() public {
        (HedgeFunV2UpgradeableReserveTreasuryLogic t, HedgeFunBondingCurve curve) = _launchReserve();
        _graduateV2(curve);
        venue.setFill(9900);
        t.execute();
        t.execute();
        assertGt(t.reserveStockLeft(), 0);
        uint256 cash = t.reserveUsdg();
        uint256 qty = t.bookedStock();
        uint256 reward = usdg.balanceOf(address(this));
        (HedgeFunV2Treasury.Action a, uint256 id) = t.execute();
        assertEq(uint256(a), uint256(HedgeFunV2Treasury.Action.RebalanceSell));
        assertEq(id, 0);
        assertEq(t.reserveStockLeft(), 0);
        assertEq(t.reserveUsdg(), cash);
        assertEq(t.bookedStock(), qty);
        assertEq(usdg.balanceOf(address(this)), reward);
        (uint256 count,, uint256 spent) = _state(t);
        assertEq(count, 0);
        assertEq(spent, 0);
    }

    function test_openingSaleRespectsListingChunkAndActualReward() public {
        HedgeFunFactory.Defaults memory d = factory.getDefaults();
        d.sellChunkUsdg = 200e6;
        vm.prank(owner);
        factory.setDefaults(d);
        (HedgeFunV2UpgradeableReserveTreasuryLogic t, HedgeFunBondingCurve curve) = _launchReserve();
        _graduateV2(curve);
        uint256 target = t.reserveStockLeft();
        uint256 keeper = usdg.balanceOf(address(this));
        venue.setFill(5000);
        t.execute();
        uint256 sold = target - t.reserveStockLeft();
        assertLe(sold, 200e6 * 1e18 * _unit() / 1e6 / 100e18);
        uint256 got = Math.mulDiv(sold * 997 / 1000, 100e18, 1e18 * _unit() / 1e6);
        assertEq(usdg.balanceOf(address(this)) - keeper, got * 50 / 10000);
        assertEq(t.reserveUsdg(), got - got * 50 / 10000);
        assertEq(t.buybackStock(), 0);
    }

    function test_staleFeedCannotSellOrChangeTarget() public {
        (HedgeFunV2UpgradeableReserveTreasuryLogic t, HedgeFunBondingCurve curve) = _launchReserve();
        _graduateV2(curve);
        uint256 left = t.reserveStockLeft();
        uint256 cash = t.reserveUsdg();
        vm.warp(block.timestamp + 27 hours);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        t.execute();
        assertEq(t.reserveStockLeft(), left);
        assertEq(t.reserveUsdg(), cash);
        _price(100e18);
        t.execute();
        assertEq(t.reserveStockLeft(), 0);
    }

    function test_invalidPackedConfigRejectedByPolicyAndDeployment() public {
        V2LotReservePolicy policy = new V2LotReservePolicy();
        EngineConfig memory e = EngineConfig(4, 3, policyKey, [bytes32(uint256(3000)), bytes32(0), bytes32(0)]);
        assertTrue(policy.validConfig(e));
        uint256[4] memory bad = [uint256(10001), uint256(10001) << 16, uint256(1) << 48, type(uint256).max];
        for (uint256 i; i < bad.length; ++i) {
            e.words[1] = bytes32(bad[i]);
            assertFalse(policy.validConfig(e));
            HedgeFunFactory.Request memory q = _request();
            _registerCurve(q);
            registry.setEngineConfig(q.symbol, q.nonce, reserveKind, e);
            (,, bytes32 terms) = factory.predict(q);
            vm.expectRevert(V2TreasuryDeployer.TreasuryDeployFailed.selector);
            factory.launch(q, terms);
        }
        e.words[1] = 0;
        e.words[0] = bytes32(uint256(5001));
        assertFalse(policy.validConfig(e));
        e.words[0] = bytes32(uint256(5000));
        assertTrue(policy.validConfig(e));
        e.words[2] = bytes32(uint256(1));
        assertFalse(policy.validConfig(e));
    }

    function test_initializeCannotResetLimitsAfterDeployment() public {
        (HedgeFunV2UpgradeableReserveTreasuryLogic t,) = _launchReserve();
        bytes32[5] memory words;
        vm.expectRevert(HedgeFunV2UpgradeableReserveTreasuryLogic.InvalidInitialization.selector);
        t.initializeProxy(words, 5000, 0, bytes32(0), bytes32(0));
        address impl = HedgeFunV2UpgradeableReserveTreasury(payable(address(t))).initialImplementation();
        vm.expectRevert(HedgeFunV2UpgradeableReserveTreasuryLogic.InvalidInitialization.selector);
        HedgeFunV2UpgradeableReserveTreasuryLogic(impl).initializeProxy(words, 5000, 0, bytes32(0), bytes32(0));
    }

    function test_upgradePreservesPrincipalPendingReserveBudgetAndLots() public {
        (HedgeFunV2UpgradeableReserveTreasuryLogic t, HedgeFunBondingCurve curve) = _launchWith(3000, 1000, 1000, 2, 0);
        _graduateV2(curve);
        venue.setFill(5000);
        t.execute();
        uint256 left = t.reserveStockLeft();
        (bool ok, bytes memory beforeLimits) = address(t).staticcall(abi.encodeWithSignature("dipLimits()"));
        assertTrue(ok);
        uint256 qty = t.bookedStock();
        uint256 cash = t.reserveUsdg();
        HedgeFunV2UpgradeableReserveTreasuryLogic next = new HedgeFunV2UpgradeableReserveTreasuryLogic(
            address(usdg),
            address(stock),
            address(venue),
            address(oracle),
            curve.token(),
            address(pm),
            address(factory),
            t.params(),
            launchConfig
        );
        V2TreasuryUpgradeController controller = registry.upgradeController();
        vm.prank(owner);
        controller.schedule(address(t), address(next), "");
        vm.expectRevert(V2TreasuryUpgradeController.NotReady.selector);
        controller.execute(address(t), "");
        vm.warp(block.timestamp + 2 days);
        controller.execute(address(t), "");
        assertEq(t.reserveStockLeft(), left);
        assertEq(t.bookedStock(), qty);
        assertEq(t.reserveUsdg(), cash);
        (, bytes memory afterLimits) = address(t).staticcall(abi.encodeWithSignature("dipLimits()"));
        assertEq(afterLimits, beforeLimits);
        _price(100e18);
        venue.setFill(10000);
        t.execute();
        _price(90e18);
        t.execute();
        (uint256 count,, uint256 spent) = _state(t);
        assertEq(count, 1);
        assertGt(spent, 0);
    }

    function testFuzz_donationsNeverIncreaseExactReserveTarget(uint96 amount) public {
        (HedgeFunV2UpgradeableReserveTreasuryLogic t, HedgeFunBondingCurve curve) = _launchReserve();
        uint256 donation = bound(uint256(amount), 0, 1000 * _unit());
        stock.mint(address(t), donation);
        _graduateV2(curve);
        (,,, uint256 principal,,) = t.dipLimits();
        assertEq(t.reserveStockLeft(), principal * 3000 / 10000);
        assertEq(t.bookedStock(), principal + donation);
        venue.setFill(5000);
        uint256 beforeStock = t.bookedStock();
        t.execute();
        assertEq(t.reserveStockLeft() + beforeStock - t.bookedStock(), principal * 3000 / 10000);
    }
}

contract V2LotReserveTest is V2LotReserveTestBase {
    function _decimals() internal pure override returns (uint8) {
        return 18;
    }
}

contract V2LotReserveSixDecimalsTest is V2LotReserveTestBase {
    function _decimals() internal pure override returns (uint8) {
        return 6;
    }
}
