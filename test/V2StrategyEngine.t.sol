// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HedgeFunFactory} from "../src/HedgeFunFactory.sol";
import {HedgeFunTreasuryBase} from "../src/HedgeFunTreasuryBase.sol";
import {HedgeFunBondingCurve} from "../src/v2/HedgeFunBondingCurve.sol";
import {HedgeFunV2BuybackTreasury} from "../src/v2/HedgeFunV2BuybackTreasury.sol";
import {HedgeFunV2EngineTreasury, HedgeFunV2EngineTreasuryCore} from "../src/v2/HedgeFunV2EngineTreasury.sol";
import {HedgeFunV2Treasury} from "../src/v2/HedgeFunV2Treasury.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {
    EngineConfig,
    PolicyManifest,
    StrategyAction,
    StrategyCapabilities
} from "../src/v2/strategy/IStrategyPolicy.sol";
import {V2RebalancePolicy} from "../src/v2/strategy/V2RebalancePolicy.sol";
import {ISwapCallback, MockLpPool} from "./mocks/Mocks.sol";
import {
    ExcessiveAmountStrategyPolicy,
    HonestHoldPolicy,
    HugeReturnStrategyPolicy,
    OptionsActionStrategyPolicy,
    RevertingStrategyPolicy,
    SpotRawActionStrategyPolicy,
    StateWritingStrategyPolicy,
    WrongConfigHashStrategyPolicy,
    WrongLengthIntentStrategyPolicy
} from "./mocks/StrategyPolicyMocks.sol";
import {V2FactoryFixture} from "./utils/V2FactoryFixture.sol";

/// @dev Adds exact-input swaps to the fixture's LP-capable V3 venue. Token0 is stock and token1 is USDG.
contract EngineVenue is MockLpPool {
    uint256 internal immutable scale;
    uint256 public price;

    constructor(address stock, address usdg, uint24 fee_, uint256 scale_, uint256 price_)
        MockLpPool(stock, usdg, fee_)
    {
        scale = scale_;
        price = price_;
        sqrtPriceX96 = uint160(Math.sqrt(Math.mulDiv(price_, 1 << 192, scale_)));
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 limit, bytes calldata data)
        external
        returns (int256 a0, int256 a1)
    {
        require(amountSpecified > 0, "exact input");
        require(zeroForOne ? limit < sqrtPriceX96 : limit > sqrtPriceX96, "SPL");
        uint256 amountIn = uint256(amountSpecified);
        uint256 net = amountIn * (1_000_000 - fee) / 1_000_000;
        uint256 amountOut = zeroForOne ? Math.mulDiv(net, price, scale) : Math.mulDiv(net, scale, price);
        IERC20(zeroForOne ? token1 : token0).transfer(recipient, amountOut);
        (a0, a1) = zeroForOne ? (int256(amountIn), -int256(amountOut)) : (-int256(amountOut), int256(amountIn));
        IERC20 input = IERC20(zeroForOne ? token0 : token1);
        uint256 beforeBalance = input.balanceOf(address(this));
        ISwapCallback(msg.sender).uniswapV3SwapCallback(a0, a1, data);
        require(input.balanceOf(address(this)) >= beforeBalance + amountIn, "IIA");
    }
}

