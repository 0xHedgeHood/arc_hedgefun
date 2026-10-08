#!/usr/bin/env bash
# The Arc (5042) deployment, in order: core, kinds 1-6 and their policies, the cirBTC oracle, the listing, and the
# hand-over offer to the owner Safe. Everything is sent by the deploying key, which owns the factory until the Safe
# calls acceptOwnership(). See docs/ARC.md.
#
#   ARC_RPC=https://rpc.mainnet.arc.io AUTH="--account deployer" DEPLOYER=0x… SAFE=0x… script/arc/deploy-arc.sh
#   ARC_RPC=http://127.0.0.1:8546 AUTH=--unlocked DEPLOYER=0x… SAFE=0x… script/arc/deploy-arc.sh   # arc-anvil rehearsal
#
# With a keystore (--account or --keystore) the password is asked once, kept in a mode-600 temporary file for the
# run and deleted on exit; the key must decrypt to DEPLOYER before anything is sent. Requires arc-forge and arc-cast
# on PATH (Circle's Arc Foundry: stock forge cannot execute Arc's USDC). A run that stops can be run again: the core
# is not redeployed once deploy/arc-v2-core.candidate.json exists, and every later step checks the chain first.
set -euo pipefail
cd "$(dirname "$0")/../.."

: "${ARC_RPC:?}" "${AUTH:?}" "${DEPLOYER:?}" "${SAFE:?}"
FORGE=${ARC_FORGE:-arc-forge}
CAST=${ARC_CAST:-arc-cast}
CIRBTC=0x171A4217b86A807A64eB94757Db6849fb4bDbAA0
BOOK=deploy/arc-v2-core.candidate.json
# Foundry reads ETH_PASSWORD as a password FILE path for --keystore; a stray one breaks every forge call here.
unset ETH_PASSWORD

die() { echo "stopped: $*" >&2; exit 1; }
want() { [[ "$2" =~ $3 ]] || die "$1 is '${2}'"; }   # name, value, pattern
ADDR='^0x[0-9a-fA-F]{40}$'; WORD='^0x[0-9a-f]{64}$'
want DEPLOYER "$DEPLOYER" "$ADDR"; want SAFE "$SAFE" "$ADDR"

if [[ " $AUTH " == *" --account "* || " $AUTH " == *" --keystore "* ]] && [[ " $AUTH " != *" --password"* ]]; then
  read -rs -p "keystore password: " pw; echo
  pwfile=$(mktemp); chmod 600 "$pwfile"; trap 'rm -f "$pwfile"' EXIT
  printf '%s' "$pw" > "$pwfile"; unset pw
  AUTH="$AUTH --password-file $pwfile"
  # shellcheck disable=SC2086
  signer=$("$CAST" wallet address $AUTH) || die "the keystore did not decrypt"
  [ "$(echo "$signer" | tr A-F a-f)" = "$(echo "$DEPLOYER" | tr A-F a-f)" ] || die "the keystore is $signer, not DEPLOYER $DEPLOYER"
  echo "signer $signer"
fi

[ "$("$CAST" chain-id --rpc-url "$ARC_RPC")" = 5042 ] || die "the RPC is not Arc (5042)"
git diff --quiet HEAD -- src script || die "uncommitted changes under src/ or script/"
GIT_COMMIT=${GIT_COMMIT:-$(git rev-parse HEAD)}
# the manifests the 4663 policies were registered with (deploy/mainnet-v2-release.json .policies)
DEPENDENCY_MANIFEST_HASH=0x622f5df8202782f2d0566683a3f092251092537a6097dc684d1c9e8f4a2ccf09
AUDIT_MANIFEST_HASH=0x92699626cb0d34f148e0437182fa93e47d7adbec49a9c5f98e3cda9d238010cf
export OPERATOR=$DEPLOYER OWNER=$SAFE PROTOCOL=$SAFE GIT_COMMIT DEPENDENCY_MANIFEST_HASH AUDIT_MANIFEST_HASH
echo "deployer $DEPLOYER: $("$CAST" balance "$DEPLOYER" --rpc-url "$ARC_RPC" --ether) USDC, nonce $("$CAST" nonce "$DEPLOYER" --rpc-url "$ARC_RPC")"

