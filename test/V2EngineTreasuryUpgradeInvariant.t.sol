// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2EngineTreasury} from "../src/v2/HedgeFunV2EngineTreasury.sol";
import {
    HedgeFunV2UpgradeableEngineTreasury,
    HedgeFunV2UpgradeableEngineTreasuryLogic
} from "../src/v2/HedgeFunV2UpgradeableEngineTreasury.sol";
import {V2TreasuryUpgradeController} from "../src/v2/V2TreasuryUpgradeController.sol";
import {MockFeed} from "./mocks/Mocks.sol";
import {StrategyEngineHandler} from "./V2StrategyEngineInvariant.t.sol";
import {V2UpgradeableEngineFixture} from "./V2EngineTreasuryUpgrade.t.sol";

/// @dev Repeated real controller upgrades interleaved with the existing trading/fault-injection handler.
/// Candidate implementations are deployed normally and share the full per-proxy identity.
contract EngineUpgradeHandler is Test {
    HedgeFunV2EngineTreasury public immutable treasury;
    HedgeFunV2UpgradeableEngineTreasury public immutable proxy;
    V2TreasuryUpgradeController public immutable controller;
    address public immutable owner;
    address public immutable candidateA;
    address public immutable candidateB;
    IERC20 private immutable stock;
    IERC20 private immutable usdg;
    MockFeed private immutable stockFeed;
    MockFeed private immutable usdgFeed;
    uint256 public upgrades;
    uint256 public cancellations;
    bool public violation;

    constructor(
        HedgeFunV2EngineTreasury t,
        V2TreasuryUpgradeController ctl,
        address owner_,
        address next,
        address stock_,
        address usdg_,
        MockFeed sf,
        MockFeed uf
    ) {
        treasury = t;
        proxy = HedgeFunV2UpgradeableEngineTreasury(payable(address(t)));
        controller = ctl;
        owner = owner_;
        candidateA = proxy.initialImplementation();
        candidateB = next;
        stock = IERC20(stock_);
        usdg = IERC20(usdg_);
        stockFeed = sf;
        usdgFeed = uf;
    }

    function schedule() external {
        address next = proxy.implementation() == candidateA ? candidateB : candidateA;
        vm.prank(owner);
        controller.schedule(address(proxy), next, "");
    }

    function cancel() external {
        vm.prank(owner);
        controller.cancel(address(proxy));
        ++cancellations;
    }

    function finishUpgrade(bool mature) external {
        (address next,,,, uint256 readyAt) = controller.proposals(address(proxy));
        if (readyAt == 0) return;
        if (block.timestamp < readyAt) {
            if (!mature) return;
            vm.warp(readyAt);
            stockFeed.set(stockFeed.answer());
            usdgFeed.set(1e8);
        }
        bytes32 beforeUpgrade = _digest();
        controller.execute(address(proxy), "");
        if (_digest() != beforeUpgrade || proxy.implementation() != next) violation = true;
        ++upgrades;
    }

    function _digest() private view returns (bytes32) {
        bytes32 strategy = keccak256(
            abi.encode(
                treasury.engineConfig(),
                treasury.configHash(),
                treasury.policyState(),
                treasury.strategyNonce(),
                treasury.lastStrategyAt(),
                treasury.turnoverEpoch(),
                treasury.turnoverInEpoch()
            )
        );
        bytes32 inventory = keccak256(
            abi.encode(
                treasury.bookedStock(),
                treasury.buybackStock(),
                treasury.avgCost(),
                treasury.totalStockReceived(),
                stock.balanceOf(address(treasury)),
                usdg.balanceOf(address(treasury))
            )
        );
        bytes32 base = keccak256(
            abi.encode(
                treasury.params(),
                treasury.liquidityVault(),
                treasury.hook(),
                treasury.lastGoodPrice(),
                treasury.lastGoodPriceAt(),
                treasury.buybackAnchorSqrtP(),
                treasury.buybackAnchorAt()
            )
        );
        return keccak256(abi.encode(strategy, inventory, base));
    }
}

contract V2EngineTreasuryUpgradeInvariantTest is V2UpgradeableEngineFixture {
    HedgeFunV2EngineTreasury private treasury;
    StrategyEngineHandler private trading;
    EngineUpgradeHandler private upgrading;

    function setUp() public {
        _setUpUpgradeableEngine(false);
        HedgeFunBondingCurve curve;
        (treasury, curve) = _launchProxy(777, 0);
        _graduateV2(curve);
        HedgeFunV2UpgradeableEngineTreasuryLogic next = _replacement(treasury);
        trading = new StrategyEngineHandler(treasury, venue, stock, usdg, stockFeed, usdgFeed);
        upgrading = new EngineUpgradeHandler(
            treasury, controller, owner, address(next), address(stock), address(usdg), stockFeed, usdgFeed
        );
        targetContract(address(trading));
        targetContract(address(upgrading));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_upgradeNeverResetsTradingStateOrCustody() public view {
        assertFalse(upgrading.violation());
        assertEq(treasury.strategyNonce(), trading.successfulExecutions());
        assertEq(treasury.lastStrategyAt(), trading.lastSuccessAt());
        assertEq(treasury.policyState(), bytes32(0));
        assertLe(treasury.bookedStock() + treasury.buybackStock(), stock.balanceOf(address(treasury)));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_upgradedEngineKeepsTurnoverAndExecutionGuards() public view {
        assertFalse(trading.violation());
        assertLe(treasury.turnoverInEpoch(), 500e6);
        assertLe(trading.ghostTurnoverInEpoch(), 500e6);
        assertEq(trading.executeAttempts(), trading.failedExecutions() + trading.successfulExecutions());
        assertEq(trading.successfulExecutions(), trading.successfulBuys() + trading.successfulSells());
    }

    function test_handlerActuallyTradesAndUpgradesRepeatedly() public {
        trading.attemptExecute(9999);
        assertEq(trading.successfulSells(), 1);
        for (uint256 i; i < 3; ++i) {
            upgrading.schedule();
            upgrading.finishUpgrade(true);
            trading.attemptExecute(9999);
        }
        assertEq(upgrading.upgrades(), 3);
        assertEq(trading.successfulSells(), 4);
        usdg.mint(address(treasury), 100_000e6);
        trading.advanceCooldownEdge(1);
        trading.attemptExecute(9999);
        assertEq(trading.successfulBuys(), 1);
        invariant_upgradeNeverResetsTradingStateOrCustody();
        invariant_upgradedEngineKeepsTurnoverAndExecutionGuards();
    }
}
