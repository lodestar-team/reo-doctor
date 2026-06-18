#!/usr/bin/env bash
# scenario-reo-production.sh — drive the PRODUCTION REO path (real oracle, renewals,
# expiry, validation toggle, fail-open) on a local Sepolia fork, tied to real reward
# collection. Run ./fund-fork.sh first. Covers ReoTestPlan / IndexerTestGuide Sets 2–5.
#
# The fork lets us self-serve what a coordinator would otherwise provide on live testnet:
# point RewardsManager at the real REO, grant ourselves ORACLE_ROLE, enable validation,
# shorten the eligibility period, and time-travel through expiry and the oracle timeout.
#
# Usage:  ./scenario-reo-production.sh
set -euo pipefail
L=${RPC_URL:-http://localhost:8545}
ME=${INDEXER:-0xFA827DB4a3fA4E5403701c728198E102897AA249}
DEPLOY=${DEPLOY:-0xb95f9644d4d8fe270dd8c9e9815aec626b30e6789da1d54f57e78b5e92b3efce}

GRT=0xf8c05dcf59e8b28bfd5eed176c562bebcfc7ac04
STAKING=0x865365C425f3A593Ffe698D9c4E6707D14d51e08
SS=0xc24a3dac5d06d771f657a48b20ce1a671b78f26b
RM=0x1f49cae7669086c8ba53cc35d1e9f80176d67e79
REO=0x6ba849fbd33257162552578b2a432d30784f2f80
DM=0x96e1b86b2739e8A3d59F40F2532caDF9cE8Da088
GOV=0x72ee30d43Fb5A90B3FE983156C5d2fBE6F6d07B3   # RewardsManager governor (Controller)
OP=0xade6b8eb69a49b56929c1d4f4b428d791861db6f    # REO OPERATOR_ROLE
ORACLE_ROLE=$(cast keccak "ORACLE_ROLE")
# Provision must cover TOTAL allocated tokens (1:1). The fork inherits live-testnet state,
# where this indexer may already have a provision + open allocations, so we top up to a
# target that leaves room for this scenario's allocation.
TARGET_GRT=200000; ALLOC_TOKENS=50000000000000000000000
PERIOD=3600; POI=0x4444444444444444444444444444444444444444444444444444444444444444

if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; X=$'\e[0m'; else B=; G=; R=; X=; fi
say(){ echo; echo "${B}$*${X}"; }; pass(){ echo "  ${G}✓${X} $*"; }; fail(){ echo "  ${R}✗${X} $*"; exit 1; }
imp(){ cast rpc anvil_setBalance "$1" 0x21e19e0c9bab2400000 --rpc-url "$L" >/dev/null; cast rpc anvil_impersonateAccount "$1" --rpc-url "$L" >/dev/null; }
S(){ local f=$1; shift; cast send "$@" --from "$f" --unlocked --rpc-url "$L" >/dev/null 2>&1; }
elig(){ cast call "$REO" 'isEligible(address)(bool)' "$ME" --rpc-url "$L"; }

cast block-number --rpc-url "$L" >/dev/null 2>&1 || fail "no fork at $L — run ./fund-fork.sh first"
for a in "$ME" "$GOV" "$OP"; do imp "$a"; done

say "Setup — provision, register, allocate, mature"
THAW=$(cast call "$DM" "getDisputePeriod()(uint64)" --rpc-url "$L"|awk '{print $1}')
CUT=$(cast call "$DM" "getFishermanRewardCut()(uint32)" --rpc-url "$L"|awk '{print $1}')
PROV_WEI=$(cast call "$STAKING" "getProvision(address,address)((uint256,uint256,uint256,uint256,uint256,uint256,uint64,uint64,uint256))" "$ME" "$SS" --rpc-url "$L" | tr -d '(' | awk -F'[, ]' '{print $1}')
PROV_GRT=$(cast from-wei "${PROV_WEI:-0}" | cut -d. -f1)
if (( PROV_GRT < TARGET_GRT )); then
  ADD_WEI=$(cast to-wei $((TARGET_GRT - PROV_GRT)))
  S "$ME" "$GRT" "approve(address,uint256)" "$STAKING" "$ADD_WEI"
  S "$ME" "$STAKING" "stake(uint256)" "$ADD_WEI"
  if (( PROV_GRT == 0 )); then
    S "$ME" "$STAKING" "provision(address,address,uint256,uint32,uint64)" "$ME" "$SS" "$ADD_WEI" "$CUT" "$THAW"
  else
    S "$ME" "$STAKING" "addToProvision(address,address,uint256)" "$ME" "$SS" "$ADD_WEI"
  fi
fi
S "$ME" "$SS" "register(address,bytes)" "$ME" "$(cast abi-encode "f(string,string,address)" "https://reo-doctor.test/" "u4pruydqqvj" 0x0000000000000000000000000000000000000000)" 2>/dev/null || true
AOUT=$(cast wallet new); ALLOC=$(echo "$AOUT"|awk '/Address/{print $NF}'); AKEY=$(echo "$AOUT"|awk '/Private key/{print $NF}')
DOMSEP=$(cast keccak "$(cast abi-encode "f(bytes32,bytes32,bytes32,uint256,address)" "$(cast keccak "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")" "$(cast keccak SubgraphService)" "$(cast keccak 1.0)" 421614 "$SS")")
STRUCTH=$(cast keccak "$(cast abi-encode "f(bytes32,address,address)" "$(cast keccak "AllocationIdProof(address indexer,address allocationId)")" "$ME" "$ALLOC")")
PROOF=$(cast wallet sign --no-hash --private-key "$AKEY" "$(cast keccak "0x1901${DOMSEP:2}${STRUCTH:2}")")
S "$ME" "$SS" "startService(address,bytes)" "$ME" "$(cast abi-encode "f(bytes32,uint256,address,bytes)" "$DEPLOY" "$ALLOC_TOKENS" "$ALLOC" "$PROOF")" || fail "startService failed"
cast rpc anvil_mine 1200 --rpc-url "$L" >/dev/null; cast rpc evm_increaseTime 7200 --rpc-url "$L" >/dev/null; cast rpc evm_mine --rpc-url "$L" >/dev/null
pass "indexer provisioned + allocation $ALLOC matured"

say "Activate production REO (coordinator actions, self-served on fork)"
S "$GOV" "$RM" "setProviderEligibilityOracle(address)" "$REO" || fail "oracle switch failed"
[[ "$(cast call "$RM" 'getProviderEligibilityOracle()(address)' --rpc-url "$L"|tr 'A-F' 'a-f')" == "$(echo "$REO"|tr 'A-F' 'a-f')" ]] && pass "RewardsManager → production REO-A" || fail "oracle not switched"
S "$OP" "$REO" "grantRole(bytes32,address)" "$ORACLE_ROLE" "$ME" || fail "grantRole failed"
S "$OP" "$REO" "setEligibilityValidation(bool)" true
S "$OP" "$REO" "setEligibilityPeriod(uint256)" "$PERIOD"
pass "validation on, ORACLE_ROLE granted, period=${PERIOD}s"

CDATA=$(cast abi-encode "f(address,bytes32,bytes)" "$ALLOC" "$POI" 0x)
collect(){ cast send "$SS" "collect(address,uint8,bytes)" "$ME" 2 "$CDATA" --from "$ME" --unlocked --rpc-url "$L" 2>&1; }

say "Set 2 — renew eligibility, collect (expect success)"
S "$ME" "$REO" "renewIndexerEligibility(address[],bytes)" "[$ME]" 0x
[[ "$(elig)" == "true" ]] && pass "renewed → isEligible=true" || fail "not eligible after renew"
collect >/dev/null 2>&1 && pass "collect succeeded while eligible" || fail "collect reverted while eligible"

say "Set 3 — wait past eligibility period → expiry, collect (expect REVERT)"
cast rpc evm_increaseTime $((PERIOD + 100)) --rpc-url "$L" >/dev/null; cast rpc evm_mine --rpc-url "$L" >/dev/null
[[ "$(elig)" == "false" ]] && pass "expired → isEligible=false" || fail "still eligible after expiry"
cast rpc anvil_mine 300 --rpc-url "$L" >/dev/null   # accrue claimable rewards so the gate is reached
OUT=$(collect || true)
echo "$OUT" | grep -qi "not eligible for rewards" && pass "collect reverted: Indexer not eligible for rewards" || fail "did not revert: $OUT"

say "Set 4 — re-renew → recovery, collect (expect success)"
S "$ME" "$REO" "renewIndexerEligibility(address[],bytes)" "[$ME]" 0x
[[ "$(elig)" == "true" ]] && pass "re-renewed → isEligible=true" || fail "not eligible after re-renew"
collect >/dev/null 2>&1 && pass "collect succeeded after recovery" || fail "collect reverted after recovery"

say "Set 5 — validation disabled → eligible regardless"
S "$OP" "$REO" "setEligibilityValidation(bool)" false
[[ "$(elig)" == "true" ]] && pass "validation off → isEligible=true (no renewal needed)" || fail "ineligible with validation off"

say "Fail-open — oracle silent past timeout → eligible (safety net)"
S "$OP" "$REO" "setEligibilityValidation(bool)" true
S "$ME" "$REO" "renewIndexerEligibility(address[],bytes)" "[$ME]" 0x
cast rpc evm_increaseTime 605000 --rpc-url "$L" >/dev/null; cast rpc evm_mine --rpc-url "$L" >/dev/null   # > oracleUpdateTimeout (7d)
[[ "$(elig)" == "true" ]] && pass "7d oracle silence → isEligible=true (fail-open; renewal alone would be false)" || fail "fail-open did not engage"

echo; echo "${G}${B}Production REO path fully verified${X} — Sets 2–5 + fail-open, tied to real reward collection."
