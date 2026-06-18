# REO Test Execution Log

Step-by-step completion + observations for GraphOps coordination (for @Rem / @Ørjan).
Plans: `IndexerTestGuide.md` (mock Sets 2m–4m, production Sets 2–5) on PR #1345.

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
| **3m** toggle ineligible → collect reverts | fork | ✅ | reverts `Indexer not eligible for rewards` (allocation mature) |
| **3m** (same, on live) | live | ⚠️→⏳ | **Premature run succeeded with 0 rewards, did NOT revert** — allocation was in its birth epoch (`ALLOCATION_TOO_YOUNG`). See **F1**. Re-running once `currentEpoch > createdAtEpoch` (epoch roll in progress). |
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

- Mock path (Sets 2m–4m): **complete** (3m's live revert pending the epoch roll; proven on fork).
- Production path (Sets 2–5 + fail-open): **complete** (on fork).
- Reproducible: `playground/{fund-fork,scenario-reo,scenario-reo-production}.sh`,
  `testnet/collect-test.sh`.