contract V2StrategyEngineTest is V2FactoryFixture {
    V2TreasuryDeployer internal deployer;
    V2RebalancePolicy internal policyImplementation;
    EngineVenue internal venue;
    bytes32 internal policyKey;
    uint8 internal engineKind;

    function setUp() public {
        _setUpV2(18);
        venue = new EngineVenue(address(stock), address(usdg), 3000, 1e30, 100e18);
        stockPool = venue;
        v3f.set(address(stock), address(usdg), 3000, address(venue));
        vm.prank(owner);
        factory.list(address(stock), address(oracle), address(venue), openPrice, true);
        usdg.mint(address(venue), 10_000_000e6);
        stock.mint(address(venue), 100_000e18);

        deployer = V2TreasuryDeployer(address(factory.treasuryDeployer()));
        (address buybackA, address buybackB) = deployer.makeChunks(type(HedgeFunV2BuybackTreasury).creationCode);
        policyImplementation = new V2RebalancePolicy();
        vm.startPrank(owner);
        assertEq(deployer.registerKind(buybackA, buybackB), 1);
        policyKey = deployer.registerPolicy(
            address(policyImplementation),
            150_000,
            deployer.POLICY_RETURN_BYTES(),
            keccak256("rebalance-dependencies-v1"),
            keccak256("rebalance-audit-v1")
        );
        (address engineA, address engineB) = deployer.makeChunks(type(HedgeFunV2EngineTreasury).creationCode);
        engineKind = deployer.registerEngineKind(
            engineA,
            engineB,
            StrategyCapabilities.SPOT_ENGINE_V1,
            StrategyCapabilities.CONFIG_SCHEMA_V1,
            StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL
        );
        vm.stopPrank();
        assertEq(engineKind, 2);
    }

    function _config() internal view returns (EngineConfig memory config) {
        config.schema = StrategyCapabilities.CONFIG_SCHEMA_V1;
        config.engineVersion = StrategyCapabilities.SPOT_ENGINE_V1;
        config.policyKey = policyKey;
        config.words[0] = bytes32(uint256(5000) | uint256(500) << 16 | uint256(600) << 32);
        config.words[1] = bytes32(uint256(100e6));
        config.words[2] = bytes32(uint256(500e6));
    }

    function _select(HedgeFunFactory.Request memory q) internal {
        deployer.setEngineConfig(q.symbol, q.nonce, engineKind, _config());
    }

    function _registerTestPolicy(address implementation, bytes32 label) internal returns (bytes32 key) {
        vm.prank(owner);
        key = deployer.registerPolicy(
            implementation,
            400_000,
            160,
            keccak256(abi.encode("test-dependencies", label)),
            keccak256(abi.encode("test-audit", label))
        );
    }

    function _launchTestPolicy(address implementation, bytes32 label, uint96 nonce)
        internal
        returns (HedgeFunV2EngineTreasury treasury)
    {
        policyKey = _registerTestPolicy(implementation, label);
        HedgeFunFactory.Request memory q = _request();
        q.nonce = nonce;
        HedgeFunBondingCurve curve;
        (treasury, curve) = _launchEngine(q);
        _graduateV2(curve);
    }

    function _launchEngine(HedgeFunFactory.Request memory q)
        internal
        returns (HedgeFunV2EngineTreasury treasury, HedgeFunBondingCurve curve)
    {
        _select(q);
        (, address predicted, bytes32 terms) = factory.predict(q);
        uint256 id = factory.launch(q, terms);
        (, address deployed,,,) = factory.strategies(id);
        assertEq(deployed, predicted);
        treasury = HedgeFunV2EngineTreasury(deployed);
        curve = HedgeFunBondingCurve(factory.curves(id));
        stock.approve(address(curve), type(uint256).max);
    }

    function test_registryAndCreate2BindTheExactCorePolicyAndConfig() public {
        HedgeFunFactory.Request memory q = _request();
        (, address kindZero,) = factory.predict(q);
        _select(q);
        (, address predicted, bytes32 terms) = factory.predict(q);
        assertTrue(predicted != kindZero);
        uint256 id = factory.launch(q, terms);
        (, address deployed,,,) = factory.strategies(id);
        HedgeFunV2EngineTreasury treasury = HedgeFunV2EngineTreasury(deployed);
        assertEq(deployed, predicted);
        assertEq(treasury.engineVersion(), StrategyCapabilities.SPOT_ENGINE_V1);
        assertEq(treasury.strategyId(), policyKey);
        assertTrue(treasury.configHash() != bytes32(0));
        assertEq(treasury.policyImplementation(), address(policyImplementation));
        assertEq(treasury.policyRuntimeCodeHash(), address(policyImplementation).codehash);
        assertEq(deployer.strategyKindOf(keccak256(abi.encode(q.symbol, address(this), q.nonce))), engineKind);

        EngineConfig memory frozen = treasury.engineConfig();
        assertEq(frozen.policyKey, policyKey);
        assertEq(frozen.words[0], _config().words[0]);
        (uint32 engineVersion, uint32 schema, bytes32 creationHash, uint256 capabilities) =
            deployer.kindManifest(engineKind);
        assertEq(engineVersion, StrategyCapabilities.SPOT_ENGINE_V1);
        assertEq(schema, StrategyCapabilities.CONFIG_SCHEMA_V1);
        assertEq(creationHash, keccak256(type(HedgeFunV2EngineTreasury).creationCode));
        assertEq(capabilities, StrategyCapabilities.SPOT_BUY | StrategyCapabilities.SPOT_SELL);
    }

    function test_engineSelectionRestatesQuoteAndLegacySetterCannotSkipConfig() public {
        HedgeFunFactory.Request memory q = _request();
        (,, bytes32 oldTerms) = factory.predict(q);
        vm.expectRevert(V2TreasuryDeployer.BadKind.selector);
        deployer.setStrategyKind(q.symbol, q.nonce, engineKind);
        _select(q);
        vm.expectRevert(HedgeFunFactory.Restated.selector);
        factory.launch(q, oldTerms);
    }

    function test_policyDisableBlocksFutureLaunchesButCannotRewriteALaunchedTreasury() public {
        HedgeFunFactory.Request memory q = _request();
        (HedgeFunV2EngineTreasury treasury,) = _launchEngine(q);
        vm.prank(owner);
        deployer.disablePolicy(policyKey);
        PolicyManifest memory manifest = deployer.policy(policyKey);
        assertFalse(manifest.enabledForNewLaunches);
        assertEq(treasury.policyImplementation(), address(policyImplementation));

        q.nonce++;
        vm.expectRevert(V2TreasuryDeployer.BadPolicy.selector);
        _select(q);
    }

    function test_optionsCapabilityCannotEnterTheSpotEngine() public {
        OptionsActionStrategyPolicy optionsPolicy = new OptionsActionStrategyPolicy();
        vm.prank(owner);
        bytes32 optionsKey = deployer.registerPolicy(
            address(optionsPolicy), 100_000, 160, keccak256("options-dependencies-v1"), keccak256("options-audit-v1")
        );
        EngineConfig memory config = _config();
        config.policyKey = optionsKey;
        HedgeFunFactory.Request memory q = _request();
        vm.expectRevert(V2TreasuryDeployer.BadPolicy.selector);
        deployer.setEngineConfig(q.symbol, q.nonce, engineKind, config);
    }

    function test_policyCodeReplacementFailsBeforePredictionOrLaunch() public {
        vm.etch(address(policyImplementation), hex"00");
        HedgeFunFactory.Request memory q = _request();
        vm.expectRevert(V2TreasuryDeployer.BadPolicy.selector);
        _select(q);
    }

    function test_coreRejectsReservedConfigBitsEvenWhenPolicyWouldIgnoreThem() public {
        HonestHoldPolicy permissivePolicy = new HonestHoldPolicy();
        vm.prank(owner);
        bytes32 permissiveKey = deployer.registerPolicy(
            address(permissivePolicy),
            100_000,
            160,
            keccak256("permissive-dependencies-v1"),
            keccak256("permissive-audit-v1")
        );
        EngineConfig memory config = _config();
        config.policyKey = permissiveKey;
        config.words[0] |= bytes32(uint256(1) << 80); // the lowest reserved bit: 64..79 are `payoutBps`
        HedgeFunFactory.Request memory q = _request();
        // the deployer runs the core constructor's own word check, so the refusal is named and comes before any quote
        vm.expectRevert(V2TreasuryDeployer.BadEngineConfig.selector);
        deployer.setEngineConfig(q.symbol, q.nonce, engineKind, config);
    }

    function test_revertingPolicyCannotConsumeNonceOrMoveAssets() public {
        HedgeFunV2EngineTreasury treasury =
            _launchTestPolicy(address(new RevertingStrategyPolicy()), keccak256("reverting-policy"), 20);
        uint256 stockBefore = stock.balanceOf(address(treasury));
        uint256 usdgBefore = usdg.balanceOf(address(treasury));
        vm.expectRevert(HedgeFunV2EngineTreasuryCore.PolicyFailure.selector);
        treasury.execute();
        assertEq(treasury.strategyNonce(), 0);
        assertEq(stock.balanceOf(address(treasury)), stockBefore);
        assertEq(usdg.balanceOf(address(treasury)), usdgBefore);
    }

    function test_hugePolicyReturndataIsRejectedBeforeCopyOrStateChange() public {
        HedgeFunV2EngineTreasury treasury =
            _launchTestPolicy(address(new HugeReturnStrategyPolicy()), keccak256("huge-return-policy"), 21);
        vm.expectRevert(HedgeFunV2EngineTreasuryCore.BadPolicyReturn.selector);
        treasury.execute();
        assertEq(treasury.strategyNonce(), 0);
        assertEq(treasury.turnoverInEpoch(), 0);
    }

    /// Audit round 4 E-5: an undeclared action word is refused by name before the enum decode, at execute and at
    /// preview. `abi.decode` alone would refuse it with empty revert data a keeper cannot tell from out-of-gas.
    function test_outOfRangeActionWordIsABadPolicyReturnNotAnEmptyRevert() public {
        HedgeFunV2EngineTreasury treasury =
            _launchTestPolicy(address(new SpotRawActionStrategyPolicy()), keccak256("raw-action-policy"), 25);
        uint256 stockBefore = stock.balanceOf(address(treasury));
        uint256 usdgBefore = usdg.balanceOf(address(treasury));
        vm.expectRevert(HedgeFunV2EngineTreasuryCore.BadPolicyReturn.selector);
        treasury.execute();
        vm.expectRevert(HedgeFunV2EngineTreasuryCore.BadPolicyReturn.selector);
        treasury.preview();
        assertEq(treasury.strategyNonce(), 0);
        assertEq(treasury.lastStrategyAt(), 0);
        assertEq(stock.balanceOf(address(treasury)), stockBefore);
        assertEq(usdg.balanceOf(address(treasury)), usdgBefore);
    }

    /// The exact-size check, pinned on its own: a valid intent one byte short or one word long is refused by name.
    /// Without the check the long one would sell and the short one would fail in the decoder with empty data.
    function test_intentOfTheWrongLengthIsABadPolicyReturnEvenWhenItsWordsAreValid() public {
        HedgeFunV2EngineTreasury short_ =
            _launchTestPolicy(address(new WrongLengthIntentStrategyPolicy(159)), keccak256("short-intent-policy"), 26);
        vm.expectRevert(HedgeFunV2EngineTreasuryCore.BadPolicyReturn.selector);
        short_.execute();
        HedgeFunV2EngineTreasury long_ =
            _launchTestPolicy(address(new WrongLengthIntentStrategyPolicy(192)), keccak256("long-intent-policy"), 27);
        uint256 stockBefore = long_.bookedStock();
        vm.expectRevert(HedgeFunV2EngineTreasuryCore.BadPolicyReturn.selector);
        long_.execute();
        assertEq(long_.bookedStock(), stockBefore);
        assertEq(short_.strategyNonce() + long_.strategyNonce(), 0);
        // control: the same intent at exactly 160 bytes is a sale
        HedgeFunV2EngineTreasury exact =
            _launchTestPolicy(address(new WrongLengthIntentStrategyPolicy(160)), keccak256("exact-intent-policy"), 28);
        exact.execute();
        assertEq(exact.strategyNonce(), 1);
    }

    function test_staticcallTrapsPolicyStateWrites() public {
        StateWritingStrategyPolicy stateful = new StateWritingStrategyPolicy();
        HedgeFunV2EngineTreasury treasury = _launchTestPolicy(address(stateful), keccak256("state-writing-policy"), 22);
        vm.expectRevert(HedgeFunV2EngineTreasuryCore.PolicyFailure.selector);
        treasury.execute();
        assertEq(stateful.writes(), 0);
        assertEq(treasury.strategyNonce(), 0);
    }

    function test_wrongCommitmentAndExcessiveAmountBothFailClosedAtTheCore() public {
        HedgeFunV2EngineTreasury wrongHash =
            _launchTestPolicy(address(new WrongConfigHashStrategyPolicy()), keccak256("wrong-hash-policy"), 23);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        wrongHash.execute();
        assertEq(wrongHash.strategyNonce(), 0);

        HedgeFunV2EngineTreasury excessive =
            _launchTestPolicy(address(new ExcessiveAmountStrategyPolicy()), keccak256("excessive-amount-policy"), 24);
        uint256 stockValue = Math.mulDiv(excessive.bookedStock(), 100e18, 1e30);
        usdg.mint(address(excessive), stockValue * 3);
        uint256 usdgBefore = excessive.reserveUsdg();
        excessive.execute();
        assertEq(usdgBefore - excessive.reserveUsdg(), 100e6, "core must cap a uint256.max policy request");
        assertEq(excessive.turnoverInEpoch(), 100e6);
    }

    function test_graduatedOverweightEngineSellsOneBoundedChunkAndAccountsTheFill() public {
        HedgeFunFactory.Request memory q = _request();
        (HedgeFunV2EngineTreasury treasury, HedgeFunBondingCurve curve) = _launchEngine(q);
        _graduateV2(curve);
        uint256 stockBefore = treasury.bookedStock();
        uint256 usdgBefore = treasury.reserveUsdg();
        assertGt(stockBefore, 0);
        (bool due, StrategyAction proposed, uint256 proposedInput) = treasury.preview();
        assertTrue(due);
        assertEq(uint256(proposed), uint256(StrategyAction.SellStock));
        assertGt(proposedInput, 0);

        (HedgeFunV2Treasury.Action action, uint256 nonce) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.RebalanceSell));
        assertEq(nonce, 1);
        assertLt(treasury.bookedStock(), stockBefore);
        assertGt(treasury.reserveUsdg(), usdgBefore);
        assertGt(treasury.turnoverInEpoch(), 0);
        assertLe(treasury.turnoverInEpoch(), 100e6);
        vm.expectRevert(HedgeFunTreasuryBase.NotDue.selector);
        treasury.execute();
    }

    function test_underweightEngineBuysStockButPolicyCannotExceedCoreCap() public {
        HedgeFunFactory.Request memory q = _request();
        q.nonce = 1;
        (HedgeFunV2EngineTreasury treasury, HedgeFunBondingCurve curve) = _launchEngine(q);
        _graduateV2(curve);
        uint256 stockValue = Math.mulDiv(treasury.bookedStock(), 100e18, 1e30);
        usdg.mint(address(treasury), stockValue * 3);
        uint256 stockBefore = treasury.bookedStock();
        uint256 usdgBefore = treasury.reserveUsdg();
        (bool due, StrategyAction proposed, uint256 proposedInput) = treasury.preview();
        assertTrue(due);
        assertEq(uint256(proposed), uint256(StrategyAction.BuyStock));
        assertEq(proposedInput, 100e6);

        (HedgeFunV2Treasury.Action action,) = treasury.execute();
        assertEq(uint256(action), uint256(HedgeFunV2Treasury.Action.RebalanceBuy));
        assertGt(treasury.bookedStock(), stockBefore);
        assertEq(usdgBefore - treasury.reserveUsdg(), 100e6);
        assertEq(treasury.turnoverInEpoch(), 100e6);
    }
}
