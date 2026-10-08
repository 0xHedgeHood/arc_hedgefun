// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunV2AllInTreasury} from "../src/v2/HedgeFunV2AllInTreasury.sol";
import {PoolTrader} from "../src/PoolTrader.sol";
import {V2ExecuteBase} from "./V2Execute.t.sol";

/// Test-only venue preserves healthy price reads but returns incomplete swap deltas. No signing or network.
contract CreatorNoFillVenue {
    uint160 private immutable _sqrt;
    int24 private immutable _tick;
    uint8 private immutable _mode;

    constructor(uint160 sqrt, int24 tick, uint8 mode) { _sqrt = sqrt; _tick = tick; _mode = mode; }
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (_sqrt, _tick, 0, 1000, 1000, 0, true);
    }
    function observe(uint32[] calldata ago) external view returns (int56[] memory tc, uint160[] memory l) {
        tc = new int56[](2); l = new uint160[](2); tc[1] = int56(_tick) * int56(uint56(ago[0]));
    }
    function swap(address, bool zeroForOne, int256 amount, uint160, bytes calldata) external view returns (int256, int256) {
        int256 input = _mode == 1 ? amount : int256(0);
        int256 output = _mode == 2 ? int256(-1) : int256(0);
        return zeroForOne ? (input, output) : (output, input);
    }
}

/// Test-only direct ledger seeding makes otherwise impractical dust/capacity and sub-unit rounding states exact.
contract CreatorRemainderHarness is HedgeFunV2AllInTreasury {
    constructor(address u, address s, address v, address o, address t, address m, address f, Params memory p)
        HedgeFunV2AllInTreasury(u, s, v, o, t, m, f, p) {}

    function seedLot(uint256 qty, uint256 cost) external { lots.push(Lot(qty, cost, false, 0)); bookedStock += qty; }
    function seedBudget(uint256 qty) external { buybackStock += qty; }
    function coalesce() external returns (bool) { return _coalesceLots(); }
    function seedReferences(uint256 stop, uint256 at) external {
        lastStopPrice = stop; lastStopAt = at; lastStopStockUpdatedAt = at;
        lastSalePrice = stop; lastGoodPrice = stop - 1e18; lastGoodPriceAt = at - 1;
    }
}

