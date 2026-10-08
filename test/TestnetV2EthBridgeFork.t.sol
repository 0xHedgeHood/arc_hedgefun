// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TestnetV2EthBridge} from "../script/testnet/TestnetV2EthBridge.s.sol";
import {TestnetEthBridgeLiquidity} from "../script/testnet/TestnetEthBridgeLiquidity.sol";
import {ActivateV2NativeLaunch} from "../script/ActivateV2NativeLaunch.s.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunV2TradeRouter} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {HedgeFunV2LaunchNativeRouter} from "../src/v2/HedgeFunV2LaunchNativeRouter.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";

contract TestnetEthBridgeOperatorInvoker {
    receive() external payable {}

    function initialize(TestnetV2EthBridge tool, bytes32 bookSha256)
        external returns (TestnetV2EthBridge.Deployment memory)
    {
        return tool.initialize("deploy/testnet-v2-fees.json", bookSha256);
    }

    function activate(ActivateV2NativeLaunch activation) external returns (HedgeFunV2LaunchNativeRouter) {
        return activation.run();
    }

    function recover(TestnetEthBridgeLiquidity bridge, uint128 liquidity) external {
        bridge.decrease(liquidity);
        bridge.collect();
        bridge.withdrawUnused();
    }
}

/// @notice Opt-in fork rehearsal with the real operator's available test ETH and a native-only creator wallet.
/// @dev vm.deal funds only the invented creator for this simulation. It never funds the operator or broadcasts.
contract TestnetV2EthBridgeForkTest is Test {
    address private constant OPERATOR = 0x75Cee941B0eF3A83feA0397BbF903C12c1D7e96D;
    address private constant CREATOR = address(uint160(uint256(keccak256("bridge-only native creator; no key"))));
    // Fixed factory setting, numerically 1% of FIRST_BUY only; the deployed factory cannot charge a dynamic percentage.
    uint256 private constant FIXED_LAUNCH_FEE = 0.0000001 ether;
    uint256 private constant FIRST_BUY = 0.00001 ether;
    bytes32 private constant FEE_BOOK_SHA256 = 0xada428eb04ac0f982fd6a002e8745b4100c6db99ce620adcf254e42ac1cbc82c;

    struct Scenario {
        HedgeFunV2Factory factory;
        HedgeFunV2LaunchNativeRouter launcher;
        HedgeFunFactory.Request request;
        HedgeFunToken.Info info;
        HedgeFunV2LaunchNativeRouter.BuyParams buy;
        HedgeFunV2TradeRouter.Hop[] path;
        address stock;
        address predicted;
        bytes32 terms;
        uint256 quotedStock;
        uint256 quotedTokens;
        uint256 initialStrategies;
    }

    function test_nativeOnlyWalletLaunchesAndBuysStockThroughRecoverableBridge() public {
        vm.skip(!vm.envOr("ETH_BRIDGE_FORK", false), "set ETH_BRIDGE_FORK=true");
        vm.createSelectFork(
            vm.envOr("ETH_BRIDGE_FORK_RPC", string("https://rpc.testnet.chain.robinhood.com")),
            vm.envUint("ETH_BRIDGE_FORK_BLOCK")
        );
        assertEq(block.chainid, 46630);

        string memory book = vm.readFile("deploy/testnet-v2-fees.json");
        assertEq(sha256(bytes(book)), FEE_BOOK_SHA256);
        TestnetV2EthBridge tool = new TestnetV2EthBridge();
        vm.etch(OPERATOR, address(new TestnetEthBridgeOperatorInvoker()).code);
        uint256 operatorNativeBefore = OPERATOR.balance;
        assertGe(operatorNativeBefore, tool.SEED_ETH() + tool.GAS_RESERVE());
        string memory candidate = "deploy/testnet-v2-native-bridge.dryrun.json";
        assertFalse(vm.exists(candidate), "preserve an existing bridge dry-run candidate");
        TestnetV2EthBridge.Deployment memory bridge =
            TestnetEthBridgeOperatorInvoker(payable(OPERATOR)).initialize(tool, FEE_BOOK_SHA256);
        tool.verify(bridge, address(bridge.liquidityManager).codehash);
        tool.verifyFile(candidate);
        vm.removeFile(candidate);
        assertEq(OPERATOR.balance, operatorNativeBefore - tool.SEED_ETH());
        assertEq(HedgeFunV2Factory(bridge.base.factory).v3Factory().getPool(tool.WETH(), tool.USDG(), 500), address(0));
        (address oracle, address listingPool,, bool enabled) = HedgeFunV2Factory(bridge.base.factory).listings(tool.WETH());
        assertEq(oracle, address(0)); assertEq(listingPool, address(0)); assertFalse(enabled);

        HedgeFunV2LaunchNativeRouter launcher = _activate(bridge, tool);
        Scenario memory s = _prepare(book, bridge, tool, launcher);
        _findExactBuy(s);
        _buy(s, tool);
        _recover(bridge, tool);
    }

    function _activate(TestnetV2EthBridge.Deployment memory bridge, TestnetV2EthBridge tool)
        private returns (HedgeFunV2LaunchNativeRouter launcher)
    {
        vm.setEnv("OPERATOR", vm.toString(OPERATOR));
        vm.setEnv("V2_FACTORY", vm.toString(bridge.base.factory));
        vm.setEnv("V2_TRADE_ROUTER", vm.toString(bridge.base.tradeRouter));
        vm.setEnv("WETH", vm.toString(tool.WETH()));
        vm.setEnv("WETH_USDG_POOL", vm.toString(bridge.pool));
        vm.setEnv("LAUNCH_FEE_WEI", vm.toString(FIXED_LAUNCH_FEE));
        launcher = TestnetEthBridgeOperatorInvoker(payable(OPERATOR)).activate(new ActivateV2NativeLaunch());
        HedgeFunV2Factory factory = HedgeFunV2Factory(bridge.base.factory);
        assertTrue(factory.launchers(address(launcher)));
        HedgeFunFactory.Defaults memory defaults = factory.getDefaults();
        assertEq(uint8(defaults.launchFeeCurrency), uint8(HedgeFunFactory.FeeCurrency.Native));
        assertEq(defaults.launchFeeAmount, FIXED_LAUNCH_FEE);
    }

    function _prepare(string memory book, TestnetV2EthBridge.Deployment memory bridge, TestnetV2EthBridge tool,
        HedgeFunV2LaunchNativeRouter launcher) private returns (Scenario memory s)
    {
        s.factory = HedgeFunV2Factory(bridge.base.factory);
        s.launcher = launcher;
        s.stock = vm.parseJsonAddress(book, ".stocks.TSLA.token");
        address stockPool = vm.parseJsonAddress(book, ".stocks.TSLA.pool");
        (,, uint256 openPrice, bool listed) = s.factory.listings(s.stock);
        assertTrue(listed);
        assertEq(IERC20(tool.USDG()).balanceOf(CREATOR), 0);
        assertEq(IERC20(s.stock).balanceOf(CREATOR), 0);
        assertEq(IERC20(tool.WETH()).balanceOf(CREATOR), 0);
        s.request.name = "Bridge native-only launch";
        s.request.symbol = "BRIDGEFORKTSLA";
        s.request.stock = s.stock;
        s.request.creator = CREATOR;
        s.request.taxBps = 300;
        s.request.creatorBps = 1000;
        s.request.tp1Bps = 300;
        s.request.tp2Bps = 600;
        s.request.dipBps = 300;
        s.request.lotBps = 2000;
        s.request.nonce = 202610010411;
        s.request.maxFee = FIXED_LAUNCH_FEE;
        s.request.expectedOpenPriceE18 = openPrice;
        vm.prank(CREATOR);
        s.factory.curveDeployer().setCurveConfig(s.request.symbol, s.request.nonce, 4400, 0);
        (s.predicted,, s.terms) = s.factory.predict(s.request);
        s.info.description = "Bridge-only native launch fork rehearsal";
        s.path = new HedgeFunV2TradeRouter.Hop[](2);
        s.path[0] = HedgeFunV2TradeRouter.Hop(bridge.pool, tool.USDG());
        s.path[1] = HedgeFunV2TradeRouter.Hop(stockPool, s.stock);
        s.buy = HedgeFunV2LaunchNativeRouter.BuyParams(FIRST_BUY, 1, 1, block.timestamp + 300, true);
        vm.deal(CREATOR, 0.001 ether); // Invented buyer funded only with native ETH on this fork.
        s.initialStrategies = s.factory.strategyCount();
    }

    function _findExactBuy(Scenario memory s) private {
        // The curve can refund integer-rounded stock. Find a nearby tiny native amount whose whole route consumes it.
        uint256 step = Math.mulDiv(2, 1e30, 3000e18, Math.Rounding.Ceil);
        for (uint256 i; i < 64; ++i) {
            uint256 amount = FIRST_BUY - i * step;
            uint256 beforeStockPool = IERC20(s.stock).balanceOf(s.path[1].pool);
            uint256 snapshot = vm.snapshotState();
            s.buy.amountIn = amount;
            vm.prank(CREATOR);
            (, uint256 tokensOut, uint256 stockRefund) = s.launcher.launchAndBuy{value: FIXED_LAUNCH_FEE + amount}(
                s.request, s.terms, s.info, s.buy, s.path
            );
            uint256 stock = beforeStockPool - IERC20(s.stock).balanceOf(s.path[1].pool);
            assertTrue(vm.revertToStateAndDelete(snapshot));
            if (stockRefund == 0 && stock > 0 && tokensOut > 0) {
                s.quotedStock = stock;
                s.quotedTokens = tokensOut;
                assertLe(amount, 0.00004 ether);
                return;
            }
        }
        fail("no exact tiny first buy within 64 bounded tries");
    }

    function _buy(Scenario memory s, TestnetV2EthBridge tool) private {
        s.buy.minStockReceived = s.quotedStock * 99 / 100;
        s.buy.minFinalOut = s.quotedTokens * 99 / 100;
        s.buy.allowPartialFill = false;
        uint256 creatorBefore = CREATOR.balance;
        uint256 protocolBefore = OPERATOR.balance;
        vm.prank(CREATOR);
        (uint256 id, uint256 tokensOut, uint256 refund) = s.launcher.launchAndBuy{
            value: FIXED_LAUNCH_FEE + s.buy.amountIn
        }(s.request, s.terms, s.info, s.buy, s.path);
        assertEq(id, s.initialStrategies);
        assertEq(tokensOut, s.quotedTokens);
        assertEq(refund, 0);
        assertEq(HedgeFunToken(s.predicted).balanceOf(CREATOR), tokensOut);
        assertEq(CREATOR.balance, creatorBefore - FIXED_LAUNCH_FEE - s.buy.amountIn);
        assertEq(OPERATOR.balance, protocolBefore + FIXED_LAUNCH_FEE);
        assertEq(IERC20(tool.USDG()).balanceOf(CREATOR), 0);
        assertEq(IERC20(s.stock).balanceOf(CREATOR), 0);
        assertEq(IERC20(tool.WETH()).balanceOf(CREATOR), 0);
    }

    function _recover(TestnetV2EthBridge.Deployment memory bridge, TestnetV2EthBridge tool) private {
        vm.prank(CREATOR);
        vm.expectRevert();
        bridge.liquidityManager.decrease(bridge.liquidity);
        uint256 wrappedBefore = IERC20(tool.WETH()).balanceOf(OPERATOR);
        TestnetEthBridgeOperatorInvoker(payable(OPERATOR)).recover(bridge.liquidityManager, bridge.liquidity);
        assertEq(bridge.liquidityManager.liquidityOwned(), 0);
        assertEq(IERC20(tool.WETH()).balanceOf(address(bridge.liquidityManager)), 0);
        assertEq(IERC20(tool.USDG()).balanceOf(address(bridge.liquidityManager)), 0);
        assertGt(IERC20(tool.WETH()).balanceOf(OPERATOR), wrappedBefore);
    }
}
