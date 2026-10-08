// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HedgeFunToken} from "../src/HedgeFunToken.sol";

/// a creator that is a contract with no way to make a call: it can hold tokens and nothing more
contract MuteCreator {}

contract StrategyTokenMetadataTest is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;
    address factory = address(0xFAC7); address creator = address(0xC4EA704); address editor = address(0xED17); address alice = address(0xA11);
    HedgeFunToken t;

    event MetadataSet(address indexed by, string logo, string description, HedgeFunToken.Socials socials, string extraURI);
    event EditorSet(address indexed editor);
    event MetadataLocked();

    function setUp() public {
        vm.warp(1_700_000_000);
        t = new HedgeFunToken("GME Strategy", "GMESTR", SUPPLY, factory, creator);
        vm.prank(factory); t.transfer(alice, 1_000e18);
        vm.prank(alice); t.approve(address(0xBEEF), 77e18);
    }

    function _s(string memory web) internal pure returns (HedgeFunToken.Socials memory) {
        return HedgeFunToken.Socials("https://x.com/gmestr", "https://t.me/gmestr", "https://discord.gg/gmestr", web, "https://warpcast.com/gmestr");
    }
    function _set(address who, string memory web) internal { vm.prank(who); t.setMetadata("ipfs://logo", "a GME treasury that never sells below cost", _s(web), "ipfs://more"); }
    function _str(uint256 n) internal pure returns (string memory) { bytes memory b = new bytes(n); for (uint256 i; i < n; i++) b[i] = "a"; return string(b); }

    /// everything a metadata call must leave exactly as it found it
    function _money() internal view returns (bytes32) {
        return keccak256(abi.encode(t.totalSupply(), t.balanceOf(factory), t.balanceOf(alice), t.balanceOf(creator), t.balanceOf(editor),
            t.allowance(alice, address(0xBEEF)), t.name(), t.symbol(), t.decimals()));
    }
    function _entry() internal view returns (bytes32) {
        (address d, string memory l, string memory de, HedgeFunToken.Socials memory s) = t.getTokenInfo();
        return keccak256(abi.encode(d, l, de, s, t.extraURI(), t.updatedAt(), t.editor(), t.locked()));
    }

    // ------------------------------------------------------------------------------------------------ birth
    function test_atBirthTheWholeSupplyIsMintedOnce_theCreatorIsRecorded_andTheEntryIsEmpty() public {
        HedgeFunToken n = new HedgeFunToken("N", "N", SUPPLY, factory, creator);
        assertEq(n.totalSupply(), SUPPLY); assertEq(n.balanceOf(factory), SUPPLY); assertEq(n.balanceOf(creator), 0, "the creator is given nothing");
        assertEq(n.deployer(), creator); assertEq(n.editor(), address(0)); assertFalse(n.locked()); assertEq(n.updatedAt(), 0);
        (address d, string memory l, string memory de, HedgeFunToken.Socials memory s) = n.getTokenInfo();
        assertEq(d, creator); assertEq(l, ""); assertEq(de, ""); assertEq(s.twitter, ""); assertEq(s.farcaster, ""); assertEq(n.extraURI(), "");
    }

    // ------------------------------------------------------------------------------------------------ the pons shape
    function test_whatTheCreatorWritesReadsBackThroughPonsReaders() public {
        _set(creator, "https://gmestr.xyz");
        assertEq(t.logo(), "ipfs://logo"); assertEq(t.description(), "a GME treasury that never sells below cost"); assertEq(t.extraURI(), "ipfs://more");
        assertEq(t.updatedAt(), block.timestamp);
        (string memory tw, string memory tg, string memory dc, string memory web, string memory fc) = t.socials();
        assertEq(tw, "https://x.com/gmestr"); assertEq(tg, "https://t.me/gmestr"); assertEq(dc, "https://discord.gg/gmestr");
        assertEq(web, "https://gmestr.xyz"); assertEq(fc, "https://warpcast.com/gmestr");
        (address d, string memory l, string memory de, HedgeFunToken.Socials memory s) = t.getTokenInfo();
        assertEq(d, creator); assertEq(l, "ipfs://logo"); assertEq(de, "a GME treasury that never sells below cost"); assertEq(s.website, "https://gmestr.xyz");
    }

    function test_theReadersHavePonsSelectors() public view {
        // what a tool written for PonsV2LauncherToken calls
        assertEq(t.getTokenInfo.selector, bytes4(keccak256("getTokenInfo()")));
        assertEq(t.socials.selector, bytes4(keccak256("socials()")));
        assertEq(t.logo.selector, bytes4(keccak256("logo()")));
        assertEq(t.description.selector, bytes4(keccak256("description()")));
        assertEq(t.deployer.selector, bytes4(keccak256("deployer()")));
    }

    function test_aSecondWriteReplacesTheWholeEntry_emptyStringsIncluded() public {
        _set(creator, "https://gmestr.xyz");
        vm.warp(block.timestamp + 1 hours);
        vm.prank(creator); t.setMetadata("", "", HedgeFunToken.Socials("", "", "", "", ""), "");
        assertEq(t.logo(), ""); assertEq(t.description(), ""); assertEq(t.extraURI(), "");
        (string memory tw,,, string memory web,) = t.socials(); assertEq(tw, ""); assertEq(web, "");
        assertEq(t.updatedAt(), block.timestamp, "clearing is a change, and is dated");
    }

    // ------------------------------------------------------------------------------------------------ who may write
    function testFuzz_nobodyButTheDeployerAndTheEditorMayWriteAnything(address who) public {
        vm.assume(who != creator && who != editor);
        vm.prank(creator); t.setEditor(editor);
        bytes32 before = _entry();
        vm.startPrank(who);
        vm.expectRevert(HedgeFunToken.NotAllowed.selector); t.setMetadata("x", "x", _s("x"), "x");
        vm.expectRevert(HedgeFunToken.NotAllowed.selector); t.setEditor(who);
        vm.expectRevert(HedgeFunToken.NotAllowed.selector); t.lock();
        vm.stopPrank();
        assertEq(_entry(), before);
    }

    function test_theFactoryThatMintedItHasNoSayInTheEntry() public {
        vm.prank(factory); vm.expectRevert(HedgeFunToken.NotAllowed.selector); t.setMetadata("x", "x", _s("x"), "x");
    }

    function test_anEditorMayWrite_butMayNeitherAppointNorLock() public {
        vm.prank(creator); t.setEditor(editor);
        _set(editor, "https://by-the-editor");
        (,,, string memory web,) = t.socials(); assertEq(web, "https://by-the-editor");
        vm.prank(editor); vm.expectRevert(HedgeFunToken.NotAllowed.selector); t.setEditor(alice);
        vm.prank(editor); vm.expectRevert(HedgeFunToken.NotAllowed.selector); t.lock();
        vm.prank(creator); t.setEditor(address(0));                                                    // dismissed
        vm.prank(editor); vm.expectRevert(HedgeFunToken.NotAllowed.selector); t.setMetadata("x", "x", _s("x"), "x");
    }

    // ------------------------------------------------------------------------------------------------ lock
    function test_aLockIsForGood_forTheEntryAndForTheEditor() public {
        vm.prank(creator); t.setEditor(editor);
        _set(creator, "https://final");
        // not while an editor is appointed: see `test_K7_1_…` below. Dismiss, then lock.
        vm.prank(creator); vm.expectRevert(HedgeFunToken.NotAllowed.selector); t.lock();
        vm.prank(creator); t.setEditor(address(0));
        vm.prank(creator); t.lock();
        assertTrue(t.locked());
        bytes32 frozen = _entry();
        vm.prank(creator); vm.expectRevert(HedgeFunToken.IsLocked.selector); t.setMetadata("x", "x", _s("https://swapped-later"), "x");
        vm.prank(editor); vm.expectRevert(HedgeFunToken.NotAllowed.selector); t.setMetadata("x", "x", _s("https://swapped-later"), "x");   // dismissed
        vm.prank(creator); vm.expectRevert(HedgeFunToken.IsLocked.selector); t.setEditor(alice);
        vm.prank(creator); vm.expectRevert(HedgeFunToken.IsLocked.selector); t.lock();
        assertEq(_entry(), frozen);
    }

    function test_anEmptyEntryCanBeLockedEmpty() public {
        vm.prank(creator); t.lock();
        vm.prank(creator); vm.expectRevert(HedgeFunToken.IsLocked.selector); t.setMetadata("x", "", _s(""), "");
        assertEq(t.logo(), ""); assertEq(t.updatedAt(), 0);
    }

    // ------------------------------------------------------------------------------------------------ caps
    function test_everyStringAtItsCapIsAccepted() public {
        string memory L = _str(256);
        vm.prank(creator); t.setMetadata(L, _str(1024), HedgeFunToken.Socials(L, L, L, L, L), L);
        assertEq(bytes(t.description()).length, 1024); assertEq(bytes(t.logo()).length, 256);
    }

    function test_oneByteOverAnyCapIsRefused_andNothingIsWritten() public {
        _set(creator, "https://gmestr.xyz");
        bytes32 before = _entry();
        string memory ok = "ok"; string memory L = _str(257);
        vm.startPrank(creator);
        vm.expectRevert(HedgeFunToken.TooLong.selector); t.setMetadata(L, ok, _s(ok), ok);
        vm.expectRevert(HedgeFunToken.TooLong.selector); t.setMetadata(ok, _str(1025), _s(ok), ok);
        vm.expectRevert(HedgeFunToken.TooLong.selector); t.setMetadata(ok, ok, _s(ok), L);
        vm.expectRevert(HedgeFunToken.TooLong.selector); t.setMetadata(ok, ok, HedgeFunToken.Socials(L, ok, ok, ok, ok), ok);
        vm.expectRevert(HedgeFunToken.TooLong.selector); t.setMetadata(ok, ok, HedgeFunToken.Socials(ok, L, ok, ok, ok), ok);
        vm.expectRevert(HedgeFunToken.TooLong.selector); t.setMetadata(ok, ok, HedgeFunToken.Socials(ok, ok, L, ok, ok), ok);
        vm.expectRevert(HedgeFunToken.TooLong.selector); t.setMetadata(ok, ok, HedgeFunToken.Socials(ok, ok, ok, L, ok), ok);
        vm.expectRevert(HedgeFunToken.TooLong.selector); t.setMetadata(ok, ok, HedgeFunToken.Socials(ok, ok, ok, ok, L), ok);
        vm.stopPrank();
        assertEq(_entry(), before, "a refused write left a trace");
    }

    function test_theCapsCountBytes_notCharacters() public {
        // 86 CJK characters are 258 bytes: under 256 characters, over 256 bytes
        bytes memory b; for (uint256 i; i < 86; i++) b = abi.encodePacked(b, unicode"币");
        assertEq(b.length, 258);
        vm.prank(creator); vm.expectRevert(HedgeFunToken.TooLong.selector); t.setMetadata(string(b), "", _s(""), "");
        bytes memory c; for (uint256 i; i < 85; i++) c = abi.encodePacked(c, unicode"币");               // 255 bytes
        vm.prank(creator); t.setMetadata(string(c), "", _s(""), "");
        assertEq(bytes(t.logo()).length, 255);
    }

    // ------------------------------------------------------------------------------------------------ the money half is out of reach
    function test_noMetadataCallMovesABalanceAnAllowanceOrTheSupply() public {
        bytes32 money = _money();
        vm.prank(creator); t.setEditor(editor);                                                          assertEq(_money(), money);
        _set(creator, "https://gmestr.xyz");                                                             assertEq(_money(), money);
        _set(editor, "https://edited");                                                                  assertEq(_money(), money);
        string memory L = _str(256);
        vm.prank(creator); t.setMetadata(L, _str(1024), HedgeFunToken.Socials(L, L, L, L, L), L);        assertEq(_money(), money);
        vm.prank(creator); t.setMetadata("", "", HedgeFunToken.Socials("", "", "", "", ""), "");         assertEq(_money(), money);
        vm.prank(creator); t.setEditor(address(0));                                                      assertEq(_money(), money);
        vm.prank(creator); t.lock();                                                                     assertEq(_money(), money);
    }

    function test_theDeployerHasNoHandleOnAnyonesTokens() public {
        vm.startPrank(creator);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, creator, 0, 1)); t.transferFrom(alice, creator, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, creator, 0, 1)); t.burn(1);   // it holds none
        vm.stopPrank();
        assertEq(t.balanceOf(alice), 1_000e18);
    }

    function test_burnIsStillForOnesOwnBalanceOnly() public {
        vm.prank(alice); t.burn(400e18);
        assertEq(t.balanceOf(alice), 600e18); assertEq(t.totalSupply(), SUPPLY - 400e18);
        vm.prank(alice); vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 600e18, 601e18)); t.burn(601e18);
    }

    // ------------------------------------------------------------------------------------------------ creators that cannot speak
    function test_aCreatorContractThatCannotCall_launchesATokenThatWorks_withAnEntryEmptyForEver() public {
        address mute = address(new MuteCreator());
        HedgeFunToken n = new HedgeFunToken("N", "N", SUPPLY, factory, mute);
        vm.prank(factory); n.transfer(alice, 5e18);
        vm.prank(alice); n.burn(1e18);
        assertEq(n.totalSupply(), SUPPLY - 1e18); assertEq(n.deployer(), mute);
        vm.prank(alice); vm.expectRevert(HedgeFunToken.NotAllowed.selector); n.setMetadata("x", "x", _s("x"), "x");
        assertEq(n.updatedAt(), 0);
    }

    function testFuzz_aZeroDeployerMeansNobodyCanEverWrite(address who) public {
        HedgeFunToken n = new HedgeFunToken("N", "N", SUPPLY, factory, address(0));
        vm.assume(who != address(0));                                                                    // nobody can send from the zero address
        vm.startPrank(who);
        vm.expectRevert(HedgeFunToken.NotAllowed.selector); n.setMetadata("x", "x", _s("x"), "x");
        vm.expectRevert(HedgeFunToken.NotAllowed.selector); n.setEditor(who);
        vm.expectRevert(HedgeFunToken.NotAllowed.selector); n.lock();
        vm.stopPrank();
        assertEq(n.editor(), address(0), "an unset editor is the zero address, and that must not make the zero deployer's token writable");
    }

    // ------------------------------------------------------------------------------------------------ events
    function test_everyChangeIsAnEventCarryingTheWholeNewValue() public {
        vm.expectEmit(true, false, false, true, address(t)); emit EditorSet(editor);
        vm.prank(creator); t.setEditor(editor);
        vm.expectEmit(true, false, false, true, address(t));
        emit MetadataSet(editor, "ipfs://logo", "a GME treasury that never sells below cost", _s("https://gmestr.xyz"), "ipfs://more");
        _set(editor, "https://gmestr.xyz");
        vm.expectEmit(true, false, false, true, address(t)); emit EditorSet(address(0));
        vm.prank(creator); t.setEditor(address(0));
        vm.expectEmit(false, false, false, true, address(t)); emit MetadataLocked();
        vm.prank(creator); t.lock();
    }

    /// This reproduced as the PoC K7_1_anEditorWritesInFrontOfTheLock_andThePhishingEntryIsFrozenForEver (audit round
    /// 7): the deployer reviewed the page and sent `lock()`; the editor -- or whoever held its key -- landed a
    /// `setMetadata` with a drainer link in front of it, in the same block; the lock then froze THAT entry, and nobody
    /// could ever repair it. A lock is now refused while an editor is appointed, so the last writer before any lock is
    /// the deployer itself.
    function test_K7_1_anEditorCannotWriteInFrontOfALock_becauseALockNeedsTheEditorGone() public {
        vm.prank(creator); t.setEditor(editor);
        _set(creator, "https://reviewed");
        _set(editor, "https://drainer");                                        // the front-run
        vm.prank(creator); vm.expectRevert(HedgeFunToken.NotAllowed.selector); t.lock();
        assertFalse(t.locked(), "the drainer link was frozen");

        vm.prank(creator); t.setEditor(address(0));                             // the forced order: dismiss ...
        vm.prank(editor); vm.expectRevert(HedgeFunToken.NotAllowed.selector); t.setMetadata("x", "x", _s("https://drainer"), "x");
        _set(creator, "https://reviewed");                                      // ... repair and re-read ...
        vm.prank(creator); t.lock();                                            // ... lock
        (,,, string memory website,) = t.socials();
        assertEq(website, "https://reviewed", "what was locked is not what the deployer last wrote");
        assertTrue(t.locked());
    }

    // ------------------------------------------------------------------------------------------------ the launch writes the first entry
    function _info(string memory web) internal pure returns (HedgeFunToken.Info memory m) {
        m.logo = "ipfs://logo"; m.description = "written by the launch"; m.socials = _s(web); m.extraURI = "ipfs://more";
    }

    /// Whoever minted the supply -- the factory -- writes ONE entry, in the launch, so the coin is never live with an
    /// empty card. The event names the creator: it is their entry.
    function test_theLauncherWritesTheFirstEntry_once_andTheEventNamesTheCreator() public {
        assertEq(t.launcher(), factory);
        bytes32 money = _money();
        vm.expectEmit(true, false, false, true, address(t));
        emit MetadataSet(creator, "ipfs://logo", "written by the launch", _s("https://first"), "ipfs://more");
        vm.prank(factory); t.initMetadata(_info("https://first"));
        assertEq(t.logo(), "ipfs://logo"); assertEq(t.updatedAt(), block.timestamp);
        assertEq(_money(), money, "writing the first entry moved money");

        vm.prank(factory); vm.expectRevert(HedgeFunToken.NotAllowed.selector); t.initMetadata(_info("https://second"));
        (,,, string memory website,) = t.socials();
        assertEq(website, "https://first");
        // and the creator's own door is exactly what it was
        _set(creator, "https://mine");
        vm.prank(factory); vm.expectRevert(HedgeFunToken.NotAllowed.selector); t.initMetadata(_info("https://third"));
    }

    function testFuzz_nobodyButTheLauncherCanWriteTheFirstEntry(address who) public {
        vm.assume(who != factory);
        vm.prank(who); vm.expectRevert(HedgeFunToken.NotAllowed.selector); t.initMetadata(_info("https://x"));
        assertEq(t.updatedAt(), 0);
    }

    /// The other direction: a creator who writes first, or locks an empty card, has shut the launcher's door for good.
    function test_aCreatorsWriteOrLockShutsTheLaunchersDoor() public {
        uint256 snap = vm.snapshotState();
        _set(creator, "https://mine");
        vm.prank(factory); vm.expectRevert(HedgeFunToken.NotAllowed.selector); t.initMetadata(_info("https://theirs"));
        vm.revertToState(snap);
        vm.prank(creator); t.lock();
        vm.prank(factory); vm.expectRevert(HedgeFunToken.NotAllowed.selector); t.initMetadata(_info("https://theirs"));
        assertEq(t.updatedAt(), 0);
    }

    /// One writer behind both doors: the launch's entry meets the same byte caps, checked before anything is written.
    function test_theLaunchersEntryMeetsTheSameCaps_andAnOverCapFieldWritesNothing() public {
        HedgeFunToken.Info memory m = _info("https://ok");
        m.description = _str(1025);
        vm.prank(factory); vm.expectRevert(HedgeFunToken.TooLong.selector); t.initMetadata(m);
        m = _info("https://ok"); m.socials.farcaster = _str(257);
        vm.prank(factory); vm.expectRevert(HedgeFunToken.TooLong.selector); t.initMetadata(m);
        assertEq(t.updatedAt(), 0); assertEq(t.logo(), "");
        m = _info("https://ok"); m.description = _str(1024); m.logo = _str(256);
        vm.prank(factory); t.initMetadata(m);                                   // the edge is allowed
        assertEq(bytes(t.description()).length, 1024);
    }

    // ------------------------------------------------------------------------------------------------ cost
    function test_gasOfTheLargestPossibleWrite_isReported() public {
        string memory L = _str(256); string memory D = _str(1024);
        HedgeFunToken.Socials memory s = HedgeFunToken.Socials(L, L, L, L, L);
        vm.prank(creator); uint256 g = gasleft(); t.setMetadata(L, D, s, L); g -= gasleft();
        console2.log("setMetadata, every string at its cap (2,816 bytes), first write, gas:", g);
        vm.prank(creator); g = gasleft(); t.setMetadata("ipfs://logo", "short", _s("https://gmestr.xyz"), ""); g -= gasleft();
        console2.log("setMetadata, a typical entry over a full one, gas:", g);
        assertLt(g, 3_000_000);
    }
}
