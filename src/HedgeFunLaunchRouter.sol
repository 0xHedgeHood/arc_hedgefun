// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HedgeFunFactory} from "./HedgeFunFactory.sol";
import {HedgeFunToken} from "./HedgeFunToken.sol";
import {IHedgeFunTreasury} from "./interfaces/IHedgeFunTreasury.sol";


/// Launch a strategy WITH capital, in one transaction: the launch, the launcher's own first buy of the token, and a
/// first lot of stock for the treasury to run the rule on.
///
/// It is periphery on purpose. A launch, a swap and a transfer are three things anyone may already do, and anyone
/// may already do them atomically from a contract of their own, so a first buy cannot be capped or forbidden by the
/// factory. What this router adds is that a creator with a wallet and no contract gets the same atomicity.
///
/// Why the two go together. The treasury's capital is one-way -- nobody, the creator included, can take it back --
/// and what it earns is spent buying the token back for every holder alike. A creator who funds the treasury and
/// holds no tokens has made a gift. The first buy is what makes funding it rational; it pays the ordinary buy tax,
/// and the launch itself starts the sell spike, so turning round and dumping it is the most expensive trade there is.
///
/// Holds nothing between calls and has no owner. If it is ever wrong, deploy another.
contract HedgeFunLaunchRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    struct Capital {
        uint256 buyStock;        // stock spent on the launcher's first buy of the token; the tokens go to the launcher
        uint256 minTokensOut;    // the pool is born in this transaction, so this guards arithmetic, not a front-runner
        uint256 seedStock;       // stock sent to the treasury as its first lot. ONE WAY.
        bool mustBook;           // revert unless the seed was booked as a lot now, at today's price
        uint256 seedUsdg;        // USDG sent to the treasury as its first dip reserve. ONE WAY. It buys nothing until the
                                 // price falls `dipBps` below the treasury's first booked lot -- so seed some stock too
    }

    HedgeFunFactory public immutable factory;
    IPoolManager public immutable poolManager;
    IHooks public immutable hook;            // the one hook every strategy's pool runs on

    event LaunchedWithCapital(uint256 indexed id, address indexed launcher, uint256 buyStock, uint256 tokensBought, uint256 seedStock, bool booked, uint256 seedUsdg);

    error NotPoolManager();
    error TooFewTokens(uint256 got);
    error NotBooked();
    error NotYourLaunch();

    constructor(HedgeFunFactory factory_) { factory = factory_; poolManager = factory_.poolManager(); hook = IHooks(address(factory_.hook())); }

    /// @notice approve this router for `launch fee (if it is charged in a token) + buyStock + seedStock` first
    /// @param terms what `factory.predict(q)` answered: the launch reverts `Restated` if any default moved since
    function launch(HedgeFunFactory.Request calldata q, bytes32 terms, Capital calldata c)
        external payable returns (uint256 id, uint256 tokensBought, bool booked)
    {
        HedgeFunToken.Info memory none;
        return _launch(q, terms, c, none, false);
    }

    /// @notice the same, and the token's page in the same transaction: a coin is never live with an empty card
    function launchWithMetadata(HedgeFunFactory.Request calldata q, bytes32 terms, Capital calldata c, HedgeFunToken.Info calldata info)
        external payable returns (uint256 id, uint256 tokensBought, bool booked)
    {
        return _launch(q, terms, c, info, true);
    }

    function _launch(HedgeFunFactory.Request calldata q, bytes32 terms, Capital calldata c, HedgeFunToken.Info memory info, bool withPage)
        internal returns (uint256 id, uint256 tokensBought, bool booked)
    {
        // The factory takes a launch from its creator, or from a launcher its owner vouched for -- this contract.
        // The salt is (symbol, creator, nonce), so a launch copied from someone else's pending transaction would
        // collide with it and revert it, and through THIS contract it would also hand the copier the first buy.
        // So the launcher must be the creator.
        if (q.creator != msg.sender) revert NotYourLaunch();
        HedgeFunFactory.Defaults memory d = factory.getDefaults();
        _fundFee(d, q.stock);
        id = withPage ? factory.launchWithMetadata{value: msg.value}(q, terms, info) : factory.launch{value: msg.value}(q, terms);
        (address token, address treasury,,,) = factory.strategies(id);

        if (c.buyStock != 0) {
            IERC20(q.stock).safeTransferFrom(msg.sender, address(this), c.buyStock);
            PoolKey memory key = token < q.stock
                ? PoolKey(Currency.wrap(token), Currency.wrap(q.stock), d.lpFee, d.tickSpacing, hook)
                : PoolKey(Currency.wrap(q.stock), Currency.wrap(token), d.lpFee, d.tickSpacing, hook);
            tokensBought = abi.decode(poolManager.unlock(abi.encode(key, token, q.stock, c.buyStock, msg.sender)), (uint256));
            if (tokensBought < c.minTokensOut) revert TooFewTokens(tokensBought);
        }
        // the reserve is simply the treasury's USDG balance: no booking, no accounting, nothing that can decline
        if (c.seedUsdg != 0) IERC20(factory.usdg()).safeTransferFrom(msg.sender, treasury, c.seedUsdg);
        if (c.seedStock != 0) {
            IERC20(q.stock).safeTransferFrom(msg.sender, treasury, c.seedStock);
            // `book()` declines, rather than reverts, when the oracle is not healthy (a weekend) or the seed is under
            // the treasury's minimum lot. The stock is the treasury's either way; anyone may book it later.
            try IHedgeFunTreasury(treasury).book() returns (bool ok) { booked = ok; } catch {}
            if (c.mustBook && !booked) revert NotBooked();
        }
        emit LaunchedWithCapital(id, msg.sender, c.buyStock, tokensBought, c.seedStock, booked, c.seedUsdg);
    }

    /// @dev the factory pulls a token fee from ITS caller, which is this router: bring it here and approve exactly it
    function _fundFee(HedgeFunFactory.Defaults memory d, address stock) internal {
        if (d.launchFeeAmount == 0) return;
        if (d.launchFeeCurrency != HedgeFunFactory.FeeCurrency.Usdg && d.launchFeeCurrency != HedgeFunFactory.FeeCurrency.Stock) return;
        IERC20 feeToken = IERC20(d.launchFeeCurrency == HedgeFunFactory.FeeCurrency.Stock ? stock : factory.usdg());
        feeToken.safeTransferFrom(msg.sender, address(this), d.launchFeeAmount);
        feeToken.forceApprove(address(factory), d.launchFeeAmount);
    }

    /// @dev the manager calls back whoever unlocked it, so this only ever runs inside `launch` above
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, address token, address stock, uint256 stockIn, address to) = abi.decode(data, (PoolKey, address, address, uint256, address));
        bool zeroForOne = Currency.unwrap(key.currency0) == stock;                // the stock goes in
        BalanceDelta delta = poolManager.swap(key, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(stockIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}), "");
        (int128 dStock, int128 dToken) = zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        uint256 owedIn = uint256(uint128(-dStock));
        poolManager.sync(Currency.wrap(stock));
        IERC20(stock).safeTransfer(address(poolManager), owedIn);
        poolManager.settle();
        uint256 out = uint256(uint128(dToken));
        poolManager.take(Currency.wrap(token), to, out);
        if (owedIn < stockIn) IERC20(stock).safeTransfer(to, stockIn - owedIn);   // a buy that ran out of pool
        return abi.encode(out);
    }
}
