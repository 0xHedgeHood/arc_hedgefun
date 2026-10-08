// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HedgeFunV2TradeRouter} from "./HedgeFunV2TradeRouter.sol";

interface IWrappedNative is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @notice Native-currency convenience around the same ERC20 route. The chain's wrapped
/// native contract is explicitly fixed at deployment; no deployment address is assumed here.
contract HedgeFunV2NativeRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    HedgeFunV2TradeRouter public immutable router;
    IWrappedNative public immutable wrappedNative;
    error BadConfig();
    error BadPayment();
    error TransferMismatch();
    error NativeTransferFailed();
    event NativeBought(uint256 indexed id, address indexed buyer, uint256 nativeIn, uint256 tokensOut, uint256 stockRefund);
    event NativeSold(uint256 indexed id, address indexed seller, uint256 nativeOut, uint256 tokenRefund);

    constructor(HedgeFunV2TradeRouter router_, IWrappedNative wrappedNative_) {
        if (address(router_).code.length == 0 || address(wrappedNative_).code.length == 0) revert BadConfig();
        router = router_;
        wrappedNative = wrappedNative_;
    }

    receive() external payable {
        if (msg.sender != address(wrappedNative)) revert BadPayment();
    }

    /// @notice p.asset must be wrappedNative and msg.value must equal p.amountIn.
    /// Non-native stock refunds remain stock; if stock itself is wrappedNative the refund is unwrapped.
    function buy(HedgeFunV2TradeRouter.TradeParams calldata p, HedgeFunV2TradeRouter.Hop[] calldata path)
        external payable nonReentrant returns (uint256 tokensOut, uint256 stockRefund)
    {
        if (p.asset != address(wrappedNative) || msg.value != p.amountIn) revert BadPayment();
        (,,,address stock,) = router.factory().strategies(p.id);
        uint256 beforeWrapped = wrappedNative.balanceOf(address(this));
        wrappedNative.deposit{value: msg.value}();
        if (wrappedNative.balanceOf(address(this)) != beforeWrapped + msg.value) revert TransferMismatch();
        IERC20(address(wrappedNative)).forceApprove(address(router), p.amountIn);
        (tokensOut, stockRefund) = router.buyFor(p, path, msg.sender);
        IERC20(address(wrappedNative)).forceApprove(address(router), 0);
        if (stockRefund != 0) {
            if (stock == address(wrappedNative)) _unwrapToCaller(stockRefund);
            else _send(stock, msg.sender, stockRefund);
        }
        if (wrappedNative.balanceOf(address(this)) != beforeWrapped) revert TransferMismatch();
        emit NativeBought(p.id, msg.sender, msg.value, tokensOut, stockRefund);
    }

    /// @notice Sell for wrappedNative using the ERC20 route, then receive native currency.
    function sell(HedgeFunV2TradeRouter.TradeParams calldata p, HedgeFunV2TradeRouter.Hop[] calldata path)
        external nonReentrant returns (uint256 nativeOut, uint256 tokenRefund)
    {
        if (p.asset != address(wrappedNative)) revert BadPayment();
        (address token,,,,) = router.factory().strategies(p.id);
        uint256 beforeHere = IERC20(token).balanceOf(address(this));
        uint256 beforeUser = IERC20(token).balanceOf(msg.sender);
        IERC20(token).safeTransferFrom(msg.sender, address(this), p.amountIn);
        if (IERC20(token).balanceOf(address(this)) != beforeHere + p.amountIn
            || IERC20(token).balanceOf(msg.sender) + p.amountIn != beforeUser) revert TransferMismatch();
        uint256 beforeWrapped = wrappedNative.balanceOf(address(this));
        IERC20(token).forceApprove(address(router), p.amountIn);
        (nativeOut, tokenRefund) = router.sell(p, path);
        IERC20(token).forceApprove(address(router), 0);
        if (wrappedNative.balanceOf(address(this)) != beforeWrapped + nativeOut) revert TransferMismatch();
        if (tokenRefund != 0) _send(token, msg.sender, tokenRefund);
        if (IERC20(token).balanceOf(address(this)) != beforeHere) revert TransferMismatch();
        _unwrapToCaller(nativeOut);
        if (wrappedNative.balanceOf(address(this)) != beforeWrapped) revert TransferMismatch();
        emit NativeSold(p.id, msg.sender, nativeOut, tokenRefund);
    }

    function _unwrapToCaller(uint256 amount) private {
        uint256 beforeNative = address(this).balance;
        wrappedNative.withdraw(amount);
        if (address(this).balance != beforeNative + amount) revert TransferMismatch();
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    function _send(address asset, address to, uint256 amount) private {
        uint256 beforeHere = IERC20(asset).balanceOf(address(this));
        uint256 beforeThere = IERC20(asset).balanceOf(to);
        IERC20(asset).safeTransfer(to, amount);
        if (IERC20(asset).balanceOf(address(this)) + amount != beforeHere
            || IERC20(asset).balanceOf(to) != beforeThere + amount) revert TransferMismatch();
    }
}