abstract contract V2CreatorTakeProfitBase is V2ExecuteBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    address private constant KEEPER = address(0xB07);

    function _deploy(uint32 trigger, uint16 bounty, uint16 deviation, uint32 tp2) private returns (CreatorRemainderHarness t) {
        HedgeFunTreasuryBase.Params memory p = _params(500);
        p.tp1Bps = trigger; p.tp2Bps = tp2; p.dipBps = uint16(trigger);
        p.bountyBps = bounty; p.maxDeviationBps = deviation; p.sellChunkUsdg = type(uint128).max;
        t = new CreatorRemainderHarness(address(usdg), address(stock), address(mirror), address(oracle), address(token), address(pm), address(this), p);
        t.wire(_tokenKey());
        treasury = t;
    }

    function _ledger() private view returns (bytes32) {
        (uint256 qty, uint256 cost, bool half, uint256 left) = treasury.lots(0);
        (uint160 sqrt, int24 tick,,) = pm.getSlot0(stockKey.toId());
        bytes32 position = keccak256(abi.encode(qty, cost, half, left, treasury.lotCount(), treasury.bookedStock(), treasury.buybackStock()));
        bytes32 references = keccak256(abi.encode(treasury.lastSalePrice(), treasury.lastGoodPrice(), treasury.lastGoodPriceAt(),
            treasury.lastPoolOnlySaleAt(), treasury.lastStopPrice(), treasury.lastStopAt(), treasury.lastStopStockUpdatedAt()));
        bytes32 balances = keccak256(abi.encode(
            stock.balanceOf(address(treasury)), usdg.balanceOf(address(treasury)), stock.balanceOf(KEEPER),
            usdg.balanceOf(KEEPER), stock.balanceOf(address(pm)), usdg.balanceOf(address(pm))));
        return keccak256(abi.encode(position, references, balances, sqrt, tick));
    }

    function test_creatorApprovedAdverseActualFillSucceedsWithoutNetProfitRequirement() public {
        CreatorRemainderHarness t = _deploy(1, 200, 99, 0);
        stock.mint(address(t), 1000 ether); assertTrue(t.book());
        usdg.mint(address(t), 1_000_000e6);
        stock.mint(address(t), 1000 ether); t.seedBudget(1000 ether);
        uint256 p = 100.01e18;
        _px(p * 9902 / 10000); stockFeed.set(int256(p / 1e10));
        (bool healthy,) = t.health(); assertTrue(healthy, "health and slippage remain mandatory");
        uint256[5] memory before = [t.bookedStock(), t.buybackStock(), t.reserveUsdg(), stock.balanceOf(KEEPER), stock.balanceOf(address(t))];
        vm.prank(KEEPER); (HedgeFunV2Treasury.Action action, uint256 id) = t.execute();
        assertEq(uint8(action), uint8(HedgeFunV2Treasury.Action.TakeProfit)); assertEq(id, 0);
        uint256 q = before[0] - t.bookedStock();
        uint256 reward = stock.balanceOf(KEEPER) - before[3];
        uint256 sold = before[4] - stock.balanceOf(address(t)) - reward;
        uint256 retained = t.buybackStock() - before[1];
        assertGt(sold, 0); assertGt(t.reserveUsdg() - before[2], 0);
        assertGt(q, 0); assertLt(q, before[0], "real venue partial fill");
        assertEq(sold + retained + reward, q);
        assertEq(reward, (q - sold) * 200 / 10000);
        assertLt(t.reserveUsdg() - before[2] + Math.mulDiv(retained, p, SCALE), Math.mulDiv(q, 100e18, SCALE),
            "a lawful creator-selected TP can lose value; this is deliberately not a runtime veto");
        assertEq(t.bookedStock() + t.buybackStock() + t.unbookedStock(), stock.balanceOf(address(t)));
    }

    function test_creator180TriggerSucceedsOnSmallHealthyActualFill() public {
        CreatorRemainderHarness t = _deploy(180, 50, 50, 0);
        _fundAndBook(0.1 ether);
        _px(101.8e18);
        vm.prank(KEEPER); t.execute();
        assertEq(t.lotCount(), 0);
        assertGt(t.reserveUsdg(), 0); assertGt(t.buybackStock(), 0); assertGt(stock.balanceOf(KEEPER), 0);
        assertEq(t.bookedStock() + t.buybackStock() + t.unbookedStock(), stock.balanceOf(address(t)));
    }

    function test_creatorOneBpsStopActuallyExecutesAndPaysOnlyActualUsdGReward() public {
        HedgeFunTreasuryBase.Params memory p = _params(1); p.tp1Bps = 1; p.tp2Bps = 0; p.dipBps = 1;
        CreatorRemainderHarness t = new CreatorRemainderHarness(address(usdg), address(stock), address(mirror), address(oracle), address(token), address(pm), address(this), p);
        t.wire(_tokenKey()); treasury = t; _fundAndBook(0.1 ether); _px(99.99e18);
        vm.prank(KEEPER); (HedgeFunV2Treasury.Action action, uint256 id) = t.execute();
        assertEq(uint8(action), uint8(HedgeFunV2Treasury.Action.Stop)); assertEq(id, 0);
        assertGt(t.reserveUsdg(), 0); assertGt(usdg.balanceOf(KEEPER), 0); assertEq(stock.balanceOf(KEEPER), 0);
        assertEq(t.lastStopPrice(), 99.99e18); assertEq(t.lastStopAt(), block.timestamp);
        assertEq(t.bookedStock() + t.buybackStock() + t.unbookedStock(), stock.balanceOf(address(t)));
    }

    function test_creatorOneBpsDipActuallyExecutesWithActualFillCost() public {
        CreatorRemainderHarness t = _deploy(1, 200, 50, 0);
        _fundAndBook(0.1 ether); usdg.mint(address(t), 100e6); _px(99.99e18);
        vm.prank(KEEPER); (HedgeFunV2Treasury.Action action,) = t.execute();
        assertEq(uint8(action), uint8(HedgeFunV2Treasury.Action.BuyDip));
        (uint256 qty, uint256 cost,,) = t.lots(1);
        uint256 reward = usdg.balanceOf(KEEPER); uint256 spent = 100e6 - t.reserveUsdg() - reward;
        assertEq(reward, spent * 200 / 10000); assertEq(cost, Math.mulDiv(spent, SCALE, qty));
        assertEq(t.bookedStock() + t.buybackStock() + t.unbookedStock(), stock.balanceOf(address(t)));
    }

    function test_noMonetaryFillRevertsAtomicallyWithoutRewardOrStopGateChange() public {
        CreatorRemainderHarness t = _deploy(1, 200, 50, 0);
        _fundAndBook(0.1 ether); _px(100.01e18); t.seedReferences(100e18, block.timestamp);
        (uint160 sqrt, int24 tick,,) = pm.getSlot0(stockKey.toId());
        for (uint8 mode; mode < 3; ++mode) {
            vm.etch(address(mirror), address(new CreatorNoFillVenue(sqrt, tick, mode)).code);
            (bool healthy,) = t.health(); assertTrue(healthy);
            bytes32 before = _ledger();
            vm.prank(KEEPER); vm.expectRevert(PoolTrader.Slippage.selector); t.execute();
            assertEq(_ledger(), before, "zero input/output cannot book effects or a keeper reward");
        }
    }

    function test_zeroSelectedQuantityRevertsAtomicallyInsteadOfPayingForAnEmptyAction() public {
        HedgeFunTreasuryBase.Params memory p = _params(500); p.tp1Bps = 1; p.tp2Bps = 0; p.dipBps = 1; p.sellChunkUsdg = 1;
        CreatorRemainderHarness t = new CreatorRemainderHarness(address(usdg), address(stock), address(mirror), address(oracle), address(token), address(pm), address(this), p);
        t.wire(_tokenKey()); treasury = t; _fundAndBook(0.1 ether); _px(1e37); t.seedReferences(100e18, block.timestamp);
        (bool healthy,) = t.health(); assertTrue(healthy);
        bytes32 before = _ledger(); vm.prank(KEEPER); vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector); t.execute();
        assertEq(_ledger(), before);
    }

    function test_distinctCost128DustLotsReleaseCapacity_keepStopGate_thenBookAndBuyNormally() public {
        CreatorRemainderHarness t = _deploy(180, 50, 50, 0);
        for (uint256 i; i < 128; ++i) t.seedLot(1, 90e18 + i * 1e15);
        stock.mint(address(t), 128);
        t.seedReferences(100e18, block.timestamp);
        uint256 lastGood = t.lastGoodPrice(); uint256 lastAt = t.lastGoodPriceAt();
        vm.recordLogs(); vm.prank(KEEPER);
        (HedgeFunV2Treasury.Action action, uint256 id) = t.execute();
        assertEq(uint8(action), uint8(HedgeFunV2Treasury.Action.TakeProfit)); assertEq(id, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1); assertEq(logs[0].topics[0], keccak256("DustCleared(uint256,uint256)"));
        assertEq(t.lotCount(), 127); assertEq(t.buybackStock(), 0); assertEq(t.unbookedStock(), 1);
        assertEq(t.lastSalePrice(), 100e18); assertEq(t.lastGoodPrice(), lastGood); assertEq(t.lastGoodPriceAt(), lastAt);
        assertEq(t.lastStopPrice(), 100e18); assertEq(t.lastStopAt(), block.timestamp); assertEq(t.lastStopStockUpdatedAt(), block.timestamp);
        assertEq(stock.balanceOf(KEEPER), 0); assertEq(usdg.balanceOf(KEEPER), 0);

        // A genuine new donation books into the released slot; the remaining distinct-cost tails still clear.
        stock.mint(address(t), 0.1 ether); assertTrue(t.book()); assertEq(t.lotCount(), 128);
        for (uint256 i; i < 127; ++i) { vm.prank(KEEPER); t.execute(); }
        assertEq(t.lotCount(), 1); assertEq(t.bookedStock(), 0.1 ether + 1); assertEq(t.buybackStock(), 0); assertEq(t.unbookedStock(), 127);
        assertEq(t.lastStopAt(), block.timestamp);
        usdg.mint(address(t), 100e6);
        vm.warp(block.timestamp + 601); _px(97e18);
        vm.prank(KEEPER); (action,) = t.execute();
        assertEq(uint8(action), uint8(HedgeFunV2Treasury.Action.BuyDip));
        assertEq(t.lastStopAt(), 0); assertEq(t.lastStopPrice(), 0); assertEq(t.lastStopStockUpdatedAt(), 0);
        assertGt(usdg.balanceOf(KEEPER), 0, "the consumed dust flag does not leak into a real buy");
        assertEq(t.bookedStock() + t.buybackStock() + t.unbookedStock(), stock.balanceOf(address(t)));
    }

    function test_oneWeiTp1StageAdvanceThenDustCleanupMovesNoRewardOrPriceReference() public {
        CreatorRemainderHarness t = _deploy(180, 50, 50, 400);
        t.seedLot(1, 90e18); stock.mint(address(t), 1); t.seedReferences(100e18, block.timestamp);
        bytes32 beforeRefs = keccak256(abi.encode(t.lastSalePrice(), t.lastGoodPrice(), t.lastGoodPriceAt(), t.lastStopPrice(), t.lastStopAt(), t.lastStopStockUpdatedAt()));
        vm.recordLogs(); vm.prank(KEEPER); t.execute();
        assertEq(vm.getRecordedLogs().length, 0);
        (uint256 qty,, bool half, uint256 left) = t.lots(0);
        assertEq(qty, 1); assertTrue(half); assertEq(left, 0); assertEq(t.bookedStock(), 1); assertEq(t.buybackStock(), 0);
        vm.prank(KEEPER); t.execute();
        assertEq(t.lotCount(), 0); assertEq(t.bookedStock(), 0); assertEq(t.buybackStock(), 0); assertEq(t.unbookedStock(), 1);
        assertEq(beforeRefs, keccak256(abi.encode(t.lastSalePrice(), t.lastGoodPrice(), t.lastGoodPriceAt(), t.lastStopPrice(), t.lastStopAt(), t.lastStopStockUpdatedAt())));
        assertEq(stock.balanceOf(KEEPER), 0); assertEq(usdg.balanceOf(KEEPER), 0);
    }

    function test_valuableRemainderReclassifiesWithoutRewardSaleOrStopGateChange() public {
        CreatorRemainderHarness t = _deploy(1, 200, 50, 0);
        t.seedLot(1e10, 1e18); stock.mint(address(t), 1e10); t.seedReferences(100e18, block.timestamp);
        _px(100e18); // entire lot is one raw USDG; its cost-basis principal is below one raw USDG
        uint256 good = t.lastGoodPrice(); uint256 at = t.lastGoodPriceAt();
        vm.recordLogs(); vm.prank(KEEPER); t.execute();
        Vm.Log[] memory logs = vm.getRecordedLogs(); assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("RemainderReclassified(uint256,uint256)"));
        assertEq(abi.decode(logs[0].data, (uint256)), 1e10);
        assertEq(t.lotCount(), 0); assertEq(t.reserveUsdg(), 0); assertEq(t.unbookedStock(), 1e10);
        assertEq(t.buybackStock(), 0); assertEq(t.unbookedStock(), 1e10); assertEq(stock.balanceOf(KEEPER), 0); assertEq(usdg.balanceOf(KEEPER), 0);
        assertEq(t.lastSalePrice(), 100e18); assertEq(t.lastGoodPrice(), good); assertEq(t.lastGoodPriceAt(), at);
        assertEq(t.lastStopPrice(), 100e18); assertEq(t.lastStopAt(), block.timestamp); assertEq(t.lastStopStockUpdatedAt(), block.timestamp);
        vm.prank(KEEPER); vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector); t.execute();
        assertEq(t.buybackStock(), 0); assertEq(t.unbookedStock(), 1e10); assertEq(stock.balanceOf(KEEPER), 0, "no repeated free reward");
    }

    function test_partialTp1RemainderReclassificationProgressesTwoCallsThenTp2WithoutEconomicSideEffects() public {
        HedgeFunTreasuryBase.Params memory p = _params(1); p.tp1Bps = 1; p.tp2Bps = 2; p.dipBps = 1; p.sellChunkUsdg = 1;
        CreatorRemainderHarness t = new CreatorRemainderHarness(address(usdg), address(stock), address(mirror), address(oracle), address(token), address(pm), address(this), p);
        t.wire(_tokenKey()); treasury = t;
        t.seedLot(4e10, 1e18); stock.mint(address(t), 4e10); t.seedReferences(100e18, block.timestamp);
        for (uint256 i; i < 4; ++i) {
            vm.recordLogs(); vm.prank(KEEPER); t.execute();
            Vm.Log[] memory logs = vm.getRecordedLogs(); assertEq(logs.length, 1);
            assertEq(logs[0].topics[0], keccak256("RemainderReclassified(uint256,uint256)"));
            assertEq(t.buybackStock(), 0); assertEq(t.unbookedStock(), (i + 1) * 1e10); assertEq(t.bookedStock() + t.unbookedStock(), 4e10);
            assertEq(t.lastSalePrice(), 100e18); assertEq(t.lastStopAt(), block.timestamp); assertEq(t.lastStopPrice(), 100e18);
            if (i < 3) {
                (uint256 qty,, bool half, uint256 left) = t.lots(0);
                assertEq(qty, (3 - i) * 1e10); assertEq(left, i == 0 ? 1e10 : 0); assertEq(half, i >= 1);
            }
        }
        assertEq(t.lotCount(), 0); assertEq(t.reserveUsdg(), 0); assertEq(stock.balanceOf(KEEPER), 0); assertEq(usdg.balanceOf(KEEPER), 0);
    }

    function test_distinctCost128ValuableRemaindersReleaseCapacityWithoutFreeRewards() public {
        CreatorRemainderHarness t = _deploy(1, 200, 50, 0);
        for (uint256 i; i < 128; ++i) t.seedLot(1e10, 1e18 + i * 1e15);
        stock.mint(address(t), 128e10); t.seedReferences(100e18, block.timestamp);
        for (uint256 i; i < 128; ++i) { vm.prank(KEEPER); t.execute(); }
        assertEq(t.lotCount(), 0); assertEq(t.bookedStock(), 0); assertEq(t.buybackStock(), 0); assertEq(t.unbookedStock(), 128e10);
        assertEq(stock.balanceOf(KEEPER), 0); assertEq(usdg.balanceOf(KEEPER), 0); assertEq(t.lastStopAt(), block.timestamp);
        stock.mint(address(t), 0.1 ether); assertTrue(t.book()); assertEq(t.lotCount(), 1);
        usdg.mint(address(t), 100e6); vm.warp(block.timestamp + 601); _px(99e18);
        vm.prank(KEEPER); (HedgeFunV2Treasury.Action action,) = t.execute();
        assertEq(uint8(action), uint8(HedgeFunV2Treasury.Action.BuyDip));
        assertEq(t.lastStopAt(), 0); assertGt(usdg.balanceOf(KEEPER), 0); assertLt(t.reserveUsdg(), 100e6); assertEq(t.bookedStock() + t.buybackStock() + t.unbookedStock(), stock.balanceOf(address(t)));
    }

    function test_exactCostCoalescedLotsConserveInventory_andNormalFillClearsStopGate() public {
        CreatorRemainderHarness t = _deploy(180, 50, 50, 0);
        t.seedLot(0.1 ether, 100e18); t.seedLot(0.2 ether, 100e18); stock.mint(address(t), 0.3 ether);
        assertTrue(t.coalesce()); assertEq(t.lotCount(), 1);
        (uint256 qty, uint256 cost,,) = t.lots(0); assertEq(qty, 0.3 ether); assertEq(cost, 100e18);
        t.seedReferences(100e18, block.timestamp);
        _px(101.8e18);
        vm.prank(KEEPER); t.execute();
        assertEq(t.lotCount(), 0); assertEq(t.lastStopAt(), 0); assertEq(t.lastStopPrice(), 0);
        uint256 basis = Math.mulDiv(qty, cost + 1, SCALE, Math.Rounding.Ceil);
        assertGt(t.reserveUsdg() + Math.mulDiv(t.buybackStock(), 101.8e18, SCALE), basis + Math.mulDiv(basis, 50, 10000, Math.Rounding.Ceil));
        assertEq(t.bookedStock() + t.buybackStock() + t.unbookedStock(), stock.balanceOf(address(t)));
    }
}

contract V2CreatorTakeProfitStock0Test is V2CreatorTakeProfitBase {
    function stockIsCurrency0() internal pure override returns (bool) { return true; }
}

contract V2CreatorTakeProfitUsdg0Test is V2CreatorTakeProfitBase {
    function stockIsCurrency0() internal pure override returns (bool) { return false; }
}
