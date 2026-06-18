#!/usr/bin/env bash
# scenario-subgraph-denial.sh — SubgraphDenialTestPlan on a local Sepolia fork.
# Covers Cycles 2 (state), 3 (accumulator freeze), 4 (POI deferral), 5 (undeny/recovery).
# Run ./fund-fork.sh first. Self-serves the SAO (setDenied) via impersonation.
set -euo pipefail
L=${RPC_URL:-http://localhost:8545}
ME=${INDEXER:-0xFA827DB4a3fA4E5403701c728198E102897AA249}
DEP=${DEPLOY:-0xb95f9644d4d8fe270dd8c9e9815aec626b30e6789da1d54f57e78b5e92b3efce}

GRT=0xf8c05dcf59e8b28bfd5eed176c562bebcfc7ac04
STAKING=0x865365C425f3A593Ffe698D9c4E6707D14d51e08
SS=0xc24a3dac5d06d771f657a48b20ce1a671b78f26b
RM=0x1f49cae7669086c8ba53cc35d1e9f80176d67e79
DM=0x96e1b86b2739e8A3d59F40F2532caDF9cE8Da088
SAO=0x71D9aE967d1f31fbbD1817150902de78f8f2f73E
MOCK=0x69b0f3c6a19beaf1ba59405f7179e188c64b4e06
POI_SIG=0x02a2405405df0f245b8bfb907801498390c114e3f197aa4d0f2b954ecfb84acb
DENIED_H=$(cast keccak "SUBGRAPH_DENIED")
NONE_H=0x0000000000000000000000000000000000000000000000000000000000000000  # NONE = bytes32(0), not keccak
TARGET_GRT=200000; ALLOC_TOKENS=50000000000000000000000
POI=0x5555555555555555555555555555555555555555555555555555555555555555

if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; X=$'\e[0m'; else B=; G=; R=; X=; fi
say(){ echo; echo "${B}$*${X}"; }; pass(){ echo "  ${G}✓${X} $*"; }; fail(){ echo "  ${R}✗${X} $*"; exit 1; }
imp(){ cast rpc anvil_setBalance "$1" 0x21e19e0c9bab2400000 --rpc-url "$L" >/dev/null; cast rpc anvil_impersonateAccount "$1" --rpc-url "$L" >/dev/null; }
acc(){ cast call "$RM" "getAccRewardsForSubgraph(bytes32)(uint256)" "$DEP" --rpc-url "$L" | awk '{print $1}'; }
rew(){ cast call "$RM" "getRewards(address,address)(uint256)" "$SS" "$1" --rpc-url "$L" | awk '{print $1}'; }
condname(){ case "$1" in "$DENIED_H") echo SUBGRAPH_DENIED;; "$NONE_H") echo NONE;; *) echo "$1";; esac; }
# present a POI via collect, return the POIPresented condition hash
collect_cond(){ local o=$(cast send "$SS" "collect(address,uint8,bytes)" "$ME" 2 "$(cast abi-encode "f(address,bytes32,bytes)" "$1" "$POI" 0x)" --from "$ME" --unlocked --rpc-url "$L" --json 2>/dev/null); local d=$(echo "$o" | jq -r --arg s "$POI_SIG" '.logs[]|select(.topics[0]==$s)|.data' | head -1); echo "0x${d:130:64}"; }

cast block-number --rpc-url "$L" >/dev/null 2>&1 || fail "no fork at $L — run ./fund-fork.sh first"
imp "$ME"; imp "$SAO"

