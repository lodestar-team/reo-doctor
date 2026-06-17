#!/usr/bin/env bash
# fund-fork.sh — stand up a local Arbitrum Sepolia fork and fund a wallet with
# testnet GRT + ETH, with no faucet and no permission. The fork carries the REAL
# REO / RewardsManager / SubgraphService / GRT contracts, so you can exercise the
# entire REO flow locally — for free, instantly, repeatably.
#
# This is how you test REO (and reo-doctor itself) when nobody will hand you 100k
# testnet GRT. On a fork we impersonate the GRT governor to mint ourselves GRT,
# and can fast-forward time to test eligibility expiry without waiting days.
#
# Usage:
#   ./fund-fork.sh [wallet-address] [grt-amount]
# Then point reo-doctor (or cast) at the fork:
#   RPC_URL=http://localhost:8545 ../reo-doctor.sh <wallet> testnet
#
# Requires: anvil + cast (foundry). Leaves anvil running in the background.

set -euo pipefail

UPSTREAM=${UPSTREAM_RPC:-https://sepolia-rollup.arbitrum.io/rpc}
PORT=${PORT:-8545}
L="http://localhost:$PORT"
ME=${1:-0xFA827DB4a3fA4E5403701c728198E102897AA249}
GRT_AMOUNT=${2:-200000}   # whole GRT

# Sepolia addresses (GIP-0088 deployment)
GRT=0xf8c05dcf59e8b28bfd5eed176c562bebcfc7ac04
GOV=0x72ee30d43Fb5A90B3FE983156C5d2fBE6F6d07B3   # GraphToken governor (can addMinter)

one_eth=0xde0b6b3a7640000

echo "▶ Starting fork of $UPSTREAM on :$PORT"
pkill -f "anvil --fork" 2>/dev/null || true; sleep 1
nohup anvil --fork-url "$UPSTREAM" --silent --port "$PORT" > /tmp/anvil-reo.log 2>&1 &
for i in $(seq 1 30); do
  cast block-number --rpc-url "$L" >/dev/null 2>&1 && break; sleep 1
done
echo "  forked at block $(cast block-number --rpc-url "$L")"

echo "▶ Funding $ME with ETH + $GRT_AMOUNT GRT"
cast rpc anvil_setBalance "$GOV" "$one_eth" --rpc-url "$L" >/dev/null
cast rpc anvil_setBalance "$ME"  "$one_eth" --rpc-url "$L" >/dev/null
cast rpc anvil_impersonateAccount "$GOV" --rpc-url "$L" >/dev/null
cast send "$GRT" "addMinter(address)" "$ME" --from "$GOV" --unlocked --rpc-url "$L" >/dev/null
cast rpc anvil_impersonateAccount "$ME" --rpc-url "$L" >/dev/null
WEI=$(cast to-wei "$GRT_AMOUNT")
cast send "$GRT" "mint(address,uint256)" "$ME" "$WEI" --from "$ME" --unlocked --rpc-url "$L" >/dev/null

BAL=$(cast call "$GRT" "balanceOf(address)(uint256)" "$ME" --rpc-url "$L" | awk '{print $1}')
echo "  GRT balance: $(cast from-wei "$BAL") GRT"
echo
echo "✓ Fork funded. RPC: $L"
echo "  Impersonation stays on — drive provision/allocate/REO toggles with --unlocked."
echo "  Fast-forward time:  cast rpc evm_increaseTime <seconds> --rpc-url $L && cast rpc evm_mine --rpc-url $L"
echo "  Stop the fork:      pkill -f 'anvil --fork'"
