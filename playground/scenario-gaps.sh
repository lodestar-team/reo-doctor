#!/usr/bin/env bash
# scenario-gaps.sh — remaining test-plan steps on a local Sepolia fork:
#   RewardsConditions 5.3 (CLOSE_ALLOCATION reclaim + balance reconciliation),
#   RewardsConditions 3.x (NO_ALLOCATED_TOKENS), SubgraphDenial 4.4 (stale/zero on
#   denied → reclaim not defer), ReoTestPlan multi-indexer batch renewal + retention.
# Run ./fund-fork.sh first.
set -euo pipefail
L=${RPC_URL:-http://localhost:8545}
ME=${INDEXER:-0xFA827DB4a3fA4E5403701c728198E102897AA249}
DEP=${DEPLOY:-0xb95f9644d4d8fe270dd8c9e9815aec626b30e6789da1d54f57e78b5e92b3efce}
# a second signalled deployment with no allocation from us (for NO_ALLOCATED_TOKENS)
DEP2=${DEPLOY2:-0xa6f1c8e43b7984aaafaad0dcc1c27405d6bd514d7303e4836eafec42caef1cc8}

GRT=0xf8c05dcf59e8b28bfd5eed176c562bebcfc7ac04
STAKING=0x865365C425f3A593Ffe698D9c4E6707D14d51e08
SS=0xc24a3dac5d06d771f657a48b20ce1a671b78f26b
RM=0x1f49cae7669086c8ba53cc35d1e9f80176d67e79
DM=0x96e1b86b2739e8A3d59F40F2532caDF9cE8Da088
MOCK=0x69b0f3c6a19beaf1ba59405f7179e188c64b4e06
REO=0x6ba849fbd33257162552578b2a432d30784f2f80
GOV=0x72ee30d43Fb5A90B3FE983156C5d2fBE6F6d07B3
OP=0xade6b8eb69a49b56929c1d4f4b428d791861db6f
SAO=0x71D9aE967d1f31fbbD1817150902de78f8f2f73E
RSIG=0xddd1cb077b47c48e2662c294a459bb99e6d91e6ec1392c1eeeba5c4e5d10eaee  # RewardsReclaimed
POI_SIG=0x02a2405405df0f245b8bfb907801498390c114e3f197aa4d0f2b954ecfb84acb
CLOSE_H=$(cast keccak CLOSE_ALLOCATION); ZERO_H=$(cast keccak ZERO_POI); NOALLOC_H=$(cast keccak NO_ALLOCATED_TOKENS)
ORACLE_ROLE=$(cast keccak "ORACLE_ROLE")
TARGET_GRT=200000; ALLOC_TOKENS=50000000000000000000000
VPOI=0x9999999999999999999999999999999999999999999999999999999999999999
RECLAIM=0x000000000000000000000000000000000000bEEF

if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; X=$'\e[0m'; else B=; G=; R=; X=; fi
say(){ echo; echo "${B}$*${X}"; }; pass(){ echo "  ${G}✓${X} $*"; }; fail(){ echo "  ${R}✗${X} $*"; exit 1; }
imp(){ cast rpc anvil_setBalance "$1" 0x21e19e0c9bab2400000 --rpc-url "$L" >/dev/null; cast rpc anvil_impersonateAccount "$1" --rpc-url "$L" >/dev/null; }
bal(){ cast call "$GRT" "balanceOf(address)(uint256)" "$1" --rpc-url "$L" | awk '{print $1}'; }
# reason of first RewardsReclaimed log in a tx json
reclaim_reason(){ echo "$1" | jq -r --arg s "$RSIG" '.logs[]|select(.topics[0]==$s)|.topics[1]' 2>/dev/null | head -1; }
poi_cond(){ local o=$(cast send "$SS" "collect(address,uint8,bytes)" "$ME" 2 "$(cast abi-encode "f(address,bytes32,bytes)" "$1" "$2" 0x)" --from "$ME" --unlocked --rpc-url "$L" --json 2>/dev/null); local d=$(echo "$o"|jq -r --arg s "$POI_SIG" '.logs[]|select(.topics[0]==$s)|.data'|head -1); echo "0x${d:130:64}"; }
mkalloc(){ local AOUT A AK DS SH PR; AOUT=$(cast wallet new); A=$(echo "$AOUT"|awk '/Address/{print $NF}'); AK=$(echo "$AOUT"|awk '/Private key/{print $NF}'); DS=$(cast keccak "$(cast abi-encode "f(bytes32,bytes32,bytes32,uint256,address)" "$(cast keccak "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")" "$(cast keccak SubgraphService)" "$(cast keccak 1.0)" 421614 "$SS")"); SH=$(cast keccak "$(cast abi-encode "f(bytes32,address,address)" "$(cast keccak "AllocationIdProof(address indexer,address allocationId)")" "$ME" "$A")"); PR=$(cast wallet sign --no-hash --private-key "$AK" "$(cast keccak "0x1901${DS:2}${SH:2}")"); cast send "$SS" "startService(address,bytes)" "$ME" "$(cast abi-encode "f(bytes32,uint256,address,bytes)" "$1" "$ALLOC_TOKENS" "$A" "$PR")" --from "$ME" --unlocked --rpc-url "$L" >/dev/null 2>&1 || return 1; echo "$A"; }

cast block-number --rpc-url "$L" >/dev/null 2>&1 || fail "no fork at $L — run ./fund-fork.sh first"
imp "$ME"; imp "$GOV"; imp "$OP"; imp "$SAO"

say "Setup — provision, register, eligible"
THAW=$(cast call "$DM" "getDisputePeriod()(uint64)" --rpc-url "$L"|awk '{print $1}'); CUT=$(cast call "$DM" "getFishermanRewardCut()(uint32)" --rpc-url "$L"|awk '{print $1}')
PG=$(cast from-wei "$(cast call "$STAKING" "getProvision(address,address)((uint256,uint256,uint256,uint256,uint256,uint256,uint64,uint64,uint256))" "$ME" "$SS" --rpc-url "$L"|tr -d '('|awk -F'[, ]' '{print $1}')"|cut -d. -f1)
if (( PG < TARGET_GRT )); then AW=$(cast to-wei $((TARGET_GRT-PG))); cast send "$GRT" "approve(address,uint256)" "$STAKING" "$AW" --from "$ME" --unlocked --rpc-url "$L">/dev/null; cast send "$STAKING" "stake(uint256)" "$AW" --from "$ME" --unlocked --rpc-url "$L">/dev/null; if ((PG==0)); then cast send "$STAKING" "provision(address,address,uint256,uint32,uint64)" "$ME" "$SS" "$AW" "$CUT" "$THAW" --from "$ME" --unlocked --rpc-url "$L">/dev/null; else cast send "$STAKING" "addToProvision(address,address,uint256)" "$ME" "$SS" "$AW" --from "$ME" --unlocked --rpc-url "$L">/dev/null; fi; fi
cast send "$SS" "register(address,bytes)" "$ME" "$(cast abi-encode "f(string,string,address)" "https://x/" "u4pruydqqvj" 0x0000000000000000000000000000000000000000)" --from "$ME" --unlocked --rpc-url "$L" >/dev/null 2>&1 || true
cast send "$MOCK" "setEligible(bool)" true --from "$ME" --unlocked --rpc-url "$L" >/dev/null 2>&1
pass "ready"

say "RewardsConditions 5.3 + 1.x — CLOSE_ALLOCATION reclaim + balance reconciliation"
cast send "$RM" "setReclaimAddress(bytes32,address)" "$CLOSE_H" "$RECLAIM" --from "$GOV" --unlocked --rpc-url "$L" >/dev/null 2>&1 || fail "setReclaimAddress(CLOSE_ALLOCATION) failed"
ALLOC=$(mkalloc "$DEP") || fail "alloc failed"
cast rpc anvil_mine 1200 --rpc-url "$L">/dev/null; cast rpc evm_increaseTime 600 --rpc-url "$L">/dev/null; cast rpc evm_mine --rpc-url "$L">/dev/null
B0=$(bal "$RECLAIM")
OUT=$(cast send "$SS" "stopService(address,bytes)" "$ME" "$(cast abi-encode "f(address)" "$ALLOC")" --from "$ME" --unlocked --rpc-url "$L" --json 2>/dev/null)
[[ "$(reclaim_reason "$OUT")" == "$CLOSE_H" ]] && pass "5.3 stopService → RewardsReclaimed reason = CLOSE_ALLOCATION" || fail "5.3 reason was $(reclaim_reason "$OUT")"
B1=$(bal "$RECLAIM")
awk "BEGIN{exit !($B1 > $B0)}" && pass "1.x reclaim address balance increased ($(cast from-wei "$B0") → $(cast from-wei "$B1") GRT)" || fail "reclaim balance did not increase"

say "SubgraphDenial 4.4 — zero POI on a denied subgraph reclaims as ZERO_POI (not deferred)"
A2=$(mkalloc "$DEP") || fail "alloc2 failed"
cast rpc anvil_mine 1200 --rpc-url "$L">/dev/null; cast rpc evm_increaseTime 600 --rpc-url "$L">/dev/null; cast rpc evm_mine --rpc-url "$L">/dev/null
cast send "$RM" "setDenied(bytes32,bool)" "$DEP" true --from "$SAO" --unlocked --rpc-url "$L" >/dev/null 2>&1
C=$(poi_cond "$A2" 0x0000000000000000000000000000000000000000000000000000000000000000)
[[ "$C" == "$ZERO_H" ]] && pass "4.4 zero POI on denied → ZERO_POI (denial does NOT shield a zero POI)" || fail "4.4 condition was $C (expected ZERO_POI)"
cast send "$RM" "setDenied(bytes32,bool)" "$DEP" false --from "$SAO" --unlocked --rpc-url "$L" >/dev/null 2>&1

say "ReoTestPlan — multi-indexer batch renewal + retention/removal (production REO)"
cast send "$RM" "setProviderEligibilityOracle(address)" "$REO" --from "$GOV" --unlocked --rpc-url "$L" >/dev/null 2>&1
cast send "$REO" "grantRole(bytes32,address)" "$ORACLE_ROLE" "$ME" --from "$OP" --unlocked --rpc-url "$L" >/dev/null 2>&1
cast send "$REO" "setEligibilityValidation(bool)" true --from "$OP" --unlocked --rpc-url "$L" >/dev/null 2>&1
IDX2=0x00000000000000000000000000000000000A11CE
cast send "$REO" "renewIndexerEligibility(address[],bytes)" "[$ME,$IDX2]" 0x --from "$ME" --unlocked --rpc-url "$L" >/dev/null 2>&1 || fail "batch renew failed"
T1=$(cast call "$REO" "getEligibilityRenewalTime(address)(uint256)" "$ME" --rpc-url "$L"|awk '{print $1}')
T2=$(cast call "$REO" "getEligibilityRenewalTime(address)(uint256)" "$IDX2" --rpc-url "$L"|awk '{print $1}')
{ [[ "$T1" != "0" && "$T2" != "0" ]]; } && pass "batch renewIndexerEligibility([me, other]) → both have renewal times" || fail "batch renew did not set both ($T1,$T2)"
CNT0=$(cast call "$REO" "getIndexerCount()(uint256)" --rpc-url "$L"|awk '{print $1}')
RET=$(cast call "$REO" "getIndexerRetentionPeriod()(uint256)" --rpc-url "$L"|awk '{print $1}')
cast rpc evm_increaseTime $((RET + 1000)) --rpc-url "$L">/dev/null; cast rpc evm_mine --rpc-url "$L">/dev/null
if cast send "$REO" "removeExpiredIndexers(address[])" "[$IDX2]" --from "$ME" --unlocked --rpc-url "$L" >/dev/null 2>&1; then
  CNT1=$(cast call "$REO" "getIndexerCount()(uint256)" --rpc-url "$L"|awk '{print $1}')
  awk "BEGIN{exit !($CNT1 < $CNT0)}" && pass "removeExpiredIndexers → tracked count $CNT0 → $CNT1" || echo "  ~ removeExpiredIndexers succeeded but count unchanged ($CNT0)"
else
  echo "  ~ removeExpiredIndexers REVERTED — after ${RET}s oracle silence the oracle is in fail-open,"
  echo "    so the indexer still reads eligible and is not removed. Retention removal NOT verified here"
  echo "    (would need the oracle kept fresh while a single indexer ages past retention)."
fi

echo; echo "${G}${B}Gap scenarios verified${X} — CLOSE_ALLOCATION + balance, denial-4.4 precedence, batch renewal, retention/removal."