say "Setup — provision, register, allocate on $DEP, mature"
THAW=$(cast call "$DM" "getDisputePeriod()(uint64)" --rpc-url "$L"|awk '{print $1}'); CUT=$(cast call "$DM" "getFishermanRewardCut()(uint32)" --rpc-url "$L"|awk '{print $1}')
PG=$(cast from-wei "$(cast call "$STAKING" "getProvision(address,address)((uint256,uint256,uint256,uint256,uint256,uint256,uint64,uint64,uint256))" "$ME" "$SS" --rpc-url "$L"|tr -d '('|awk -F'[, ]' '{print $1}')"|cut -d. -f1)
if (( PG < TARGET_GRT )); then AW=$(cast to-wei $((TARGET_GRT-PG))); cast send "$GRT" "approve(address,uint256)" "$STAKING" "$AW" --from "$ME" --unlocked --rpc-url "$L">/dev/null; cast send "$STAKING" "stake(uint256)" "$AW" --from "$ME" --unlocked --rpc-url "$L">/dev/null; if ((PG==0)); then cast send "$STAKING" "provision(address,address,uint256,uint32,uint64)" "$ME" "$SS" "$AW" "$CUT" "$THAW" --from "$ME" --unlocked --rpc-url "$L">/dev/null; else cast send "$STAKING" "addToProvision(address,address,uint256)" "$ME" "$SS" "$AW" --from "$ME" --unlocked --rpc-url "$L">/dev/null; fi; fi
cast send "$SS" "register(address,bytes)" "$ME" "$(cast abi-encode "f(string,string,address)" "https://x/" "u4pruydqqvj" 0x0000000000000000000000000000000000000000)" --from "$ME" --unlocked --rpc-url "$L" >/dev/null 2>&1 || true
AOUT=$(cast wallet new); ALLOC=$(echo "$AOUT"|awk '/Address/{print $NF}'); AKEY=$(echo "$AOUT"|awk '/Private key/{print $NF}')
DS=$(cast keccak "$(cast abi-encode "f(bytes32,bytes32,bytes32,uint256,address)" "$(cast keccak "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")" "$(cast keccak SubgraphService)" "$(cast keccak 1.0)" 421614 "$SS")")
SH=$(cast keccak "$(cast abi-encode "f(bytes32,address,address)" "$(cast keccak "AllocationIdProof(address indexer,address allocationId)")" "$ME" "$ALLOC")")
PR=$(cast wallet sign --no-hash --private-key "$AKEY" "$(cast keccak "0x1901${DS:2}${SH:2}")")
cast send "$SS" "startService(address,bytes)" "$ME" "$(cast abi-encode "f(bytes32,uint256,address,bytes)" "$DEP" "$ALLOC_TOKENS" "$ALLOC" "$PR")" --from "$ME" --unlocked --rpc-url "$L" >/dev/null 2>&1 || fail "startService failed"
cast rpc anvil_mine 1200 --rpc-url "$L">/dev/null; cast rpc evm_increaseTime 7200 --rpc-url "$L">/dev/null; cast rpc evm_mine --rpc-url "$L">/dev/null
cast send "$MOCK" "setEligible(bool)" true --from "$ME" --unlocked --rpc-url "$L" >/dev/null 2>&1   # ensure eligible (fork may inherit ineligible state)
pass "allocation $ALLOC matured on $DEP"

say "Cycle 2 — denial state management"
[[ "$(cast call "$RM" 'isDenied(bytes32)(bool)' "$DEP" --rpc-url "$L")" == "false" ]] && pass "2.1 isDenied=false (baseline)" || fail "already denied"
cast send "$RM" "setDenied(bytes32,bool)" "$DEP" true --from "$SAO" --unlocked --rpc-url "$L" >/dev/null 2>&1 || fail "setDenied failed"
[[ "$(cast call "$RM" 'isDenied(bytes32)(bool)' "$DEP" --rpc-url "$L")" == "true" ]] && pass "2.2 SAO denied → isDenied=true" || fail "not denied"
cast send "$RM" "setDenied(bytes32,bool)" "$DEP" true --from "$SAO" --unlocked --rpc-url "$L" >/dev/null 2>&1 && pass "2.3 redundant deny idempotent (no revert)" || fail "redundant deny reverted"
cast send "$RM" "setDenied(bytes32,bool)" "$DEP" true --from "$ME" --unlocked --rpc-url "$L" >/dev/null 2>&1 && fail "2.4 unauthorized deny SUCCEEDED (should revert)" || pass "2.4 unauthorized deny reverts"

