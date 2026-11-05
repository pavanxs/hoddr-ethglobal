# Launchpad requirements

This checkpoint records the requested product and the initial implementation decisions. It is not a claim that the application is complete.

## Product
An Ethereum launchpad with an actual Continuous Clearing Auction, a v4 liquidity market, optional onchain human verification, and optional ENS parent-domain eligibility. The first complete test environment is a local chain; Ethereum Sepolia is the external test environment.

## Launch configuration
- Multiple phases, selected by block number. The initial template has an early verified/reputable phase and a later open phase.
- Each phase defines a minimum bid, an unverified base-cap schedule, a verified-cap schedule, and optional human/ENS conditions.
- Caps can grow during a phase. They apply to cumulative committed quote amounts, not a fresh allowance per bid.
- Verification changes must not reset previous spending.
- An ENS restriction admits owners of active genuine descendants of the selected parent, including nested descendants. It does not use a string suffix or a resolver address as ownership evidence.
- Parent ownership is not necessary merely to choose that namespace as an eligibility rule.

## Identity and caps
World ID proof validity is checked by a contract, not replaced by a server-issued approval ticket. The first adapter uses the legacy Orb proof format supported by the existing staging SDK and Sepolia router. SDK and proof protocol versions are separate.

Several wallets may bind to one stable human identity through individual wallet-bound proofs. Wallet bindings are immutable and bounded. Cap accounting includes all linked wallets' previous spending, including spending before verification.

Unverified limits are per account and remain splittable across accounts. The application must not claim otherwise.

ZKPassport and ACE Permitter were suggested as optional integrations. Their actual contracts, trust assumptions and compatibility must be verified before enabling them. The initial policy uses one identity provider per launch rather than pretending unrelated provider identifiers identify the same person.

## Lock commitments
A contract wrapper owns each CCA bid and receives its purchased tokens. The real participant remains the beneficiary. Tokens stay locked until the committed unlock time; unused quote and failure refunds have separate exit rules.

Longer commitments can earn higher caps. Lock terms cannot be shortened after obtaining a bonus. For linked accounts with mixed commitments, accounting uses a conservative effective bonus rather than reclassifying short-locked purchases as long-locked.

## Auction and pool
Use pinned upstream CCA contracts and their actual price/allocation rules. Do not substitute the existing educational auction model.

CCA admission hooks and v4 trading/initialization hooks have separate jobs. A successful transaction or auction is not proof that a liquidity pool was created: inspect migration events and resulting pool/position state.

Claims, refunds and recovery do not depend on obtaining a fresh human proof or an available ENS gateway.

## Interface
Focused Explore, Create launch and My positions flows. Show network, eligibility, current phase, effective allowance, lock commitment and transaction state clearly. Local synthetic identity fixtures must be labelled as tests. No fake successful transactions or working-provider claims.

## Validation
Contract tests cover phase boundaries, growing caps, linked-wallet accounting, verification after earlier bids, minimum bids, ENS ownership/expiry/path forgery, proof binding, lock immutability, refunds and actual pool migration. Browser checks cover desktop/mobile launch creation, participation and exits.

## Development boundaries
Keep test keys and private state local. Do not modify the existing crypto-social application or shared dependency targets. Root coordinates reviewed commits and pushes to the requested repository.
