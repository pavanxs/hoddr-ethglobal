# World ID staging

The launchpad can request a wallet-bound Orb proof through the pinned World ID SDK and submit it to the Sepolia IdentityRegistry. A staging proof is a test credential. The Local network uses a separate synthetic fixture.

## Setup

1. Deploy the launchpad and its IdentityRegistry on Ethereum Sepolia using the registered staging app ID and action. The registry must point to the official legacy Sepolia World ID router. The launchpad factory must point to this registry.
2. Set the public Sepolia deployment record's `localTestOnly` to `false` and its `world` object to `{"appId":"app_…","action":"your-registered-action","environment":"staging"}`.
3. Set the following environment variables for the local API process. Use the RP signing key from the World ID Developer Portal in a server-only environment. The launchpad wallet key serves a different purpose.

| Server setting | Meaning |
| --- | --- |
| `LAUNCHPAD_WORLD_APP_ID` | Same staging app ID as the registry |
| `LAUNCHPAD_WORLD_ACTION` | Same registered action as the registry |
| `LAUNCHPAD_WORLD_RP_ID` | RP ID from the Developer Portal |
| `LAUNCHPAD_WORLD_RP_SIGNING_KEY` | RP request signing key |

4. Open Sepolia in the app, connect the beneficiary wallet and choose Verify. Open the official staging connector and approve with a staging Orb identity. The wallet then simulates and submits `verifyAndBind`. A mined successful binding is required to unlock the verified bidding tier. Adding credentials or approving the connector alone does not establish that binding.

## Data and testing

The server signs a five-minute request. The frontend reads the wallet signal, app, action and router directly from the configured registry. It checks the returned protocol, nonce, Orb credential, signal and proof encoding. The Sepolia router performs the cryptographic check. The app keeps the pending result in browser memory. Wallet simulation and submission transmit the proof to the chain RPC, and confirmed transaction calldata is public.

The browser uses the upstream `@worldcoin/idkit-core` 4.6.0 global build (SHA-256 `6a1d22e21a0ede5d53c2f1d5267d6b904505bb355e44cf7345a6e643b192544f`). The server uses `@worldcoin/idkit-server` 1.2.0 (SHA-256 `1554079557297f8dc605a9f9be2d4431549c9458a46cc05f161ca2ecc6d0956c`). Their MIT notices accompany the files.

Run `node --test tests/world.test.mjs` on Node 24. The tests use a temporary signer and substituted SDK response. A real Portal staging approval and Sepolia receipt require a deployed testnet registry and the user's wallet.

[World ID onchain verification](https://docs.world.org/world-id/idkit/onchain-verification) · [RP request signatures](https://docs.world.org/world-id/idkit/signatures)
