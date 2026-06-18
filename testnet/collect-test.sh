#!/usr/bin/env bash
# collect-test.sh — run REO Sets 2m/3m/4m against the REAL Arbitrum Sepolia indexer
# set up by the baseline phase. Uses the funded wallet key + the per-allocation keys
# persisted under testnet/logs/. Run AFTER allocations have matured ≥1 epoch.
#
# Sets:
#   2m  collect while ELIGIBLE      → expect success (non-zero indexing rewards)
#   3m  setEligible(false), collect → expect revert "Indexer not eligible for rewards"
#   4m  setEligible(true),  collect → expect success (optimistic recovery)
#
# Usage:  ./collect-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

RPC=https://sepolia-rollup.arbitrum.io/rpc
SS=0xc24a3dac5d06d771f657a48b20ce1a671b78f26b
MOCK=0x69b0f3c6a19beaf1ba59405f7179e188c64b4e06
ME=0xfa827db4a3fa4e5403701c728198e102897aa249
KEY=$(cat .wallet/sepolia-indexer.key)
POI=0x2222222222222222222222222222222222222222222222222222222222222222  # arbitrary non-zero; correctness not checked on-chain
ALLOC=$(cat testnet/logs/alloc-1.addr)

if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; X=$'\e[0m'; else B=; G=; R=; X=; fi
pass(){ echo "  ${G}✓${X} $*"; }; fail(){ echo "  ${R}✗${X} $*"; }
# Maturity guard (see FINDINGS.md F1): the ineligible-collect revert only fires once the
# allocation is mature. While currentEpoch <= createdAtEpoch the collect succeeds with 0
# rewards and does NOT revert (ALLOCATION_TOO_YOUNG precedes the eligibility check).
EM=0x88b3C7f37253bAA1A9b95feAd69bD5320585826D
CUR=$(cast call "$EM" "currentEpoch()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
CREATED=$(cat testnet/logs/created.epoch 2>/dev/null || echo 0)
if [[ "$CREATED" != "0" && "$CUR" -le "$CREATED" ]]; then
  echo "${R}⚠ allocation too young${X}: currentEpoch=$CUR, createdAtEpoch=$CREATED."
  echo "  Set 3m will NOT revert yet (it returns 0, no revert). Wait for epoch > $CREATED, then re-run."
  exit 2
fi

CDATA=$(cast abi-encode "f(address,bytes32,bytes)" "$ALLOC" "$POI" 0x)
collect(){ cast send "$SS" "collect(address,uint8,bytes)" "$ME" 2 "$CDATA" --private-key "$KEY" --rpc-url "$RPC" 2>&1; }
toggle(){ cast send "$MOCK" "setEligible(bool)" "$1" --private-key "$KEY" --rpc-url "$RPC" >/dev/null 2>&1; }

echo "${B}Set 2m — collect while ELIGIBLE${X}  (alloc $ALLOC)"
toggle true
OUT=$(collect); echo "$OUT" | grep -qi "transactionHash\|status" && pass "collect succeeded while eligible" || { fail "unexpected:"; echo "$OUT" | tail -2; }

echo "${B}Set 3m — toggle INELIGIBLE, collect (expect revert)${X}"
toggle false
OUT=$(collect || true)
echo "$OUT" | grep -qi "not eligible for rewards" && pass "reverted: Indexer not eligible for rewards" || { fail "did not revert:"; echo "$OUT" | tail -2; }

echo "${B}Set 4m — re-enable ELIGIBLE, collect (expect success)${X}"
toggle true
OUT=$(collect); echo "$OUT" | grep -qi "transactionHash\|status" && pass "collect succeeded after recovery" || { fail "unexpected:"; echo "$OUT" | tail -2; }

echo; echo "Done. Verify reward amounts: query allocation indexingRewards in the network subgraph."
