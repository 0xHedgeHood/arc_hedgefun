// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunV2TradeRouter} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {HedgeFunV2LaunchNativeRouter} from "../src/v2/HedgeFunV2LaunchNativeRouter.sol";
import {IWrappedNative} from "../src/v2/HedgeFunV2NativeRouter.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";

interface IV3PoolLiquidity {
    function liquidity() external view returns (uint128);
}

/// @notice Opt an existing V2 factory into native-currency launch-and-buy for future launches.
/// @dev Requires OPERATOR, V2_FACTORY, V2_TRADE_ROUTER, WETH, WETH_USDG_POOL and LAUNCH_FEE_WEI.
///      Run a fork simulation before broadcasting. The supplied pool must be the factory's canonical
///      initialized and funded WETH/USDG V3 pool; individual stock routes remain a per-launch quote.
contract ActivateV2NativeLaunch is Script {
    error BadBinding(string what);
    error BadFee();
    error ReadbackFailed(string what);

    function run() external returns (HedgeFunV2LaunchNativeRouter launchRouter) {
        address operator = vm.envAddress("OPERATOR");
        HedgeFunV2Factory factory = HedgeFunV2Factory(vm.envAddress("V2_FACTORY"));
        HedgeFunV2TradeRouter tradeRouter = HedgeFunV2TradeRouter(vm.envAddress("V2_TRADE_ROUTER"));
        IWrappedNative weth = IWrappedNative(vm.envAddress("WETH"));
        address pool = vm.envAddress("WETH_USDG_POOL");
        uint256 feeWei = vm.envUint("LAUNCH_FEE_WEI");

        // Every binding and market check runs before the first broadcast transaction.
        if (operator == address(0) || msg.sender != operator) revert BadBinding("operator sender");
        if (
            address(factory).code.length == 0 || address(tradeRouter).code.length == 0 || address(weth).code.length == 0
                || pool.code.length == 0
        ) revert BadBinding("contract code");
        if (factory.owner() != operator) revert BadBinding("factory owner");
        if (!factory.publicLaunch()) revert BadBinding("public launch closed");
        if (address(factory.curveDeployer()).code.length == 0) revert BadBinding("V2 curve deployer");
        if (address(tradeRouter.factory()) != address(factory)) revert BadBinding("trade router factory");
        if (feeWei == 0) revert BadFee();

        address usdg = factory.usdg();
        if (usdg == address(weth) || usdg.code.length == 0 || address(factory.v3Factory()).code.length == 0) {
            revert BadBinding("USDG or V3 factory");
        }
        IUniswapV3Pool v3Pool = IUniswapV3Pool(pool);
        address token0 = v3Pool.token0();
        address token1 = v3Pool.token1();
        if (!((token0 == address(weth) && token1 == usdg) || (token0 == usdg && token1 == address(weth)))) {
            revert BadBinding("WETH/USDG pool tokens");
        }
        if (factory.v3Factory().getPool(address(weth), usdg, v3Pool.fee()) != pool) {
            revert BadBinding("noncanonical WETH/USDG pool");
        }
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        if (
            sqrtPriceX96 == 0 || IV3PoolLiquidity(pool).liquidity() == 0 || IERC20(address(weth)).balanceOf(pool) == 0
                || IERC20(usdg).balanceOf(pool) == 0
        ) {
            revert BadBinding("uninitialized or empty WETH/USDG pool");
        }

        HedgeFunFactory.Defaults memory defaults = factory.getDefaults();
        defaults.launchFeeCurrency = HedgeFunFactory.FeeCurrency.Native;
        defaults.launchFeeAmount = feeWei;

        vm.startBroadcast(operator);
        launchRouter = new HedgeFunV2LaunchNativeRouter(tradeRouter, weth);
        factory.setLauncher(address(launchRouter), true);
        factory.setDefaults(defaults);
        vm.stopBroadcast();

        // These checks are against Foundry's simulated state. After broadcasting, verify receipts and
        // run VerifyV2NativeLaunch against the confirmed chain state.
        if (
            address(launchRouter.factory()) != address(factory)
                || address(launchRouter.tradeRouter()) != address(tradeRouter)
                || address(launchRouter.wrappedNative()) != address(weth)
        ) revert ReadbackFailed("router bindings");
        if (!factory.launchers(address(launchRouter))) revert ReadbackFailed("launcher permission");
        if (keccak256(abi.encode(factory.getDefaults())) != keccak256(abi.encode(defaults))) {
            revert ReadbackFailed("factory defaults");
        }

        console2.log("V2 factory", address(factory));
        console2.log("V2 trade router", address(tradeRouter));
        console2.log("native launch router", address(launchRouter));
        console2.log("WETH/USDG route pool", pool);
        console2.log("native launch fee (wei)", feeWei);
        console2.log("expected defaults hash");
        console2.logBytes32(keccak256(abi.encode(defaults)));
        console2.log("simulation readback passed; verify three receipts and live state after broadcast");
    }
}

/// @notice Read-only confirmation after all three activation transactions have succeeded on chain.
/// @dev Requires OPERATOR, V2_FACTORY, V2_TRADE_ROUTER, WETH, LAUNCH_ROUTER,
///      LAUNCH_FEE_WEI and EXPECTED_DEFAULTS_HASH from the reviewed activation simulation.
contract VerifyV2NativeLaunch is Script {
    error NotActivated(string what);

    function run() external view {
        address operator = vm.envAddress("OPERATOR");
        HedgeFunV2Factory factory = HedgeFunV2Factory(vm.envAddress("V2_FACTORY"));
        address tradeRouter = vm.envAddress("V2_TRADE_ROUTER");
        address weth = vm.envAddress("WETH");
        HedgeFunV2LaunchNativeRouter launcher = HedgeFunV2LaunchNativeRouter(payable(vm.envAddress("LAUNCH_ROUTER")));
        uint256 feeWei = vm.envUint("LAUNCH_FEE_WEI");
        bytes32 expectedDefaultsHash = vm.envBytes32("EXPECTED_DEFAULTS_HASH");

        if (address(factory).code.length == 0 || address(launcher).code.length == 0) {
            revert NotActivated("contract code");
        }
        if (factory.owner() != operator || !factory.publicLaunch() || !factory.launchers(address(launcher))) {
            revert NotActivated("owner or launcher permission");
        }
        if (
            address(launcher.factory()) != address(factory) || address(launcher.tradeRouter()) != tradeRouter
                || address(launcher.wrappedNative()) != weth
        ) revert NotActivated("router bindings");
        HedgeFunFactory.Defaults memory defaults = factory.getDefaults();
        if (
            defaults.launchFeeCurrency != HedgeFunFactory.FeeCurrency.Native || defaults.launchFeeAmount != feeWei
                || keccak256(abi.encode(defaults)) != expectedDefaultsHash
        ) revert NotActivated("factory defaults");

        console2.log("live V2 native launch verified", address(launcher));
    }
}
