// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {HedgeFunFactory} from "../../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunBondingCurve} from "../../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2Treasury} from "../../src/v2/HedgeFunV2Treasury.sol";
import {TestStock, TestFeed} from "./TestnetAssets.sol";
import {TestnetMarket, IV3Factory, IV3Pool} from "./TestnetMarket.sol";
import {DemoBallot} from "../../src/demo/DemoBallot.sol";

interface IDemoV3History {
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory, uint160[] memory);
}

/// Isolated synthetic venue for a public testnet demo. No existing stock price or pool is changed.
/// The factory is the deployed 698e577 fees core: kind zero retains profit in stock for buyback.
contract TestnetHackathonDemo is Script {
    address constant OPERATOR = 0x75Cee941B0eF3A83feA0397BbF903C12c1D7e96D;
    address constant CREATOR = 0xD4f69D180a9bc36F27D307E90E365d1E012816d5;
    address constant FACTORY = 0xACEB03aAeE5494Aa54929Ec840630ae32A9ade0A;
    address constant MARKET = 0xc1AF2f52980F8A7AA4E90A8E30D5c3FaF0375f21;
    address constant USDG = 0x539574139BB4Ac74Fd2183ba0E38ed777E30B58d;
    address constant USDG_FEED = 0x6beF5980dDa88F8B925f814C5033959A13ae535A;
    address constant CALENDAR = 0xB8661bAd51e504862107CF4eBAdB1c8c2ABFA6CD;
    address constant V3_FACTORY = 0x0b0a96D7EB396E7471998889C4803dD0F529Eb01;
    address constant DEMO_STOCK = 0xcB4820d3C59Ec8A6b78312693d09d620f4277643;
    uint96 constant NONCE = 2026100101;
    uint256 constant OPEN = 27_932_960_894;
    error WrongVenue();

    function _guard(address sender) internal view {
        require(block.chainid == 46630 && msg.sender == sender, "testnet signer only");
        require(
            HedgeFunV2Factory(FACTORY).owner() == OPERATOR && TestnetMarket(MARKET).owner() == OPERATOR,
            "pinned venue owner"
        );
    }

    function deployVenue() external {
        _guard(OPERATOR);
        vm.startBroadcast();
        TestStock stock = new TestStock("Demo Tesla stock (synthetic testnet, no value)", "DTSLA", OPERATOR, 100e18);
        TestFeed feed = new TestFeed("DTSLA / USD (operator simulated)", 358e8, OPERATOR);
        stock.setOperator(MARKET, true);
        feed.setOperator(MARKET, true);
        PriceOracle oracle = new PriceOracle(address(stock), address(feed), USDG_FEED, CALENDAR, 26 hours, 26 hours);
        address pool = IV3Factory(V3_FACTORY).createPool(address(stock), USDG, 3000);
        bool stock0 = address(stock) < USDG;
        uint160 sqrtP =
            uint160(Math.sqrt(stock0 ? Math.mulDiv(358e18, 1 << 192, 1e30) : Math.mulDiv(1e30, 1 << 192, 358e18)));
        int24 centre = TickMath.getTickAtSqrtPrice(sqrtP) / 60 * 60;
        int24 lower = centre - 6960;
        int24 upper = centre + 6960;
        TestnetMarket market = TestnetMarket(MARKET);
        market.addLine(pool, address(stock), feed, 18, lower, upper);
        IV3Pool(pool).initialize(sqrtP);
        IV3Pool(pool).increaseObservationCardinalityNext(720);
        uint256 a = TickMath.getSqrtPriceAtTick(lower);
        uint256 b = TickMath.getSqrtPriceAtTick(upper);
        uint128 liquidity = uint128(
            stock0
                ? Math.mulDiv(30_000_000e6, 1 << 96, uint256(sqrtP) - a)
                : Math.mulDiv(Math.mulDiv(30_000_000e6, uint256(sqrtP), b - uint256(sqrtP)), b, 1 << 96)
        );
        market.provide(pool, liquidity);
        HedgeFunV2Factory(FACTORY).list(address(stock), address(oracle), pool, OPEN, true);
        HedgeFunV2Factory(FACTORY).setListingGates(address(stock), 50, 100, 2_000e6);
        stock.mint(CREATOR, 100e18);
        vm.stopBroadcast();
        console2.log("demo stock", address(stock));
        console2.log("demo feed", address(feed));
        console2.log("demo oracle", address(oracle));
        console2.log("demo pool", pool);
    }

    function launch(address stock) external {
        _guard(CREATOR);
        require(stock == DEMO_STOCK, "pinned demo stock");
        HedgeFunV2Factory f = HedgeFunV2Factory(FACTORY);
        (address oracle, address pool, uint256 open, bool enabled) = f.listings(stock);
        require(enabled && open == OPEN && PriceOracle(oracle).stock() == stock, "demo listing");
        require(TestStock(stock).owner() == OPERATOR && TestStock(stock).operators(MARKET), "demo stock");
        (address lineStock,,,,,) = TestnetMarket(MARKET).lines(pool);
        require(lineStock == stock, "demo market");
        HedgeFunFactory.Defaults memory d = f.getDefaults();
        require(d.launchFeeCurrency == HedgeFunFactory.FeeCurrency.Usdg && d.launchFeeAmount == 25e6, "fee changed");
        HedgeFunFactory.Request memory q;
        q.name = "Hedgefun Hackathon Demo";
        q.symbol = "HFDEMO";
        q.stock = stock;
        q.creator = CREATOR;
        q.taxBps = 300;
        q.creatorBps = 1000;
        q.tp1Bps = 300;
        q.tp2Bps = 600;
        q.dipBps = 500;
        q.lotBps = 2000;
        q.nonce = NONCE;
        q.maxFee = d.launchFeeAmount;
        q.expectedOpenPriceE18 = open;
        vm.startBroadcast();
        f.curveDeployer().setCurveConfig(q.symbol, NONCE, 1000, 0);
        vm.stopBroadcast();
        (address token,, bytes32 terms) = f.predict(q);
        require(token.code.length == 0, "already launched");
        vm.startBroadcast();
        IERC20(USDG).approve(FACTORY, d.launchFeeAmount);
        uint256 id = f.launch(q, terms);
        vm.stopBroadcast();
        console2.log("demo strategy id", id);
        console2.log("demo token", token);
        console2.log("demo curve", f.curves(id));
    }

    function graduate(uint256 id) external {
        _guard(CREATOR);
        HedgeFunV2Factory f = HedgeFunV2Factory(FACTORY);
        (address token, address treasury, address hook, address stock, address creator) = f.strategies(id);
        HedgeFunFactory.Strategy memory s = HedgeFunFactory.Strategy(token, treasury, hook, stock, creator);
        require(s.creator == CREATOR && s.stock == DEMO_STOCK, "demo only");
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(f.curves(id));
        require(uint8(curve.status()) == 0, "active curve only");
        (address oracle, address pool,,) = f.listings(s.stock);
        require(TestStock(s.stock).owner() == OPERATOR, "demo owner");
        (address lineStock,,,,,) = TestnetMarket(MARKET).lines(pool);
        require(lineStock == s.stock, "isolated demo line");
        (bool valid, uint256 price) = PriceOracle(oracle).tryPrice();
        require(valid && price == 358e18, "baseline feed");
        // The treasury is not wired before graduation, so its health() intentionally returns false.
        // Demand actual history on the isolated underlying pool instead of bypassing that gate.
        uint32[] memory ages = new uint32[](2);
        ages[0] = 600;
        IDemoV3History(pool).observe(ages);
        (uint256 spent, uint256 out,) = curve.quoteBuyFor(100e18, CREATOR);
        require(spent > 0 && spent < 10e18 && out > 0, "bounded graduate quote");
        vm.startBroadcast();
        IERC20(s.stock).approve(address(curve), spent);
        curve.buy(spent, out * 99 / 100, CREATOR, block.timestamp + 300);
        vm.stopBroadcast();
        require(uint8(curve.status()) == 2, "graduate receipt");
        console2.log("stock spent", spent);
        console2.log("tokens received", out);
    }

    function deployBallot(uint256 id, uint256 deadline) external {
        _guard(CREATOR);
        (address token,,, address stock, address creator) = HedgeFunV2Factory(FACTORY).strategies(id);
        require(creator == CREATOR && stock == DEMO_STOCK, "demo strategy only");
        vm.startBroadcast();
        DemoBallot ballot = new DemoBallot(token, OPERATOR, 0xdA1AEE7018a3925AA06dEEb8631Fca09E1067614, deadline);
        vm.stopBroadcast();
        console2.log("demo ballot", address(ballot));
        console2.log("poll deadline", deadline);
    }
}
