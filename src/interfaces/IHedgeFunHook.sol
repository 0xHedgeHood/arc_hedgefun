// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// the hook as a treasury sees it
interface IHedgeFunHook {
    function noteEvent() external;
    function meanTick(uint32 window) external view returns (bool ok, int24 mean);
    function observationCount() external view returns (uint16);
}
