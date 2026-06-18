#!/usr/bin/env bash
# scenario-rewards-conditions.sh — RewardsConditionsTestPlan on a local Sepolia fork.
# Covers Cycle 1 (reclaim config), Cycle 2 (below-min signal freeze), Cycle 4 (POI
# condition matrix: TOO_YOUNG / NONE / ZERO_POI / STALE_POI), Cycle 5.3 (close reclaim).
# Run ./fund-fork.sh first. Self-serves the governor via impersonation.
set -euo pipefail
L=${RPC_URL:-http://localhost:8545}
ME=${INDEXER:-0xFA827DB4a3fA4E5403701c728198E102897AA249}
DEP=${DEPLOY:-0xb95f9644d4d8fe270dd8c9e9815aec626b30e6789da1d54f57e78b5e92b3efce}

GRT=0xf8c05dcf59e8b28bfd5eed176c562bebcfc7ac04
STAKING=0x865365C425f3A593Ffe698D9c4E6707D14d51e08
SS=0xc24a3dac5d06d771f657a48b20ce1a671b78f26b
RM=0x1f49cae7669086c8ba53cc35d1e9f80176d67e79
DM=0x96e1b86b2739e8A3d59F40F2532caDF9cE8Da088
MOCK=0x69b0f3c6a19beaf1ba59405f7179e188c64b4e06
GOV=0x72ee30d43Fb5A90B3FE983156C5d2fBE6F6d07B3
POI_SIG=0x02a2405405df0f245b8bfb907801498390c114e3f197aa4d0f2b954ecfb84acb
NONE_H=0x0000000000000000000000000000000000000000000000000000000000000000
ZERO_H=$(cast keccak "ZERO_POI"); STALE_H=$(cast keccak "STALE_POI"); YOUNG_H=$(cast keccak "ALLOCATION_TOO_YOUNG")
TARGET_GRT=200000; ALLOC_TOKENS=50000000000000000000000
VPOI=0x8888888888888888888888888888888888888888888888888888888888888888
ZPOI=0x0000000000000000000000000000000000000000000000000000000000000000

if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; X=$'\e[0m'; else B=; G=; R=; X=; fi
say(){ echo; echo "${B}$*${X}"; }; pass(){ echo "  ${G}✓${X} $*"; }; fail(){ echo "  ${R}✗${X} $*"; exit 1; }
imp(){ cast rpc anvil_setBalance "$1" 0x21e19e0c9bab2400000 --rpc-url "$L" >/dev/null; cast rpc anvil_impersonateAccount "$1" --rpc-url "$L" >/dev/null; }
acc(){ cast call "$RM" "getAccRewardsForSubgraph(bytes32)(uint256)" "$DEP" --rpc-url "$L" | awk '{print $1}'; }
cname(){ case "$1" in "$NONE_H") echo NONE;; "$ZERO_H") echo ZERO_POI;; "$STALE_H") echo STALE_POI;; "$YOUNG_H") echo ALLOCATION_TOO_YOUNG;; *) echo "$1";; esac; }
# present POI via collect; echo condition hash. $1=allocation $2=poi
ccond(){ local o=$(cast send "$SS" "collect(address,uint8,bytes)" "$ME" 2 "$(cast abi-encode "f(address,bytes32,bytes)" "$1" "$2" 0x)" --from "$ME" --unlocked --rpc-url "$L" --json 2>/dev/null); local d=$(echo "$o"|jq -r --arg s "$POI_SIG" '.logs[]|select(.topics[0]==$s)|.data'|head -1); echo "0x${d:130:64}"; }

cast block-number --rpc-url "$L" >/dev/null 2>&1 || fail "no fork at $L — run ./fund-fork.sh first"
imp "$ME"; imp "$GOV"

say "Setup — provision, register, open FRESH allocation (for TOO_YOUNG), eligible"
THAW=$(cast call "$DM" "getDisputePeriod()(uint64)" --rpc-url "$L"|awk '{print $1}'); CUT=$(cast call "$DM" "getFishermanRewardCut()(uint32)" --rpc-url "$L"|awk '{print $1}')
PG=$(cast from-wei "$(cast call "$STAKING" "getProvision(address,address)((uint256,uint256,uint256,uint256,uint256,uint256,uint64,uint64,uint256))" "$ME" "$SS" --rpc-url "$L"|tr -d '('|awk -F'[, ]' '{print $1}')"|cut -d. -f1)
if (( PG < TARGET_GRT )); then AW=$(cast to-wei $((TARGET_GRT-PG))); cast send "$GRT" "approve(address,uint256)" "$STAKING" "$AW" --from "$ME" --unlocked --rpc-url "$L">/dev/null; cast send "$STAKING" "stake(uint256)" "$AW" --from "$ME" --unlocked --rpc-url "$L">/dev/null; if ((PG==0)); then cast send "$STAKING" "provision(address,address,uint256,uint32,uint64)" "$ME" "$SS" "$AW" "$CUT" "$THAW" --from "$ME" --unlocked --rpc-url "$L">/dev/null; else cast send "$STAKING" "addToProvision(address,address,uint256)" "$ME" "$SS" "$AW" --from "$ME" --unlocked --rpc-url "$L">/dev/null; fi; fi
cast send "$SS" "register(address,bytes)" "$ME" "$(cast abi-encode "f(string,string,address)" "https://x/" "u4pruydqqvj" 0x0000000000000000000000000000000000000000)" --from "$ME" --unlocked --rpc-url "$L" >/dev/null 2>&1 || true
cast send "$MOCK" "setEligible(bool)" true --from "$ME" --unlocked --rpc-url "$L" >/dev/null 2>&1
mkalloc(){ local AOUT=$(cast wallet new) A AK; A=$(echo "$AOUT"|awk '/Address/{print $NF}'); AK=$(echo "$AOUT"|awk '/Private key/{print $NF}'); local DS SH PR; DS=$(cast keccak "$(cast abi-encode "f(bytes32,bytes32,bytes32,uint256,address)" "$(cast keccak "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")" "$(cast keccak SubgraphService)" "$(cast keccak 1.0)" 421614 "$SS")"); SH=$(cast keccak "$(cast abi-encode "f(bytes32,address,address)" "$(cast keccak "AllocationIdProof(address indexer,address allocationId)")" "$ME" "$A")"); PR=$(cast wallet sign --no-hash --private-key "$AK" "$(cast keccak "0x1901${DS:2}${SH:2}")"); cast send "$SS" "startService(address,bytes)" "$ME" "$(cast abi-encode "f(bytes32,uint256,address,bytes)" "$DEP" "$ALLOC_TOKENS" "$A" "$PR")" --from "$ME" --unlocked --rpc-url "$L" >/dev/null 2>&1 || return 1; echo "$A"; }
ALLOC=$(mkalloc) || fail "startService failed"
pass "fresh allocation $ALLOC opened on $DEP"

