// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HedgeFunFactory} from "../../src/HedgeFunFactory.sol";

/// @notice The factory defaults a Robinhood Chain (4663) V2 core is constructed with.
/// @dev One explicit copy, so the fork rehearsal and the deployment cannot disagree, and nothing here is read from
///      a testnet script. These are release CANDIDATES: `DeployV2MainnetCore` refuses to run unless the caller
///      supplies their hash, which is how a reviewer confirms the exact values and how an edit here is noticed.
///      A treasury and a curve freeze what they read at launch; the owner can change these for later launches.
library V2MainnetDefaults {
    /// The share of supply every launch sells on its curve: `CurveDeployer` is constructed with it and accepts
    /// no other. 79.31%, the ordinary-curve allocation of the launchpads this one is compared with.
    /// The defaults hash does not cover it: the deployment takes it again as EXPECTED_SALE_BPS, and the readback
    /// requires the deployed curve deployer to carry it.
    uint16 internal constant SALE_BPS = 7931;
    /// The registry's default share of a graduation's raise seeded into the locked LP; the readback requires it.
    uint16 internal constant LP_BPS = 7000;

    function release() internal pure returns (HedgeFunFactory.Defaults memory d) {
        d.supply = 1_000_000_000e18;
        // 0.20%. V2's locked liquidity vault collects it for the buy-back, so V1's zero-fee default cannot be reused;
        // with the 1% minimum tax a trade costs about 1.2%, inside the range of the launchpads this one is compared with.
        d.lpFee = 2000;
        d.tickSpacing = 60;
        d.minTaxBps = 100; // the 1% base tax; a creator chooses 1% to 15%
        d.maxTaxBps = 1500;
        d.protocolBps = 3000; // 30% of the collected tax; the creator takes up to 10% and the token's treasury the rest
        d.maxCreatorBps = 5000; // up to half the collected tax: a creator tax on top of the base, at most equal to it
        d.spikeBps = 0; // V2 LP fees can fund buybacks without strategy profit; no buyback-triggered sell spike.
        d.spikeSeconds = 0;
        d.sweepTipBps = 0;
        d.snipeBps = 9900;
        d.snipeSeconds = 3;
        d.bountyBps = 10; // 0.1%: too little to pay an outside keeper for a take-profit, so the keeper is run in-house
        d.maxSlippageBps = 100;
        d.maxDeviationBps = 50;
        d.maxBuybackImpactBps = 300;
        d.buybackCooldown = 10; // seconds between buy-backs; retain the 600-second TWAP and bounded anchor fallback
        d.minLotUsdg = 5e6;
        d.buybackChunkUsdg = 500e6;
        d.sellChunkUsdg = 2_000e6;
        d.launchFeeCurrency = HedgeFunFactory.FeeCurrency.Native;
        d.launchFeeAmount = 0.0005 ether;
    }
}
