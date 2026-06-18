#!/usr/bin/env bash
# reo-doctor — read-only REO (Rewards Eligibility Oracle) monitor for Graph Network
# indexers. Reports oracle wiring, your eligibility + expiry, and a per-allocation
# STALE_POI countdown — the two ways REO can silently cost an indexer rewards.
#
# GIP-0088 / REO. Read-only: only `cast call` (view) + a subgraph query. No keys.
#
# Usage:
#   ./reo-doctor.sh <indexer-address> [testnet|mainnet] [--json|--prometheus] [--watch[=N]]
#
# Output modes:
#   (default)      human-readable
#   --json         one JSON object (machine-readable; for scripting/dashboards)
#   --prometheus   Prometheus exposition format (node_exporter textfile / pushgateway)
#   --watch[=N]    re-run every N seconds (default 60); Ctrl-C to stop
#
# Exit code: 0 = healthy, 1 = action needed (allocation stale/near-stale, or ineligible
#            while revertOnIneligible is on), 2 = REO not active on this network.
#
# Env: RPC_URL (override RPC), GRAPH_API_KEY (enables allocation countdowns).
# Requires: cast (foundry), jq; curl when GRAPH_API_KEY is set.

set -euo pipefail

# ---- args ---------------------------------------------------------------
FORMAT=human; WATCH=0; WATCH_INTERVAL=60; POSARGS=()
for a in "$@"; do
  case "$a" in
    --json) FORMAT=json;;
    --prometheus|--prom) FORMAT=prometheus;;
    --watch) WATCH=1;;
    --watch=*) WATCH=1; WATCH_INTERVAL=${a#--watch=};;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    --*) echo "unknown flag: $a" >&2; exit 1;;
    *) POSARGS+=("$a");;
  esac
done
INDEXER_RAW=${POSARGS[0]:-}; NETWORK=${POSARGS[1]:-testnet}
[[ -z "$INDEXER_RAW" ]] && { echo "Usage: $0 <indexer-address> [testnet|mainnet] [--json|--prometheus] [--watch[=N]]" >&2; exit 1; }
INDEXER=$(echo "$INDEXER_RAW" | tr '[:upper:]' '[:lower:]')
command -v cast >/dev/null || { echo "error: 'cast' (foundry) not found" >&2; exit 1; }
command -v jq   >/dev/null || { echo "error: 'jq' not found" >&2; exit 1; }

