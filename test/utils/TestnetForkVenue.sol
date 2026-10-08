// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {TestnetMarket} from "../../script/testnet/TestnetMarket.sol";

/// @notice What the testnet fork suites need from the venue without assuming anything was ever launched.
library TestnetForkVenue {
    error NoListedStock();

    /// @dev The first of the test market's stocks that `factory` lists. A fork suite used to read
    ///      `factory.strategies(0)` for this, which reverts on a factory nobody has launched on yet: a core that
    ///      was just deployed could not be tested until someone had used it.
    function listedStock(HedgeFunV2Factory factory, TestnetMarket market) internal view returns (address stock) {
        uint256 count = market.poolCount();
        for (uint256 i; i < count; ++i) {
            (stock,,,,,) = market.lines(market.pools(i));
            (,,, bool enabled) = factory.listings(stock);
            if (enabled) return stock;
        }
        revert NoListedStock();
    }
}
