# Arc (5042)

Status: source, scripts and fork tests. Nothing is deployed on Arc yet. Every number below was read from Arc mainnet on 2026-10-07.

Arc is Circle's L1. Its gas token is USDC: the native balance has 18 decimals, and the ERC-20 at `0x3600000000000000000000000000000000000000` shows the same balance with 6 decimals. Chain ID 5042, RPC `https://rpc.mainnet.arc.io`, explorer `https://explorer.arc.io`. Testnet is 5042002.

## What runs on Arc

The V2 launchpad with crypto assets in place of stock tokens. Launches pair with cirBTC first. WETH follows once a Uniswap V3 WETH/USDC pool has depth (see [WETH](#weth)).

The core is the 4663 core with two contracts swapped and one removed:

| 4663 | Arc | Why |
| --- | --- | --- |
| `HedgeFunV2Factory` | `HedgeFunV2ArcFactory` | A listing's opening price is scaled by 1e36 (1e18 on 4663). On 4663 one unit of the listed price is 1e9 raw stock units across the 1e9-token supply. For 8-decimal cirBTC that is 10 BTC, about $830,000 of opening FDV, so the ~$2,140 opening rounds to zero. With 1e36 the cirBTC opening price is about 2.57e15. |
| `CurveDeployer` | `ArcCurveDeployer` | `sqrtPrice` squares the token/stock ratio in Q192, which overflows at a ratio of 2^64. A 1e9-token supply over ~2.6M satoshis is ~3.9e20. At and above 2^64 the Arc deployer takes the root of the Q128 ratio and shifts it up 32 bits. Below 2^64 its answer is the 4663 deployer's, bit for bit. |
| `HedgeFunV2NativeRouter` | none | Arc's native currency is USDC, and there is no wrapped form to deposit into. Buyers approve USDC to `HedgeFunV2TradeRouter` like any ERC-20. |

Everything else is the 4663 code: token and treasury deployers, the hook, the trade router, all seven strategy kinds, the vault and the upgrade controller. Both swapped contracts are copies of the originals with that one difference each. The originals are untouched, so `tools/verify_mainnet_release.py` still finds no modified file under `src/` against the 4663 release commit.

The two new oracle contracts are `CryptoPriceOracle` and `CryptoCalendar`, described below.

## Venues

| | Address | Note |
| --- | --- | --- |
| Uniswap V4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | Same address as on 4663. The hook mines to the same salt range. |
| Uniswap V3 factory | `0xf0db7b58379503491d857dB50AC9ece64c653918` | Not in Uniswap's deployment list. Its runtime is the 4663 V3 factory's byte for byte except the 20-byte self-address immutable, and its pools match 4663's V3 pools except their immutables. |
| cirBTC/USDC 0.01% | `0x82916bee18fCEF517B26C72d7Cb5F13694E1dB41` | About 6.0M USDC and 65.6 cirBTC; observation ring 3,600 slots. |
| CREATE2 deployer | `0x4e59b44847b379578588920cA78FbF26c0B4956C` | |
| Safe v1.4.1 / v1.3.0 | Canonical addresses | Both have code on Arc, so the owner and protocol Safes are created the usual way. |

## Price

`CryptoPriceOracle` divides Chainlink BTC/USD (`0xa109B535C70C8Be9995be64Bb6751AcDB27e03De`) by Chainlink USDC/USD (`0x84EA90AC252Dc437031461836DB5164219147905`). Its read functions are `PriceOracle`'s, so listings and treasuries use it unchanged. It differs from `PriceOracle` in two places:

- It never asks the asset for `oraclePaused()`. cirBTC and WETH have no such function, and `PriceOracle` would fail closed on them forever.
- Its calendar is a `CryptoCalendar`, open every day. The engines' daily turnover rolls at 00:00 UTC. The owner Safe can halt it. While halted every oracle on it answers false and treasuries stop. Curve and pool trading continue.

Both Arc feeds print on a 0.5% move or every 24 hours. Each leg is refused after 25 hours. A pool can sit up to 0.5% from the last print with nothing wrong, so the Arc defaults set the deviation gate to 100 bps (50 on 4663) and the slippage bound to 150 bps (100 on 4663).

The higher slippage raises the floors a creator meets on Arc:

| Floor | 4663 (0.05% pool) | Arc cirBTC (0.01% pool) |
| --- | --- | --- |
| Take-profit and dip rungs, 2 x (slippage + pool fee) | 2.10% | 3.02% |
| Engine band, 2 x (slippage + pool fee + bounty) | 2.30% | 3.22% |

The launch fee is 1 native USDC, paid as `msg.value = 1e18` and forwarded to the protocol Safe. No approval is needed.

The listing targets the same $50,000 graduation FDV as on 4663: $2,140 opening FDV with 79.31% sold. The ArcStockpad launchpad graduates at $17,000 FDV, for comparison.

## Tooling

Arc's USDC moves balances through a native precompile at `0x1800000000000000000000000000000000000000`. Stock Foundry does not have it, so every USDC transfer on an Arc fork reverts. Use Circle's Arc Foundry:

```sh
gh release download v0.8.0-2 -R circlefin/arc-foundry -p 'arc-foundry-v0.8.0-2-aarch64-apple-darwin.tar.gz*'
shasum -a 256 -c arc-foundry-v0.8.0-2-aarch64-apple-darwin.tar.gz.sha256
tar -xzf arc-foundry-v0.8.0-2-aarch64-apple-darwin.tar.gz   # forge, cast, anvil; install as arc-forge etc.
```

The macOS binary links Homebrew's libusb (`brew install libusb`). It compiles with the repo's pinned solc 0.8.26, so bytecode is the same as stock Foundry's.

Fork tests are opt-in:

```sh
forge test --match-contract ArcComponentsTest                       # stock Foundry, no fork
ARC_FORK=true arc-forge test --network arc --match-contract ArcForkTest
```

`ArcForkTest` deploys the core with `DeployArcCore`, the oracle with `DeployArcOracles`, and lists cirBTC with `ListArcCrypto`. It then runs three tests:

- a native-USDC launch fee, curve buys paid in USDC through the real cirBTC pool, graduation into V4, a V4 round trip, and a take-profit sold into the real cirBTC pool after a 6% move;
- kinds 1 to 6 registered by the production scripts, then one launch of each of the seven kinds bought through to graduation;
- the listed opening price against the $2,140 target.

`vm.deal` funds native USDC there, which the ERC-20 view reads as the same balance.

## Deployment order

Every script refuses a chain other than 5042. Run each with `arc-forge script ... --network arc --rpc-url arc`. Use a `maxFeePerGas` of at least 20 gwei: the mempool drops anything lower without an error.

1. Create the owner and protocol Safes (two signatures at least).
2. `DeployArcCore`: six contracts. Needs OWNER, PROTOCOL, GIT_COMMIT, EXPECTED_DEFAULTS_HASH (`keccak256(abi.encode(ArcDefaults.release()))`) and EXPECTED_SALE_BPS=7931. With DEPLOYER_SETS_UP=true the deploying key owns the factory until `HandOverArc`. Then `VerifyArcCore`.
3. Register kinds 1 to 6 with the 4663 scripts: `RegisterV2UpgradeableKinds`, `RegisterV2TradablePercent`, `RegisterV2PercentBuyback`, `RegisterV2UpgradeableCycle`, `RegisterV2LotReserve`. On 5042 their runtime pins (`script/helpers/IncomeKindCompatibility.sol`) check the Arc factory and curve deployer templates. Kind 6 links the `LotReserveScheduler` library, which must be deployed on Arc first. Register the spot engine's policy as on 4663.
4. `DeployArcOracles` with OWNER and SYMBOLS=cirBTC: one `CryptoCalendar` owned by the owner Safe and one oracle. It checks each feed's description and decimals and requires a live price.
5. `ListArcCrypto`: run `plan()` with SYMBOLS=cirBTC and ORACLE_cirBTC, review, then `run()` with EXPECTED_PLAN_HASH. Gates 100 / 150 / 2,000 USDC; LP share 7,000; band ceiling zero.
6. `HandOverArc`, the Safe accepts, `VerifyArcHandOver`. The Safe opens public launch.

The scripts write `deploy/arc-v2-core.candidate.json` (or `.dryrun.json`). Like the 4663 candidate, it is unverified until the receipts and `VerifyArcCore` agree.

`script/arc/deploy-arc.sh` runs steps 2 to 6 in that order, with the deploying key as the factory owner until the hand-over, and resumes from where a stopped run left off. Rehearse it first on a local fork, where the same nonces give the same addresses:

```sh
arc-anvil --network arc --fork-url https://rpc.mainnet.arc.io --auto-impersonate --port 8546 --chain-id 5042
ARC_RPC=http://127.0.0.1:8546 AUTH=--unlocked DEPLOYER=0x… SAFE=0x… script/arc/deploy-arc.sh
```

On 2026-10-08 the rehearsal took 36 transactions and 1.64 USDC of gas. Delete `deploy/arc-v2-core.candidate.json` and `broadcast/*/5042` before the real run, which is the same command with `ARC_RPC=https://rpc.mainnet.arc.io AUTH="--account deployer"`. The Safe then sends `acceptOwnership()` (`0x79ba5097`) and `setPublicLaunch(true)` (`0x3d1a7ae3` followed by the word 1) to the factory.

`LaunchArcToken` launches a cirBTC token from the broadcasting wallet, and `BuyArcToken` buys one with USDC. Send the buy in a later block: in a launch's first three seconds the opening snipe tax is up to 99%.

## WETH

`ArcAssets` carries WETH with no pool, so `ListArcCrypto` refuses it. Arc's WETH/USDC depth is in an Aerodrome Slipstream pool (`0x6F302dECb49fB30B2D2c609BDD16e04e7Dd096FC`, about $880,000). The core cannot trade there: Slipstream's `getPool` takes a tick spacing, and its `slot0` returns six words where Uniswap V3 returns seven. The Uniswap V3 WETH/USDC pools held about $1,200.

To list WETH:

1. Fund the 0.05% WETH/USDC pool on the V3 factory above. Arbitrage against Slipstream keeps it priced. A 2,000 USDC treasury sale should move it well under 1%. In a ±10% range that takes roughly $20,000 to $80,000 of liquidity, depending on the chunk.
2. Grow its observation ring to at least 660 slots (`increaseObservationCardinalityNext`).
3. Set the pool and fee in `ArcAssets`, then run steps 4 and 5 for WETH.

WETH has 18 decimals, so neither Arc contract change is needed for it, and both handle it.

## Front end

- Chain 5042, native currency USDC with 18 decimals, explorer `explorer.arc.io`.
- Launch: `launch{value: 1e18}`. Buy and sell: approve USDC (6 decimals) to the trade router; a cirBTC route is one hop through `0x8291…dB41`.
- The listed `openPriceE18` on Arc is raw stock per raw token times 1e36. Read `OPEN_PRICE_SCALE()` on the factory.
- There is no native router.
