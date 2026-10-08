// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HedgeFunFactory} from "../../src/HedgeFunFactory.sol";
import {V2MainnetDefaults} from "../mainnet/V2MainnetDefaults.sol";

/// @notice The factory defaults an Arc (5042) V2 core is constructed with: the 4663 release, with three changes.
/// @dev `DeployArcCore` refuses to run unless the caller supplies `keccak256(abi.encode(release()))`, as on 4663.
///
///      1. The launch fee is native USDC. Arc's native currency is USDC with 18 decimals, so `Native` charges it
///         with `msg.value` and no approval, and the factory forwards it to the protocol Safe. One USDC, against
///         0.0005 ETH (about $1.30) on 4663.
///      2. The deviation gate is 100 bps, not 50. Arc's Chainlink BTC/USD and ETH/USD feeds update on a 0.5% move
///         or every 24 hours, so a pool may sit up to 0.5% from the last print with nothing wrong; 50 bps would
///         stop every treasury each time the market moved that far between prints.
///      3. The slippage bound is 150 bps, to stay above the deviation gate as `ListArcCrypto` requires.
library ArcDefaults {
    uint16 internal constant SALE_BPS = V2MainnetDefaults.SALE_BPS;
    uint16 internal constant LP_BPS = V2MainnetDefaults.LP_BPS;

    function release() internal pure returns (HedgeFunFactory.Defaults memory d) {
        d = V2MainnetDefaults.release();
        d.launchFeeCurrency = HedgeFunFactory.FeeCurrency.Native;
        d.launchFeeAmount = 1e18;
        d.maxDeviationBps = 100;
        d.maxSlippageBps = 150;
    }
}