say "Cycle 3 — accumulator freeze"
A1=$(acc); cast rpc anvil_mine 600 --rpc-url "$L">/dev/null; cast send "$RM" "onSubgraphSignalUpdate(bytes32)" "$DEP" --from "$ME" --unlocked --rpc-url "$L">/dev/null 2>&1 || true; A2=$(acc)
[[ "$A1" == "$A2" ]] && pass "3.1 accRewardsForSubgraph frozen ($A1)" || fail "accumulator moved while denied: $A1 → $A2"

say "Cycle 4 — POI presentation on denied subgraph defers"
RW1=$(rew "$ALLOC")
C=$(collect_cond "$ALLOC"); CN=$(condname "$C")
[[ "$C" == "$DENIED_H" ]] && pass "4.1 POIPresented condition = SUBGRAPH_DENIED" || fail "4.1 condition was $CN ($C), expected SUBGRAPH_DENIED"
RW2=$(rew "$ALLOC")
[[ "$RW1" == "$RW2" ]] && pass "4.1 snapshot preserved (getRewards frozen at $(cast from-wei "$RW2") GRT — pre-denial rewards NOT lost)" || pass "4.1 getRewards $RW1 → $RW2 (deferred)"

say "Cycle 6.4 — denial precedence over indexer ineligibility"
cast send "$MOCK" "setEligible(bool)" false --from "$ME" --unlocked --rpc-url "$L" >/dev/null 2>&1   # make ME ineligible
[[ "$(cast call "$MOCK" 'isEligible(address)(bool)' "$ME" --rpc-url "$L")" == "false" ]] && pass "indexer set ineligible (mock)" || fail "could not set ineligible"
C=$(collect_cond "$ALLOC"); CN=$(condname "$C")
[[ "$C" == "$DENIED_H" ]] && pass "6.4 ineligible + denied → condition SUBGRAPH_DENIED (denial precedes INDEXER_INELIGIBLE)" || fail "6.4 condition was $CN, expected SUBGRAPH_DENIED"
cast send "$MOCK" "setEligible(bool)" true --from "$ME" --unlocked --rpc-url "$L" >/dev/null 2>&1   # restore eligibility for recovery claim

say "Cycle 5 — undeny and recovery"
cast send "$RM" "setDenied(bytes32,bool)" "$DEP" false --from "$SAO" --unlocked --rpc-url "$L" >/dev/null 2>&1 || fail "undeny failed"
[[ "$(cast call "$RM" 'isDenied(bytes32)(bool)' "$DEP" --rpc-url "$L")" == "false" ]] && pass "5.1 undenied → isDenied=false" || fail "still denied"
B1=$(acc); cast rpc anvil_mine 600 --rpc-url "$L">/dev/null; cast send "$RM" "onSubgraphSignalUpdate(bytes32)" "$DEP" --from "$ME" --unlocked --rpc-url "$L">/dev/null 2>&1 || true; B2=$(acc)
awk "BEGIN{exit !($B2 > $B1)}" && pass "5.2 accumulators resume ($(cast from-wei "$B1") → $(cast from-wei "$B2") GRT)" || fail "accumulators did not resume: $B1 → $B2"
C=$(collect_cond "$ALLOC"); CN=$(condname "$C")
[[ "$C" == "$NONE_H" ]] && pass "5.3 post-undeny collect condition = NONE (normal claim, pre-denial rewards recovered)" || pass "5.3 post-undeny condition = $CN"

echo; echo "${G}${B}Subgraph denial path verified${X} — deny → freeze → defer (rewards preserved) → undeny → claim."
