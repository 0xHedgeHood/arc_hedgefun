// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunV2EngineTreasury, HedgeFunV2EngineTreasuryCore} from "../src/v2/HedgeFunV2EngineTreasury.sol";
import {EngineConfig} from "../src/v2/strategy/IStrategyPolicy.sol";
import {GraduationStock} from "./utils/V2FactoryFixture.sol";
import {V2StrategyEngineAccountingFixture} from "./V2StrategyEngineAccounting.t.sol";

interface IRewardObserver { function onReward() external; }

/// Normal ERC20 transfer followed by an adversarial recipient callback, including USDG's six decimals.
contract RewardCallbackAsset is GraduationStock {
    address private watchedTreasury;
    address private watchedRecipient;
    constructor(uint8 decimals_) GraduationStock(decimals_) {}
    function watch(address treasury, address recipient) external {
        watchedTreasury = treasury;
        watchedRecipient = recipient;
    }
    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from == watchedTreasury && to == watchedRecipient && amount != 0) IRewardObserver(to).onReward();
    }
}

contract RewardObservingKeeper is IRewardObserver {
    HedgeFunV2EngineTreasury public immutable treasury;
    IERC20 public immutable stock;
    IERC20 public immutable usdg;
    bool public observed;
    bool public inventoryMatches;
    uint64 public seenNonce;
    uint256 public seenLastStrategyAt;
    uint256 public seenTurnover;
    bytes4 public executeError;
    bytes4 public bookError;
    constructor(HedgeFunV2EngineTreasury treasury_, IERC20 stock_, IERC20 usdg_) {
        treasury = treasury_; stock = stock_; usdg = usdg_;
    }
    function run() external { treasury.execute(); }
    function onReward() external {
        require(msg.sender == address(stock) || msg.sender == address(usdg));
        observed = true;
        seenNonce = treasury.strategyNonce();
        seenLastStrategyAt = treasury.lastStrategyAt();
        seenTurnover = treasury.turnoverInEpoch();
        inventoryMatches = treasury.bookedStock() + treasury.buybackStock() == stock.balanceOf(address(treasury));
        (bool ok, bytes memory reason) = address(treasury).call(abi.encodeCall(HedgeFunV2EngineTreasuryCore.execute, ()));
        require(!ok); executeError = bytes4(reason);
        (ok, reason) = address(treasury).call(abi.encodeCall(HedgeFunV2EngineTreasuryCore.book, ()));
        require(!ok); bookError = bytes4(reason);
    }
}

