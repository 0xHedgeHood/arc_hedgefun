// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// A strategy token. Fixed supply, minted once, no owner, no mint function, nothing to pause. Anyone may burn their
/// own balance, which is how the treasury and the tax hook return value to holders: there is no redemption, no
/// dividend and no claim on the treasury, so a shrinking supply is the only link between the two.
///
/// It also carries what its creator says about it -- a logo, a description, five links and an `extraURI` -- read
/// through `logo`, `description`, `extraURI`, `socials` and `getTokenInfo`.
///
///   - The strings are not constructor arguments, so they are in no predicted address. They are written by
///     `setMetadata` (the deployer or its editor), or once by the factory inside the launch (`initMetadata`).
///   - They can change, and a link that can change can be swapped for a phishing one after people trust it. Every
///     change is therefore an event carrying the full new value, `updatedAt` is on chain for a page to show, and the
///     creator can `lock()` the entry for good, after which it is immutable.
///
/// `deployer` is the creator. It is reference data plus the right to write these strings: it confers
/// NOTHING over the supply, the balances or the allowances, and nothing in this file's metadata half calls `_mint`,
/// `_burn`, `_transfer` or `_approve`. It is the creator as recorded at launch, on purpose not the hook's payout
/// creator: moving where the fees go and rewriting what the page says are different powers, and a takeover of the
/// first must not reach the second. A deployer that cannot make a call (a contract with no way to, or address zero)
/// simply leaves the metadata empty for ever; the token is otherwise unaffected. There is no protocol power here and
/// no external call, so nothing to re-enter.
contract HedgeFunToken is ERC20 {
    struct Socials { string twitter; string telegram; string discord; string website; string farcaster; }
    /// a whole entry, as the launch carries it
    struct Info { string logo; string description; Socials socials; string extraURI; }

    /// the creator recorded at launch. May write the metadata, appoint an editor, and lock. Nothing else.
    address public immutable deployer;
    /// whoever the supply was minted to: the factory. Its one power is `initMetadata`, once, during the launch.
    address public immutable launcher;
    /// one address the deployer lets write the metadata on its behalf (a Safe does not want to sign for a Telegram link).
    /// It can neither appoint nor lock.
    address public editor;
    bool public locked;
    uint64 public updatedAt;            // 0 = never set

    string public logo;
    string public description;
    string public extraURI;             // a JSON document for anything that is not one of the seven fields
    Socials private _socials;

    uint256 public constant MAX_LINK_BYTES = 256;
    uint256 public constant MAX_DESCRIPTION_BYTES = 1024;

    event MetadataSet(address indexed by, string logo, string description, Socials socials, string extraURI);
    event EditorSet(address indexed editor);
    event MetadataLocked();

    error NotAllowed();
    error IsLocked();
    error TooLong();

    constructor(string memory name_, string memory symbol_, uint256 supply, address mintTo, address creator) ERC20(name_, symbol_) {
        deployer = creator; launcher = mintTo;
        _mint(mintTo, supply);
    }

    function burn(uint256 amount) external { _burn(msg.sender, amount); }

    // ------------------------------------------------------------------------------------------------ metadata, write
    /// @notice replace the whole entry. Lengths are BYTES, and every one is checked before anything is written.
    function setMetadata(string calldata logo_, string calldata description_, Socials calldata socials_, string calldata extraURI_) external {
        if (msg.sender != deployer && msg.sender != editor) revert NotAllowed();
        if (locked) revert IsLocked();
        _write(msg.sender, logo_, description_, socials_, extraURI_);
    }

    /// @notice the creator's first entry, written by the launch itself -- so the coin is never live with an empty card.
    /// @dev Between `launch` and a second transaction the token trades with no logo and no links, and the opening
    ///      seconds are exactly when screeners and bots index it; some never read again. And a second signature gets
    ///      dropped (a closed tab, a wallet prompt), which leaves a blank coin for good. So whoever minted the supply
    ///      -- the factory -- may write ONE entry, on the creator's behalf, in the launch transaction: the factory
    ///      only launches for `q.creator` itself or through a launcher that insists on the same, so these are the
    ///      creator's words. Once, and only while nothing has been written: `updatedAt != 0` shuts it, as does a lock.
    ///      After it the launcher has exactly the power over this page it had before: none. The event names the
    ///      deployer, because that is whose entry it is.
    function initMetadata(Info calldata m) external {
        if (msg.sender != launcher || updatedAt != 0 || locked) revert NotAllowed();
        _write(deployer, m.logo, m.description, m.socials, m.extraURI);
    }

    /// @dev one writer for both doors, so the caps can never drift apart
    function _write(address by, string calldata logo_, string calldata description_, Socials calldata socials_, string calldata extraURI_) internal {
        if (bytes(description_).length > MAX_DESCRIPTION_BYTES || bytes(logo_).length > MAX_LINK_BYTES || bytes(extraURI_).length > MAX_LINK_BYTES
            || bytes(socials_.twitter).length > MAX_LINK_BYTES || bytes(socials_.telegram).length > MAX_LINK_BYTES
            || bytes(socials_.discord).length > MAX_LINK_BYTES || bytes(socials_.website).length > MAX_LINK_BYTES
            || bytes(socials_.farcaster).length > MAX_LINK_BYTES) revert TooLong();
        logo = logo_; description = description_; _socials = socials_; extraURI = extraURI_;
        updatedAt = uint64(block.timestamp);
        emit MetadataSet(by, logo_, description_, socials_, extraURI_);
    }

    /// @notice appoint one editor, or dismiss it with address(0). The deployer only.
    function setEditor(address editor_) external {
        if (msg.sender != deployer) revert NotAllowed();
        if (locked) revert IsLocked();
        editor = editor_;
        emit EditorSet(editor_);
    }

    /// @notice freeze the metadata for ever. The deployer only; there is no way back.
    /// @dev Not while an editor is appointed. A lock freezes whatever entry landed before it, and an editor
    ///      -- or whoever stole its key -- could land one in front of the deployer's `lock()`, in the same block: a
    ///      drainer link frozen for good, which the deployer could never repair. So the order is forced: dismiss the
    ///      editor, read the page, lock. After `setEditor(address(0))` only the deployer can write, and nobody races
    ///      themselves.
    function lock() external {
        if (msg.sender != deployer) revert NotAllowed();
        if (locked) revert IsLocked();
        if (editor != address(0)) revert NotAllowed();
        locked = true;
        emit MetadataLocked();
    }

    // ------------------------------------------------------------------------------------------------ metadata, read
    function socials() external view
        returns (string memory twitter, string memory telegram, string memory discord, string memory website, string memory farcaster)
    {
        Socials memory v = _socials;
        return (v.twitter, v.telegram, v.discord, v.website, v.farcaster);
    }

    function getTokenInfo() external view
        returns (address tokenDeployer, string memory tokenLogo, string memory tokenDescription, Socials memory tokenSocials)
    {
        return (deployer, logo, description, _socials);
    }
}
