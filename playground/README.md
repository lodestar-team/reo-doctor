# reo-doctor playground

Test REO behaviour locally with **no testnet GRT and no faucet**, against the *real*
contracts. `fund-fork.sh` forks Arbitrum Sepolia with `anvil`, then impersonates the GRT
governor to mint you GRT — so you own a full, free, repeatable REO testbed.

```bash
./fund-fork.sh                       # fork + mint 200k GRT to the default wallet
RPC_URL=http://localhost:8545 ../reo-doctor.sh <wallet> testnet
```

Because it's your own chain, you can do what the real testnet won't let you:

- **Mint GRT** — no 100k-GRT gate, no begging in Discord.
- **Grant yourself ORACLE_ROLE** (impersonate the operator) to test the production-REO path.
- **Fast-forward time** to test the 14-day eligibility expiry instantly:
  ```bash
  cast rpc evm_increaseTime 1209601 --rpc-url http://localhost:8545
  cast rpc evm_mine --rpc-url http://localhost:8545
  ```
- **Toggle eligibility** via the mock and watch reo-doctor catch it:
  ```bash
  cast send 0x69b0f3c6a19beaf1ba59405f7179e188c64b4e06 "setEligible(bool)" false \
    --from <wallet> --unlocked --rpc-url http://localhost:8545
  ```

Why this matters: it's how we develop and regression-test reo-doctor (conjure a state,
assert the tool reports it), *and* a learning sandbox any indexer can use to understand
REO before it hits mainnet.

> Requires `anvil` + `cast` (Foundry). The fork runs in the background; stop it with
> `pkill -f 'anvil --fork'`.
