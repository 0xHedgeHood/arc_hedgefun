// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HedgeFunFactory} from "../HedgeFunFactory.sol";
import {HedgeFunToken} from "../HedgeFunToken.sol";
import {HedgeFunV2TradeRouter} from "./HedgeFunV2TradeRouter.sol";
import {IWrappedNative} from "./HedgeFunV2NativeRouter.sol";

/// @notice Creates a V2 launch and makes its creator's opening buy with one native-currency payment.
/// @dev The factory must whitelist this router and charge its launch fee in native currency. The buy
///      travels through the existing canonical V3 route to the launch's stock-denominated curve.
///      A capped curve fill refunds unused stock, not the input currency, if the caller opts into it.
contract HedgeFunV2LaunchNativeRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    HedgeFunV2TradeRouter public immutable tradeRouter;
    HedgeFunFactory public immutable factory;
    IWrappedNative public immutable wrappedNative;

    struct BuyParams {
        uint256 amountIn;
        uint256 minStockReceived;
        uint256 minFinalOut;
        uint256 deadline;
        bool allowPartialFill;
    }

    error BadConfig();
    error BadPayment();
    error BadRequest();
    error TransferMismatch();
    error NativeTransferFailed();

    event NativeLaunchedAndBought(
        uint256 indexed id,
        address indexed creator,
        uint256 launchFee,
        uint256 nativeBuyIn,
        uint256 tokensOut,
        uint256 stockRefund
    );

    constructor(HedgeFunV2TradeRouter tradeRouter_, IWrappedNative wrappedNative_) {
        if (address(tradeRouter_).code.length == 0 || address(wrappedNative_).code.length == 0) revert BadConfig();
        tradeRouter = tradeRouter_;
        factory = tradeRouter_.factory();
        wrappedNative = wrappedNative_;
    }

    receive() external payable {
        if (msg.sender != address(wrappedNative)) revert BadPayment();
    }

    /// @notice Pay the factory's native launch fee and buy on the new curve in one atomic transaction.
    /// @dev Quote `terms` with factory.predict(q). The actual factory-assigned id is passed to the
    ///      trade router; another launch landing first cannot invalidate the buy's id. A stale fee,
    ///      terms, route or quote reverts the entire launch. Tokens go directly to q.creator, preserving the creator's opening-tax
    ///      exemption. If b.allowPartialFill is true, unused stock is forwarded to the creator;
    ///      when the listed stock is wrappedNative, the refund is unwrapped to native currency.
    function launchAndBuy(
        HedgeFunFactory.Request calldata q,
        bytes32 terms,
        HedgeFunToken.Info calldata info,
        BuyParams calldata b,
        HedgeFunV2TradeRouter.Hop[] calldata path
    ) external payable nonReentrant returns (uint256 id, uint256 tokensOut, uint256 stockRefund) {
        if (
            q.creator != msg.sender || b.amountIn == 0 || b.minStockReceived == 0 || b.minFinalOut == 0
                || b.deadline < block.timestamp
        ) revert BadRequest();
        uint256 fee = _nativeFee();
        if (msg.value != fee + b.amountIn) revert BadPayment();
        id = factory.launchWithMetadata{value: fee}(q, terms, info);
        (tokensOut, stockRefund) = _buy(id, b, path, q.creator, q.stock);
        emit NativeLaunchedAndBought(id, q.creator, fee, b.amountIn, tokensOut, stockRefund);
    }

    function _nativeFee() private view returns (uint256 fee) {
        HedgeFunFactory.Defaults memory d = factory.getDefaults();
        if (d.launchFeeCurrency != HedgeFunFactory.FeeCurrency.Native) revert BadConfig();
        return d.launchFeeAmount;
    }

    function _buy(
        uint256 id,
        BuyParams calldata b,
        HedgeFunV2TradeRouter.Hop[] calldata path,
        address creator,
        address stock
    ) private returns (uint256 tokensOut, uint256 stockRefund) {
        uint256 nativeBefore = address(this).balance - b.amountIn;
        uint256 wrappedBefore = wrappedNative.balanceOf(address(this));
        uint256 stockBefore = IERC20(stock).balanceOf(address(this));
        wrappedNative.deposit{value: b.amountIn}();
        if (wrappedNative.balanceOf(address(this)) != wrappedBefore + b.amountIn) revert TransferMismatch();
        IERC20(address(wrappedNative)).forceApprove(address(tradeRouter), b.amountIn);
        HedgeFunV2TradeRouter.TradeParams memory p = HedgeFunV2TradeRouter.TradeParams({
            id: id,
            asset: address(wrappedNative),
            amountIn: b.amountIn,
            minStockReceived: b.minStockReceived,
            minFinalOut: b.minFinalOut,
            deadline: b.deadline,
            expectedStage: tradeRouter.ACTIVE(),
            allowPartialFill: b.allowPartialFill
        });
        (tokensOut, stockRefund) = tradeRouter.buyFor(p, path, creator);
        IERC20(address(wrappedNative)).forceApprove(address(tradeRouter), 0);

        if (stockRefund != 0) {
            if (stock == address(wrappedNative)) {
                if (wrappedNative.balanceOf(address(this)) != wrappedBefore + stockRefund) revert TransferMismatch();
                wrappedNative.withdraw(stockRefund);
                (bool ok,) = creator.call{value: stockRefund}("");
                if (!ok) revert NativeTransferFailed();
            } else {
                if (IERC20(stock).balanceOf(address(this)) != stockBefore + stockRefund) revert TransferMismatch();
                uint256 creatorBefore = IERC20(stock).balanceOf(creator);
                IERC20(stock).safeTransfer(creator, stockRefund);
                if (IERC20(stock).balanceOf(creator) != creatorBefore + stockRefund) revert TransferMismatch();
            }
        }
        if (
            wrappedNative.balanceOf(address(this)) != wrappedBefore
                || IERC20(stock).balanceOf(address(this)) != stockBefore || address(this).balance != nativeBefore
        ) revert TransferMismatch();
    }
}
