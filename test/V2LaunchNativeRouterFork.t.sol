// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestnetV2EthMarket} from "../script/testnet/TestnetV2EthMarket.s.sol";
import {ActivateV2NativeLaunch} from "../script/ActivateV2NativeLaunch.s.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunV2TradeRouter} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {HedgeFunV2LaunchNativeRouter} from "../src/v2/HedgeFunV2LaunchNativeRouter.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";

contract V2LaunchNativeMarketInvoker {
    receive() external payable {}

    function deploy(TestnetV2EthMarket tool, string memory book)
        external
        returns (TestnetV2EthMarket.Deployment memory)
    {
        return tool.deploy(book, sha256(bytes(book)));
    }

    function poke(TestnetV2EthMarket tool, TestnetV2EthMarket.Deployment memory market) external {
        tool.poke(market);
    }

    function activate(TestnetV2EthMarket tool, TestnetV2EthMarket.Deployment memory market) external {
        tool.activate(market);
    }

    function activateLaunch(ActivateV2NativeLaunch activation) external returns (HedgeFunV2LaunchNativeRouter) {
        return activation.run();
    }
}

/// @notice Opt-in, in-memory testnet fork: deployed V2 core, genuine WETH and USDG,
///         canonical V3 pools, then the real native-launch activation and first buy.
/// @dev The independent ETH market is deployed only on this fork. vm.deal supplies rehearsal ETH;
///      no private key, signing, or public-chain transaction is involved.
contract V2LaunchNativeRouterForkTest is Test {
    address private constant OPERATOR = 0x75Cee941B0eF3A83feA0397BbF903C12c1D7e96D;
    address private constant CREATOR = address(uint160(uint256(keccak256("native launch fork creator; no key"))));
    uint256 private constant FEE = 0.001 ether;
    uint256 private constant BUY = 0.0001 ether;
    bytes32 private constant FEE_BOOK_SHA256 = 0xada428eb04ac0f982fd6a002e8745b4100c6db99ce620adcf254e42ac1cbc82c;

    struct Scenario {
        HedgeFunV2Factory factory;
        HedgeFunV2TradeRouter tradeRouter;
        HedgeFunV2LaunchNativeRouter launcher;
        HedgeFunFactory.Request q;
        HedgeFunToken.Info info;
        HedgeFunV2LaunchNativeRouter.BuyParams buy;
        HedgeFunV2TradeRouter.Hop[] path;
        address weth;
        address stock;
        address stockPool;
        address predicted;
        bytes32 terms;
        uint256 initialStrategies;
        uint256 poolStockBefore;
        uint256 quotedStock;
        uint256 quotedOut;
        uint256 quotedRefund;
    }

    function test_fork_nativeLaunchActivatesAndBuysThroughCanonicalTwoHopV3() public {
        vm.skip(!vm.envOr("V2_NATIVE_LAUNCH_FORK", false), "set V2_NATIVE_LAUNCH_FORK=true");
        uint256 forkBlock = vm.envUint("V2_NATIVE_LAUNCH_FORK_BLOCK");
        vm.createSelectFork(
            vm.envOr("V2_NATIVE_LAUNCH_RPC", string("https://rpc.testnet.chain.robinhood.com")), forkBlock
        );
        assertEq(block.chainid, 46630);
        emit log_named_uint("native launch fork block", block.number);

        TestnetV2EthMarket.Deployment memory market = _publishEthMarket();
        HedgeFunV2LaunchNativeRouter launcher = _activateNativeLaunch(market);
        Scenario memory s = _prepare(market, launcher);
        _quote(s);
        _assertAtomicRollback(s);
        _assertSuccessfulBuy(s);
    }

    function _publishEthMarket() private returns (TestnetV2EthMarket.Deployment memory market) {
        // The verified public book is an exact byte copy at the Foundry read-allowlisted path.
        string memory book = vm.readFile("deploy/testnet-v2-fees.json");
        assertEq(sha256(bytes(book)), FEE_BOOK_SHA256);
        TestnetV2EthMarket tool = new TestnetV2EthMarket();
        vm.etch(OPERATOR, address(new V2LaunchNativeMarketInvoker()).code);
        vm.deal(OPERATOR, 2 ether);
        market = V2LaunchNativeMarketInvoker(payable(OPERATOR)).deploy(tool, book);
        vm.warp(market.initializedAt + 1);
        V2LaunchNativeMarketInvoker(payable(OPERATOR)).poke(tool, market);
        vm.warp(market.initializedAt + 600);
        V2LaunchNativeMarketInvoker(payable(OPERATOR)).activate(tool, market);
    }

    function _activateNativeLaunch(TestnetV2EthMarket.Deployment memory market)
        private
        returns (HedgeFunV2LaunchNativeRouter launcher)
    {
        TestnetV2EthMarket tool = new TestnetV2EthMarket();
        HedgeFunV2Factory factory = HedgeFunV2Factory(market.base.factory);
        HedgeFunV2TradeRouter tradeRouter = HedgeFunV2TradeRouter(market.base.tradeRouter);
        assertEq(address(tradeRouter.factory()), address(factory));
        assertEq(factory.v3Factory().getPool(tool.WETH(), tool.USDG(), 500), market.pool);
        vm.setEnv("OPERATOR", vm.toString(OPERATOR));
        vm.setEnv("V2_FACTORY", vm.toString(address(factory)));
        vm.setEnv("V2_TRADE_ROUTER", vm.toString(address(tradeRouter)));
        vm.setEnv("WETH", vm.toString(tool.WETH()));
        vm.setEnv("WETH_USDG_POOL", vm.toString(market.pool));
        vm.setEnv("LAUNCH_FEE_WEI", vm.toString(FEE));
        ActivateV2NativeLaunch activation = new ActivateV2NativeLaunch();
        launcher = V2LaunchNativeMarketInvoker(payable(OPERATOR)).activateLaunch(activation);
        assertTrue(factory.launchers(address(launcher)));
        HedgeFunFactory.Defaults memory defaults = factory.getDefaults();
        assertEq(uint8(defaults.launchFeeCurrency), uint8(HedgeFunFactory.FeeCurrency.Native));
        assertEq(defaults.launchFeeAmount, FEE);
    }

    function _prepare(TestnetV2EthMarket.Deployment memory market, HedgeFunV2LaunchNativeRouter launcher)
        private
        returns (Scenario memory s)
    {
        string memory book = vm.readFile("deploy/testnet-v2-fees.json");
        s.factory = HedgeFunV2Factory(market.base.factory);
        s.tradeRouter = HedgeFunV2TradeRouter(market.base.tradeRouter);
        s.launcher = launcher;
        s.weth = new TestnetV2EthMarket().WETH();
        s.stock = vm.parseJsonAddress(book, ".stocks.TSLA.token");
        s.stockPool = vm.parseJsonAddress(book, ".stocks.TSLA.pool");
        assertEq(
            s.factory.v3Factory().getPool(s.factory.usdg(), s.stock, IUniswapV3Pool(s.stockPool).fee()), s.stockPool
        );
        s.q = _request(s.factory, s.stock, "NATIVEFORKTSLA", 202610010301);
        (s.predicted,, s.terms) = s.factory.predict(s.q);
        s.path = new HedgeFunV2TradeRouter.Hop[](2);
        s.path[0] = HedgeFunV2TradeRouter.Hop(market.pool, s.factory.usdg());
        s.path[1] = HedgeFunV2TradeRouter.Hop(s.stockPool, s.stock);
        s.info.description = "Native launch fork rehearsal";
        s.buy = HedgeFunV2LaunchNativeRouter.BuyParams({
            amountIn: BUY, minStockReceived: 1, minFinalOut: 1, deadline: block.timestamp + 300, allowPartialFill: true
        });
        vm.deal(CREATOR, 1 ether);
        s.initialStrategies = s.factory.strategyCount();
        s.poolStockBefore = IERC20(s.stock).balanceOf(s.stockPool);
    }

    function _quote(Scenario memory s) private {
        uint256 snapshot = vm.snapshotState();
        vm.prank(CREATOR);
        (, s.quotedOut, s.quotedRefund) = s.launcher.launchAndBuy{value: FEE + BUY}(s.q, s.terms, s.info, s.buy, s.path);
        s.quotedStock = s.poolStockBefore - IERC20(s.stock).balanceOf(s.stockPool);
        assertGt(s.quotedStock, 0);
        assertGt(s.quotedOut, 0);
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    function _assertAtomicRollback(Scenario memory s) private {
        // Bound both legs using the actual fork quote, then make the curve leg fail and
        // prove that its native fee, strategy deployment, and real V3 swaps all roll back.
        s.buy.minStockReceived = s.quotedStock * 99 / 100;
        s.buy.minFinalOut = s.quotedOut + 1;
        uint256 creatorBefore = CREATOR.balance;
        uint256 protocolBefore = OPERATOR.balance;
        vm.prank(CREATOR);
        vm.expectRevert();
        s.launcher.launchAndBuy{value: FEE + BUY}(s.q, s.terms, s.info, s.buy, s.path);
        assertEq(s.factory.strategyCount(), s.initialStrategies);
        assertEq(s.predicted.code.length, 0);
        assertEq(CREATOR.balance, creatorBefore);
        assertEq(OPERATOR.balance, protocolBefore);
        assertEq(IERC20(s.stock).balanceOf(s.stockPool), s.poolStockBefore);
    }

    function _assertSuccessfulBuy(Scenario memory s) private {
        uint256 creatorBefore = CREATOR.balance;
        uint256 protocolBefore = OPERATOR.balance;
        s.buy.minStockReceived = s.quotedStock * 99 / 100;
        s.buy.minFinalOut = s.quotedOut * 99 / 100;
        vm.prank(CREATOR);
        (uint256 id, uint256 out, uint256 refund) =
            s.launcher.launchAndBuy{value: FEE + BUY}(s.q, s.terms, s.info, s.buy, s.path);
        assertEq(id, s.initialStrategies);
        assertEq(out, s.quotedOut);
        assertEq(refund, s.quotedRefund);
        assertEq(s.factory.strategyCount(), s.initialStrategies + 1);
        assertEq(HedgeFunToken(s.predicted).balanceOf(CREATOR), out);
        assertEq(HedgeFunToken(s.predicted).description(), s.info.description);
        assertEq(CREATOR.balance, creatorBefore - FEE - BUY);
        assertEq(OPERATOR.balance, protocolBefore + FEE);
        assertEq(s.poolStockBefore - IERC20(s.stock).balanceOf(s.stockPool), s.quotedStock);
        assertEq(IERC20(s.stock).balanceOf(CREATOR), refund);
        assertEq(address(s.launcher).balance, 0);
        assertEq(IERC20(s.weth).balanceOf(address(s.launcher)), 0);
        assertEq(IERC20(s.stock).balanceOf(address(s.launcher)), 0);
        assertEq(IERC20(s.weth).allowance(address(s.launcher), address(s.tradeRouter)), 0);
    }

    function _request(HedgeFunV2Factory factory, address stock, string memory symbol, uint96 nonce)
        private
        view
        returns (HedgeFunFactory.Request memory q)
    {
        (,, uint256 openPrice, bool enabled) = factory.listings(stock);
        assertTrue(enabled);
        q.name = "Native launch fork";
        q.symbol = symbol;
        q.stock = stock;
        q.creator = CREATOR;
        q.taxBps = 300;
        q.creatorBps = 1000;
        q.tp1Bps = 300;
        q.tp2Bps = 600;
        q.dipBps = 300;
        q.stopBps = 0;
        q.lotBps = 2000;
        q.nonce = nonce;
        q.maxFee = FEE;
        q.expectedOpenPriceE18 = openPrice;
    }
}
