// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HedgeFunFactory} from "../../src/HedgeFunFactory.sol";
import {HedgeFunV2ArcFactory} from "../../src/v2/arc/HedgeFunV2ArcFactory.sol";
import {HedgeFunBondingCurve} from "../../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2TradeRouter as Router} from "../../src/v2/HedgeFunV2TradeRouter.sol";
import {ArcAssets} from "./ArcAssets.sol";

/// @notice Launches one kind-0 token on cirBTC from the broadcasting wallet. For the first launch after deployment
///         and for smoke tests; buy with `BuyArcToken` afterwards, in a later block: a buy in the launch's first
///         seconds pays the opening snipe tax, up to 99%.
/// @dev Requires V2_FACTORY, V2_TRADE_ROUTER, NAME and SYMBOL; NONCE is optional. Pays the factory's native USDC
///      launch fee. Rungs: 1% tax, 5% take-profit, 10% second take-profit, 5% dip.
contract LaunchArcToken is Script {
    function run() external {
        HedgeFunV2ArcFactory f = HedgeFunV2ArcFactory(vm.envAddress("V2_FACTORY"));
        Router router = Router(vm.envAddress("V2_TRADE_ROUTER"));
        require(block.chainid == 5042 && address(router.factory()) == address(f), "binding");
        ArcAssets.Asset memory btc = ArcAssets.get("cirBTC");
        (,, uint256 open, bool live) = f.listings(btc.token);
        require(live, "cirBTC is not listed");

        HedgeFunFactory.Request memory q;
        q.name = vm.envString("NAME"); q.symbol = vm.envString("SYMBOL"); q.stock = btc.token; q.creator = msg.sender;
        q.taxBps = 100; q.creatorBps = 1000; q.tp1Bps = 500; q.tp2Bps = 1000; q.dipBps = 500; q.stopBps = 0;
        q.lotBps = 2000; q.nonce = uint96(vm.envOr("NONCE", uint256(1)));
        q.maxFee = f.getDefaults().launchFeeAmount; q.expectedOpenPriceE18 = open;
        (,, bytes32 terms) = f.predict(q);

        vm.startBroadcast();
        uint256 id = f.launch{value: q.maxFee}(q, terms);
        vm.stopBroadcast();
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(f.curves(id));
        console2.log("strategy id", id);
        console2.log("token", curve.token());
        console2.log("curve", address(curve));
    }
}

/// @notice Buys strategy ID with BUY_USDC (6-decimal units) of USDC through the cirBTC/USDC pool, from the
///         broadcasting wallet. On the curve a buy past its end fills to the end, graduates, and refunds cirBTC.
/// @dev Requires V2_FACTORY, V2_TRADE_ROUTER, ID and BUY_USDC. MIN_TOKENS defaults to 1: set it for a real buy.
contract BuyArcToken is Script {
    IERC20 private constant USDC = IERC20(0x3600000000000000000000000000000000000000);

    function run() external {
        HedgeFunV2ArcFactory f = HedgeFunV2ArcFactory(vm.envAddress("V2_FACTORY"));
        Router router = Router(vm.envAddress("V2_TRADE_ROUTER"));
        require(block.chainid == 5042 && address(router.factory()) == address(f), "binding");
        uint256 id = vm.envUint("ID");
        uint256 amount = vm.envUint("BUY_USDC");
        HedgeFunBondingCurve curve = HedgeFunBondingCurve(f.curves(id));
        uint8 stage = uint8(curve.status());
        Router.Hop[] memory path = new Router.Hop[](1);
        path[0] = Router.Hop(ArcAssets.get("cirBTC").pool, curve.stock());
        vm.startBroadcast();
        USDC.approve(address(router), amount);
        (uint256 got, uint256 refund) = router.buy(Router.TradeParams(id, address(USDC), amount, 1,
            vm.envOr("MIN_TOKENS", uint256(1)), block.timestamp + 600, stage, stage == 0), path);
        vm.stopBroadcast();
        console2.log("tokens bought", got);
        console2.log("cirBTC refunded", refund);
        console2.log("curve status (0 active, 2 graduated)", uint256(curve.status()));
    }
}