# shellcheck disable=SC2086
run() { "$FORGE" script --network arc --rpc-url "$ARC_RPC" --sender "$DEPLOYER" $AUTH --broadcast --slow "$@"; }
read_() { "$CAST" call "$@" --rpc-url "$ARC_RPC"; }

if [ ! -f "$BOOK" ]; then
  echo "== 1. core"
  hash=$("$FORGE" script script/arc/ArcDefaultsHash.s.sol | awk '/ARC_DEFAULTS_HASH/ {print $2}')
  want "the defaults hash" "$hash" "$WORD"
  echo "defaults hash $hash"
  EXPECTED_DEFAULTS_HASH=$hash EXPECTED_SALE_BPS=7931 DEPLOYER_SETS_UP=true run script/arc/DeployArcCore.s.sol:DeployArcCore
fi
V2_FACTORY=$(python3 -c "import json;print(json.load(open('$BOOK'))['factory'])")
want "the factory" "$V2_FACTORY" "$ADDR"
export V2_FACTORY
echo "factory $V2_FACTORY"

registry=$(read_ "$V2_FACTORY" 'treasuryDeployer()(address)')
kinds=$(read_ "$registry" 'kindCount()(uint256)')
if [ "$kinds" = 1 ]; then
  echo "== 2. kinds 1 and 2";  run script/RegisterV2UpgradeableKinds.s.sol:RegisterV2UpgradeableKinds
  echo "== 3. kind 2 policy";  run script/RegisterV2RebalancePolicy.s.sol:RegisterV2RebalancePolicy
  echo "== 4. kind 3";         run script/RegisterV2TradablePercent.s.sol:RegisterV2TradablePercent
  echo "== 5. kind 4";         run script/RegisterV2PercentBuyback.s.sol:RegisterV2PercentBuyback
  echo "== 6. kind 5";         run script/RegisterV2UpgradeableCycle.s.sol:RegisterV2UpgradeableCycle
  echo "== 7. kind 6";         run script/RegisterV2LotReserve.s.sol:RegisterV2LotReserve
  kinds=$(read_ "$registry" 'kindCount()(uint256)')
fi
[ "$kinds" = 7 ] || die "the registry holds $kinds kinds: registration stopped part way; finish the remaining kinds by hand"

listed=$(read_ "$V2_FACTORY" 'listings(address)(address,address,uint256,bool)' "$CIRBTC" | tail -1)
if [ "$listed" != true ]; then
  if [ -z "${ORACLE_cirBTC:-}" ]; then
    echo "== 8. cirBTC oracle"
    out=$(SYMBOLS=cirBTC run script/arc/DeployArcOracles.s.sol:DeployArcOracles)
    echo "$out" | grep -E "^ *(calendar|oracle) 0x"
    ORACLE_cirBTC=$(echo "$out" | awk '/^ *oracle 0x/ {print $2}')
    want "the oracle" "$ORACLE_cirBTC" "$ADDR"
    echo "if the listing below stops, run again with ORACLE_cirBTC=$ORACLE_cirBTC"
  fi
  export ORACLE_cirBTC SYMBOLS=cirBTC
  echo "== 9. list cirBTC (oracle $ORACLE_cirBTC)"
  plan=$("$FORGE" script --network arc --rpc-url "$ARC_RPC" script/arc/ListArcCrypto.s.sol:ListArcCrypto --sig 'plan()')
  echo "$plan" | grep -E "^  " | head -12
  EXPECTED_PLAN_HASH=$(echo "$plan" | grep -A1 EXPECTED_PLAN_HASH | tail -1 | tr -d ' ')
  want "the plan hash" "$EXPECTED_PLAN_HASH" "$WORD"
  export EXPECTED_PLAN_HASH
  run script/arc/ListArcCrypto.s.sol:ListArcCrypto
fi

if [ "$(read_ "$V2_FACTORY" 'pendingOwner()(address)')" != "$SAFE" ] \
   && [ "$(read_ "$V2_FACTORY" 'owner()(address)')" = "$DEPLOYER" ]; then
  echo "== 10. offer the factory to the Safe"
  run script/arc/DeployArcCore.s.sol:HandOverArc
fi
echo "done. The Safe accepts with acceptOwnership() on $V2_FACTORY, then opens launch with setPublicLaunch(true)."
