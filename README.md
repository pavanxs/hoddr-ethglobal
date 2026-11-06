# HODDR Launchpad

Create a token sale, set rules for each phase, and let bidders choose a holding period. The launchpad runs a Uniswap Continuous Clearing Auction. A successful sale can initialize a v4 pool and mint its liquidity position.

## Try the local app

Open [HODDR Launchpad](http://127.0.0.1:5192). Choose **Community member** in the wallet menu. In the seeded HODDR sale, use **Verify** for a synthetic local identity and enter `alice.community.eth`. Set a bid amount and a maximum price above the current clearing price. **My positions** holds buyer claims and refunds. **Seller collection** holds creator proceeds, unsold tokens and the liquidity position.

Local blocks advance when you transact or use **Local tools**. The example has 32 blocks for community members followed by 48 open blocks. The public Sepolia network requires a separate deployment.

## Run from the repository

The pinned tool installer targets Windows x64. The existing experiments workspace uses read-only dependencies from its parent. On a separate checkout, install this package’s declared dependencies first. Use Node 24 or later and Bun for the test commands.

```sh
node scripts/setup-tools.mjs
node scripts/fetch-contracts.mjs
node scripts/forge.mjs build
node scripts/export-abis.mjs
npm run dev
```

The dev command starts a fresh, disposable Anvil chain on port 8547, deploys the contracts, and serves the API on 5193 and the UI on 5192. In a second terminal run `npm run demo:local` to create the example. Stopping the dev command ends that local chain. The local API uses Anvil's unlocked test accounts and binds to loopback.

## What the sale enforces

- Each block-based phase sets a minimum bid, separate starting and ending caps for verified and open bidders, and optional ENS eligibility. Verified wallets that belong to one identity share a budget. Open wallets each receive their own base cap.
- ENS checks the current owner of a qualifying subname beneath the selected parent. A transferred or expired name can prevent new bids. A bidder can still collect an earlier purchase or refund.
- A bid wrapper tracks the beneficiary and holds purchased tokens until its lock expires. ETH refunds can be withdrawn independently.
- The token allocation must add up to 100%. This version uses native ETH, a 0.30% pool fee, tick spacing 60 and 50% of raised ETH as the liquidity budget. The creator receives the remaining available proceeds. The settlement contract checks the pool and LP position before releasing successful-sale proceeds.
- World ID staging support uses a server-signed proof request and an onchain legacy Orb verifier. Local tests use clearly labeled fixtures. The standalone World ID lab’s staging success is separate from a public launchpad transaction. ZKPassport and ACE are unavailable in this version.

## Checks

| Command | What it checks |
| --- | --- |
| `npm run test:contracts` | Solidity rules, locks, identity, ENS, refunds and actual v4 liquidity |
| `npm run test:ui` | Forms, pricing limits and navigation |
| `npm run test:world` | Staging request signing, proof binding and SDK provenance |
| `npm run test:sale` | Two transaction flows against the running local app, covering a successful and a failed sale |
| `npm run test:browser` | Desktop and phone browser navigation against the running app |
| `node tests/browser-smoke.mjs --write-local` | Browser interactions that create an auction and move local test funds |
| `npm run typecheck` and `npm run build` | TypeScript and production assets |

See [launch rules](docs/launchpad-spec.md), [identity and ENS](docs/identity-ens.md), [World ID staging](docs/world-staging.md) and [pinned upstream sources](contracts.sources.json).
