# HODDR Launchpad

A phased token launchpad combining Continuous Clearing Auctions, configurable participation limits, ENS eligibility and onchain human checks.

## Build status

Initial development checkpoint. The full interface, contracts and local-chain integration are being built and tested. This repository does not yet represent a completed or audited deployment.

The requested behavior is recorded in [the launchpad specification](docs/launchpad-spec.md).

## Planned flow

1. Configure a token launch, phases, growing limits and lock choices.
2. Select optional human verification and ENS parent-domain rules.
3. Bid through a custody wrapper with contract-enforced limits.
4. Create liquidity after a successful auction.
5. Claim or refund according to the auction result; purchased tokens follow the chosen lock.

Unverified accounts may receive a small base allowance in open phases. Such per-account limits do not prevent account splitting.

## Development

The first complete environment is a local Ethereum-compatible chain. Sepolia is used for external integration checks. A local wallet configuration may be created from [.env.example](.env.example); actual configuration and signing material are excluded from Git and must never be included in browser bundles.

Toolchain pins and official binary checksums are in [toolchain.lock.json](toolchain.lock.json). Runtime/build instructions will be updated as the implementation lands.

## Upstream sources

- [Uniswap Continuous Clearing Auction](https://github.com/Uniswap/continuous-clearing-auction), pinned at `7d7602d257733315434570f2a0c2f94f1c7b207a`.
- [Uniswap Liquidity Launcher](https://github.com/Uniswap/liquidity-launcher), pinned at `1c5904912aefceaceb89c24528cd5e25d0b61597`.
- [World ID onchain verification](https://docs.world.org/world-id/idkit/onchain-verification).
- [ENSv2](https://docs.ens.domains/ensv2/).

The first World adapter targets legacy Orb proofs; it does not imply World ID 4.0 contract support. Optional verification providers remain disabled until their integrations are verified.
