#!/usr/bin/env bash
# reo-doctor — read-only REO (Rewards Eligibility Oracle) status checker for
# Graph Network indexers. Reports the active oracle wiring, your eligibility,
# expiry countdown, and tells you which test set (or operational action) applies.
#
# GIP-0088 / REO. Read-only: only `cast call` (view) + a subgraph query. No keys.
#
# Usage:
#   ./reo-doctor.sh <indexer-address> [testnet|mainnet]
#
# Env:
#   RPC_URL        Optional. Override the default RPC for the chosen network.
#   GRAPH_API_KEY  Optional. If set, also lists your active allocations.
#
# Requires: cast (foundry), jq. curl only if GRAPH_API_KEY is set.

set -euo pipefail

# ---- args ---------------------------------------------------------------
INDEXER_RAW=${1:-}
NETWORK=${2:-testnet}
if [[ -z "$INDEXER_RAW" ]]; then
  echo "Usage: $0 <indexer-address> [testnet|mainnet]" >&2
  exit 1
fi
INDEXER=$(echo "$INDEXER_RAW" | tr '[:upper:]' '[:lower:]')

command -v cast >/dev/null || { echo "error: 'cast' (foundry) not found" >&2; exit 1; }
command -v jq   >/dev/null || { echo "error: 'jq' not found" >&2; exit 1; }

# ---- per-network wiring (verified against PR #1345 Testnet/MainnetDetails) ----
if [[ "$NETWORK" == "mainnet" ]]; then
  RPC=${RPC_URL:-https://arb1.arbitrum.io/rpc}
  REO=0x8ec2767a9d9ba02b4e09e8ff4fac2e14a340f304       # RewardsEligibilityOracleA
  MOCK=                                                  # no mock on mainnet
  REWARDS_MANAGER=0x971b9d3d0ae3eca029cab5ea1fb0f72c85e6a525
  SUBGRAPH_SERVICE=0xb2bb92d0de618878e438b55d5846cfecd9301105
  NET_SUBGRAPH=DZz4kDTdmzWLWsV373w2bSmoar3umKKH9y82SUKr5qmp
else
  NETWORK=testnet
  RPC=${RPC_URL:-https://sepolia-rollup.arbitrum.io/rpc}
  REO=0x6ba849fbd33257162552578b2a432d30784f2f80       # RewardsEligibilityOracleA
  MOCK=0x69b0f3c6a19beaf1ba59405f7179e188c64b4e06       # RewardsEligibilityOracleMock
  REWARDS_MANAGER=0x1f49cae7669086c8ba53cc35d1e9f80176d67e79
  SUBGRAPH_SERVICE=0xc24a3dac5d06d771f657a48b20ce1a671b78f26b
  NET_SUBGRAPH=3xQHhMudr1oh69ut36G2mbzpYmYxwqCeU6wwqyCDCnqV
fi

# ---- pretty ------------------------------------------------------------
if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; D=$'\e[2m'; X=$'\e[0m'
else B=; G=; Y=; R=; D=; X=; fi
ok(){   echo "  ${G}✓${X} $*"; }
warn(){ echo "  ${Y}!${X} $*"; }
bad(){  echo "  ${R}✗${X} $*"; }
hdr(){  echo; echo "${B}$*${X}"; }
lc(){ echo "$1" | tr '[:upper:]' '[:lower:]'; }
call(){ cast call "$1" "$2" "${@:3}" --rpc-url "$RPC" 2>/dev/null || true; }

echo "${B}reo-doctor${X} ${D}· $NETWORK · indexer $INDEXER${X}"

# ---- 1. oracle wiring --------------------------------------------------
hdr "Oracle wiring (RewardsManager $REWARDS_MANAGER)"
ACTIVE=$(lc "$(call "$REWARDS_MANAGER" 'getProviderEligibilityOracle()(address)')")
if [[ -z "$ACTIVE" ]]; then
  warn "RewardsManager has no eligibility oracle wired — REO is not active on $NETWORK yet."
  echo "  ${D}(The REO contracts may be deployed but not yet connected to RewardsManager.)${X}"
  echo; echo "${B}Verdict${X}"
  echo "  Nothing to test here yet. REO is currently live on Arbitrum Sepolia (testnet)."
  exit 0
fi
REVERT=$(call "$REWARDS_MANAGER" 'getRevertOnIneligible()(bool)')

MODE=unknown
if [[ -n "$MOCK" && "$ACTIVE" == "$(lc "$MOCK")" ]]; then MODE=mock
elif [[ "$ACTIVE" == "$(lc "$REO")" ]]; then MODE=production
fi

case "$MODE" in
  mock)       ok   "active oracle: MOCK ($ACTIVE) — you control your own eligibility";;
  production) ok   "active oracle: production REO ($ACTIVE)";;
  *)          warn "active oracle: $ACTIVE — matches neither known REO nor mock";;
