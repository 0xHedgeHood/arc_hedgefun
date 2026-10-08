// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {HedgeFunV2AssetPercentEngineTreasury} from "../src/v2/HedgeFunV2AssetPercentEngineTreasury.sol";
import {EngineConfig, StrategyAction, StrategyContext, StrategyIntent} from "../src/v2/strategy/IStrategyPolicy.sol";
import {V2AssetPercentEngineFixture} from "./V2AssetPercentEngine.t.sol";
import {RewardCallbackAsset, IRewardObserver} from "./V2EngineKeeperReward.t.sol";

/// A schema-2 policy that advertises capabilities independently of its hostile proposed action.
contract PercentHostilePolicy {
    uint256 private immutable mode;
    uint256 private immutable capabilities;
    uint256 public writes;
    constructor(uint256 mode_, uint256 capabilities_) { mode = mode_; capabilities = capabilities_; }
    function policyMetadata() external view returns (uint32, uint32, uint256) { return (1, 2, capabilities); }
    function decide(StrategyContext calldata c, EngineConfig calldata, bytes32 state)
        external returns (StrategyIntent memory intent)
    {
        intent = StrategyIntent(c.configHash, c.nonce, mode == 1 ? StrategyAction.BuyStock : StrategyAction.SellStock,
            type(uint256).max, state);
        if (mode == 3) intent.nonce = c.nonce + 1;
        if (mode == 4) intent.configHash = bytes32(uint256(c.configHash) ^ 1);
        if (mode == 5) assembly ("memory-safe") { mstore(add(intent, 0x40), 64) return(intent, 160) }
        if (mode == 6) assembly ("memory-safe") { return(intent, 192) }
        if (mode == 7) assembly ("memory-safe") { for {} 1 {} {} }
        if (mode == 8) ++writes;
        if (mode == 9) assembly ("memory-safe") { return(0, 65536) }
    }
}

