// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The crypto assets Arc listings may use, with every address they are bound to.
/// @dev Read from Arc mainnet on 2026-10-07:
///
///      cirBTC   Circle Wrapped Bitcoin, 8 decimals. Its USDC pool on the Uniswap V3 factory is the 0.01% tier, about
///               6.0M USDC and 65.6 cirBTC deep with a 3,600-slot observation ring. Priced by Chainlink BTC/USD.
///      WETH     18 decimals. Its deep USDC market is an Aerodrome Slipstream pool, which the core cannot trade in;
///               the Uniswap V3 pools held about $1,200. NOT listable until a V3 pool is funded (docs/ARC.md), so
///               `pool` is zero and `ListArcCrypto` refuses it. Priced by Chainlink ETH/USD.
///
///      Both feeds: 8 decimals, 0.5% deviation threshold, 24-hour heartbeat. The USDC/USD feed divides out the
///      quote's own drift, as on 4663.
library ArcAssets {
    address internal constant USDC_USD_FEED = 0x84EA90AC252Dc437031461836DB5164219147905;
    string internal constant USDC_USD_DESCRIPTION = "USDC / USD";
    /// one 24h heartbeat plus an hour
    uint256 internal constant MAX_FEED_AGE = 25 hours;

    struct Asset {
        string symbol;
        address token;
        uint8 decimals;
        address feed;
        string feedDescription;
        address pool;
        uint24 fee;
        uint16 maxDeviationBps;
        uint16 maxSlippageBps;
        uint64 sellChunkUsdg;
    }

    error UnknownAsset(string symbol);

    function get(string memory symbol) internal pure returns (Asset memory a) {
        bytes32 h = keccak256(bytes(symbol));
        if (h == keccak256("cirBTC")) {
            return Asset("cirBTC", 0x171A4217b86A807A64eB94757Db6849fb4bDbAA0, 8,
                0xa109B535C70C8Be9995be64Bb6751AcDB27e03De, "BTC / USD",
                0x82916bee18fCEF517B26C72d7Cb5F13694E1dB41, 100, 100, 150, 2_000e6);
        }
        if (h == keccak256("WETH")) {
            return Asset("WETH", 0x128cC466B61f542da60c70e3aA11c10e19B84EDB, 18,
                0x50FCDD99D6762D1C170DC6A9111db944AEE6D364, "ETH / USD",
                address(0), 0, 100, 150, 2_000e6);
        }
        revert UnknownAsset(symbol);
    }
}
