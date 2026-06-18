# REO Test Execution Log

Step-by-step completion + observations for the REO test coordination (Edge & Node — @Rem).
Plans: `IndexerTestGuide.md` (mock Sets 2m–4m, production Sets 2–5) on PR #1345.

**Test plans tested at commit** `14823afc9f396ebaba6398994b25989d4c249d51`
(branch `deployment/testnet/2026-06-09/gip-0088` = PR #1345 head; the latest commit to the REO
testing docs as of 2026-06-17 09:32 UTC). All five plan docs verified by blob hash against that
commit.

- **Indexer**: `0xfa827db4a3fa4e5403701c728198e102897aa249` (Arbitrum Sepolia)
- **Where**: `live` = real Arbitrum Sepolia · `fork` = local `anvil` fork of Sepolia (real
  contracts; used to self-serve coordinator actions + time-travel without ORACLE_ROLE/GRT)
- **Date**: 2026-06-18 · Issues cross-referenced to `FINDINGS.md`

## Environment verified (live Sepolia)

| Check | Value |
|---|---|
| Active oracle (RewardsManager) | Mock `0x69b0…4e06` (default testnet wiring) |
| `revertOnIneligible` | `true` |
| REO-A `eligibilityValidation` / `eligibilityPeriod` | `false` / `1209600` s (14 d) |
| `maxPOIStaleness` / dispute period / fisherman cut | `28800` s / `28800` s / `500000` ppm |
| EIP-712 domain | `SubgraphService` / `1.0` |
| Mainnet (Arb One) | REO deployed but **dormant** — RewardsManager not wired (`getProviderEligibilityOracle` reverts) |

## Baseline (prerequisite)

| Step | Where | Status | Observation |
|---|---|---|---|
| Stake + provision 100k → SubgraphService | live | ✅ | tx `0x7de9c4ea…` |
| Register (url, geohash) | live | ✅ | tx `0x43d7cddf…` |
| Open 3 allocations (30k each, signalled deployments) | live | ✅ | 100k provision backs 90k allocated (1:1); fine |

## Mock oracle path — Sets 2m–4m (the default testnet path)

| Step | Where | Status | Observation |
|---|---|---|---|
| **2m** collect while eligible | live + fork | ✅ | non-zero rewards; eligible collect succeeds |
| **3m** toggle ineligible → collect reverts | live + fork | ✅ | **live**: mature allocation (epoch 11972) reverts `Indexer not eligible for rewards`. Premature run (epoch 11971) deferred as `ALLOCATION_TOO_YOUNG` with no revert — **F1**, now demonstrated both ways on the same live allocation. |
| **4m** re-enable → collect (recovery) | live + fork | ✅ | collect succeeds, full rewards |

## Production oracle path — Sets 2–5 + fail-open (self-served on fork)

> Live testnet uses the mock by default, so the production REO path was exercised on a fork:
> repoint RewardsManager → REO-A, grant ORACLE_ROLE, enable validation, shorten period to
> 3600 s, and time-travel. All reproduced cold via `playground/scenario-reo-production.sh`.

| Step | Where | Status | Observation |
|---|---|---|---|
| **2** renew eligibility (ORACLE_ROLE) → collect | fork | ✅ | `renewIndexerEligibility` → isEligible=true; collect succeeds |
| **3** wait past period → expiry → collect | fork | ✅ | expired → isEligible=false; collect **reverts** with claimable rewards present |
| **4** re-renew → recovery → collect | fork | ✅ | isEligible=true; collect succeeds |
| **5** validation disabled → eligible | fork | ✅ | isEligible=true with no renewal |
| Fail-open: oracle silent > timeout (7 d) | fork | ✅ | isEligible=true despite expired renewal (safety net engages) |
| Freshly-activated oracle, validation on, never updated | fork | ✅ | isEligible=true (fail-open while oracle has never reported) |

## SubgraphDenialTestPlan — Cycles 2–6 (self-served on fork)

> `playground/scenario-subgraph-denial.sh` — SAO `setDenied` via impersonation, condition
> decoded from the `POIPresented` event.

| Step | Status | Observation |
|---|---|---|
| 2.1 baseline `isDenied=false` | ✅ | |
| 2.2 SAO `setDenied(true)` → `isDenied=true` | ✅ | |
| 2.3 redundant deny idempotent | ✅ | no revert |
| 2.4 unauthorized deny reverts | ✅ | non-SAO blocked |
| 3.1 accumulator freeze | ✅ | `getAccRewardsForSubgraph` unchanged while denied |
| 4.1 POI on denied **defers** | ✅ | `POIPresented.condition = SUBGRAPH_DENIED`; `getRewards` frozen (~253 GRT preserved, snapshot not advanced) |
| 6.4 denial precedence over ineligibility | ✅ | ineligible + denied → condition `SUBGRAPH_DENIED`, **not** `INDEXER_INELIGIBLE` |
| 5.1 undeny → `isDenied=false` | ✅ | |
| 5.2 accumulators resume | ✅ | grows again after undeny |
| 5.3 pre-denial rewards claimable | ✅ | post-undeny collect condition = `NONE` (= `bytes32(0)`), normal claim |

## RewardsConditionsTestPlan — Cycles 1, 2, 4 (self-served on fork)

> `playground/scenario-rewards-conditions.sh` — governor via impersonation; POI condition
> decoded from `POIPresented`.

