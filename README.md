# Hedgefun on Arc

Hedgefun is a token launchpad where every token owns a treasury. A creator launches a token against an underlying asset, and the token trades on a bonding curve priced in that asset. When the curve sells out, the token graduates: part of the raise is locked as Uniswap V4 liquidity, and the rest goes to the token's treasury. From then on the treasury trades the asset by a rule the creator picked at launch, such as take-profit and dip rungs, buy-back and burn, or a target-weight rebalance. Trading tax funds the treasury, the creator and the protocol.

The same contracts run on Robinhood Chain (4663) with tokenized stocks. This repository is the Arc (5042) port, with cirBTC as the first underlying asset and USDC as gas, quote and launch fee.

Status: live on Arc mainnet since 2026-10-08 at https://arc.hedgefun.trade. The core is owned by a Safe, and public launch is open. Deployment steps are in [docs/ARC.md](docs/ARC.md).

| Contract | Arc mainnet (5042) |
| --- | --- |
| Factory (`HedgeFunV2ArcFactory`) | `0x7BbaAb5d1426650FaaAEB0214D5a045A80FD2621` |
| Trade router | `0xD86745C6e81D4095A47979267267c2bf41fBFC46` |
| Hook | `0xb5bAbc5609de876D56662d066a0B5f63eF90a8CC` |
| Treasury registry | `0x093CD301Ce1AdEEdd9bC3814f9c00E42Ba603BeD` |
| Curve deployer (`ArcCurveDeployer`) | `0xCF6225669B65E779BaCd86465E9a240ac786B5D3` |
| cirBTC oracle (`CryptoPriceOracle`) | `0xf9d49B6b88C5C6b7Ac1424e83DcB41C41674fAf9` |

The deployment record is [deploy/arc-v2-core.candidate.json](deploy/arc-v2-core.candidate.json). The Safe's opening batch is [deploy/safe-arc-accept-and-open.json](deploy/safe-arc-accept-and-open.json).

## How a launch works on Arc

1. The creator calls `launch` with 1 native USDC as the fee. The factory deploys the token, its treasury and its curve in one transaction.
2. Buyers pay USDC. The trade router swaps it to cirBTC through the cirBTC/USDC Uniswap V3 pool and buys on the curve.
3. The buy that sells out the curve graduates the token in the same transaction. 70% of the raised cirBTC seeds a permanently locked V4 position. The other 30% goes to the treasury.
4. The treasury trades cirBTC against USDC in the V3 pool when its rule fires. It checks the pool against Chainlink BTC/USD before every trade. Anyone can call `execute()`, and the caller earns a bounty.

## Strategy kinds

| Kind | Treasury |
| --- | --- |
| 0 | Lot strategy: take-profit, dip and optional stop rungs chosen by the creator |
| 1 | Buy-back and burn |
| 2 | Spot engine: keeps the asset at a target share of the treasury |
| 3 | Rebalance by tradable percentage |
| 4 | Percentage buy-back |
| 5 | Cycle: sells, waits, then makes one bounded recovery buy |
| 6 | Lot strategy that sells an opening reserve for USDC after graduation |

## Layout

| Path | What |
| --- | --- |
| `src/v2/arc/HedgeFunV2ArcFactory.sol` | The Arc factory. It is the V2 factory with the listing's opening price scaled by 1e36, so an 8-decimal asset can be listed. |
| `src/v2/arc/ArcCurveDeployer.sol` | Curve and graduation module. Its `sqrtPrice` serves token/asset ratios above 2^64, which a 1e9-token supply against satoshis reaches. |
| `src/CryptoPriceOracle.sol`, `src/CryptoCalendar.sol` | Chainlink asset/USD over USDC/USD, open every day, with a halt held by the owner Safe |
| `src/v2/` | Bonding curve, treasuries, trade router, liquidity vault, strategy policies |
| `src/hooks/` | The Uniswap V4 hook: tax, opening snipe tax, TWAP ring |
| `script/arc/` | `DeployArcCore`, `DeployArcOracles`, `ListArcCrypto`, hand-over and verification |
| `test/ArcFork.t.sol` | The whole Arc path on an Arc mainnet fork |
| `test/ArcComponents.t.sol` | The Arc-only components without a fork |

## Build and test

```sh
git clone --recurse-submodules https://github.com/0xHedgeHood/arc_hedgefun
cd arc_hedgefun
forge build --sizes
forge test
```

Arc's USDC moves balances through a native precompile that stock Foundry does not have. Fork tests against Arc therefore use Circle's [Arc Foundry](https://github.com/circlefin/arc-foundry):

```sh
ARC_FORK=true arc-forge test --network arc --match-contract ArcForkTest -vv
```

That suite deploys the core, the cirBTC oracle and the listing on a fork of Arc mainnet. It then launches with a native USDC fee and buys through the real cirBTC/USDC pool to graduation. After graduation it trades on V4 and sells a take-profit into the real pool. A second test registers all seven strategy kinds and graduates a launch of each.

## License

MIT
