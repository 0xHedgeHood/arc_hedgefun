// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";
import {HedgeFunBondingCurve as Curve} from "../src/v2/HedgeFunBondingCurve.sol";
import {CurveDeployer} from "../src/v2/CurveDeployer.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract CurveStock is ERC20 {
    address public blocked;
    bool public taxed;
    bool public senderSurcharge;
    constructor() ERC20("Stock", "STK") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function configure(address b, bool t) external { blocked = b; taxed = t; }
    function setSenderSurcharge(bool value) external { senderSurcharge = value; }
    function _update(address from, address to, uint256 amount) internal override {
        require(to != blocked, "blocked");
        if (senderSurcharge && from != address(0)) super._update(from, address(0), amount / 100);
        if (taxed && from != address(0)) { super._update(from, address(0), amount / 100); amount -= amount / 100; }
        super._update(from, to, amount);
    }
}
contract BondingCurveTest is Test {
    Curve curve; CurveStock stock; HedgeFunToken token;
    address protocol = address(0x11); address creator = address(0x22); address treasury = address(0x33);
    uint256 constant SUPPLY = 1_000_000e18;
    uint256 releasedStock; uint256 releasedToken;
    bool failGraduation; bool skipRelease;
    function graduateCurve() external {
        require(!failGraduation, "seed failed");
        if (!skipRelease) (releasedStock, releasedToken) = Curve(msg.sender).release();
    }
    function setUp() public {
        stock = new CurveStock();
        token = new HedgeFunToken("Meme", "MEME", SUPPLY, address(this), creator);
        curve = new Curve(_init());
        token.transfer(address(curve), SUPPLY);
        stock.mint(address(this), 1_000_000e18);
        stock.approve(address(curve), type(uint256).max);
        token.approve(address(curve), type(uint256).max);
    }
    function _init() internal view returns (Curve.Init memory) {
        return Curve.Init(address(this), address(token), address(stock), treasury, protocol, creator,
            SUPPLY, 100e18, 8000, 1000, 2000, 1000, 0, 0, new address[](0));
    }
    function testBuySellConservation() public {
        (uint256 spent, uint256 output, uint256 burned) = curve.quoteBuy(10e18);
        curve.buy(10e18, output, address(this), block.timestamp);
        assertEq(token.totalSupply(), SUPPLY - burned);
        assertEq(curve.tokenReserve() + output + burned, SUPPLY);
        assertEq(stock.balanceOf(address(curve)), spent);
        uint256 buyFee = spent * curve.taxBps() / 10000;
        assertEq(burned, 0, "flat buy fee is stock, not a token burn");
        assertEq(curve.realStockReserve(), spent - buyFee);
        (uint256 proceeds, uint256 fee) = curve.quoteSell(output);
        uint256 beforeBalance = stock.balanceOf(address(this));
        curve.sell(output, proceeds, address(this), block.timestamp);
        assertEq(stock.balanceOf(address(this)) - beforeBalance, proceeds);
        assertEq(stock.balanceOf(address(curve)), curve.realStockReserve() + curve.totalFees());
        assertEq(curve.totalFees(), buyFee + fee);
        assertEq(curve.claimable(protocol) + curve.claimable(creator) + curve.claimable(treasury), buyFee + fee);
        assertLt(proceeds, spent);
    }
    function testCapReleaseAndDonationIsolation() public {
        (uint256 spent, uint256 out, uint256 burn) = curve.quoteBuy(type(uint256).max);
        stock.mint(address(curve), 123e18);
        (uint256 spentAfter, uint256 outAfter,) = curve.quoteBuy(type(uint256).max);
        assertEq(spent, spentAfter); assertEq(out, outAfter);
        uint256 beforeBalance = stock.balanceOf(address(this));
        curve.buy(type(uint256).max, out, address(this), block.timestamp);
        // The test factory is also this buyer: release returns the principal to it atomically.
        assertEq(beforeBalance + releasedStock - stock.balanceOf(address(this)), spent);
        assertEq(curve.tokenReserve(), 0);
        assertEq(out + burn + releasedToken, SUPPLY);
        assertEq(uint256(curve.status()), uint256(Curve.Status.Graduated));
        vm.expectRevert(Curve.Closed.selector); curve.sell(1, 0, address(this), block.timestamp);
        vm.prank(creator); vm.expectRevert(Curve.NotFactory.selector); curve.release();
        uint256 fee = spent * curve.taxBps() / 10000;
        assertEq(releasedStock, spent - fee); assertEq(releasedToken, SUPPLY / 5);
        assertEq(stock.balanceOf(address(curve)), 123e18 + fee);
        assertEq(curve.totalFees(), fee);
        vm.expectRevert(Curve.Closed.selector); curve.release();
    }
    function testClaimsIndependentAndSurviveGraduation() public {
        (,uint256 out) = curve.buy(10e18, 0, address(this), block.timestamp);
        curve.sell(out / 2, 0, address(this), block.timestamp);
        uint256 fee = curve.claimable(protocol);
        stock.configure(protocol, false);
        vm.expectRevert(bytes("blocked")); curve.claimFees(protocol);
        assertEq(curve.claimable(protocol), fee);
        curve.claimFees(creator);
        assertGt(stock.balanceOf(creator), 0);
        curve.buy(type(uint256).max, 0, address(this), block.timestamp);
        assertEq(stock.balanceOf(address(curve)), curve.totalFees());
        stock.configure(address(0), false);
        curve.claimFees(protocol); curve.claimFees(creator); curve.claimFees(treasury);
        assertEq(curve.totalFees(), 0); assertEq(stock.balanceOf(address(curve)), 0);
    }
    function testRejectTaxedInputAndSlippageDeadline() public {
        stock.configure(address(0), true);
        vm.expectRevert(Curve.UnsupportedTransfer.selector); curve.buy(10e18, 0, address(this), block.timestamp);
        assertEq(curve.realStockReserve(), 0);
        assertEq(curve.totalFees(), 0, "failed collection rolls back every fee credit");
        stock.configure(address(0), false);
        vm.expectRevert(Curve.Slippage.selector); curve.buy(10e18, SUPPLY, address(this), block.timestamp);
        vm.warp(100);
        vm.expectRevert(Curve.Expired.selector); curve.buy(10e18, 0, address(this), 99);
        vm.expectRevert(Curve.BadTrade.selector); curve.buy(0, 0, address(this), 100);
        vm.expectRevert(Curve.BadTrade.selector); curve.buy(10e18, 0, address(curve), 100);
    }
    function testUnfundedCurveCannotTrade() public {
        Curve empty = new Curve(_init());
        stock.approve(address(empty), type(uint256).max);
        vm.expectRevert(Curve.Insolvent.selector); empty.buy(10e18, 0, address(this), block.timestamp);
    }
    function testTokenDonationDoesNotChangeQuotes() public {
        (,uint256 out) = curve.buy(10e18, 0, address(this), block.timestamp);
        (uint256 spent, uint256 quoted,) = curve.quoteBuy(3e18);
        token.transfer(address(curve), out / 2);
        (uint256 spent2, uint256 quoted2,) = curve.quoteBuy(3e18);
        assertEq(spent, spent2); assertEq(quoted, quoted2);
    }
    function testFuzzRoundTripCannotProfit(uint96 input) public {
        uint256 amount = bound(uint256(input), 1e9, 350e18);
        uint256 startBalance = stock.balanceOf(address(this));
        (,uint256 out) = curve.buy(amount, 0, address(this), block.timestamp);
        curve.sell(out, 0, address(this), block.timestamp);
        assertLe(stock.balanceOf(address(this)), startBalance);
        assertEq(stock.balanceOf(address(curve)), curve.realStockReserve() + curve.totalFees());
        assertEq(token.balanceOf(address(curve)), curve.tokenReserve());
    }
    function testDeployerPredictAndAuthorization() public {
        CurveDeployer d = new CurveDeployer(7931); d.bind();
        bytes memory args = abi.encode(_init()); bytes32 salt = bytes32(uint256(77));
        address predicted = d.predict(salt, args);
        vm.prank(creator); vm.expectRevert(); d.deploy(salt, args);
        assertEq(d.deploy(salt, args), predicted);
        assertEq(Curve(predicted).factory(), address(this));
    }
    function testTinyUnitsCannotExtractPreviousBuyRounding() public {
        HedgeFunToken tinyToken = new HedgeFunToken("Tiny", "T", 100, address(this), creator);
        Curve.Init memory p = _init(); p.token = address(tinyToken); p.supply = 100; p.virtualStock = 100; p.taxBps = 0;
        Curve tiny = new Curve(p);
        tinyToken.transfer(address(tiny), 100); tinyToken.approve(address(tiny), type(uint256).max);
        stock.approve(address(tiny), type(uint256).max);
        (uint256 spent, uint256 out) = tiny.buy(200, 0, address(this), block.timestamp);
        assertEq(spent, 195); assertEq(out, 66);
        vm.expectRevert(Curve.BadTrade.selector); tiny.buy(4, 0, address(this), block.timestamp);
        uint256 beforeBalance = stock.balanceOf(address(this));
        (,out) = tiny.buy(9, 0, address(this), block.timestamp);
        tiny.sell(out, 0, address(this), block.timestamp);
        assertEq(stock.balanceOf(address(this)), beforeBalance);
    }
    function testFuzzTinyCanonicalReserveRoundTrips(uint16 input, uint16 nextInput, uint16 virtualAmount) public {
        HedgeFunToken tinyToken = new HedgeFunToken("Tiny", "T", 10000, address(this), creator);
        Curve.Init memory p = _init(); p.token = address(tinyToken); p.supply = 10000;
        p.virtualStock = bound(virtualAmount, 1, 10000); p.taxBps = 0;
        Curve tiny = new Curve(p); tinyToken.transfer(address(tiny), 10000);
        tinyToken.approve(address(tiny), type(uint256).max); stock.approve(address(tiny), type(uint256).max);
        uint256 first = bound(input, 1, p.virtualStock);
        (uint256 spent, uint256 out,) = tiny.quoteBuy(first);
        if (spent == 0 || out == 0) return;
        tiny.buy(first, 0, address(this), block.timestamp);
        uint256 next = bound(nextInput, 1, p.virtualStock);
        (spent, out,) = tiny.quoteBuy(next);
        if (spent == 0 || out == 0) return;
        uint256 beforeBalance = stock.balanceOf(address(this));
        tiny.buy(next, 0, address(this), block.timestamp);
        tiny.sell(out, 0, address(this), block.timestamp);
        assertEq(stock.balanceOf(address(this)), beforeBalance);
        assertEq(tiny.virtualStock() + tiny.realStockReserve(), (tiny.invariant() + tiny.tokenReserve() - 1) / tiny.tokenReserve());
    }

    function testFuzzTerminalReachability(uint16 supplySeed, uint16 virtualSeed, uint16 saleSeed, uint16 budgetSeed) public {
        uint256 supply = bound(supplySeed, 10, 10000);
        HedgeFunToken tinyToken = new HedgeFunToken("Tiny", "T", supply, address(this), creator);
        Curve.Init memory p = _init(); p.token = address(tinyToken); p.supply = supply;
        p.virtualStock = bound(virtualSeed, 1, 10000); p.saleBps = uint16(bound(saleSeed, 1000, 9000)); p.taxBps = 0;
        Curve tiny = new Curve(p); tinyToken.transfer(address(tiny), supply);
        tinyToken.approve(address(tiny), type(uint256).max); stock.approve(address(tiny), type(uint256).max);
        uint256 budget = bound(budgetSeed, 0, tiny.terminalStock() - p.virtualStock - 1);
        (uint256 spent, uint256 out,) = tiny.quoteBuy(budget);
        if (spent > 0 && out > 0) {
            tiny.buy(budget, 0, address(this), block.timestamp);
            (uint256 proceeds,) = tiny.quoteSell(out / 2);
            if (proceeds > 0) tiny.sell(out / 2, 0, address(this), block.timestamp);
        }
        (spent, out,) = tiny.quoteBuy(type(uint256).max);
        assertGt(spent, 0); assertGt(out, 0);
        tiny.buy(type(uint256).max, out, address(this), block.timestamp);
        assertEq(uint256(tiny.status()), uint256(Curve.Status.Graduated));
        assertEq(releasedToken, tiny.minTokenReserve());
        assertEq(releasedStock + p.virtualStock, tiny.terminalStock());
    }

    function test_RevertGraduationRollsBackFinalBuyAndKeepsSellsOpen() public {
        (,uint256 out) = curve.buy(10e18, 0, address(this), block.timestamp);
        uint256 reserve = curve.realStockReserve();
        uint256 inventory = curve.tokenReserve();
        uint256 supply = token.totalSupply();
        uint256 balance = stock.balanceOf(address(this));
        failGraduation = true;
        vm.expectRevert(bytes("seed failed"));
        curve.buy(type(uint256).max, 0, address(this), block.timestamp);
        assertEq(uint256(curve.status()), uint256(Curve.Status.Active));
        assertEq(curve.realStockReserve(), reserve);
        assertEq(curve.tokenReserve(), inventory);
        assertEq(token.totalSupply(), supply);
        assertEq(stock.balanceOf(address(this)), balance);
        assertGt(curve.sell(out / 2, 0, address(this), block.timestamp), 0);
        failGraduation = false;
        curve.buy(type(uint256).max, 0, address(this), block.timestamp);
        assertEq(uint256(curve.status()), uint256(Curve.Status.Graduated));
    }

    function testFactoryCannotLeaveReadyPersisted() public {
        skipRelease = true;
        vm.expectRevert(Curve.GraduationFailed.selector);
        curve.buy(type(uint256).max, 0, address(this), block.timestamp);
        assertEq(uint256(curve.status()), uint256(Curve.Status.Active));
        assertEq(curve.realStockReserve(), 0);
    }

    function testTaxedOutputCannotUnderpaySellerOrFeeRecipient() public {
        (,uint256 out) = curve.buy(10e18, 0, address(this), block.timestamp);
        curve.sell(out / 2, 0, address(this), block.timestamp);
        uint256 fees = curve.totalFees();
        uint256 reserve = curve.realStockReserve();
        stock.mint(address(curve), 1e18); // Donations must not mask nonstandard transfers.
        stock.configure(address(0), true);
        vm.expectRevert(Curve.UnsupportedTransfer.selector);
        curve.sell(out / 2, 0, address(this), block.timestamp);
        assertEq(curve.realStockReserve(), reserve);
        vm.expectRevert(Curve.UnsupportedTransfer.selector);
        curve.claimFees(protocol);
        assertEq(curve.totalFees(), fees);
    }

    function testSenderSurchargeCannotExceedBuyBudgetOrConsumeDonations() public {
        stock.setSenderSurcharge(true);
        uint256 beforeUser = stock.balanceOf(address(this));
        vm.expectRevert(Curve.UnsupportedTransfer.selector);
        curve.buy(10e18, 0, address(this), block.timestamp);
        assertEq(stock.balanceOf(address(this)), beforeUser);
        stock.setSenderSurcharge(false);
        (,uint256 out) = curve.buy(10e18, 0, address(this), block.timestamp);
        stock.mint(address(curve), 1e18);
        uint256 reserve = curve.realStockReserve();
        stock.setSenderSurcharge(true);
        vm.expectRevert(Curve.UnsupportedTransfer.selector);
        curve.sell(out, 0, address(this), block.timestamp);
        assertEq(curve.realStockReserve(), reserve);
        assertEq(stock.balanceOf(address(curve)), reserve + curve.totalFees() + 1e18);
    }

    function _feeCurve(uint256 supply, uint256 virtualAmount, uint16 baseTax) private returns (Curve c, HedgeFunToken t) {
        t = new HedgeFunToken("Fee test", "FEE", supply, address(this), creator);
        Curve.Init memory p = _init();
        p.token = address(t); p.supply = supply; p.virtualStock = virtualAmount; p.taxBps = baseTax;
        c = new Curve(p);
        t.transfer(address(c), supply);
        t.approve(address(c), type(uint256).max);
        stock.approve(address(c), type(uint256).max);
    }

    function test_threePercentBuySellRevenueIsSplitTwentyTenSeventy() public {
        (Curve c, HedgeFunToken t) = _feeCurve(SUPPLY, 100e18, 300);
        (uint256 spent, uint256 out, uint256 burned) = c.quoteBuy(10e18);
        uint256 buyFee = spent * 300 / 10000;
        c.buy(10e18, out, address(this), block.timestamp);
        assertEq(burned, 0);
        assertEq(t.totalSupply(), SUPPLY);
        assertEq(c.realStockReserve(), spent - buyFee);
        assertEq(c.totalFees(), buyFee);
        assertEq(c.claimable(protocol), buyFee * 2000 / 10000);
        assertEq(c.claimable(creator), buyFee * 1000 / 10000);
        assertEq(c.claimable(treasury), buyFee - buyFee * 2000 / 10000 - buyFee * 1000 / 10000);
        (uint256 proceeds, uint256 sellFee) = c.quoteSell(out / 4);
        c.sell(out / 4, proceeds, address(this), block.timestamp);
        assertEq(c.totalFees(), buyFee + sellFee);
        assertEq(c.claimable(protocol), buyFee * 2000 / 10000 + sellFee * 2000 / 10000);
        assertEq(c.claimable(creator), buyFee * 1000 / 10000 + sellFee * 1000 / 10000);
        uint256 reserve = c.realStockReserve();
        c.claimFees(protocol); c.claimFees(creator); c.claimFees(treasury);
        assertEq(c.totalFees(), 0);
        assertEq(c.realStockReserve(), reserve);
        assertEq(stock.balanceOf(address(c)), reserve);
        assertEq(stock.balanceOf(protocol) + stock.balanceOf(creator) + stock.balanceOf(treasury), buyFee + sellFee);
    }

    function test_partialCapChargesOnlyFilledStockAndReleasesNetPrincipal() public {
        (Curve c, HedgeFunToken t) = _feeCurve(SUPPLY, 100e18, 300);
        uint256 offered = 1000e18;
        (uint256 spent, uint256 out, uint256 burn) = c.quoteBuy(offered);
        (uint256 requoted, uint256 sameOut, uint256 sameBurn) = c.quoteBuy(spent);
        assertEq(requoted, spent); assertEq(sameOut, out); assertEq(sameBurn, burn);
        assertLt(spent, offered);
        (, uint256 fewer,) = c.quoteBuy(spent - 1);
        assertLt(fewer, out, "one raw less cannot buy the final allocation");
        stock.mint(address(c), 7e18);
        uint256 beforeBalance = stock.balanceOf(address(this));
        c.buy(offered, out, address(this), block.timestamp);
        uint256 fee = spent * 300 / 10000;
        assertEq(beforeBalance + releasedStock - stock.balanceOf(address(this)), spent);
        assertEq(releasedStock, c.terminalStock() - c.virtualStock());
        assertEq(releasedStock, spent - fee);
        assertEq(releasedToken, c.minTokenReserve());
        assertEq(t.totalSupply(), SUPPLY, "base fee never burns tokens");
        assertEq(c.totalFees(), fee);
        assertEq(stock.balanceOf(address(c)), fee + 7e18);
        c.claimFees(protocol); c.claimFees(creator); c.claimFees(treasury);
        assertEq(stock.balanceOf(address(c)), 7e18, "donation is neither fees nor graduation principal");
    }

    function test_capReachabilityAtZeroAndMaximumConstructorFee() public {
        uint16[4] memory rates = [uint16(0), 300, 1500, 9999];
        for (uint256 i; i < rates.length; ++i) {
            (Curve c, HedgeFunToken t) = _feeCurve(100, 100, rates[i]);
            (uint256 spent, uint256 out, uint256 burn) = c.quoteBuy(type(uint256).max);
            assertEq(out, 80);
            assertEq(burn, 0);
            uint256 fee = spent * rates[i] / 10000;
            assertEq(spent - fee, 400);
            assertLt((spent - 1) - (spent - 1) * rates[i] / 10000, 400);
            c.buy(type(uint256).max, out, address(this), block.timestamp);
            assertEq(releasedStock, 400);
            assertEq(releasedToken, 20);
            assertEq(t.totalSupply(), 100);
            assertEq(c.totalFees(), fee);
            assertEq(stock.balanceOf(address(c)), fee);
        }
    }

    /// Independent small-unit search: the best affordable inventory change is found by enumerating
    /// token reserves and all smaller gross payments, rather than copying the inverse-fee formula.
    function testFuzz_smallUnitsChooseMinimalPaymentForBestAffordableFill(uint16 offerSeed, uint16 feeSeed) public {
        uint256 offer = bound(offerSeed, 1, 1000);
        uint16 rate = uint16(bound(feeSeed, 0, 9999));
        (Curve c,) = _feeCurve(100, 100, rate);
        uint256 affordableNet = offer - offer * rate / 10000;
        uint256 bestReserve = 100;
        for (uint256 reserve = 20; reserve <= 100; ++reserve) {
            uint256 cost = Math.ceilDiv(10000, reserve) - 100;
            if (cost <= affordableNet) { bestReserve = reserve; break; }
        }
        (uint256 spent, uint256 out, uint256 burn) = c.quoteBuy(offer);
        assertEq(out, 100 - bestReserve);
        assertEq(burn, 0);
        uint256 requiredNet = Math.ceilDiv(10000, bestReserve) - 100;
        uint256 expectedPayment;
        if (requiredNet != 0) {
            for (uint256 payment = 1; payment <= offer; ++payment) {
                if (payment - payment * rate / 10000 >= requiredNet) { expectedPayment = payment; break; }
            }
        }
        assertEq(spent, expectedPayment);
        assertLe(spent, offer);
        if (spent == 0 || out == 0) return;
        c.buy(offer, out, address(this), block.timestamp);
        uint256 fee = spent * rate / 10000;
        assertEq(c.totalFees(), fee);
        assertEq(stock.balanceOf(address(c)), c.realStockReserve() + c.totalFees());
        if (uint256(c.status()) == uint256(Curve.Status.Graduated)) {
            assertEq(releasedStock, requiredNet);
        } else {
            assertEq(c.realStockReserve(), requiredNet);
            assertEq(c.virtualStock() + c.realStockReserve(), Math.ceilDiv(c.invariant(), c.tokenReserve()));
        }
    }

    function testFuzz_roundTripsAccrueFeesWithoutReserveRoundingSubsidy(uint96 input, uint16 feeSeed) public {
        uint16 rate = uint16(bound(feeSeed, 1, 1500));
        (Curve c, HedgeFunToken t) = _feeCurve(SUPPLY, 100e18, rate);
        uint256 amount = bound(input, 1e9, 100e18);
        uint256 beforeBalance = stock.balanceOf(address(this));
        (uint256 spent, uint256 out) = c.buy(amount, 0, address(this), block.timestamp);
        uint256 buyFee = spent * rate / 10000;
        (, uint256 sellFee) = c.quoteSell(out);
        uint256 proceeds = c.sell(out, 0, address(this), block.timestamp);
        assertEq(c.realStockReserve(), 0, "complete round trip removes only funded principal");
        assertEq(c.tokenReserve(), SUPPLY);
        assertEq(t.totalSupply(), SUPPLY);
        assertEq(c.totalFees(), buyFee + sellFee);
        assertEq(stock.balanceOf(address(c)), buyFee + sellFee);
        assertEq(beforeBalance - stock.balanceOf(address(this)), spent - proceeds);
        assertEq(spent - proceeds, buyFee + sellFee, "all round trip loss is a fee liability");
    }

}
