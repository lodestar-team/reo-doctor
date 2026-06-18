# reo-doctor

A read-only health check for **REO** — the Rewards Eligibility Oracle introduced
to The Graph Network in [GIP-0088](https://github.com/graphprotocol/contracts). One
command tells an indexer whether they're eligible for indexing rewards, when that
eligibility expires, and what to do about it.

```
$ ./reo-doctor.sh 0xYourIndexer testnet

reo-doctor · testnet · indexer 0xyourindexer…

Oracle wiring (RewardsManager 0x1f49…67e79)
  ✓ active oracle: MOCK (0x69b0…4e06) — you control your own eligibility
  ✓ revertOnIneligible = true (ineligible close reverts, rewards preserved)

REO parameters (0x6ba8…2f80)
  ! eligibilityValidation = false (everyone eligible — emergency/default state)
  · eligibilityPeriod = 1209600 s (~14.0 days)

Your eligibility
  ✓ isEligible = true

POI staleness guard (SubgraphService 0xc24a…f26b)
  · maxPOIStaleness = 28800 s — present a POI more often than this…

Active allocations — POI staleness countdown   (needs GRAPH_API_KEY)
  ✓ 0x102d…d207  healthy (stale in 4.1h)
  ! 0x9cf3…f33d  stale in 1.4h
  ✗ 0xdfd9…c446  STALE NOW — rewards reclaimable as STALE_POI; present a POI

Verdict
  Mock oracle is live → run IndexerTestGuide Sets 2m–4m.
  ⚠ action needed (exit 1)
```

Exit code is monitoring-friendly: **0** = healthy, **1** = action needed (an allocation is
stale/near-stale, or you're ineligible while `revertOnIneligible` is on). Drop it in cron.

## Why

Under REO, an indexer only collects indexing rewards while *eligible*. Two operational
rules now matter:

1. **Renew before eligibility expires.** While ineligible (with `revertOnIneligible`),
   closing an allocation reverts — rewards are preserved, not lost, but you can't collect.
2. **Present a POI before `maxPOIStaleness`.** You can't present a POI while ineligible,
   so a prolonged ineligible period can push an allocation past staleness, at which point
   accrued rewards are reclaimed as `STALE_POI` — the one case where rewards *are* lost.

`reo-doctor` reads the live on-chain state and surfaces both, plus the active oracle
wiring, so you don't have to assemble a dozen `cast call`s by hand. It's also a fast way
to follow the [REO test plan](https://github.com/graphprotocol/contracts/pull/1345):
it tells you which test set applies to the current deployment.

## Usage

```bash
./reo-doctor.sh <indexer-address> [testnet|mainnet] [--json|--prometheus] [--watch[=N]]
```

- `testnet` → Arbitrum Sepolia (default) · `mainnet` → Arbitrum One
- `--json` — one JSON object (scripting / dashboards)
- `--prometheus` — Prometheus exposition format (gauges below)
- `--watch[=N]` — re-run every N seconds (default 60); Ctrl-C to stop

Optional environment:

| Var | Effect |
|-----|--------|
| `RPC_URL` | Override the default RPC for the chosen network |
| `GRAPH_API_KEY` | Enables the per-allocation staleness countdown (lists active allocations) |

### Put it in your monitoring

Prometheus via node_exporter's textfile collector (cron):

```bash
GRAPH_API_KEY=… reo-doctor.sh 0xYourIndexer mainnet --prometheus \
  > /var/lib/node_exporter/textfile/reo.prom
```

Gauges: `reo_up`, `reo_eligible`, `reo_revert_on_ineligible`, `reo_action_needed`,
`reo_eligibility_seconds_to_expiry`, and **`reo_seconds_to_poi_stale{allocation="0x…"}`** —
alert when that drops below, say, an hour. Or just `reo-doctor … || alert` in cron (exit 1 =
action needed).

## Requirements

- [`cast`](https://book.getfoundry.sh/getting-started/installation) (Foundry)
- `jq`
- `curl` (only when `GRAPH_API_KEY` is set)

Everything it does is **read-only** — `cast call` (view functions) and a subgraph query.
It never asks for, reads, or sends a private key.

## Contract addresses

Baked in per network, verified against the GIP-0088 deployment details. Override the RPC
with `RPC_URL` if you run your own node.

## Also in this repo: a REO test harness

Be aware before cloning: most of this repo by volume is **not** the `reo-doctor.sh` tool —
it's a harness built while helping test the REO upgrade (PR #1345). Two distinct things,
one repo:

- **`reo-doctor.sh`** — the read-only indexer tool described above.
- **`playground/`** — a local `anvil`-fork sandbox + scenario scripts that reproduce the REO
  test plans against the *real* Sepolia contracts, with no testnet GRT or coordinator access
  required (it impersonates the needed roles and time-travels on the fork):
  - `fund-fork.sh` — fork Sepolia + mint test GRT
  - `scenario-reo.sh` — mock-oracle eligibility (Sets 2m–4m)
  - `scenario-reo-production.sh` — production oracle (Sets 2–5 + fail-open)
  - `scenario-subgraph-denial.sh` — denial freeze/defer/undeny (Cycles 2–5 + precedence)
  - `scenario-rewards-conditions.sh` — POI condition matrix, reclaim config, below-min-signal
- **`testnet/`** — scripts for the live-Sepolia runs.
- **Reports** — [`TESTING_REPORT-2026-06-17.md`](TESTING_REPORT-2026-06-17.md) (methodology),
  [`TEST_EXECUTION_LOG.md`](TEST_EXECUTION_LOG.md) (per-step matrix, honest about what was and
  wasn't run), [`FINDINGS.md`](FINDINGS.md) (validated issues).

### What was actually tested

Comprehensive coverage of REO-specific behaviour — **not** 100% of every step across all five
plans. Live Sepolia: baseline + Sets 2m/4m (3m pending an epoch roll). Fork: production path,
denial, and reward conditions. Not run: full BaselineTestPlan, UI/Explorer verification, some
CLI-driven lifecycle/observability steps, and the zero-global-signal cycle. The execution log
is the source of truth.

## Status

`reo-doctor.sh` is working: oracle wiring, eligibility + expiry, **per-allocation `STALE_POI`
countdown**, a monitoring exit code, and `--json` / `--prometheus` / `--watch` output modes. The
harness reproduces its scenarios cold. Still on the roadmap: eligibility-expiry thresholds and a
Discord/Telegram webhook sink. Issues and PRs welcome.

## Licence

MIT