# ---- per-network wiring (verified against PR #1345 Testnet/MainnetDetails) ----
if [[ "$NETWORK" == "mainnet" ]]; then
  RPC=${RPC_URL:-https://arb1.arbitrum.io/rpc}
  REO=0x8ec2767a9d9ba02b4e09e8ff4fac2e14a340f304; MOCK=
  REWARDS_MANAGER=0x971b9d3d0ae3eca029cab5ea1fb0f72c85e6a525
  SUBGRAPH_SERVICE=0xb2bb92d0de618878e438b55d5846cfecd9301105
  NET_SUBGRAPH=DZz4kDTdmzWLWsV373w2bSmoar3umKKH9y82SUKr5qmp
else
  NETWORK=testnet
  RPC=${RPC_URL:-https://sepolia-rollup.arbitrum.io/rpc}
  REO=0x6ba849fbd33257162552578b2a432d30784f2f80; MOCK=0x69b0f3c6a19beaf1ba59405f7179e188c64b4e06
  REWARDS_MANAGER=0x1f49cae7669086c8ba53cc35d1e9f80176d67e79
  SUBGRAPH_SERVICE=0xc24a3dac5d06d771f657a48b20ce1a671b78f26b
  NET_SUBGRAPH=3xQHhMudr1oh69ut36G2mbzpYmYxwqCeU6wwqyCDCnqV
fi

lc(){ echo "$1" | tr '[:upper:]' '[:lower:]'; }
call(){ cast call "$1" "$2" "${@:3}" --rpc-url "$RPC" 2>/dev/null || true; }

# ===================== GATHER (compute state into globals) =====================
# Sets: MODE active_oracle REVERT VALIDATION PERIOD ELIGIBLE EXPIRY_LEFT(secs|"") STALE
#       NOW ALLOCS[] (each "id secs status") RC
gather(){
  ACTIVE=$(lc "$(call "$REWARDS_MANAGER" 'getProviderEligibilityOracle()(address)')")
  REVERT=$(call "$REWARDS_MANAGER" 'getRevertOnIneligible()(bool)')
  ALLOCS=(); RC=0; EXPIRY_LEFT=""; ELIGIBLE=""; VALIDATION=""; PERIOD=""; STALE=""
  if [[ -z "$ACTIVE" ]]; then MODE=dormant; RC=2; return; fi
  if [[ -n "$MOCK" && "$ACTIVE" == "$(lc "$MOCK")" ]]; then MODE=mock
  elif [[ "$ACTIVE" == "$(lc "$REO")" ]]; then MODE=production
  else MODE=unknown; fi

  VALIDATION=$(call "$REO" 'getEligibilityValidation()(bool)')
  PERIOD=$(call "$REO" 'getEligibilityPeriod()(uint256)' | awk '{print $1}')
  local oracle=$REO; [[ "$MODE" == "mock" ]] && oracle=$MOCK
  ELIGIBLE=$(call "$oracle" 'isEligible(address)(bool)' "$INDEXER")
  NOW=$(cast block latest --field timestamp --rpc-url "$RPC" 2>/dev/null || echo 0)
  if [[ "$MODE" == "production" && "$VALIDATION" == "true" ]]; then
    local renew; renew=$(call "$REO" 'getEligibilityRenewalTime(address)(uint256)' "$INDEXER" | awk '{print $1}')
    [[ -n "$renew" && "$renew" != "0" ]] && EXPIRY_LEFT=$(( renew + PERIOD - NOW ))
  fi
  STALE=$(call "$SUBGRAPH_SERVICE" 'maxPOIStaleness()(uint256)' | awk '{print $1}')
  [[ "$ELIGIBLE" != "true" && "$REVERT" == "true" && "$MODE" != "mock" ]] && RC=1

  # per-allocation staleness (needs GRAPH_API_KEY + maxPOIStaleness)
  [[ -z "${GRAPH_API_KEY:-}" || -z "$STALE" ]] && return
  local url="https://gateway.thegraph.com/api/$GRAPH_API_KEY/subgraphs/id/$NET_SUBGRAPH"
  local q resp ids id created lastpoi base left
  q=$(jq -Rs . <<GQL
{ allocations(where:{indexer_:{id:"$INDEXER"},status:"Active"}){ id } }
GQL
)
  resp=$(curl -s "$url" -H 'content-type: application/json' -d "{\"query\":$q}" 2>/dev/null || true)
  ids=$(echo "$resp" | jq -r '.data.allocations[]?.id' 2>/dev/null || true)
  [[ -z "$ids" ]] && return
  while read -r id; do
    [[ -z "$id" ]] && continue
    local s; s=$(call "$SUBGRAPH_SERVICE" 'getAllocation(address)((address,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,bool))' "$id" | tr -d '()')
    created=$(echo "$s" | cut -d, -f4 | awk '{print $1}'); lastpoi=$(echo "$s" | cut -d, -f6 | awk '{print $1}')
    base=${lastpoi:-0}; [[ "$base" == "0" || "${created:-0}" -gt "$base" ]] && base=${created:-0}
    left=$(( base + STALE - NOW ))
    local st=healthy
    if   (( left <= 0 ));      then st=stale; RC=1
    elif (( left < 3600 ));    then st=critical; RC=1
    elif (( left < STALE/4 )); then st=warn; fi
    ALLOCS+=("$id $left $st")
  done <<< "$ids"
}

# ===================== RENDERERS =====================
render_human(){
  if [[ -t 1 ]]; then local B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' D=$'\e[2m' X=$'\e[0m'
  else local B= G= Y= R= D= X=; fi
  echo "${B}reo-doctor${X} ${D}· $NETWORK · indexer $INDEXER${X}"
  if [[ "$MODE" == "dormant" ]]; then
    echo; echo "  ${Y}!${X} RewardsManager has no eligibility oracle wired — REO not active on $NETWORK yet."
    echo "  ${D}REO is currently live on Arbitrum Sepolia (testnet).${X}"; return
  fi
  echo; echo "${B}Oracle wiring${X}"
  case "$MODE" in
    mock) echo "  ${G}✓${X} active oracle: MOCK ($ACTIVE) — you control your own eligibility";;
    production) echo "  ${G}✓${X} active oracle: production REO ($ACTIVE)";;
    *) echo "  ${Y}!${X} active oracle: $ACTIVE — unrecognised";;
  esac
  [[ "$REVERT" == "true" ]] && echo "  ${G}✓${X} revertOnIneligible = true" || echo "  ${Y}!${X} revertOnIneligible = $REVERT"
  echo; echo "${B}Eligibility${X}"
  [[ "$ELIGIBLE" == "true" ]] && echo "  ${G}✓${X} isEligible = true" || echo "  ${R}✗${X} isEligible = false"
  if [[ -n "$EXPIRY_LEFT" ]]; then
    if (( EXPIRY_LEFT > 0 )); then echo "  ${D}·${X} expires in ~$(awk -v l=$EXPIRY_LEFT 'BEGIN{printf "%.1f",l/3600}') h"
    else echo "  ${R}✗${X} eligibility EXPIRED — renew to collect rewards"; fi
  fi
  if (( ${#ALLOCS[@]} )); then
    echo; echo "${B}Active allocations — POI staleness countdown${X}"
    local a id secs st hrs
    for a in "${ALLOCS[@]}"; do
      id=${a%% *}; secs=$(echo "$a"|awk '{print $2}'); st=${a##* }; hrs=$(awk -v s=$secs 'BEGIN{printf "%.1f",s/3600}')
      case "$st" in
        stale)    echo "  ${R}✗${X} $id  STALE NOW — reclaimable as STALE_POI; present a POI";;
        critical) echo "  ${R}✗${X} $id  stale in ${hrs}h — present a POI now";;
        warn)     echo "  ${Y}!${X} $id  stale in ${hrs}h";;
        *)        echo "  ${G}✓${X} $id  healthy (stale in ${hrs}h)";;
      esac
    done
  elif [[ -n "${GRAPH_API_KEY:-}" ]]; then echo; echo "  ${D}no active allocations${X}"; fi
  (( RC == 1 )) && { echo; echo "  ${R}⚠ action needed${X} (exit 1)"; }
}

render_json(){
  local allocs="[]" a id secs st
  if (( ${#ALLOCS[@]} )); then
    allocs=$(for a in "${ALLOCS[@]}"; do id=${a%% *}; secs=$(echo "$a"|awk '{print $2}'); st=${a##* }
      jq -nc --arg id "$id" --argjson s "$secs" --arg st "$st" '{allocation:$id,secondsToStale:$s,status:$st}'; done | jq -sc .)
  fi
  # precompute nullable numbers as valid JSON (number or null)
  local stale_j="null" expiry_j="null"
  [[ -n "${STALE:-}" ]] && stale_j="$STALE"
  [[ -n "${EXPIRY_LEFT:-}" ]] && expiry_j="$EXPIRY_LEFT"
  jq -nc \
    --arg net "$NETWORK" --arg idx "$INDEXER" --arg mode "$MODE" --arg oracle "${ACTIVE:-}" \
    --argjson revert "$([[ "$REVERT" == true ]] && echo true || echo false)" \
    --argjson elig "$([[ "$ELIGIBLE" == true ]] && echo true || echo false)" \
    --argjson validation "$([[ "$VALIDATION" == true ]] && echo true || echo false)" \
    --argjson stale "$stale_j" --argjson expiry "$expiry_j" \
    --argjson allocs "$allocs" --argjson rc "$RC" '
    {network:$net, indexer:$idx, oracleMode:$mode, oracle:$oracle, revertOnIneligible:$revert,
     isEligible:$elig, eligibilityValidation:$validation, maxPOIStaleness:$stale,
     secondsToExpiry:$expiry, allocations:$allocs, actionNeeded:($rc==1), exitCode:$rc}'
}

render_prometheus(){
  local ts; ts=""  # node_exporter textfile collector adds its own timestamp
  echo "# HELP reo_up reo-doctor scrape succeeded (1) / REO dormant (0)"
  echo "# TYPE reo_up gauge"
  echo "reo_up{network=\"$NETWORK\",indexer=\"$INDEXER\"} $([[ "$MODE" == dormant ]] && echo 0 || echo 1)"
  [[ "$MODE" == dormant ]] && return
  echo "# TYPE reo_eligible gauge"
  echo "reo_eligible{network=\"$NETWORK\",indexer=\"$INDEXER\"} $([[ "$ELIGIBLE" == true ]] && echo 1 || echo 0)"
  echo "# TYPE reo_revert_on_ineligible gauge"
  echo "reo_revert_on_ineligible{network=\"$NETWORK\"} $([[ "$REVERT" == true ]] && echo 1 || echo 0)"
  echo "# TYPE reo_action_needed gauge"
  echo "reo_action_needed{network=\"$NETWORK\",indexer=\"$INDEXER\"} $([[ "$RC" == 1 ]] && echo 1 || echo 0)"
  [[ -n "$EXPIRY_LEFT" ]] && { echo "# TYPE reo_eligibility_seconds_to_expiry gauge"; echo "reo_eligibility_seconds_to_expiry{network=\"$NETWORK\",indexer=\"$INDEXER\"} $EXPIRY_LEFT"; }
  if (( ${#ALLOCS[@]} )); then
    echo "# HELP reo_seconds_to_poi_stale seconds until allocation reclaimed as STALE_POI"
    echo "# TYPE reo_seconds_to_poi_stale gauge"
    local a id secs; for a in "${ALLOCS[@]}"; do id=${a%% *}; secs=$(echo "$a"|awk '{print $2}')
      echo "reo_seconds_to_poi_stale{network=\"$NETWORK\",indexer=\"$INDEXER\",allocation=\"$id\"} $secs"; done
  fi
}

run_once(){ gather; case "$FORMAT" in json) render_json;; prometheus) render_prometheus;; *) render_human;; esac; return "$RC"; }

# ===================== MAIN =====================
if (( WATCH )); then
  trap 'exit 0' INT
  while true; do
    [[ "$FORMAT" == human ]] && { clear 2>/dev/null || true; echo "# $(date '+%H:%M:%S') · every ${WATCH_INTERVAL}s · Ctrl-C to stop"; }
    run_once || true
    sleep "$WATCH_INTERVAL"
  done
else
  run_once
fi