contract PercentRewardKeeper is IRewardObserver {
    HedgeFunV2AssetPercentEngineTreasury private immutable treasury;
    IERC20 private immutable stock;
    bool public observed;
    constructor(HedgeFunV2AssetPercentEngineTreasury t, IERC20 s) { treasury = t; stock = s; }
    function run() external { treasury.execute(); }
    function onReward() external {
        require(msg.sender == address(stock));
        require(treasury.strategyNonce() == 1 && treasury.lastStrategyAt() == block.timestamp);
        require(treasury.turnoverInEpoch() >= 5e6);
        require(treasury.bookedStock() + treasury.buybackStock() == stock.balanceOf(address(treasury)));
        (bool ok, bytes memory error_) = address(treasury).call(abi.encodeCall(treasury.execute, ()));
        require(!ok && bytes4(error_) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        observed = true;
    }
}

contract V2AssetPercentGuardsTest is V2AssetPercentEngineFixture {
    function _hostile(uint256 mode, uint256 caps, uint96 nonce) private returns (HedgeFunV2AssetPercentEngineTreasury t) {
        address implementation = address(new PercentHostilePolicy(mode, caps));
        vm.prank(owner);
        percentPolicyKey = deployer.registerPolicy(implementation, 150_000, 160,
            keccak256(abi.encode("hostile-deps", mode, caps)), keccak256(abi.encode("hostile-audit", mode, caps)));
        return _launchPercent(nonce, 1000, 5000, 0);
    }

    function test_oversizedSellAndBuyAmountsAreIndependentlyClippedToPercentAndListing() public {
        vm.prank(owner); factory.setListingGates(address(stock), 50, 100, 25e6);
        HedgeFunV2AssetPercentEngineTreasury sale = _hostile(2, 3, 1200);
        (bool due,, uint256 amount) = sale.preview(); assertTrue(due);
        assertLe(Math.mulDiv(amount, PRICE, 1e30), 25e6);
        sale.execute(); assertLe(sale.turnoverInEpoch(), 25e6);
        HedgeFunV2AssetPercentEngineTreasury buy = _hostile(1, 3, 1201);
        usdg.mint(address(buy), _risk(buy).nav * 3);
        (due,, amount) = buy.preview(); assertTrue(due); assertEq(amount, 25e6);
        buy.execute(); assertEq(buy.turnoverInEpoch(), 25e6);
    }

    function test_wrongNonceOrHashCannotConsumeBudgetOrAdvanceState() public {
        _assertWait(_hostile(3, 3, 1202));
        _assertWait(_hostile(4, 3, 1203));
    }

    function test_unsupportedActionAndWrongReturnSizesFailByName() public {
        HedgeFunV2AssetPercentEngineTreasury t = _hostile(5, 3, 1204);
        vm.expectRevert(HedgeFunV2AssetPercentEngineTreasury.BadPolicyReturn.selector); t.execute();
        t = _hostile(6, 3, 1205);
        vm.expectRevert(HedgeFunV2AssetPercentEngineTreasury.BadPolicyReturn.selector); t.execute();
        t = _hostile(9, 3, 1206);
        vm.expectRevert(HedgeFunV2AssetPercentEngineTreasury.BadPolicyReturn.selector); t.execute();
    }

    function test_staticCallGasAndStateWriteBoundaries() public {
        HedgeFunV2AssetPercentEngineTreasury t = _hostile(7, 3, 1207);
        vm.expectRevert(HedgeFunV2AssetPercentEngineTreasury.PolicyFailure.selector); t.execute();
        assertEq(t.strategyNonce(), 0); assertEq(t.turnoverInEpoch(), 0);
        t = _hostile(8, 3, 1208);
        vm.expectRevert(HedgeFunV2AssetPercentEngineTreasury.PolicyFailure.selector); t.execute();
        assertEq(PercentHostilePolicy(t.policyImplementation()).writes(), 0);
        assertEq(t.strategyNonce(), 0); assertEq(t.turnoverInEpoch(), 0);
    }

    function test_policyCapabilityAndCodeHashCannotBeBypassedAtExecution() public {
        HedgeFunV2AssetPercentEngineTreasury t = _hostile(1, 2, 1209); // sells only, proposes buy
        usdg.mint(address(t), _risk(t).nav * 3);
        (bool due,,) = t.preview(); assertFalse(due);
        vm.expectRevert(HedgeFunV2AssetPercentEngineTreasury.BadIntent.selector); t.execute();
        t = _launchPercent(1210, 1000, 5000, 0);
        vm.etch(t.policyImplementation(), hex"00");
        vm.expectRevert(HedgeFunV2AssetPercentEngineTreasury.PolicyUnavailable.selector); t.execute();
        assertEq(t.strategyNonce(), 0); assertEq(t.turnoverInEpoch(), 0);
    }

    function test_inheritedManualTradingEntryPointsRemainClosed() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(1211, 1000, 5000, 0);
        vm.expectRevert(HedgeFunV2Treasury.UseExecute.selector); t.takeProfit(0);
        vm.expectRevert(HedgeFunV2Treasury.UseExecute.selector); t.stopLoss(0);
        vm.expectRevert(HedgeFunV2Treasury.UseExecute.selector); t.buyDip();
    }

    function test_totalNavOverflowAndBuyerDustFailClosedWithoutStateChange() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(1212, 1000, 5000, 0);
        deal(address(usdg), address(t), type(uint256).max);
        Risk memory r = _risk(t); assertFalse(r.healthy); assertEq(r.nav, 0);
        (bool due,,) = t.preview(); assertFalse(due);
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector); t.execute();
        assertEq(t.strategyNonce(), 0); assertEq(t.turnoverInEpoch(), 0);
        // Separate bounded ledger for a partial buy whose actual input is under minLot.
        t = _launchPercent(1213, 1000, 5000, 0);
        usdg.mint(address(t), _risk(t).nav * 3); venue.setFillBps(1);
        uint256 held = t.bookedStock(); uint256 cash = t.reserveUsdg();
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector); t.execute();
        assertEq(t.bookedStock(), held); assertEq(t.reserveUsdg(), cash);
        assertEq(t.turnoverInEpoch(), 0); assertEq(t.strategyNonce(), 0);
    }

    function test_rewardCallbackSeesFinalNetInventoryAndCannotReenter() public {
        HedgeFunV2AssetPercentEngineTreasury t = _launchPercent(1214, 1000, 5000, 0);
        usdg.mint(address(t), _risk(t).nav * 3);
        PercentRewardKeeper keeper = new PercentRewardKeeper(t, IERC20(address(stock)));
        vm.etch(address(stock), address(new RewardCallbackAsset(18)).code);
        RewardCallbackAsset(address(stock)).watch(address(t), address(keeper));
        keeper.run(); assertTrue(keeper.observed()); assertGt(stock.balanceOf(address(keeper)), 0);
    }
}
