// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// Test doubles for the PUBLIC Robinhood Chain testnet (chain 46630) only. None of these has value, backing,
/// redemption or a peg, and none belongs on mainnet. They exist because the testnet has no USDG, no Chainlink equity
/// feeds, and faucet stock tokens without `oraclePaused()` (see docs/TESTNET_V2.md for the inventory).
///
/// Roles: the owner (the operator's EOA) may appoint operators. `TestnetMarket` is appointed on every token and
/// feed so that it can mint what a liquidity or price move needs and keep the feed on the pool price.
abstract contract TestnetRoles is Ownable2Step {
    mapping(address => bool) public operators;
    event OperatorSet(address indexed who, bool enabled);
    error NotOperator();

    modifier onlyOperator() {
        if (msg.sender != owner() && !operators[msg.sender]) revert NotOperator();
        _;
    }

    function setOperator(address who, bool enabled) external onlyOwner {
        operators[who] = enabled;
        emit OperatorSet(who, enabled);
    }
}

/// A capped self-service drip, so team members can top themselves up without the operator.
abstract contract Drip is ERC20 {
    uint256 public constant DRIP_INTERVAL = 1 days;
    uint256 public immutable dripAmount;
    mapping(address => uint256) public lastDrip;
    error DripTooSoon(uint256 nextAt);

    constructor(uint256 dripAmount_) { dripAmount = dripAmount_; }

    /// @notice mints `dripAmount` to the caller, at most once per `DRIP_INTERVAL`
    function drip() external {
        uint256 last = lastDrip[msg.sender];
        if (last != 0 && block.timestamp < last + DRIP_INTERVAL) revert DripTooSoon(last + DRIP_INTERVAL);
        lastDrip[msg.sender] = block.timestamp;
        _mint(msg.sender, dripAmount);
    }
}

/// Six decimals, like USDG. Not USDG: the name says so, and the front end must show the name.
contract TestUsdg is ERC20, TestnetRoles, Drip {
    constructor(address initialOwner)
        ERC20("Test USDG (testnet, no value)", "tUSDG") Ownable(initialOwner) Drip(10_000e6) {}

    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external onlyOperator { _mint(to, amount); }
}

/// A stock token with the surface this repository asks of one (`src/interfaces/IStockToken.sol`): `oraclePaused()`,
/// and a `uiMultiplier()` of 1e18 like every live token today. `delegate` is deliberately absent, exactly as on the
/// live token, so `HedgeFunTreasuryBase.setVoteDelegate` takes its not-accepted branch here too. 18 decimals.
contract TestStock is ERC20, TestnetRoles, Drip {
    bool public oraclePaused;
    uint256 public uiMultiplier = 1e18;
    event OraclePausedSet(bool paused);
    error InvalidMultiplier();

    constructor(string memory name_, string memory symbol_, address initialOwner, uint256 dripAmount_)
        ERC20(name_, symbol_) Ownable(initialOwner) Drip(dripAmount_) {}

    function mint(address to, uint256 amount) external onlyOperator { _mint(to, amount); }

    /// @notice simulates a corporate action: every `PriceOracle` on this stock fails closed while it is set
    function setOraclePaused(bool paused) external onlyOwner {
        oraclePaused = paused;
        emit OraclePausedSet(paused);
    }

    function setUiMultiplier(uint256 multiplier) external onlyOwner {
        if (multiplier == 0) revert InvalidMultiplier();
        uiMultiplier = multiplier;
    }
}

/// An AggregatorV3 whose answer the operator sets. With `alwaysFresh` (the default) `updatedAt` reads as the
/// current block, so the testnet needs no keeper to stay inside `PriceOracle`'s 26-hour age limit; switch it off to
/// test a stale feed, and the feed then reports the time of its last `set`.
contract TestFeed is TestnetRoles {
    uint8 public constant decimals = 8;
    string public description;
    int256 public answer;
    uint256 public setAt;
    uint80 public round;
    bool public alwaysFresh = true;
    event AnswerSet(uint80 indexed round, int256 answer);
    event AlwaysFreshSet(bool fresh);
    error InvalidAnswer();

    constructor(string memory description_, int256 initialAnswer, address initialOwner) Ownable(initialOwner) {
        description = description_;
        _set(initialAnswer);
    }

    function set(int256 nextAnswer) external onlyOperator { _set(nextAnswer); }

    function setAlwaysFresh(bool fresh) external onlyOwner {
        alwaysFresh = fresh;
        emit AlwaysFreshSet(fresh);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 at = alwaysFresh ? block.timestamp : setAt;
        return (round, answer, at, at, round);
    }

    function _set(int256 nextAnswer) private {
        if (nextAnswer <= 0) revert InvalidAnswer();
        answer = nextAnswer;
        setAt = block.timestamp;
        round++;
        emit AnswerSet(round, nextAnswer);
    }
}