contract V2EngineKeeperRewardTest is V2StrategyEngineAccountingFixture {
    address private constant KEEPER = address(0xB07);
    address private constant SECOND_KEEPER = address(0xB08);
    bytes32 private constant REWARD_TOPIC = keccak256("KeeperRewardPaid(uint64,address,address,uint256)");
    bytes32 private constant EXECUTED_TOPIC = keccak256("StrategyExecuted(uint64,uint8,uint256,uint256,uint256,uint256,uint256,bytes32)");

    function _config(uint256 maxTrade, uint256 maxDaily) internal view override returns (EngineConfig memory c) {
        c = super._config(maxTrade, maxDaily);
        c.words[0] = bytes32(uint256(5000) | uint256(1000) << 16 | uint256(600) << 32);
    }

    function _rate(uint16 bounty) private {
        HedgeFunFactory.Defaults memory d = factory.getDefaults();
        d.bountyBps = bounty;
        vm.prank(owner); factory.setDefaults(d);
    }

    function _buyTreasury(uint96 nonce) private returns (HedgeFunV2EngineTreasury t) {
        t = _launch(nonce, 100e6, 500e6);
        usdg.mint(address(t), Math.mulDiv(t.bookedStock(), PRICE, 1e30) * 3);
    }

    function _rewardLog(HedgeFunV2EngineTreasury t, address keeper, address asset, uint256 amount) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) if (logs[i].emitter == address(t) && logs[i].topics[0] == REWARD_TOPIC) {
            assertFalse(seen, "one reward per execution"); seen = true;
            assertEq(uint256(logs[i].topics[1]), 1);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), keeper);
            assertEq(address(uint160(uint256(logs[i].topics[3]))), asset);
            assertEq(abi.decode(logs[i].data, (uint256)), amount);
        }
        assertEq(seen, amount != 0);
    }

    function testFuzz_sellRewardUsesActualUsdOutput(uint16 fill, uint16 rate) public {
        fill = uint16(bound(fill, 500, 10000)); rate = uint16(bound(rate, 0, 200));
        _rate(rate); venue.setFillBps(fill);
        HedgeFunV2EngineTreasury t = _launch(810, 100e6, 500e6);
        uint256 cash = t.reserveUsdg(); uint256 poolCash = usdg.balanceOf(address(venue));
        uint256 stockBefore = t.bookedStock(); uint256 keeperCash = usdg.balanceOf(KEEPER);
        vm.recordLogs(); vm.prank(KEEPER); t.execute();
        uint256 gross = poolCash - usdg.balanceOf(address(venue));
        uint256 reward = Math.mulDiv(gross, rate, 10000);
        assertEq(usdg.balanceOf(KEEPER) - keeperCash, reward, "executor gets actual output reward");
        assertEq(t.reserveUsdg() - cash, gross - reward);
        assertEq(t.turnoverInEpoch(), Math.mulDiv(stockBefore - t.bookedStock(), PRICE, 1e30));
        assertEq(t.bookedStock() + t.buybackStock(), stock.balanceOf(address(t)));
        _rewardLog(t, KEEPER, address(usdg), reward);
    }

    function testFuzz_buyRewardUsesActualStockAndNetCost(uint16 fill, uint16 rate) public {
        fill = uint16(bound(fill, 500, 10000)); rate = uint16(bound(rate, 0, 200));
        _rate(rate); venue.setFillBps(fill);
        HedgeFunV2EngineTreasury t = _buyTreasury(811);
        uint256 cash = t.reserveUsdg(); uint256 held = t.bookedStock(); uint256 cost = t.avgCost();
        uint256 poolStock = stock.balanceOf(address(venue)); uint256 keeperStock = stock.balanceOf(KEEPER);
        vm.recordLogs(); vm.prank(KEEPER); t.execute();
        uint256 spent = cash - t.reserveUsdg();
        uint256 gross = poolStock - stock.balanceOf(address(venue));
        uint256 reward = Math.mulDiv(gross, rate, 10000); uint256 retained = gross - reward;
        assertEq(stock.balanceOf(KEEPER) - keeperStock, reward);
        assertEq(t.bookedStock(), held + retained, "book only retained stock");
        assertEq(t.avgCost(), Math.ceilDiv(held * cost + spent * 1e30, held + retained), "reward is part of cost");
        assertEq(t.turnoverInEpoch(), spent);
        assertEq(t.buybackStock(), 0);
        assertEq(t.bookedStock(), stock.balanceOf(address(t)));
        _rewardLog(t, KEEPER, address(stock), reward);
    }

    function test_executionEventKeepsGrossOutputWhileRewardEventExplainsNet() public {
        HedgeFunV2EngineTreasury t = _buyTreasury(812);
        uint256 poolStock = stock.balanceOf(address(venue));
        vm.recordLogs(); vm.prank(KEEPER); t.execute();
        Vm.Log[] memory logs = vm.getRecordedLogs(); bool seen;
        for (uint256 i; i < logs.length; ++i) if (logs[i].emitter == address(t) && logs[i].topics[0] == EXECUTED_TOPIC) {
            (,, uint256 gross,,,) = abi.decode(logs[i].data, (uint256,uint256,uint256,uint256,uint256,bytes32));
            assertEq(gross, poolStock - stock.balanceOf(address(venue))); seen = true;
        }
        assertTrue(seen);
    }

    function test_competingKeeperCannotCollectTwice() public {
        HedgeFunV2EngineTreasury t = _launch(813, 100e6, 500e6);
        vm.prank(KEEPER); t.execute();
        uint256 paid = usdg.balanceOf(KEEPER); assertGt(paid, 0);
        // The default policy returns Hold during cooldown; no second swap or reward is allowed.
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector); vm.prank(SECOND_KEEPER); t.execute();
        assertEq(usdg.balanceOf(KEEPER), paid); assertEq(usdg.balanceOf(SECOND_KEEPER), 0);
        assertEq(t.strategyNonce(), 1);
    }

    function test_holdAndDustPayNothingAndDoNotConsumeState() public {
        HedgeFunV2EngineTreasury t = _launch(814, 100e6, 500e6);
        uint256 value = Math.mulDiv(t.bookedStock(), PRICE, 1e30);
        usdg.mint(address(t), value); // exactly the target; Hold
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector); vm.prank(KEEPER); t.execute();
        assertEq(t.strategyNonce(), 0); assertEq(usdg.balanceOf(KEEPER), 0); assertEq(stock.balanceOf(KEEPER), 0);
        HedgeFunV2EngineTreasury dust = _launch(815, 100e6, 500e6);
        venue.setFillBps(499);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector); vm.prank(KEEPER); dust.execute();
        assertEq(dust.strategyNonce(), 0); assertEq(dust.turnoverInEpoch(), 0);
        assertEq(usdg.balanceOf(KEEPER), 0);
    }

    function test_sellRewardTransferFailureRollsBackSwapAndState() public {
        HedgeFunV2EngineTreasury t = _launch(816, 100e6, 500e6);
        uint256 held = t.bookedStock(); uint256 treasuryCash = t.reserveUsdg();
        uint256 poolCash = usdg.balanceOf(address(venue)); uint256 poolStock = stock.balanceOf(address(venue));
        vm.mockCall(address(usdg), abi.encodeWithSelector(IERC20.transfer.selector, KEEPER), abi.encode(false));
        vm.expectRevert(); vm.prank(KEEPER); t.execute();
        assertEq(t.bookedStock(), held); assertEq(stock.balanceOf(address(t)), held);
        assertEq(t.reserveUsdg(), treasuryCash); assertEq(usdg.balanceOf(address(venue)), poolCash);
        assertEq(stock.balanceOf(address(venue)), poolStock); assertEq(t.strategyNonce(), 0);
        assertEq(t.turnoverInEpoch(), 0); assertEq(t.lastStrategyAt(), 0); assertEq(usdg.balanceOf(KEEPER), 0);
    }

    function test_buyRewardTransferFailureRollsBackNetCostAndSwap() public {
        HedgeFunV2EngineTreasury t = _buyTreasury(817);
        uint256 held = t.bookedStock(); uint256 cost = t.avgCost(); uint256 cash = t.reserveUsdg();
        uint256 poolStock = stock.balanceOf(address(venue)); uint256 poolCash = usdg.balanceOf(address(venue));
        stock.blockRecipient(KEEPER);
        vm.expectRevert(); vm.prank(KEEPER); t.execute();
        assertEq(t.bookedStock(), held); assertEq(t.avgCost(), cost); assertEq(t.reserveUsdg(), cash);
        assertEq(stock.balanceOf(address(t)), held); assertEq(stock.balanceOf(address(venue)), poolStock);
        assertEq(usdg.balanceOf(address(venue)), poolCash); assertEq(t.strategyNonce(), 0);
        assertEq(t.turnoverInEpoch(), 0); assertEq(stock.balanceOf(KEEPER), 0);
    }

    function _callback(bool buy) private {
        HedgeFunV2EngineTreasury t = buy ? _buyTreasury(818) : _launch(819, 100e6, 500e6);
        RewardObservingKeeper keeper = new RewardObservingKeeper(t, IERC20(address(stock)), IERC20(address(usdg)));
        address asset = buy ? address(stock) : address(usdg);
        vm.etch(asset, address(new RewardCallbackAsset(buy ? 18 : 6)).code);
        RewardCallbackAsset(asset).watch(address(t), address(keeper));
        keeper.run();
        assertTrue(keeper.observed()); assertTrue(keeper.inventoryMatches());
        assertEq(keeper.seenNonce(), 1); assertEq(keeper.seenLastStrategyAt(), block.timestamp);
        assertGt(keeper.seenTurnover(), 0);
        assertEq(keeper.executeError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(keeper.bookError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertGt(IERC20(asset).balanceOf(address(keeper)), 0);
    }
    function test_buyRewardCallbackSeesFinalLedgerAndCannotReenter() public { _callback(true); }
    function test_sellRewardCallbackSeesFinalLedgerAndCannotReenter() public { _callback(false); }
}