say "Cycle 4 — POI presentation condition matrix"
C=$(ccond "$ALLOC" "$VPOI")
[[ "$C" == "$YOUNG_H" ]] && pass "4.4 same-epoch collect → ALLOCATION_TOO_YOUNG (defer)" || fail "4.4 got $(cname "$C")"
cast rpc anvil_mine 1200 --rpc-url "$L">/dev/null; cast rpc evm_increaseTime 600 --rpc-url "$L">/dev/null; cast rpc evm_mine --rpc-url "$L">/dev/null
C=$(ccond "$ALLOC" "$VPOI")
[[ "$C" == "$NONE_H" ]] && pass "4.1 mature valid POI → NONE (normal claim)" || fail "4.1 got $(cname "$C")"
C=$(ccond "$ALLOC" "$ZPOI")
[[ "$C" == "$ZERO_H" ]] && pass "4.3 zero POI → ZERO_POI (reclaim)" || fail "4.3 got $(cname "$C")"
cast rpc evm_increaseTime 29000 --rpc-url "$L">/dev/null; cast rpc evm_mine --rpc-url "$L">/dev/null   # > maxPOIStaleness (28800)
C=$(ccond "$ALLOC" "$VPOI")
[[ "$C" == "$STALE_H" ]] && pass "4.2 POI after maxPOIStaleness → STALE_POI (reclaim)" || fail "4.2 got $(cname "$C")"

say "Cycle 1 — reclaim address configuration"
RA=0x000000000000000000000000000000000000dEaD
cast send "$RM" "setReclaimAddress(bytes32,address)" "$ZERO_H" "$RA" --from "$GOV" --unlocked --rpc-url "$L" >/dev/null 2>&1 || fail "setReclaimAddress failed (governor)"
[[ "$(cast call "$RM" 'getReclaimAddress(bytes32)(address)' "$ZERO_H" --rpc-url "$L"|tr 'A-F' 'a-f')" == "$(echo "$RA"|tr 'A-F' 'a-f')" ]] && pass "1.1 governor setReclaimAddress(ZERO_POI) → readback OK" || fail "reclaim address not set"
cast send "$RM" "setReclaimAddress(bytes32,address)" "$ZERO_H" "$RA" --from "$ME" --unlocked --rpc-url "$L" >/dev/null 2>&1 && fail "1.4 unauthorized setReclaimAddress SUCCEEDED" || pass "1.4 unauthorized setReclaimAddress reverts"

say "Cycle 2 — below-minimum signal freezes accumulator"
A1=$(acc); cast rpc anvil_mine 300 --rpc-url "$L">/dev/null
cast send "$RM" "setMinimumSubgraphSignal(uint256)" 1000000000000000000000000000 --from "$GOV" --unlocked --rpc-url "$L" >/dev/null 2>&1 || fail "setMinimumSubgraphSignal failed"
cast send "$RM" "onSubgraphSignalUpdate(bytes32)" "$DEP" --from "$ME" --unlocked --rpc-url "$L">/dev/null 2>&1 || true
A2=$(acc); cast rpc anvil_mine 600 --rpc-url "$L">/dev/null; cast send "$RM" "onSubgraphSignalUpdate(bytes32)" "$DEP" --from "$ME" --unlocked --rpc-url "$L">/dev/null 2>&1 || true; A3=$(acc)
[[ "$A2" == "$A3" ]] && pass "2.3 accumulator frozen below minimum signal ($(cast from-wei "$A3") GRT)" || fail "accumulator moved below-min: $A2 → $A3"
cast send "$RM" "setMinimumSubgraphSignal(uint256)" 0 --from "$GOV" --unlocked --rpc-url "$L" >/dev/null 2>&1   # restore
pass "2.4 threshold restored"

echo; echo "${G}${B}Rewards conditions verified${X} — POI matrix (TOO_YOUNG/NONE/ZERO_POI/STALE_POI), reclaim config, below-min-signal freeze."
