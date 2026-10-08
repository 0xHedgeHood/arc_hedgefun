// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {V2LiquidityVault} from "../src/v2/V2LiquidityVault.sol";
import {V2TreasuryUpgradeController} from "../src/v2/V2TreasuryUpgradeController.sol";
import {EngineBinding} from "../src/v2/HedgeFunV2EngineTreasury.sol";
import {EngineConfig} from "../src/v2/strategy/IStrategyPolicy.sol";
import {
    HedgeFunV2TradablePercentEngineTreasury,
    HedgeFunV2TradablePercentEngineTreasuryLogic
} from "../src/v2/HedgeFunV2TradablePercentEngineTreasury.sol";

/// Read-only public RPC; changes exist only in the fork. The first test replaces implementation code locally
/// to compare old/new behavior at exactly the same weekend timestamp. The second uses the real upgrade delay.
abstract contract TestnetV2BuybackForkFixture is Test {
    HedgeFunV2TradablePercentEngineTreasuryLogic internal treasury;
    HedgeFunV2TradablePercentEngineTreasury internal proxy;
    HedgeFunV2TradablePercentEngineTreasuryLogic internal next;
    V2TreasuryUpgradeController internal controller;

    function setUp() public {
        vm.skip(!vm.envOr("WEEKEND_BUYBACK_FORK", false), "set WEEKEND_BUYBACK_FORK=true");
        uint256 number = vm.envUint("WEEKEND_BUYBACK_FORK_BLOCK");
        vm.createSelectFork(vm.envOr("WEEKEND_BUYBACK_FORK_RPC", string("https://rpc.testnet.chain.robinhood.com")), number);
        assertEq(block.chainid, 46630);
        emit log_named_uint("fork block", number);
        treasury = HedgeFunV2TradablePercentEngineTreasuryLogic(
            vm.envOr("WEEKEND_BUYBACK_TREASURY", address(0x1A6803bDBFe57A76c5264aebeb619fFA3Abf2b95))
        );
        proxy = HedgeFunV2TradablePercentEngineTreasury(payable(address(treasury)));
        controller = proxy.treasuryUpgradeController();
        HedgeFunV2Factory factory = HedgeFunV2Factory(treasury.factory());
        EngineConfig memory config = treasury.engineConfig();
        EngineBinding memory binding = EngineBinding({
            config: config,
            manifest: V2TreasuryDeployer(address(factory.treasuryDeployer())).policy(config.policyKey),
            treasury: address(treasury)
        });
        next = new HedgeFunV2TradablePercentEngineTreasuryLogic(
            address(treasury.usdg()), address(treasury.stock()), address(treasury.pool()),
            address(treasury.oracle()), address(treasury.token()), address(treasury.poolManager()),
            address(factory), treasury.params(), binding
        );
        assertLe(address(next).code.length, 24_576);
        assertEq(next.upgradeConfigHash(), proxy.upgradeConfigHash());
    }

}

contract TestnetV2WeekendBuybackForkTest is TestnetV2BuybackForkFixture {
    function test_sameWeekendStateOldCodeRejectsNewCodeBuysFun() public {
        assertTrue(treasury.oracle().calendar().isScheduledClosure(block.timestamp));
        assertEq(treasury.lastGoodPrice(), 0, "reproduce the new pool without an oracle cache");
        assertEq(treasury.params().bandBpsPerHour, 0);
        V2LiquidityVault(treasury.liquidityVault()).collectFees();
        uint256 budget = treasury.buybackStock();
        assertGt(budget, 0, "real accrued LP fees fund this test");
        vm.expectRevert(HedgeFunTreasuryBase.Unhealthy.selector);
        treasury.buyback();

        // A local code overlay isolates the behavior change from any time, price or pool-state change.
        vm.etch(proxy.implementation(), address(next).code);
        IERC20 stock = treasury.stock();
        IERC20 token = treasury.token();
        uint256 balance = stock.balanceOf(address(treasury));
        uint256 principal = balance - budget;
        uint256 booked = treasury.bookedStock();
        uint256 supply = token.totalSupply();
        uint256 nonce = treasury.strategyNonce();
        (uint256 spent, uint256 burned) = treasury.buyback();
        assertGt(spent, 0);
        assertGt(burned, 0);
        assertEq(treasury.buybackStock(), budget - spent);
        assertEq(stock.balanceOf(address(treasury)), balance - spent);
        assertEq(stock.balanceOf(address(treasury)) - treasury.buybackStock(), principal);
        assertEq(treasury.bookedStock(), booked);
        assertEq(treasury.strategyNonce(), nonce);
        assertEq(token.totalSupply(), supply - burned);
        assertEq(treasury.lastGoodPrice(), 0);
        assertEq(treasury.lastGoodPriceAt(), 0);
        emit log_named_uint("spent stock raw", spent);
        emit log_named_uint("burned FUN raw", burned);
        emit log_named_uint("stock USDG TWAP 1e18", treasury.twapPrice());
    }

    function test_candidateCanUpgradeThroughExistingControllerAfterDelay() public {
        uint256 balance = treasury.stock().balanceOf(address(treasury));
        uint256 booked = treasury.bookedStock();
        uint256 budget = treasury.buybackStock();
        bytes32 terms = keccak256(abi.encode(treasury.params(), treasury.engineConfig()));
        vm.prank(controller.owner());
        controller.schedule(address(proxy), address(next), "");
        vm.expectRevert(V2TreasuryUpgradeController.NotReady.selector);
        controller.execute(address(proxy), "");
        vm.warp(block.timestamp + controller.UPGRADE_DELAY());
        controller.execute(address(proxy), "");
        assertEq(proxy.implementation(), address(next));
        assertEq(treasury.stock().balanceOf(address(treasury)), balance);
        assertEq(treasury.bookedStock(), booked);
        assertEq(treasury.buybackStock(), budget);
        assertEq(keccak256(abi.encode(treasury.params(), treasury.engineConfig())), terms);
    }
}
