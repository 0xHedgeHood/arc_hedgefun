// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @notice The buy fee of the version-2 hook, which every testnet core deployed before the stock-side buy fee
///         still runs: taken in the strategy token, held as claims, and converted to stock by the factory owner.
///         `HedgeFunV2Hook` version 3 takes the buy fee in stock and has neither function.
interface ILegacyV2FeeConversion {
    function pendingTokenFees(PoolId id) external view returns (uint256);
    function convertFees(PoolKey calldata key, uint256 maxTokens, uint256 minStockOut, uint160 sqrtPriceLimitX96, uint256 deadline)
        external returns (uint256 consumed, uint256 stockOut);
}
