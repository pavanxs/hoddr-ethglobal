# Ethereum Sepolia integration

The Sepolia deployment uses Uniswap’s existing CCA factory, LBP strategy, v4 PoolManager and PositionManager. HODDR deploys four contracts of its own. The launch factory creates the bid-wrapper factory and the phase-hook deployer in its constructor.

| Existing contract | Ethereum Sepolia address |
| --- | --- |
| LBP strategy | `0x95434E898Af471945Cab33D5064d2aC1A6Ba2000` |
| CCA factory | `0x000000001F26a0044BaA66024e7b6599c61963F8` |
| v4 PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| v4 PositionManager | `0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4` |
| World ID v3 staging router | `0x469449f251692E0779667583026b5A1E99512157` |

The deployed CCA factory’s immutable fee controller is the zero address. The pinned upstream fee library returns zero in that case. HODDR also accepts its own immutable zero-fee controller. Other controllers fail validation.

## Reproduce the fork test

From the launchpad directory, run the local Anvil binary with these arguments in its own terminal.

```sh
.tools/foundry/anvil --host 127.0.0.1 --port 8548 --chain-id 11155111 --fork-url https://ethereum-sepolia-rpc.publicnode.com --fork-block-number 12074409 --hardfork amsterdam --no-storage-caching --silent
```

Run the following in a second terminal. The deployer requires an Anvil fork at the fixed loopback address. The sale uses its unlocked local accounts. The public RPC only supplies historical chain state.

```sh
npm run check:sepolia
npm run deploy:sepolia-fork
npm run test:sepolia-fork
```

Fork manifests and transaction checkpoints stay in the ignored `.local-chain` directory. Ethereum Sepolia activated Amsterdam on October 6, 2026. The local fork’s default tip can differ substantially from a public RPC fee estimate. [Ethereum Foundation announcement](https://blog.ethereum.org/2026/09/17/glamsterdam-testnet-announcement)

A run against block 12,074,409 completed four HODDR deployments and eight sale transactions on the fork. One buyer paid 0.2 fork ETH, claimed just under 200 sale tokens and withdrew them. The vault held a funded position in the official v4 pool before transferring LP position #41424 to the seller. This sale used open bidding. The contract suite separately exercises the World ID and ENS gates together.

## Public deployment

Run `npm run check:sepolia` to check the current ENS anchors, active .eth route and World router. The optional arguments are a known ENSv2 user registry and a label to inspect. A label inside a registry becomes publicly reachable through .eth only after the parent route connects to that registry.

For a public deployment, supply the dedicated Ethereum Sepolia account settings from `.env.example`, the registered World staging app and action, and an explicit total deployment fee ceiling. The wallet must hold ETH on chain ID 11155111. Running this command sends public testnet transactions.

```sh
node --env-file=.env scripts/deploy-sepolia.mjs --broadcast
```

The script checks all pinned addresses, verifies the signer matches the public wallet address and checks the available balance and budget before each transaction. It records each submitted hash for recovery. A completed run writes only public deployment data to `deployments/sepolia.json`. Set `LAUNCHPAD_WORLD_APP_ID`, `LAUNCHPAD_WORLD_ACTION` and `SEPOLIA_DEPLOY_MAX_ETH` before running it. Follow [World ID staging setup](world-staging.md) to enable actual wallet-bound staging proof requests in the UI.

A public deployment and a World app approval are separate steps. Verify the resulting identity binding on the deployed registry before using it as evidence of integration.
