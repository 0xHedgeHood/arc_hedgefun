// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Creator-selected ordinary V2 rungs have format bounds, not execution-cost floors.
library V2CreatorParams {
    error BadConfig();

    function validate(uint256 tp1Bps, uint256 tp2Bps, uint256 dipBps, uint256 stopBps) internal pure {
        if (tp1Bps == 0 || (tp2Bps != 0 && tp2Bps <= tp1Bps)
            || dipBps == 0 || dipBps >= 10_000 || stopBps >= 10_000) revert BadConfig();
    }
}
