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
  · maxPOIStaleness = 28800 s (~8 h) — present a POI more often than this…

Verdict
  Mock oracle is live → run IndexerTestGuide Sets 2m–4m.
  Toggle your eligibility:  cast send 0x69b0…4e06 "setEligible(bool)" <true|false> …
```

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
to follow GraphOps' [REO test plan](https://github.com/graphprotocol/contracts/pull/1345):
it tells you which test set applies to the current deployment.

## Usage

```bash
./reo-doctor.sh <indexer-address> [testnet|mainnet]
```

- `testnet` → Arbitrum Sepolia (default)
- `mainnet` → Arbitrum One

Optional environment:

| Var | Effect |
|-----|--------|
| `RPC_URL` | Override the default RPC for the chosen network |
| `GRAPH_API_KEY` | If set, also lists your active allocations from the network subgraph |

## Requirements

- [`cast`](https://book.getfoundry.sh/getting-started/installation) (Foundry)
- `jq`
- `curl` (only when `GRAPH_API_KEY` is set)

Everything it does is **read-only** — `cast call` (view functions) and a subgraph query.
It never asks for, reads, or sends a private key.

## Contract addresses

Baked in per network, verified against the GIP-0088 deployment details. Override the RPC
with `RPC_URL` if you run your own node.

## Status

Early but working. Roadmap: per-allocation `STALE_POI` countdown, JSON output mode, and a
watch mode for continuous monitoring. Issues and PRs welcome.

## Licence

MIT
