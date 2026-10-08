// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CryptoCalendar} from "../../src/CryptoCalendar.sol";
import {CryptoPriceOracle} from "../../src/CryptoPriceOracle.sol";
import {ArcAssets} from "./ArcAssets.sol";

interface IChainlinkFeed {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
}

/// @notice Deploys one `CryptoCalendar`, owned by the owner Safe, and a `CryptoPriceOracle` per asset on Arc (5042).
/// @dev Requires OWNER (the Safe that may halt the calendar) and SYMBOLS, e.g. `cirBTC`. CALENDAR reuses a calendar
///      already deployed. Before anything is sent, every feed's description and decimals are checked against
///      `ArcAssets` and every new oracle must answer a live price. The oracles have no owner.
contract DeployArcOracles is Script {
    uint256 public constant CHAIN_ID = 5042;

    struct Deployed { CryptoCalendar calendar; CryptoPriceOracle[] oracles; }

    error WrongChain(uint256 chainId);
    error BadFeed(address feed);
    error BadToken(address token);
    error NoLivePrice(string symbol);

    function run() external returns (Deployed memory x) {
        x = deploy(msg.sender, vm.envAddress("OWNER"), vm.envOr("CALENDAR", address(0)), vm.split(vm.envString("SYMBOLS"), ","));
        console2.log("calendar", address(x.calendar), "owner", x.calendar.owner());
        for (uint256 i; i < x.oracles.length; ++i) {
            (, uint256 p) = x.oracles[i].tryPrice();
            console2.log("oracle", address(x.oracles[i]), IERC20Metadata(x.oracles[i].stock()).symbol(), p);
        }
    }

    function deploy(address deployer, address owner, address existingCalendar, string[] memory symbols)
        public
        returns (Deployed memory x)
    {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        _requireFeed(ArcAssets.USDC_USD_FEED, ArcAssets.USDC_USD_DESCRIPTION);
        ArcAssets.Asset[] memory assets = new ArcAssets.Asset[](symbols.length);
        for (uint256 i; i < symbols.length; ++i) {
            assets[i] = ArcAssets.get(symbols[i]);
            _requireFeed(assets[i].feed, assets[i].feedDescription);
            if (IERC20Metadata(assets[i].token).decimals() != assets[i].decimals) revert BadToken(assets[i].token);
        }
        x.oracles = new CryptoPriceOracle[](symbols.length);
        vm.startBroadcast(deployer);
        x.calendar = existingCalendar == address(0) ? new CryptoCalendar(owner) : CryptoCalendar(existingCalendar);
        for (uint256 i; i < assets.length; ++i) {
            x.oracles[i] = new CryptoPriceOracle(assets[i].token, assets[i].feed, ArcAssets.USDC_USD_FEED,
                address(x.calendar), ArcAssets.MAX_FEED_AGE, ArcAssets.MAX_FEED_AGE);
        }
        vm.stopBroadcast();
        if (x.calendar.owner() != owner && x.calendar.pendingOwner() != owner) revert BadToken(address(x.calendar));
        for (uint256 i; i < assets.length; ++i) {
            (bool ok, uint256 p) = x.oracles[i].tryPrice();
            if (!ok || p == 0) revert NoLivePrice(assets[i].symbol);
        }
    }

    function _requireFeed(address feed, string memory description) private view {
        if (feed.code.length == 0 || IChainlinkFeed(feed).decimals() != 8
            || keccak256(bytes(IChainlinkFeed(feed).description())) != keccak256(bytes(description))) revert BadFeed(feed);
    }
}
