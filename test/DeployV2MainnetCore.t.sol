// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HedgeFunFactory, TokenDeployer} from "../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../src/v2/HedgeFunV2Factory.sol";
import {HedgeFunV2Hook} from "../src/hooks/HedgeFunV2Hook.sol";
import {V2TreasuryDeployer} from "../src/v2/V2TreasuryDeployer.sol";
import {CurveDeployer} from "../src/v2/CurveDeployer.sol";
import {HedgeFunV2TradeRouter} from "../src/v2/HedgeFunV2TradeRouter.sol";
import {HedgeFunV2NativeRouter, IWrappedNative} from "../src/v2/HedgeFunV2NativeRouter.sol";
import {MockToken, MockV3Factory} from "./mocks/Mocks.sol";
import {V2MainnetCore} from "../script/mainnet/V2MainnetCore.sol";
import {V2MainnetDefaults} from "../script/mainnet/V2MainnetDefaults.sol";
import {
    DeployV2MainnetCore,
    VerifyV2MainnetCore,
    HandOverV2Mainnet,
    VerifyV2MainnetHandOver
} from "../script/mainnet/DeployV2MainnetCore.s.sol";
import {RehearseV2Launchpad} from "../script/mainnet/RehearseV2Launchpad.s.sol";
import {V2LaunchFeeDefaults} from "../script/testnet/V2LaunchFeeDefaults.sol";
import {RegisterV2UpgradeableKinds} from "../script/RegisterV2UpgradeableKinds.s.sol";
import {RegisterV2TradablePercent} from "../script/RegisterV2TradablePercent.s.sol";
import {RegisterV2PercentBuyback} from "../script/RegisterV2PercentBuyback.s.sol";
import {RegisterV2UpgradeableCycle} from "../script/RegisterV2UpgradeableCycle.s.sol";

/// Answers the two calls the deployment asks a Safe, and takes native currency as a Safe does.
contract SafeLike {
    uint256 private immutable threshold;
    uint256 private immutable count;

    constructor(uint256 threshold_, uint256 count_) { (threshold, count) = (threshold_, count_); }

    function getThreshold() external view returns (uint256) { return threshold; }
    function getOwners() external view returns (address[] memory owners) { owners = new address[](count); }
    function accept(HedgeFunV2Factory factory) external { factory.acceptOwnership(); }
    function open(HedgeFunV2Factory factory) external { factory.setPublicLaunch(true); }
    receive() external payable {}
}

/// A multisig that cannot be paid: every native launch fee sent to it would revert the launch.
contract SafeThatRefusesNative {
    function getThreshold() external pure returns (uint256) { return 2; }
    function getOwners() external pure returns (address[] memory owners) { owners = new address[](3); }
}

contract WrappedNative is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }
}

/// The deployment's own storage is not visible to a test; this exposes its constants and defaults.
contract MainnetCoreProbe is V2MainnetCore {
    function defaultsHash() external pure returns (bytes32) { return keccak256(abi.encode(_defaults())); }
}

/// `V2MainnetCore._deployCore` except for the one argument a mis-edit of `V2MainnetDefaults.SALE_BPS`, or a
/// deployment from another branch, would change. No readback: the tests run the scripts' own.
contract OtherSaleShareCore is V2MainnetCore {
    function deployWith(uint16 sale, address deployer, Roles memory r) external returns (Deployed memory x) {
        HedgeFunFactory.Defaults memory d = _defaults();
        (bytes32 salt,) = _mineHook(0);
        vm.startBroadcast(deployer);
        x.hookSalt = salt;
        x.treasury = new V2TreasuryDeployer();
        x.token = new TokenDeployer();
        x.curve = new CurveDeployer(sale);
        x.hook = new HedgeFunV2Hook{salt: salt}(IPoolManager(PM));
        x.factory = new HedgeFunV2Factory(
            deployer, PM, V3_FACTORY, USDG, r.protocol, address(x.treasury), address(x.token), address(x.hook),
            address(x.curve), d
        );
        x.router = new HedgeFunV2TradeRouter(x.factory);
        x.nativeRouter = new HedgeFunV2NativeRouter(x.router, IWrappedNative(r.weth));
        vm.stopBroadcast();
    }
}

