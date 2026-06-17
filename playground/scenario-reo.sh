#!/usr/bin/env bash
# scenario-reo.sh — drive the full REO indexer flow on a local Sepolia fork and
# assert the optimistic-denial behaviour. Run ./fund-fork.sh first (fork up +
# wallet funded with GRT). No testnet GRT, no graph-node, no waiting.
#
# Proves IndexerTestGuide Sets 2m–4m end to end:
#   provision → register → allocate (EIP-712 proof) → collect while eligible (ok)
#   → toggle ineligible → collect reverts → toggle eligible → collect ok.
#
# Usage:  ./scenario-reo.sh
# Env:    RPC_URL (default http://localhost:8545), INDEXER, INDEXER_KEY (defaults
#         to the playground wallet), DEPLOY (bytes32 of a signalled deployment).

set -euo pipefail

L=${RPC_URL:-http://localhost:8545}
ME=${INDEXER:-0xFA827DB4a3fA4E5403701c728198E102897AA249}
# A subgraph deployment WITH signal on Sepolia (so indexing rewards are non-zero).
# Frozen at fork block; override with DEPLOY=0x... if the fork is far from this one.
DEPLOY=${DEPLOY:-0xb95f9644d4d8fe270dd8c9e9815aec626b30e6789da1d54f57e78b5e92b3efce}

# Sepolia (GIP-0088) addresses
GRT=0xf8c05dcf59e8b28bfd5eed176c562bebcfc7ac04
STAKING=0x865365C425f3A593Ffe698D9c4E6707D14d51e08
SS=0xc24a3dac5d06d771f657a48b20ce1a671b78f26b
MOCK=0x69b0f3c6a19beaf1ba59405f7179e188c64b4e06
DM=0x96e1b86b2739e8A3d59F40F2532caDF9cE8Da088

STAKE=100000000000000000000000   # 100k GRT provisioned
ALLOC_TOKENS=50000000000000000000000  # 50k allocated
POI=0x1111111111111111111111111111111111111111111111111111111111111111  # arbitrary; close doesn't verify correctness

if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; X=$'\e[0m'; else B=; G=; R=; X=; fi
say(){ echo "${B}$*${X}"; }
pass(){ echo "  ${G}✓${X} $*"; }
fail(){ echo "  ${R}✗${X} $*"; exit 1; }
send(){ cast send "$@" --from "$ME" --unlocked --rpc-url "$L" >/dev/null 2>&1; }

cast block-number --rpc-url "$L" >/dev/null 2>&1 || fail "no fork at $L — run ./fund-fork.sh first"
cast rpc anvil_impersonateAccount "$ME" --rpc-url "$L" >/dev/null
cast rpc anvil_setBalance "$ME" 0x21e19e0c9bab2400000 --rpc-url "$L" >/dev/null  # gas

# Read the live constraints the SubgraphService enforces on a provision.
THAW=$(cast call "$DM" "getDisputePeriod()(uint64)" --rpc-url "$L" | awk '{print $1}')
CUT=$(cast call "$DM" "getFishermanRewardCut()(uint32)" --rpc-url "$L" | awk '{print $1}')

say "1. Provision $(cast from-wei "$STAKE") GRT to SubgraphService"
send "$GRT" "approve(address,uint256)" "$STAKING" "$STAKE"
send "$STAKING" "stake(uint256)" "$STAKE"
if cast call "$STAKING" "getProvision(address,address)((uint256,uint256,uint256,uint256,uint256,uint256,uint64,uint64,uint256))" "$ME" "$SS" --rpc-url "$L" | grep -q "^($STAKE,"; then
  pass "provision already present"
else
  send "$STAKING" "provision(address,address,uint256,uint32,uint64)" "$ME" "$SS" "$STAKE" "$CUT" "$THAW" || fail "provision failed"
  pass "provisioned (cut=$CUT thawing=$THAW)"
fi

say "2. Register on SubgraphService"
REG=$(cast abi-encode "f(string,string,address)" "https://reo-doctor.test/" "u4pruydqqvj" 0x0000000000000000000000000000000000000000)
send "$SS" "register(address,bytes)" "$ME" "$REG" || true   # reverts if already registered; fine
pass "registered"

say "3. Open allocation (EIP-712 AllocationIdProof)"
AOUT=$(cast wallet new); ALLOC=$(echo "$AOUT" | awk '/Address/{print $NF}'); AKEY=$(echo "$AOUT" | awk '/Private key/{print $NF}')
DTH=$(cast keccak "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
DOMSEP=$(cast keccak "$(cast abi-encode "f(bytes32,bytes32,bytes32,uint256,address)" "$DTH" "$(cast keccak SubgraphService)" "$(cast keccak 1.0)" 421614 "$SS")")
STRUCTH=$(cast keccak "$(cast abi-encode "f(bytes32,address,address)" "$(cast keccak "AllocationIdProof(address indexer,address allocationId)")" "$ME" "$ALLOC")")
PROOF=$(cast wallet sign --no-hash --private-key "$AKEY" "$(cast keccak "0x1901${DOMSEP:2}${STRUCTH:2}")")
ADATA=$(cast abi-encode "f(bytes32,uint256,address,bytes)" "$DEPLOY" "$ALLOC_TOKENS" "$ALLOC" "$PROOF")
send "$SS" "startService(address,bytes)" "$ME" "$ADATA" || fail "startService failed (is DEPLOY signalled on this fork?)"
cast call "$SS" "getAllocation(address)((address,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,bool))" "$ALLOC" --rpc-url "$L" | grep -qi "$ME" || fail "allocation not found on-chain"
pass "allocation $ALLOC opened"

say "4. Accrue rewards (mine blocks + advance time)"
cast rpc anvil_mine 1200 --rpc-url "$L" >/dev/null
cast rpc evm_increaseTime 14400 --rpc-url "$L" >/dev/null; cast rpc evm_mine --rpc-url "$L" >/dev/null
pass "advanced ~2 epochs"

CDATA=$(cast abi-encode "f(address,bytes32,bytes)" "$ALLOC" "$POI" 0x)
collect(){ cast send "$SS" "collect(address,uint8,bytes)" "$ME" 2 "$CDATA" --from "$ME" --unlocked --rpc-url "$L" 2>&1; }

say "5. Set 2m — collect while ELIGIBLE (expect success)"
[[ "$(cast call "$MOCK" 'isEligible(address)(bool)' "$ME" --rpc-url "$L")" == "true" ]] || fail "expected eligible"
collect >/dev/null 2>&1 && pass "collect succeeded" || fail "collect reverted while eligible"

say "6. Set 3m — toggle INELIGIBLE, collect (expect REVERT)"
send "$MOCK" "setEligible(bool)" false
cast rpc anvil_mine 1200 --rpc-url "$L" >/dev/null
OUT=$(collect || true)
echo "$OUT" | grep -qi "not eligible for rewards" && pass "reverted: Indexer not eligible for rewards" || fail "did not revert as expected: $OUT"

say "7. Set 4m — re-enable ELIGIBLE, collect (expect success)"
send "$MOCK" "setEligible(bool)" true
collect >/dev/null 2>&1 && pass "collect succeeded after recovery" || fail "collect reverted after recovery"

echo; say "${G}All REO scenarios passed.${X} Optimistic denial verified on a local fork — no testnet GRT required."