esac
[[ "$REVERT" == "true" ]] && ok "revertOnIneligible = true (ineligible close reverts, rewards preserved)" \
                          || warn "revertOnIneligible = $REVERT (ineligible close does NOT revert — reclaim path)"

# ---- 2. REO parameters -------------------------------------------------
hdr "REO parameters ($REO)"
VALIDATION=$(call "$REO" 'getEligibilityValidation()(bool)')
PERIOD=$(call "$REO" 'getEligibilityPeriod()(uint256)' | awk '{print $1}')
[[ "$VALIDATION" == "true" ]] && ok "eligibilityValidation = true (enforced)" \
                              || warn "eligibilityValidation = false (everyone eligible — emergency/default state)"
printf "  ${D}·${X} eligibilityPeriod = %s s (~%s days)\n" "$PERIOD" "$(awk -v p="$PERIOD" 'BEGIN{printf "%.1f", p/86400}')"

# ---- 3. your eligibility ----------------------------------------------
hdr "Your eligibility"
ORACLE_TO_CHECK=$REO
[[ "$MODE" == "mock" ]] && ORACLE_TO_CHECK=$MOCK
ELIGIBLE=$(call "$ORACLE_TO_CHECK" 'isEligible(address)(bool)' "$INDEXER")
[[ "$ELIGIBLE" == "true" ]] && ok "isEligible = true" || bad "isEligible = false"

if [[ "$MODE" == "production" && "$VALIDATION" == "true" ]]; then
  RENEW=$(call "$REO" 'getEligibilityRenewalTime(address)(uint256)' "$INDEXER" | awk '{print $1}')
  NOW=$(call "$REWARDS_MANAGER" 'paused()(bool)' >/dev/null 2>&1; cast block latest --field timestamp --rpc-url "$RPC")
  if [[ "$RENEW" == "0" ]]; then
    warn "never renewed (renewalTime = 0)"
  else
    EXPIRY=$((RENEW + PERIOD)); LEFT=$((EXPIRY - NOW))
    if (( LEFT > 0 )); then ok "renewed; expires in ~$(awk -v l=$LEFT 'BEGIN{printf "%.1f", l/3600}') h"
    else bad "eligibility EXPIRED $(awk -v l=$((-LEFT)) 'BEGIN{printf "%.1f", l/3600}') h ago — renew to collect rewards"; fi
  fi
fi

# ---- 4. POI staleness rule --------------------------------------------
hdr "POI staleness guard (SubgraphService $SUBGRAPH_SERVICE)"
STALE=$(call "$SUBGRAPH_SERVICE" 'maxPOIStaleness()(uint256)' | awk '{print $1}' || true)
if [[ -n "${STALE:-}" ]]; then
  printf "  ${D}·${X} maxPOIStaleness = %s s (~%s days) — present a POI more often than this,\n" \
    "$STALE" "$(awk -v s="$STALE" 'BEGIN{printf "%.1f", s/86400}')"
  echo "    or accrued rewards are reclaimed as STALE_POI (you can't present a POI while ineligible)."
fi