/// Offline: the chain's fixed dependencies are placed at the addresses the mainnet scripts pin.
contract DeployV2MainnetCoreTest is Test {
    address deployer = makeAddr("mainnet deployer");
    SafeLike owner;
    SafeLike protocol;
    WrappedNative weth;
    DeployV2MainnetCore script;
    MainnetCoreProbe probe;
    bytes32 reviewed;

    function setUp() public {
        vm.chainId(4663);
        probe = new MainnetCoreProbe();
        _deployAt(bytes.concat(type(PoolManager).creationCode, abi.encode(address(this))), probe.PM());
        vm.etch(probe.V3_FACTORY(), address(new MockV3Factory()).code);
        _deployAt(bytes.concat(type(MockToken).creationCode, abi.encode("USDG", uint8(6))), probe.USDG());
        owner = new SafeLike(2, 3);
        protocol = new SafeLike(3, 5);
        weth = new WrappedNative();
        script = new DeployV2MainnetCore();
        reviewed = probe.defaultsHash();
    }

    /// run the constructor AT `where`, so immutables that record the contract's own address hold that address
    function _deployAt(bytes memory creation, address where) internal {
        vm.etch(where, creation);
        (bool ok, bytes memory runtime) = where.call("");
        require(ok, "constructor");
        vm.etch(where, runtime);
    }

    function _roles() internal view returns (V2MainnetCore.Roles memory) {
        return V2MainnetCore.Roles(address(owner), address(protocol), address(weth));
    }

    function test_safeOwnsFromBirth_closedEmptyAndTheDeployerHoldsNothing() public {
        V2MainnetCore.Deployed memory x = script.deploy(deployer, _roles(), false, reviewed, 7931, 0);
        HedgeFunV2Factory f = x.factory;
        assertEq(f.owner(), address(owner));
        assertEq(f.pendingOwner(), address(0));
        assertEq(f.protocol(), address(protocol));
        assertFalse(f.publicLaunch());
        assertEq(f.strategyCount(), 0);
        assertEq(x.treasury.kindCount(), 1, "kind 0 only");
        assertEq(x.treasury.upgradeController().owner(), address(owner));
        assertEq(uint160(address(x.hook)) & 0x3FFF, script.HOOK_FLAGS());
        assertEq(address(x.nativeRouter.wrappedNative()), address(weth));
        assertEq(keccak256(abi.encode(f.getDefaults())), reviewed);
        assertEq(address(script).balance, 0, "the probes leave nothing behind");
        assertEq(weth.totalSupply(), 0);
        assertEq(address(protocol).balance, 0);

        // The deploying key cannot do anything an owner can.
        vm.startPrank(deployer);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", deployer));
        f.setPublicLaunch(true);
        vm.expectRevert(V2TreasuryDeployer.NotOwner.selector);
        x.treasury.registerKind(address(1), address(2));
        vm.stopPrank();

        new VerifyV2MainnetCore().check(x, address(owner), _roles(), reviewed, 7931);
        new VerifyV2MainnetHandOver().check(f, address(owner));
    }

    /// The path the registration scripts need: they broadcast as the factory owner, which a Safe cannot do.
    function test_deployerSetsUp_registersEveryUpgradeableKind_thenHandsOverBeforeLaunchOpens() public {
        V2MainnetCore.Deployed memory x = script.deploy(deployer, _roles(), true, reviewed, 7931, 0);
        HedgeFunV2Factory f = x.factory;
        assertEq(f.owner(), deployer);
        assertFalse(f.publicLaunch());
        new VerifyV2MainnetCore().check(x, deployer, _roles(), reviewed, 7931);

        // The existing, chain-agnostic registration scripts accept a core deployed by this script.
        RegisterV2UpgradeableKinds.Kinds memory k = new RegisterV2UpgradeableKinds().register(deployer, f);
        assertEq(k.buyback, 1);
        assertEq(k.engine, 2);
        RegisterV2TradablePercent.Registration memory rebalance = new RegisterV2TradablePercent().register(
            deployer, f, keccak256("mainnet test dependencies"), keccak256("mainnet test audit")
        );
        assertEq(rebalance.kind, 3);
        assertEq(new RegisterV2PercentBuyback().register(deployer, f), 4);
        assertEq(new RegisterV2UpgradeableCycle().register(deployer, f), 5);
        assertEq(x.treasury.kindCount(), 6);

        HandOverV2Mainnet handOver = new HandOverV2Mainnet();
        vm.expectRevert(abi.encodeWithSelector(HandOverV2Mainnet.NotFactoryOwner.selector, address(this)));
        handOver.handOver(address(this), f, address(owner));
        vm.expectRevert(abi.encodeWithSelector(V2MainnetCore.UnsafeRole.selector, makeAddr("a key")));
        handOver.handOver(deployer, f, makeAddr("a key"));
        handOver.handOver(deployer, f, address(owner));
        assertEq(f.owner(), deployer, "nothing moves until the Safe accepts");
        assertEq(f.pendingOwner(), address(owner));
        VerifyV2MainnetHandOver verify = new VerifyV2MainnetHandOver();
        vm.expectRevert(abi.encodeWithSelector(V2MainnetCore.ReadbackFailed.selector, "owner"));
        verify.check(f, address(owner));

        uint256 epoch = f.ownershipEpoch();
        owner.accept(f);
        assertEq(f.owner(), address(owner));
        assertEq(f.ownershipEpoch(), epoch + 1, "an upgrade scheduled by the deployer cannot execute");
        assertEq(x.treasury.upgradeController().owner(), address(owner));
        verify.check(f, address(owner));
        assertEq(x.treasury.kindCount(), 6, "registrations are the registry's and stay");
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", deployer));
        f.setPublicLaunch(true);
        owner.open(f);
        assertTrue(f.publicLaunch());
    }

    function test_handOverIsRefusedOnceLaunchIsOpen() public {
        V2MainnetCore.Deployed memory x = script.deploy(deployer, _roles(), true, reviewed, 7931, 0);
        vm.prank(deployer);
        x.factory.setPublicLaunch(true);
        HandOverV2Mainnet handOver = new HandOverV2Mainnet();
        vm.expectRevert(HandOverV2Mainnet.LaunchAlreadyOpen.selector);
        handOver.handOver(deployer, x.factory, address(owner));
    }

    function test_refusesEveryOtherChain() public {
        uint256[3] memory chains = [uint256(46630), 31337, 1];
        for (uint256 i; i < chains.length; ++i) {
            vm.chainId(chains[i]);
            vm.expectRevert(abi.encodeWithSelector(DeployV2MainnetCore.WrongChain.selector, chains[i]));
            script.deploy(deployer, _roles(), false, reviewed, 7931, 0);
        }
    }

    function test_refusesDefaultsNobodyReviewed() public {
        vm.expectRevert(abi.encodeWithSelector(DeployV2MainnetCore.DefaultsNotReviewed.selector, reviewed));
        script.deploy(deployer, _roles(), false, keccak256("some other defaults"), 7931, 0);
    }

    function test_refusesASaleShareNobodyReviewed() public {
        vm.expectRevert(abi.encodeWithSelector(DeployV2MainnetCore.SaleShareNotReviewed.selector, uint16(7931)));
        script.deploy(deployer, _roles(), false, reviewed, 4400, 0);
        V2MainnetCore.Deployed memory x = script.deploy(deployer, _roles(), true, reviewed, 7931, 0);
        assertEq(x.curve.DEFAULT_SALE_BPS(), 7931);
        assertEq(x.treasury.DEFAULT_LP_BPS(), 7000);
        VerifyV2MainnetCore verify = new VerifyV2MainnetCore();
        vm.expectRevert(abi.encodeWithSelector(VerifyV2MainnetCore.SaleShareNotReviewed.selector, uint16(7931)));
        verify.check(x, deployer, _roles(), reviewed, 4400);
    }

    /// The sale share is permanent and the defaults hash does not cover it: a core whose curve deployer carries
    /// another one has the reviewed defaults, and is still refused by the readback every script shares.
    function test_verificationRefusesACoreBuiltWithAnotherSaleShare() public {
        V2MainnetCore.Deployed memory x = new OtherSaleShareCore().deployWith(4400, deployer, _roles());
        assertEq(keccak256(abi.encode(x.factory.getDefaults())), reviewed, "the defaults are the reviewed ones");
        assertEq(x.curve.DEFAULT_SALE_BPS(), 4400);
        VerifyV2MainnetCore verify = new VerifyV2MainnetCore();
        vm.expectRevert(abi.encodeWithSelector(V2MainnetCore.ReadbackFailed.selector, "sale share"));
        verify.check(x, deployer, _roles(), reviewed, 7931);
    }

    function test_refusesRolesThatAreNotMultisigs() public {
        V2MainnetCore.Roles memory r = _roles();
        r.owner = makeAddr("an owner key");
        vm.expectRevert(abi.encodeWithSelector(V2MainnetCore.UnsafeRole.selector, r.owner));
        script.deploy(deployer, r, false, reviewed, 7931, 0);

        r = _roles();
        r.protocol = address(new SafeLike(1, 3)); // one signature moves the fees
        vm.expectRevert(abi.encodeWithSelector(V2MainnetCore.UnsafeRole.selector, r.protocol));
        script.deploy(deployer, r, false, reviewed, 7931, 0);

        r = _roles();
        r.owner = address(new SafeLike(4, 3)); // a threshold nobody can meet
        vm.expectRevert(abi.encodeWithSelector(V2MainnetCore.UnsafeRole.selector, r.owner));
        script.deploy(deployer, r, false, reviewed, 7931, 0);

        // the key that deploys is not one of the Safes, in either mode
        vm.expectRevert(abi.encodeWithSelector(V2MainnetCore.UnsafeRole.selector, address(owner)));
        script.deploy(address(owner), _roles(), true, reviewed, 7931, 0);
    }

    function test_refusesAWrappedNativeThatDoesNotWrap() public {
        V2MainnetCore.Roles memory r = _roles();
        r.weth = address(new MockToken("WETH", 18)); // right name and decimals, no deposit
        vm.expectRevert(abi.encodeWithSelector(V2MainnetCore.BadWrappedNative.selector, r.weth));
        script.deploy(deployer, r, false, reviewed, 7931, 0);

        r.weth = script.USDG();
        vm.expectRevert(abi.encodeWithSelector(V2MainnetCore.BadWrappedNative.selector, r.weth));
        script.deploy(deployer, r, false, reviewed, 7931, 0);

        r.weth = makeAddr("no code");
        vm.expectRevert(abi.encodeWithSelector(V2MainnetCore.BadWrappedNative.selector, r.weth));
        script.deploy(deployer, r, false, reviewed, 7931, 0);
    }

    /// The launch fee is native and `protocol` is immutable: a recipient that cannot take it refuses every launch.
    function test_refusesAProtocolRecipientThatCannotTakeTheNativeFee() public {
        V2MainnetCore.Roles memory r = _roles();
        r.protocol = address(new SafeThatRefusesNative());
        vm.expectRevert(abi.encodeWithSelector(V2MainnetCore.ProtocolRefusesNative.selector, r.protocol));
        script.deploy(deployer, r, false, reviewed, 7931, 0);
    }

    function test_refusesAMissingChainDependency() public {
        vm.etch(script.V3_FACTORY(), "");
        vm.expectRevert(abi.encodeWithSelector(V2MainnetCore.MissingCode.selector, script.V3_FACTORY()));
        script.deploy(deployer, _roles(), false, reviewed, 7931, 0);
    }

    /// The mainnet defaults are their own explicit copy. They must still say what the release fee choices say.
    function test_releaseDefaultsAreTheReleaseFeeChoicesAndTheOnePercentBaseTax() public pure {
        assertEq(V2MainnetDefaults.release().bountyBps, 10, "a 0.1% keeper reward");
        HedgeFunFactory.Defaults memory d = V2MainnetDefaults.release();
        assertEq(
            keccak256(abi.encode(V2LaunchFeeDefaults.applyTo(V2MainnetDefaults.release()))), keccak256(abi.encode(d))
        );
        assertEq(uint8(d.launchFeeCurrency), uint8(HedgeFunFactory.FeeCurrency.Native));
        assertEq(d.launchFeeAmount, 0.0005 ether);
        assertEq(d.maxCreatorBps, 5000);
        assertEq(d.minTaxBps, 100);
        assertEq(d.maxTaxBps, 1500);
        assertEq(d.protocolBps, 3000);
        assertEq(d.lpFee, 2000);
        assertEq(d.buybackCooldown, 10);
        assertEq(d.sweepTipBps, 0);
    }

    /// The rehearsal runs the same core code on a local fork, in both ownership modes, and broadcasts nothing.
    function test_rehearsalRunsTheSameCoreOnALocalForkOnly() public {
        RehearseV2Launchpad rehearsal = new RehearseV2Launchpad();
        address calendar = address(protocol); // any contract: the core does not use it, an oracle will
        vm.expectRevert(RehearseV2Launchpad.ForkOnly.selector);
        rehearsal.rehearse(deployer, _roles(), calendar, false, 0);

        vm.chainId(31337);
        uint256 snapshot = vm.snapshotState();
        V2MainnetCore.Deployed memory x = rehearsal.rehearse(deployer, _roles(), calendar, false, 0);
        assertEq(x.factory.owner(), address(owner));
        assertEq(x.treasury.kindCount(), 2, "kind 0, and the owner's kind-1 registration rehearsed");
        assertFalse(x.factory.publicLaunch());
        vm.revertToState(snapshot);

        x = rehearsal.rehearse(deployer, _roles(), calendar, true, 0);
        assertEq(x.factory.owner(), deployer);
        assertEq(x.treasury.kindCount(), 2);

        vm.expectRevert(abi.encodeWithSelector(V2MainnetCore.MissingCode.selector, makeAddr("no calendar")));
        rehearsal.rehearse(deployer, _roles(), makeAddr("no calendar"), false, 0);
    }
}
