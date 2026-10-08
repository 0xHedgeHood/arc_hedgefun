// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HedgeFunFactory} from "../../src/HedgeFunFactory.sol";
import {HedgeFunV2Factory} from "../../src/v2/HedgeFunV2Factory.sol";
import {CurveDeployer} from "../../src/v2/CurveDeployer.sol";

/// @dev Creates one isolated Robinhood testnet TSLA strategy. The broadcast signer is an
/// encrypted testnet keystore supplied to forge, never an environment or CLI private key.
contract TestnetTSLAStressLaunch is Script {
    uint256 private constant CHAIN_ID = 46630;
    address private constant FACTORY = 0x3E95976E2425e63cb2A8d48BBce8976F55627019;
    address private constant TSLA = 0xcee322837F181Bd93AC2d71e4dDf334BFF565b98;
    address private constant USDG = 0x539574139BB4Ac74Fd2183ba0E38ed777E30B58d;

    function run() external {
        require(block.chainid == CHAIN_ID, "wrong chain");
        uint256 expectedOpening = _verifyBook();
        (HedgeFunFactory.Request memory q, address exempt, uint256 fee) = _context(expectedOpening);
        CurveDeployer registry = HedgeFunV2Factory(FACTORY).curveDeployer();
        address[] memory list = new address[](1);
        list[0] = exempt;
        vm.startBroadcast();
        registry.setCurveConfig(q.symbol, q.nonce, 4400, 180);
        registry.setOpeningTaxExemptions(q.symbol, q.nonce, list);
        vm.stopBroadcast();
        _launch(q, fee);
    }

    function _verifyBook() private view returns (uint256 expectedOpening) {
        string memory book = vm.readFile("deploy/testnet-v2-whitelist.json");
        require(vm.parseJsonUint(book, ".chainId") == CHAIN_ID, "wrong book chain");
        require(vm.parseJsonAddress(book, ".factory") == FACTORY, "wrong factory");
        require(vm.parseJsonAddress(book, ".stocks.TSLA.token") == TSLA, "wrong TSLA");
        require(vm.parseJsonAddress(book, ".usdg") == USDG, "wrong USDG");
        expectedOpening = vm.parseJsonUint(book, ".stocks.TSLA.openPriceE18");
    }

    function _context(uint256 expectedOpening)
        private view returns (HedgeFunFactory.Request memory q, address exempt, uint256 fee)
    {
        address creator = vm.envAddress("STRESS_CREATOR");
        exempt = vm.envAddress("STRESS_EXEMPT");
        uint256 nonceValue = vm.envUint("STRESS_NONCE");
        require(nonceValue <= type(uint96).max, "nonce out of range");
        require(creator != address(0) && exempt != address(0) && exempt != creator, "bad recipients");
        require(msg.sender == creator, "wrong broadcaster");
        HedgeFunV2Factory factory = HedgeFunV2Factory(FACTORY);
        require(factory.publicLaunch(), "public launch off");
        HedgeFunFactory.Defaults memory d = factory.getDefaults();
        require(d.launchFeeCurrency == HedgeFunFactory.FeeCurrency.Usdg && d.launchFeeAmount <= 50e6,
            "unexpected fee");
        (,, uint256 opening, bool enabled) = factory.listings(TSLA);
        require(enabled && opening == expectedOpening, "listing changed");

        q.name = "Hedgefun TSLA Stress";
        q.symbol = "HFTTS1";
        q.stock = TSLA;
        q.creator = creator;
        q.taxBps = 300;
        q.creatorBps = 1000;
        q.tp1Bps = 500;
        q.tp2Bps = 1000;
        q.dipBps = 500;
        q.stopBps = 500;
        q.lotBps = 2000;
        q.nonce = uint96(nonceValue);
        q.maxFee = d.launchFeeAmount;
        q.expectedOpenPriceE18 = opening;
        // Salt/metadata collisions are detectable before either registration transaction.
        require(factory.predictToken(q).code.length == 0, "nonce used");
        require(factory.predictCurve(q).code.length == 0, "curve nonce used");
        fee = d.launchFeeAmount;
        require(IERC20(USDG).balanceOf(creator) >= fee, "fee balance");
    }

    function _launch(HedgeFunFactory.Request memory q, uint256 fee) private {
        HedgeFunV2Factory factory = HedgeFunV2Factory(FACTORY);
        (,, bytes32 terms) = factory.predict(q);
        address predictedCurve = factory.predictCurve(q);
        require(predictedCurve.code.length == 0, "nonce used");
        uint256 expectedId = factory.strategyCount();
        console2.log("expected strategy id", expectedId);
        console2.log("predicted curve", predictedCurve);
        vm.startBroadcast();
        IERC20(USDG).approve(FACTORY, fee);
        uint256 id = factory.launch(q, terms);
        vm.stopBroadcast();
        require(id == expectedId && factory.curves(id) == predictedCurve, "launch mismatch");
        console2.log("launched strategy id", id);
    }
}
