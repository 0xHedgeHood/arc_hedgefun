# Scripts

Three groups, by the chain a script may touch. A mainnet script imports nothing from `testnet/`.

| Directory | Chain | What is there |
|---|---|---|
| `mainnet/` | Robinhood Chain, **4663** | `DeployV2MainnetCore` deploys the V2 core and refuses every other chain; `VerifyV2MainnetCore`, `HandOverV2Mainnet` and `VerifyV2MainnetHandOver` are in the same file. `RehearseV2Launchpad` runs the same code (`V2MainnetCore`, with `V2MainnetDefaults`) on a local fork, chain 31337, and refuses to broadcast. |
| `testnet/` | Robinhood testnet, **46630** | Every script bound to the testnet and its stand-ins: the test tokens, feeds, market and oracles (`Testnet*.sol`), the deployments built on them, the journeys and demos, and `ConfigureV2LaunchFees`. Each one checks the chain ID and refuses another. |
| this directory | whichever chain the factory is on | Owner operations that take the factory from the environment: `RegisterV2*` (strategy kinds and policies), `SetV2KeeperReward`, `ActivateV2NativeLaunch`, and the listing check `CheckV2Listings`. `helpers/` holds the guards the registrations share. They broadcast as the factory owner. |

Start from [docs/V2_DEPLOYMENT_REHEARSAL.md](../docs/V2_DEPLOYMENT_REHEARSAL.md) for mainnet and
[docs/TESTNET_V2.md](../docs/TESTNET_V2.md) for the testnet.

## What the mainnet core does and does not do

`DeployV2MainnetCore` sends seven transactions: the treasury registry (which creates kind 0 and the upgrade
controller), the token deployer, the curve deployer, the hook at a mined address, the factory, the trade router
and the native router. The factory is born with public launch closed, nothing listed, and kind 0 only.

It does not register a strategy kind or a policy, list a stock, whitelist a launch router or open public launch.
Those are the factory owner's. There is no mainnet script for listing stocks yet.

## Order of operations

1. `RehearseV2Launchpad` on a fork at a recent block, with the real Safes and wrapped native token, in the
   ownership mode you will use. Review the defaults and take their hash from its output.
2. `DeployV2MainnetCore`, then `VerifyV2MainnetCore` against the confirmed chain.
3. Owner setup: the `RegisterV2*` scripts for the kinds to offer, listings, and `ActivateV2NativeLaunch` if a
   launch is to buy with the native currency in one transaction. Each has its own `Verify*`.
4. If the deploying key did the setup: `HandOverV2Mainnet`, the Safe's `acceptOwnership()`, then
   `VerifyV2MainnetHandOver`.
5. The Safe opens public launch.

A strategy kind is permanent once registered and cannot be replaced. Register a kind only when its code is final.

## The whole sequence on a mainnet fork

`test/MainnetV2EndToEndFork.t.sol` runs steps 2 and 3 on a fork of chain 4663 and then uses what they built:
`DeployV2MainnetCore.deploy`, the four `RegisterV2*` scripts in the order above (kinds 1 to 5), a listing of the
real NVDA token, and one launch per kind taken through graduation and every action its strategy has, against the
real NVDA/USDG pool and oracle. A price move is a real swap on that pool plus a mocked report from the NVDA feed;
the file's header lists everything that is simulated. It is skipped unless asked for, and CI does not run it:

```sh
MAINNET_E2E=1 RH_RPC=<archive RPC URL> forge test --mc MainnetV2EndToEndForkTest -vv
```

It forks block 81,045,655 (2026-10-05, US session); `MAINNET_E2E_BLOCK` overrides that, and another block's pool
depth and prices may not fit the scenarios. No script registers the spot engine's policy (`V2RebalancePolicy`)
on mainnet yet; the test makes the owner's `registerPolicy` call directly.