| Step | Status | Observation |
|---|---|---|
| 4.4 same-epoch collect → `ALLOCATION_TOO_YOUNG` | ✅ | defer; **same condition hash as our live 3m collect → independently confirms F1** |
| 4.1 mature valid POI → `NONE` | ✅ | normal claim (`condition = bytes32(0)`) |
| 4.3 zero POI → `ZERO_POI` | ✅ | reclaim path |
| 4.2 POI after `maxPOIStaleness` → `STALE_POI` | ✅ | reclaim path (time-travelled +29000 s > 28800) |
| 1.1 governor `setReclaimAddress` + readback | ✅ | |
| 1.4 unauthorized `setReclaimAddress` reverts | ✅ | |
| 2.3 below-min-signal freezes accumulator | ✅ | raised `minimumSubgraphSignal` → `getAccRewardsForSubgraph` frozen |
| 5.3 close reclaim → `CLOSE_ALLOCATION` | ✅ | `stopService` → `RewardsReclaimed` reason `CLOSE_ALLOCATION`; reclaim address balance 0 → 252.8 GRT (balance reconciliation) |
| 1.5 reclaim balance reconciliation | ✅ | confirmed via the CLOSE_ALLOCATION reclaim above |
| 5.2 healthy resize (no reclaim) | ✅ | `resizeAllocation(indexer, alloc, newTokens)` 50k → 70k; contract fn, no CLI needed |
| 5.1 stale resize → `STALE_POI` reclaim | ✅ | resize past `maxPOIStaleness` → `RewardsReclaimed` reason `STALE_POI`, pending cleared |
| 3.2 `NO_ALLOCATED_TOKENS` | ✅ | `onSubgraphAllocationUpdate` on a signalled, zero-allocation deployment → `RewardsReclaimed` reason `NO_ALLOCATED_TOKENS` (~130 GRT to reclaim addr) |
| Cycle 7 (zero global signal) | ⏭️ | skipped — impractical on shared chain (doc says unit-test only) |

### SubgraphDenial — additional (`scenario-gaps.sh`)

| Step | Status | Observation |
|---|---|---|
| 4.4 zero POI on denied → `ZERO_POI` (reclaim, not defer) | ✅ | confirms denial does **not** shield a stale/zero POI; precedence holds |

### ReoTestPlan — additional (`scenario-gaps.sh`)

| Step | Status | Observation |
|---|---|---|
| Multi-indexer batch `renewIndexerEligibility([a,b])` | ✅ | both addresses get renewal times in one call |
| Indexer retention removal (`removeExpiredIndexer`) | ✅ | function is **singular** + returns bool (never reverts) — my earlier `removeExpiredIndexers(address[])` didn't exist. With retention shortened to 60 s and a 61 s hop (no fail-open), `removeExpiredIndexer(IDX2)` returned `true` and tracked count dropped 2 → 1. |

## Observations / unexpected output (for collation)

1. **F1 (most important)** — On the mock path, Set 3m's ineligible collect **does not revert** if
   the allocation is immature (`currentEpoch <= createdAtEpoch`), stale, or POI is zero — it
   succeeds with **0 rewards**. The eligibility gate is only on the *claimed* path inside
   `takeRewards`, reached after the `TOO_YOUNG / ZERO_POI / STALE_POI / SUBGRAPH_DENIED`
   precedence checks. A tester running 3m on a fresh allocation will see a *successful* collect
   and may wrongly conclude REO isn't blocking. Correct behaviour, but a likely false-alarm.
   Suggest the guide state the maturity/non-stale/non-zero-POI precondition for 3m.
2. **F2** — Guide lists production `eligibilityPeriod` as "10–15 min"; on-chain REO-A is **14 days**.
3. **F3** — `SUBGRAPH_SERVICE` used in commands but not exported in the env block.
4. **F4–F7** — minor doc/sentence/gateway-URL nits (see `FINDINGS.md`).
5. **Not an issue** — provisioning the documented 100k min and then trying a large new allocation
   can hit `ProvisionTrackerInsufficientTokens`; this is correct (provision must cover *total*
   allocated tokens 1:1). Size allocations to provision.

## Coverage summary

- **Mock path** (Sets 2m–4m): complete (3m's live revert pending the epoch roll; proven on fork).
- **Production path** (Sets 2–5 + fail-open): complete (fork).
- **Subgraph denial** (Cycles 2–5, 6.4, 4.4): complete (fork).
- **Rewards conditions** (POI matrix, reclaim config + balance, below-min-signal,
  `CLOSE_ALLOCATION`): complete (fork); Cycle 7 skipped, CLI-driven resize not run.
- **Multi-indexer batch renewal**: ✅. **Retention removal**: ✅. **Resize lifecycle**: ✅.
  **`NO_ALLOCATED_TOKENS`**: ✅.
- **Observability** (Cycle 6): conditions `NONE / ZERO_POI / STALE_POI / ALLOCATION_TOO_YOUNG /
  SUBGRAPH_DENIED / CLOSE_ALLOCATION / NO_ALLOCATED_TOKENS` were each decoded from the real
  `POIPresented` / `RewardsReclaimed` events across the scenarios above — so the event surface
  is exercised, though not assembled into a single formal audit table.
- **Genuinely not done** (only these remain):
  - **UI / Explorer verification** — scriptable with Playwright against the real Explorer; not yet run.
  - **Full BaselineTestPlan** query-serving / attestations — needs a live graph-node + indexer-service
    stack; not REO-specific; mocking it would not be a valid test.
- Reproducible end-to-end:
  `playground/{fund-fork,scenario-reo,scenario-reo-production,scenario-subgraph-denial,scenario-rewards-conditions,scenario-gaps}.sh`,
  `testnet/collect-test.sh`.
