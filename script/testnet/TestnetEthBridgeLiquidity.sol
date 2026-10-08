// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IV3Factory, IV3Pool} from "./TestnetMarket.sol";

interface IBridgeV3Pool is IV3Pool {
    function burn(int24 tickLower, int24 tickUpper, uint128 amount) external returns (uint256 amount0, uint256 amount1);
    function collect(address recipient, int24 tickLower, int24 tickUpper, uint128 amount0Requested, uint128 amount1Requested)
        external returns (uint128 amount0, uint128 amount1);
}

/// @notice Recoverable, prefunded liquidity for the testnet WETH/tUSDG payment bridge only.
/// @dev No mint authority, price setter, oracle, strategy listing, or native ETH custody.
contract TestnetEthBridgeLiquidity is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable weth;
    address public immutable usdg;
    IBridgeV3Pool public immutable pool;
    int24 public immutable tickLower;
    int24 public immutable tickUpper;
    uint128 public liquidityOwned;

    bool private _minting;
    uint256 private _max0;
    uint256 private _max1;

    error BadConfig();
    error BadCallback();
    error InputLimit();
    error TransferMismatch();

    constructor(address initialOwner, address factory, address weth_, address usdg_, address pool_, int24 lower, int24 upper)
        Ownable(initialOwner)
    {
        IBridgeV3Pool p = IBridgeV3Pool(pool_);
        int24 spacing = p.tickSpacing();
        if (initialOwner == address(0) || IERC20Metadata(weth_).decimals() != 18 || IERC20Metadata(usdg_).decimals() != 6
            || p.token0() != usdg_ || p.token1() != weth_ || p.fee() != 3000
            || IV3Factory(factory).getPool(weth_, usdg_, 3000) != pool_
            || spacing != 60 || lower >= upper || lower % spacing != 0 || upper % spacing != 0) revert BadConfig();
        weth = weth_; usdg = usdg_; pool = p; tickLower = lower; tickUpper = upper;
    }

    function provide(uint128 liquidity, uint256 maxUsdg, uint256 maxWeth)
        external onlyOwner nonReentrant returns (uint256 amountUsdg, uint256 amountWeth)
    {
        if (liquidity == 0 || maxUsdg == 0 || maxWeth == 0) revert BadConfig();
        _minting = true; _max0 = maxUsdg; _max1 = maxWeth;
        (amountUsdg, amountWeth) = pool.mint(address(this), tickLower, tickUpper, liquidity, "");
        if (_minting || amountUsdg == 0 || amountWeth == 0) revert BadCallback();
        liquidityOwned += liquidity;
    }

    /// @notice Burn any part of the owned position. Call collect to receive principal and earned fees.
    function decrease(uint128 liquidity) external onlyOwner nonReentrant returns (uint256 amountUsdg, uint256 amountWeth) {
        if (liquidity == 0 || liquidity > liquidityOwned) revert BadConfig();
        (amountUsdg, amountWeth) = pool.burn(tickLower, tickUpper, liquidity);
        liquidityOwned -= liquidity;
    }

    /// @notice Pay all accrued fees and burned principal directly to the current owner.
    function collect() external onlyOwner nonReentrant returns (uint128 amountUsdg, uint128 amountWeth) {
        // V3 crystallizes active-position fees during a position update; collect alone reads stale tokensOwed.
        if (liquidityOwned != 0) pool.burn(tickLower, tickUpper, 0);
        return pool.collect(owner(), tickLower, tickUpper, type(uint128).max, type(uint128).max);
    }

    /// @notice Return prefunding that the position did not use.
    function withdrawUnused() external onlyOwner nonReentrant returns (uint256 amountUsdg, uint256 amountWeth) {
        amountUsdg = IERC20(usdg).balanceOf(address(this));
        amountWeth = IERC20(weth).balanceOf(address(this));
        if (amountUsdg != 0) IERC20(usdg).safeTransfer(owner(), amountUsdg);
        if (amountWeth != 0) IERC20(weth).safeTransfer(owner(), amountWeth);
    }

    function uniswapV3MintCallback(uint256 owed0, uint256 owed1, bytes calldata) external {
        if (msg.sender != address(pool) || !_minting || owed0 > _max0 || owed1 > _max1) revert BadCallback();
        _minting = false; _max0 = 0; _max1 = 0;
        _send(usdg, owed0); _send(weth, owed1);
    }

    function _send(address token, uint256 amount) private {
        if (amount == 0) return;
        uint256 here = IERC20(token).balanceOf(address(this));
        uint256 there = IERC20(token).balanceOf(address(pool));
        if (here < amount) revert InputLimit();
        IERC20(token).safeTransfer(address(pool), amount);
        if (IERC20(token).balanceOf(address(this)) + amount != here
            || IERC20(token).balanceOf(address(pool)) != there + amount) revert TransferMismatch();
    }
}
