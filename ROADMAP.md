# reo-doctor roadmap — the best possible REO tool for indexers

reo-doctor starts as a one-shot status checker. Its enduring value is **operational
monitoring once REO is live on mainnet**, where two failure modes actually cost indexers
rewards: eligibility lapsing, and POIs going stale while ineligible. The roadmap turns the
checker into an indexer's REO cockpit.

## v0 — one-shot doctor ✅ (shipped, bash)
Wiring → params → eligibility + expiry → POI-staleness → allocations → verdict. Read-only.
Testnet + mainnet aware, degrades gracefully where REO is dormant.

## v0.x — operational essentials (bash, high value, low cost)
- [x] **Per-allocation STALE_POI countdown** — the one that loses real money. Per active
      allocation: time until `max(createdAt, lastPOIPresentedAt) + maxPOIStaleness`, amber/red
      thresholds. Source: on-chain `getAllocation` field (subgraph doesn't expose it).
- [x] **Exit-code contract** — 0 healthy, 1 action-needed. Drops into cron/monitoring.
- [ ] **Eligibility expiry thresholds** — amber when < N hours left, red when expired.
- [ ] **`--json`** — machine-readable output for scripting and dashboard ingestion.
- [ ] **`--watch [interval]`** — poll, diff, print only on change.

## v1 — the daemon (Rust; horizon-doctor family / Jenny's wheelhouse)
The point where bash stops being the right tool.
- [ ] **Prometheus exporter** — `reo_eligible`, `reo_seconds_to_expiry`,
      `reo_seconds_to_poi_stale{allocation}`, `reo_oracle_active`. Grafana panel + alert rules.
- [ ] **Alert sinks** — Discord / Telegram / generic webhook on threshold breach (reuses the
      Night's-Watch / Foghorn alerting patterns). Optionally feed the Lodestar dashboard.
- [ ] **Multi-indexer** — operators running several indexers from one config.
- [ ] **Robust ABI/state reads** — typed, no `cast` shelling, retries, multi-RPC failover.

## v2 — actions (opt-in, key-holding)
- [ ] **Auto-renew daemon** — for the production-REO path, renew eligibility before expiry
      (guarded, opt-in, dry-run default). Turns "renew before expiry" from a chore into a
      non-event.

## Sandbox — community gift (bash, in progress)
- [x] `playground/fund-fork.sh` — fork Sepolia + mint GRT, no faucet.
- [ ] Full scenario harness: provision → register → allocate → present POI → REO toggle →
      time-travel → assert. Doubles as reo-doctor's integration test suite.
- [ ] One-command `make demo` walking an indexer through Sets 2m–4m on the fork.

## Distribution
- Canonical home: `lodestar-team/reo-doctor` (this repo).
- Courtesy copy of `reo-doctor.sh` upstreamed into `graphprotocol/contracts` PR #1345
  `support/`, where the test cohort already looks.
- Announce in The Graph indexer Discord + The Night's Watch once REO nears mainnet.
