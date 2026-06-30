# hyperwars contracts

Foundry project for the on-chain game.

## Env

`contracts/.env` (gitignored):

```
HYPE_MAINNET=<alchemy or other mainnet HyperEVM RPC>
HYPE_TESTNET=<alchemy or other testnet HyperEVM RPC>
DEPLOYER_PK=<0x-prefixed private key of the deploying EOA>
FORK_URL=<RPC used for local anvil fork>
```

Load it in the current shell before running deploy commands:

```bash
set -a; source .env; set +a
```

## Deploy to testnet

HyperEVM has two block tiers — small blocks (1s, **2M gas cap**) and big blocks
(1min, ~30M gas). The GameMaster implementation deploy exceeds the small-block
cap, so the deployer EOA must be opted into big blocks first, or the broadcast
will fail with `exceeds block gas limit`.

### 1. Enable big blocks for the deployer (one-time per EOA)

```bash
cd scripts
pnpm install --ignore-workspace   # standalone install; --ignore-workspace
                                  # is required so pnpm doesn't walk up to
                                  # the root workspace and skip this dir
pnpm bb on                        # testnet
# pnpm bb on mainnet              # mainnet
cd ../
```

Expect `{ status: 'ok', ... }`. The flag persists on the EOA until you flip it
back with `pnpm bb off`.

### 2. Broadcast the deploy

```bash
export ETHERSCAN_API_KEY=<hyperevmscan_key>
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $HYPE_MAINNET \
  --private-key $DEPLOYER_PK \
  --broadcast --slow --legacy -vvv \
  --verify --verifier etherscan
```

- `--slow` sends one tx at a time and waits for inclusion — avoids the
  `already known` race the public RPC throws when forge fires txs in parallel.
- `--legacy` uses legacy tx envelope, which Hyperliquid handles more
  predictably than EIP-1559.
- `--verify --verifier etherscan` verifies each contract on hyperevmscan as
  it lands. Endpoint + key are wired through the `[etherscan]` block in
  `foundry.toml`; only `ETHERSCAN_API_KEY` needs to be set per-shell.

Big blocks settle every ~minute, so the deploy is slower wall-clock (~5-10
minutes for the six txs) but goes through.

### 3. Capture the deployed addresses

Broadcast log lands at:

```
contracts/broadcast/Deploy.s.sol/998/run-latest.json
```

Pull the four addresses for downstream wiring:

```bash
jq -r '.transactions[]
  | select(.contractName != null)
  | "\(.contractName): \(.contractAddress)"' \
  broadcast/Deploy.s.sol/998/run-latest.json
```

The script's console output also prints them under `=== hyperwars deploy ===`.

### 4. Optional: opt back out of big blocks

Once deployed, normal txs (room creation, settlement) fit in small blocks. Flip
the deployer back so its routine txs confirm in ~1s:

```bash
cd scripts
pnpm bb off
```

## Deploy to mainnet

Same as testnet but:

- swap `$HYPE_TESTNET` for `$HYPE_MAINNET`
- swap `https://api.hyperliquid-testnet.xyz` for `https://api.hyperliquid.xyz`
  in the big-blocks toggle
- broadcast log lands under `broadcast/Deploy.s.sol/999/`

## Optional deploy env

The script reads these extra env vars (addresses default to the deployer):

- `OWNER` — GameMaster owner. Defaults to the broadcast key.
- `PROTOCOL_TREASURY` — builder-fee fallback recipient. Defaults to the broadcast key.
- `BUILDER_FEE_RECIPIENT` — factory-wide builder-fee recipient forwarded to
  `GameRoomFactory`'s constructor. Empty/unset means `address(0)`, so
  `GameMaster.createRoom` falls back to `PROTOCOL_TREASURY` (existing behavior).
  Set it only when you want every room's builder fee to go to a fixed address
  instead of the treasury.
- `MAX_PLAYERS` — per-factory cap on `config.maxPlayers`, enforced in
  `createRoom`. Default: `10`.
- `MAX_ASSETS` — per-factory cap on `allowedAssets` length. Default: `5`.
- `MAX_ROUND_DURATION` — per-factory cap on `config.maxRoundDuration` (blocks).
  Default: `3600`. `MAX_PLAYERS * MAX_ASSETS` bounds the heaviest settlement
  transaction; the defaults keep it under the 2M small-block gas cap.
- `SKIP_REGISTER_FACTORY=true` — skip `registerFactory` step. Use when
  `OWNER != DEPLOYER_PK`; then call `registerFactory(factory)` from the owner
  key afterwards.

## Local fork

For the docker-compose anvil fork + auto-deploy flow, see the root
`docker-compose.yml` and `.docker/contracts-deploy/entrypoint.sh`. The deploy
script is the same; only the RPC and the post-deploy file write differ.

## Recovery: a deploy failed mid-broadcast

If forge errored after some txs landed (look for `hash:` not `null` in
`run-latest.json`), resume from the stopped point:

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $HYPE_TESTNET --private-key $DEPLOYER_PK \
  --broadcast --resume --slow --legacy -vvv \
  --verify --verifier etherscan
```

If nothing landed but `cast nonce $DEPLOYER --rpc-url $HYPE_TESTNET` moved,
check `compute-address` for each consumed nonce to find any contracts that
deployed at unexpected addresses before re-running cleanly.
