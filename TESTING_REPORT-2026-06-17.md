# REO Testing Report — 2026-06-17

**Subject**: Rewards Eligibility Oracle (REO / GIP-0088) on Arbitrum Sepolia
**Reference**: `graphprotocol/contracts` PR #1345 (`deployment/testnet/2026-06-09/gip-0088`)
**Tester**: lodestar-team · tooling: [`reo-doctor`](https://github.com/lodestar-team/reo-doctor)
**Method**: live read-only verification + live baseline transactions on Arbitrum Sepolia
(funded by Ørjan with 100k GRT), plus behavioural tests on a local `anvil` fork for the
parts that need coordinator powers or time-travel.

---

## Summary

REO's optimistic-denial model was reproduced: an eligible indexer collects indexing
rewards; an ineligible indexer's collect **reverts** (rewards preserved, not lost);
re-enabling eligibility restores collection. The exact revert string and POI-condition
hashes were confirmed on-chain.

**Honest scope** — what was tested *where*:
- **Live Arbitrum Sepolia**: baseline (stake/provision/register/allocate), Sets 2m, 3m, 4m.
  Set 3m was run twice on the same allocation: at epoch 11971 (birth epoch) it deferred as
  `ALLOCATION_TOO_YOUNG` with **no revert**, and at epoch 11972 (mature) it **reverted** with
  `Indexer not eligible for rewards` — demonstrating finding **F1** both ways, live.
- **Local fork** (the rest): production REO path (Sets 2–5 + fail-open), subgraph denial
  (Cycles 2–5 + 6.4), and reward conditions (POI matrix, reclaim config, below-min-signal).
  Done on a fork because they need coordinator roles (oracle/SAO/governor) and time-travel.

This is **comprehensive coverage of the REO-specific behaviour**, not 100% of every step in
all five test plans — see [`TEST_EXECUTION_LOG.md`](TEST_EXECUTION_LOG.md) for the exact
per-step matrix (including what was *not* run: full BaselineTestPlan, UI verification, some
CLI-driven lifecycle/observability steps, and Cycle 7 zero-signal).

The fork method is also offered to Edge & Node as a way to let testers reproduce these
flows without testnet GRT or coordinator access.

---

## Environment verified (live Arbitrum Sepolia, chainId 421614)

| Property | Value | Source |
|---|---|---|
| Active oracle (RewardsManager) | **Mock** `0x69b0…4e06` | `getProviderEligibilityOracle()` |
| `revertOnIneligible` | `true` | `getRevertOnIneligible()` |
| REO-A `eligibilityValidation` | `false` | `getEligibilityValidation()` |
| `eligibilityPeriod` | `1209600` s (14 d) | `getEligibilityPeriod()` |
| `maxPOIStaleness` (SubgraphService) | `28800` s (8 h) | `maxPOIStaleness()` |
| Dispute period / fisherman cut | `28800` s / `500000` ppm | DisputeManager |
| EIP-712 domain | name `SubgraphService`, version `1.0` | `eip712Domain()` |

All function signatures in the docs resolve correctly on-chain.

**Mainnet (Arbitrum One)**: REO contract is deployed (`0x8ec2…f304` has code) but **not yet
wired** — `RewardsManager.getProviderEligibilityOracle()` reverts. REO is therefore dormant
on mainnet; live testing is Sepolia-only.

---

## Funding and the two test substrates

- **Initial blocker**: provisioning needs the minimum stake (docs: 100k GRT). Sepolia GRT
  mint is gated (`Only minter can call`); there is no working faucet. We first worked around
  this with a fork (below).
- **Then funded**: Ørjan sent **100k GRT + ETH** to our indexer
  `0xfa82…a249`, which unblocked **live** baseline + collect testing on real Sepolia.
- **Why a fork is still used for parts**: the production-REO, denial, and reward-condition
  tests need **coordinator powers** (oracle/SAO/governor roles) and **time-travel** past the
  14-day eligibility period and 8-hour staleness window — neither of which a tester has on
  live testnet. A fork of Sepolia carries the real contracts and lets us impersonate those
  roles and advance time. Scripted in `playground/`.
- The fork also remains a faucet-free, coordinator-free way for *other* testers to reproduce
  these flows — offered to Edge & Node as an addition to the test materials.

---

## Test results — live Arbitrum Sepolia

Funded by Ørjan with 100k GRT + ETH to indexer
`0xfa827db4a3fa4e5403701c728198e102897aa249`.

| Step | Action | Result |
|---|---|---|
| Provision | stake 100k → `provision(SS, 100k, cut=500000, thaw=28800)` | ✅ tx `0x7de9c4ea…8308` |
| Register | `register(url, geohash, 0x0)` | ✅ tx `0x43d7cddf…8896` |
| Allocate ×3 | `startService` on 3 signalled deployments, 30k each (EIP-712 proof) | ✅ allocs `0xdFd9…c446`, `0x9cF3…F33d`, `0x102d…d207` |
| **Set 2m** | mock eligible → `collect(IndexingRewards)` | ✅ collect succeeded |
| **Set 3m** (birth epoch 11971) | `setEligible(false)` → collect | ⚠️ succeeded with **0** rewards, **no revert** (`ALLOCATION_TOO_YOUNG`) — see **F1** |
| **Set 3m** (mature, epoch 11972) | `setEligible(false)` → collect | ✅ **reverts** `Indexer not eligible for rewards` |
| **Set 4m** | `setEligible(true)` → collect | ✅ collect succeeded |

The Set 3m anomaly is **not** a contract bug: the allocation was still in its creation epoch
(`ALLOCATION_TOO_YOUNG`), so the collect distributed 0 and never reached the eligibility gate.
It is documented as finding **F1** and the collect harness now guards against running too early.
The genuine revert is corroborated on the fork (below), where the allocation was mature.

## Corroboration — local fork (mature allocation, reproduced cold-start)

| Step | Action | Result |
|---|---|---|
| Provision | stake + `provision(indexer, SS, 100k, cut=500000, thaw=28800)` | ✅ provision present |
| Register | `register(indexer, abi.encode(url, geohash, 0x0))` | ✅ registered |
| Allocate | `startService` with EIP-712 `AllocationIdProof(indexer, allocationId)` | ✅ allocation open, 50k tokens |
| **Set 2m** | mock eligible → `collect(indexer, IndexingRewards=2, …)` | ✅ **collect succeeded** |
| **Set 3m** | `setEligible(false)` → collect | ✅ **reverted: `Indexer not eligible for rewards`** |
| **Set 4m** | `setEligible(true)` → collect | ✅ **collect succeeded (recovery)** |

Confirms the **optimistic model**: while ineligible the collect reverts and accrued rewards
are preserved, not zeroed or reclaimed; on re-eligibility they are collectable in full.

### Key encodings confirmed against source (`graphprotocol/contracts@main`)
- `startService` data = `abi.encode(bytes32 subgraphDeploymentId, uint256 tokens, address allocationId, bytes proof)`
- proof = `allocationId` key signs the **pure EIP-712** digest of `AllocationIdProof(address indexer,address allocationId)` (no `eth_sign` prefix); domain `SubgraphService`/`1.0`.
- `collect` for indexing rewards: `feeType = 2` (`PaymentTypes.IndexingRewards`), data = `abi.encode(address allocationId, bytes32 poi, bytes poiMetadata)`.
- The on-chain close/collect does **not** verify POI correctness — an arbitrary non-zero POI
  is sufficient to exercise the rewards/eligibility path. (No graph-node needed for REO tests.)

---

## Findings

Issues are tracked separately in **[`FINDINGS.md`](FINDINGS.md)** to keep this report to
methodology + results. Headline: one validated test-guide finding (F1 — Set 3m silently
succeeds with 0 rewards, instead of reverting, on an immature/stale allocation; *correct*
contract behaviour but a real documentation trap) plus six documentation nits (F2–F7).

---

## Recommendations

1. **Add a fork-based path to the test materials.** It removes the 100k-GRT barrier entirely
   and lets any indexer reproduce Sets 2m–4m in minutes. `reo-doctor`'s `playground/` is
   offered as a starting point.
2. Apply findings #1–#2 before wider tester onboarding (both are actively misleading).
3. On mainnet, surface eligibility-expiry and POI-staleness as standing monitoring — the two
   ways REO can silently cost rewards. (`reo-doctor` roadmap targets exactly this.)

*Reproduce: `cd playground && ./fund-fork.sh && ./scenario-reo.sh` (requires Foundry).*
