#!/usr/bin/env bash
# The Arc (5042) deployment, in order: core, kinds 1-6 and their policies, the cirBTC oracle, the listing, and the
# hand-over offer to the owner Safe. Everything is sent by the deploying key, which owns the factory until the Safe
# calls acceptOwnership(). See docs/ARC.md.
#
#   ARC_RPC=https://rpc.mainnet.arc.io AUTH="--account deployer" script/arc/deploy-arc.sh      # Arc mainnet
#   ARC_RPC=http://127.0.0.1:8546 AUTH="--unlocked" script/arc/deploy-arc.sh                  # arc-anvil fork rehearsal
#
# Requires arc-forge and arc-cast on PATH (Circle's Arc Foundry; stock forge cannot execute Arc's USDC), DEPLOYER and SAFE. Each
# step reads back what it did and stops the run on any mismatch; a step that already landed is not repeated when the
# file it writes is present, so a run that stopped can be resumed.
set -euo pipefail
cd "$(dirname "$0")/../.."

: "${ARC_RPC:?}" "${AUTH:?}" "${DEPLOYER:?}" "${SAFE:?}"
FORGE=${ARC_FORGE:-arc-forge}
CAST=${ARC_CAST:-arc-cast}
GIT_COMMIT=${GIT_COMMIT:-$(git rev-parse HEAD)}
# the manifests the 4663 policies were registered with (deploy/mainnet-v2-release.json .policies)
DEPENDENCY_MANIFEST_HASH=0x622f5df8202782f2d0566683a3f092251092537a6097dc684d1c9e8f4a2ccf09
AUDIT_MANIFEST_HASH=0x92699626cb0d34f148e0437182fa93e47d7adbec49a9c5f98e3cda9d238010cf
BOOK=deploy/arc-v2-core.candidate.json
export OPERATOR=$DEPLOYER OWNER=$SAFE PROTOCOL=$SAFE GIT_COMMIT DEPENDENCY_MANIFEST_HASH AUDIT_MANIFEST_HASH

[ "$("$CAST" chain-id --rpc-url "$ARC_RPC")" = 5042 ] || { echo "not Arc (5042)"; exit 1; }
git diff --quiet HEAD -- src script || { echo "uncommitted changes under src/ or script/"; exit 1; }

run() { "$FORGE" script --network arc --rpc-url "$ARC_RPC" --sender "$DEPLOYER" $AUTH --broadcast --slow "$@"; }

if [ ! -f "$BOOK" ]; then
  echo "== 1. core"
  export EXPECTED_SALE_BPS=7931 DEPLOYER_SETS_UP=true
  export EXPECTED_DEFAULTS_HASH=$("$FORGE" script script/arc/ArcDefaultsHash.s.sol | awk '/ARC_DEFAULTS_HASH/ {print $2}')
  echo "defaults hash $EXPECTED_DEFAULTS_HASH"
  run script/arc/DeployArcCore.s.sol:DeployArcCore
fi
V2_FACTORY=$(python3 -c "import json;print(json.load(open('$BOOK'))['factory'])")
export V2_FACTORY
echo "factory $V2_FACTORY"

kinds=$("$CAST" call "$V2_FACTORY" 'treasuryDeployer()(address)' --rpc-url "$ARC_RPC" | xargs -I{} "$CAST" call {} 'kindCount()(uint256)' --rpc-url "$ARC_RPC")
if [ "$kinds" = 1 ]; then
  echo "== 2. kinds 1 and 2";  run script/RegisterV2UpgradeableKinds.s.sol:RegisterV2UpgradeableKinds
  echo "== 3. kind 2 policy";  run script/RegisterV2RebalancePolicy.s.sol:RegisterV2RebalancePolicy
  echo "== 4. kind 3";         run script/RegisterV2TradablePercent.s.sol:RegisterV2TradablePercent
  echo "== 5. kind 4";         run script/RegisterV2PercentBuyback.s.sol:RegisterV2PercentBuyback
  echo "== 6. kind 5";         run script/RegisterV2UpgradeableCycle.s.sol:RegisterV2UpgradeableCycle
  echo "== 7. kind 6";         run script/RegisterV2LotReserve.s.sol:RegisterV2LotReserve
fi

listed=$("$CAST" call "$V2_FACTORY" 'listings(address)(address,address,uint256,bool)' 0x171A4217b86A807A64eB94757Db6849fb4bDbAA0 --rpc-url "$ARC_RPC" | tail -1)
if [ "$listed" != true ]; then
  if [ -z "${ORACLE_cirBTC:-}" ]; then
    echo "== 8. cirBTC oracle"
    out=$(SYMBOLS=cirBTC run script/arc/DeployArcOracles.s.sol:DeployArcOracles)
    echo "$out" | grep -E "calendar|oracle"
    export ORACLE_cirBTC=$(echo "$out" | grep -E "^ *oracle 0x" | awk '{print $2}')
  fi
  echo "== 9. list cirBTC (oracle $ORACLE_cirBTC)"
  export SYMBOLS=cirBTC
  export EXPECTED_PLAN_HASH=$("$FORGE" script --network arc --rpc-url "$ARC_RPC" script/arc/ListArcCrypto.s.sol:ListArcCrypto --sig 'plan()' | grep -A1 EXPECTED_PLAN_HASH | tail -1 | tr -d ' ')
  run script/arc/ListArcCrypto.s.sol:ListArcCrypto
fi

if [ "$("$CAST" call "$V2_FACTORY" 'pendingOwner()(address)' --rpc-url "$ARC_RPC")" != "$SAFE" ] \
   && [ "$("$CAST" call "$V2_FACTORY" 'owner()(address)' --rpc-url "$ARC_RPC")" = "$DEPLOYER" ]; then
  echo "== 10. offer the factory to the Safe"
  run script/arc/DeployArcCore.s.sol:HandOverArc
fi
echo "done. The Safe accepts with acceptOwnership() on $V2_FACTORY, then opens launch with setPublicLaunch(true)."
