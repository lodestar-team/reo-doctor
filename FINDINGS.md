# REO Testing — Findings

Validated issues from testing REO on Arbitrum Sepolia (GIP-0088 / PR #1345).
Methodology and full test results live separately in `TESTING_REPORT-2026-06-17.md`.

**Bar for inclusion**: each item is either reproduced on-chain or traced to source. Items we
suspected but disproved are listed under *Non-issues* so the record is honest.

---

## Behaviour / test-guide findings

### F1 — Set 3m can silently succeed (not revert) on an immature/stale allocation `[med]`
**Type**: documentation / test-guide clarity. **Not a contract bug** — behaviour is correct per source.

`IndexerTestGuide.md` Set 3m says: while ineligible, "close/collect reverts with `Indexer not
eligible for rewards`." In practice the collect **succeeds with 0 rewards and does not revert**
unless the allocation is *eligible to actually pay out*. The eligibility gate is only on the
"claimed" reward path; it is reached **after** these precedence conditions, each of which
returns 0 without consulting eligibility:

- `ALLOCATION_TOO_YOUNG` — `currentEpoch <= createdAtEpoch` (allocation opened this epoch)
- `ZERO_POI` — POI presented is `bytes32(0)`
- `STALE_POI` — `now - max(createdAt, lastPOIPresentedAt) > maxPOIStaleness`
- `SUBGRAPH_DENIED`

**Reproduced (live Sepolia, 2026-06-17)**: indexer `0xfa82…a249`, mock eligibility set `false`,
`revertOnIneligible=true`, ~8.4 GRT of *projected* rewards (`getRewards`), allocation opened in
the current epoch (`currentEpoch == createdAtEpoch == 11971`). `collect(IndexingRewards)`
**succeeded**, payout event amount = `0`, **no revert**. The revert only manifests once the
allocation is mature (`currentEpoch > createdAtEpoch`), non-stale, and presents a non-zero POI.

**Source** (`graphprotocol/contracts`, live branch `deployment/testnet/2026-06-09/gip-0088`):
- `packages/subgraph-service/contracts/libraries/AllocationHandler.sol` `presentPOI` — condition
  select + path split: STALE_POI/ZERO_POI → `reclaimRewards` (no eligibility check); else →
  `takeRewards`.
- `packages/contracts/contracts/rewards/RewardsManager.sol` — `takeRewards` early-returns 0
  before `_deniedRewards`; the `require(!isIneligible || !revertOnIneligible, "Indexer not
  eligible for rewards")` (the revert) sits inside `_deniedRewards`, on the claimed path only.

**Impact**: a tester running Set 3m on a freshly-opened allocation (the natural thing to do)
observes a *successful* collect and may conclude REO's revert is broken. It isn't — the test
was run before the allocation could pay out.

**Suggested fix**: in Set 3m, state the precondition explicitly — "the allocation must be mature
(`currentEpoch > createdAtEpoch`), non-stale, with a non-zero POI; otherwise the collect
succeeds with 0 rewards instead of reverting, because TOO_YOUNG / ZERO_POI / STALE_POI are
evaluated before the eligibility check." A one-line precedence note would prevent the false alarm.

---

## Documentation findings (IndexerTestGuide.md / TestnetDetails.md)

| # | Sev | Where | Finding |
|---|-----|-------|---------|
| F2 | med | IndexerTestGuide, prod-path env | States production `eligibilityPeriod` is "10–15 minutes"; on-chain REO-A reads **14 days** (`1209600`), matching TestnetDetails. Misleads Set 3's "wait for expiry". Note that the coordinator shortens it for production-path runs. |
| F3 | med | IndexerTestGuide env block | `SUBGRAPH_SERVICE` is used in Set 3.3 + the denial section but never exported. Add `export SUBGRAPH_SERVICE=0xc24a3dac5d06d771f657a48b20ce1a671b78f26b`. |
| F4 | low | IndexerTestGuide (~L436) | Broken sentence: "On Arbitrum Sepolia the RewardsManager the mock." (missing verb). |
| F5 | low | TestnetDetails Gateway row vs examples | Gateway row says `gateway.testnet.thegraph.com`; the curl example and `indexer-status.sh` use `gateway.thegraph.com`. Clarify which resolves the testnet network subgraph. |
| F6 | nit | IndexerTestGuide vs indexer-status.sh | `graphNetwork(id:"1")` vs `graphNetworks{…}` — pick one. |
| F7 | nit | TestnetDetails mock note | Make explicit the mock keys eligibility off `msg.sender` = the **indexer wallet**, often distinct from the operator wallet that signs collects/closes. |

---

## Non-issues (checked, working as intended)

- **Revert string** `Indexer not eligible for rewards` matches the docs and source exactly
  (`RewardsManager._deniedRewards`). Confirmed on the fork with a mature allocation.
- **`revertOnIneligible = true`** confirmed on live Sepolia and on the fork; semantics
  unchanged between implementations (flag introduced in commit `e3bec768d7`, PR #1331, present
  in both).
- **Ineligible collect returning 0 without revert (F1)** is *correct* for an immature/stale/zero
  allocation — not a counterexample to `revertOnIneligible`.
- **Function signatures** in the docs all resolve on-chain; EIP-712 domain is `SubgraphService`/`1.0`.
