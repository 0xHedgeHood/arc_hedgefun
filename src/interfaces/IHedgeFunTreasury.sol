// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/// the treasury as the factory and the two routers see it
interface IHedgeFunTreasury {
    function wire(PoolKey calldata key) external;
    function book() external returns (bool);
    function poolKey() external view returns (Currency, Currency, uint24, int24, IHooks);
}
