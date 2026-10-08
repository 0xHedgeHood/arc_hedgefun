// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The ordinary V2 lot strategy must clear slippage, the pool fee and its keeper payment once.
/// @dev Actual take-profit fills also check their conservative all-in basis. Engine/V1/legacy floors stay unchanged.
library V2TriggerFloor {
    error TriggerInsideExecutionFriction(uint256 tp1Bps, uint256 dipBps, uint256 minimumBps);

    /// @notice Refuse a TP or dip rung below the all-in execution floor, before quoting or creating a treasury.
    function validate(uint256 tp1Bps, uint256 dipBps, uint256 maxSlippageBps, uint256 poolFeeBps, uint256 bountyBps)
        internal
        pure
    {
        uint256 minimum = maxSlippageBps + poolFeeBps + bountyBps;
        if (tp1Bps < minimum || dipBps < minimum) {
            revert TriggerInsideExecutionFriction(tp1Bps, dipBps, minimum);
        }
    }
}
