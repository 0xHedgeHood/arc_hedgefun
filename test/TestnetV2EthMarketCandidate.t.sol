// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TestnetV2EthMarket} from "../script/testnet/TestnetV2EthMarket.s.sol";
import {TestnetCryptoCalendar, TestnetCryptoOracle} from "../script/testnet/TestnetCryptoOracle.sol";
import {TestnetNativeMarket} from "../script/testnet/TestnetNativeMarket.sol";
import {TestFeed} from "../script/testnet/TestnetAssets.sol";

contract NativeCandidateWriterHarness is TestnetV2EthMarket {
    function writeCandidate(Deployment memory x, string memory phase) external { _write(x, phase); }
}

/// Opt-in permission and real serializer smoke test. It never signs or broadcasts.
/// Run with the generated native config and NATIVE_CONFIG_SMOKE=true.
contract TestnetV2EthMarketCandidateTest is Test {
    function test_realPhaseWriterHasPublisherShapeAndNarrowFilePermissions() public {
        if (!vm.envOr("NATIVE_CONFIG_SMOKE", false)) { vm.skip(true); return; }
        string memory base = vm.readFile("deploy/testnet-v2-fees.json");
        NativeCandidateWriterHarness tool = new NativeCandidateWriterHarness();
        vm.setEnv("GIT_COMMIT", vm.envOr("GIT_COMMIT", string("0a541ce7117e058b0c2c2da1424bc1c51ac77987")));
        TestnetV2EthMarket.Deployment memory x;
        x.base.factory = vm.parseJsonAddress(base, ".factory");
        x.base.treasuryDeployer = vm.parseJsonAddress(base, ".treasuryDeployer");
        x.base.tradeRouter = vm.parseJsonAddress(base, ".tradeRouter");
        x.base.nativeRouter = vm.parseJsonAddress(base, ".nativeRouter");
        x.base.path = "deploy/testnet-v2-fees.json";
        x.base.feature = vm.parseJsonString(base, ".featureVersion");
        x.base.bookSha256 = sha256(bytes(base));
        x.base.sourceCommit = vm.parseJsonString(base, ".verification.sourceCommit");
        x.base.sourceBookSha256 = vm.parseJsonString(base, ".verification.sourceBookSha256");
        x.base.verificationBlock = vm.parseJsonUint(base, ".verification.blockNumber");
        x.base.verificationBlockHash = vm.parseJsonBytes32(base, ".verification.blockHash");
        x.calendar = TestnetCryptoCalendar(address(0x111)); x.feed = TestFeed(address(0x112));
        x.oracle = TestnetCryptoOracle(address(0x113)); x.seeder = TestnetNativeMarket(address(0x114)); x.pool = address(0x115);
        x.wethImplementation = 0xf40600e58a560a988D7B60D61F22F7AB18106ED6;
        x.tickLower = 190250; x.tickUpper = 202250; x.liquidity = 190030603296690;
        x.initializedAt = 1000; x.initializedBlock = x.base.verificationBlock + 100; x.deadline = 1300;
        x.provided0 = 2695105669; x.provided1 = 899999999999999792;
        vm.warp(1000);
        for (uint256 i; i < 3; ++i) {
            string memory phase = i == 0 ? "init" : i == 1 ? "poke" : "activate";
            string memory path = string.concat("deploy/testnet-v2-native-market.", phase, ".dryrun.json");
            require(!vm.exists(path), "Preserve an existing native dry-run file");
            vm.roll(x.initializedBlock + i); tool.writeCandidate(x, phase);
            string memory candidate = vm.readFile(path);
            assertEq(vm.parseJsonUint(candidate, ".block"), block.number);
            assertEq(vm.parseJsonUint(candidate, ".initializedBlock"), x.initializedBlock);
            assertEq(vm.parseJsonString(candidate, ".phase"), phase);
            assertFalse(vm.parseJsonBool(candidate, ".broadcast"));
            assertFalse(vm.parseJsonBool(candidate, ".broadcastRequested"));
            assertEq(vm.parseJsonString(candidate, ".schema"), "v2-testnet-native-market-candidate-v1");
            assertEq(vm.parseJsonUint(candidate, ".plannedTransactionCount"), 17);
            assertEq(vm.parseJsonUint(candidate, ".phaseCounts.init"), 12);
            assertEq(vm.parseJsonUint(candidate, ".phaseCounts.poke"), 1);
            assertEq(vm.parseJsonUint(candidate, ".phaseCounts.activate"), 4);
            assertEq(vm.parseJsonAddress(candidate, ".market.token"), tool.WETH());
            assertEq(vm.parseJsonAddress(candidate, ".market.calendar"), address(x.calendar));
            assertEq(vm.parseJsonString(candidate, ".market.priceSource"), "pool-twap");
            assertEq(vm.parseJsonString(candidate, ".minLiquidity"), "95015301648345");
            assertEq(vm.parseJsonString(candidate, ".market.minLiquidity"), "95015301648345");
            assertEq(vm.parseJsonUint(candidate, ".maxDeviationBps"), 50);
            assertEq(vm.parseJsonUint(candidate, ".maxSlippageBps"), 100);
            assertEq(vm.parseJsonString(candidate, ".sellChunkUsdg"), "0");
            assertEq(vm.parseJsonUint(candidate, ".lpBps"), 5000);
            assertEq(vm.parseJsonUint(candidate, ".bandCeiling"), 0);
            vm.removeFile(path);
        }
        assertEq(vm.readFile("deploy/testnet-v2-fees.json"), base);
    }
}