# ---- 5. allocations + per-allocation STALE_POI countdown (optional) ----
# Returns 1 if any allocation is stale or within 1h of staleness (for the exit code).
ALLOC_ALERT=0
if [[ -n "${GRAPH_API_KEY:-}" ]]; then
  hdr "Active allocations — POI staleness countdown"
  URL="https://gateway.thegraph.com/api/$GRAPH_API_KEY/subgraphs/id/$NET_SUBGRAPH"
  Q=$(jq -Rs . <<GQL
{ allocations(where:{indexer_:{id:"$INDEXER"},status:"Active"}){ id subgraphDeployment{ipfsHash} } }
GQL
)
  RESP=$(curl -s "$URL" -H 'content-type: application/json' -d "{\"query\":$Q}")
  IDS=$(echo "$RESP" | jq -r '.data.allocations[]?.id' 2>/dev/null)
  if [[ -z "$IDS" ]]; then
    warn "no active allocations (or GRAPH_API_KEY/subgraph query failed)"
  elif [[ -z "${STALE:-}" ]]; then
    echo "$IDS" | while read -r id; do echo "  $id"; done
    warn "maxPOIStaleness unavailable — cannot compute countdown"
  else
    NOW=$(cast block latest --field timestamp --rpc-url "$RPC")
    # struct: (indexer, deployment, tokens, createdAt[f4], closedAt, lastPOIPresentedAt[f6], ...)
    af(){ call "$SUBGRAPH_SERVICE" 'getAllocation(address)((address,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,bool))' "$1" | tr -d '()' | cut -d, -f"$2" | awk '{print $1}'; }
    echo "$IDS" | while read -r id; do
      created=$(af "$id" 4); lastpoi=$(af "$id" 6)
      base=$lastpoi; [[ "${lastpoi:-0}" == "0" || "$created" -gt "${lastpoi:-0}" ]] && base=$created
      left=$(( base + STALE - NOW ))
      hrs=$(awk -v l=$left 'BEGIN{printf "%.1f", l/3600}')
      if   (( left <= 0 ));     then bad  "$id  ${R}STALE NOW${X} — rewards reclaimable as STALE_POI; present a POI";  echo stale >> /tmp/reo_alert.$$
      elif (( left < 3600 ));   then bad  "$id  stale in ${hrs}h — present a POI now";                                 echo stale >> /tmp/reo_alert.$$
      elif (( left < STALE/4 )); then warn "$id  stale in ${hrs}h";
      else ok "$id  healthy (stale in ${hrs}h)"; fi
    done
    [[ -f /tmp/reo_alert.$$ ]] && { ALLOC_ALERT=1; rm -f /tmp/reo_alert.$$; }
  fi
fi

# ---- verdict -----------------------------------------------------------
hdr "Verdict"
case "$MODE" in
  mock)
    echo "  Mock oracle is live → run IndexerTestGuide ${B}Sets 2m–4m${X}."
    echo "  Toggle your eligibility:  cast send $MOCK \"setEligible(bool)\" <true|false> --rpc-url $RPC --private-key \$KEY";;
  production)
    if [[ "$VALIDATION" == "true" ]]; then
      echo "  Production REO live, validation ON → run ${B}Sets 2–4${X} (renew → close → expire → recover)."
    else
      echo "  Production REO live, validation OFF → ${B}Set 5${X} (everyone eligible)."
    fi;;
  *) echo "  Unrecognised oracle — confirm the deployment before testing.";;
esac
if [[ "$ELIGIBLE" != "true" && "$REVERT" == "true" ]]; then
  echo "  ${Y}Note:${X} you are ineligible — closing an allocation will revert until you become eligible."
fi

# ---- exit code (cron / monitoring friendly) ---------------------------
#   0 = healthy   1 = action needed (ineligible while enforced, or an allocation stale/near-stale)
RC=0
[[ "$ELIGIBLE" != "true" && "$REVERT" == "true" && "$MODE" != "mock" ]] && RC=1
(( ALLOC_ALERT )) && RC=1
[[ "$RC" == "1" ]] && echo "  ${R}⚠ action needed${X} (exit 1)"
exit $RC
