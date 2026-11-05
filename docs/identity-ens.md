# Onchain identity and ENS admission

Status: compiled successfully with Solidity 0.8.26, and all 89 focused Solidity tests passed through the isolated Foundry runner. This verifies the contract logic with explicit local fixtures. It does not claim a real World proof or production ENS transaction has been completed.

## What decides participation

The auction hook reads the participant's identity from `IdentityRegistry` and, when a phase requires ENS, calls that phase's `ENSDomainGate`. Neither contract accepts an app-server approval ticket. The participant is the authenticated beneficiary; it is not the shared bid-lock contract.

The hook owns spending limits, phase rules, minimum bids and lock commitments. These modules only answer identity and name-ownership questions.

## IdentityRegistry

Constructor:

```solidity
IdentityRegistry(address router, string appId, string action, bool localTestOnly)
```

Real mode currently supports the reviewed Ethereum Sepolia World ID v3 Orb Router, `0x469449f251692E0779667583026b5A1E99512157`, with group ID `1`. The app ID, action, Router and deployment chain cannot be changed. Unknown real-mode chains and other Router addresses are rejected.

Enrollment:

```solidity
verifyAndBind(address beneficiary, uint256 root, uint256 nullifierHash, uint256[8] proof)
```

The beneficiary must call this function. The contract computes its expected signal and external nullifier itself, calls the actual Router, and writes a binding only after verification succeeds. Invalid proofs revert. There is no fallback to a server result.

Use `expectedSignal(beneficiary)` **unchanged** as the `signal` in `IDKit.orbLegacy({ signal })`. It is a non-hex UTF-8 string containing the version, deployment chain, registry address and beneficiary. `expectedSignalHash(beneficiary)` exposes the exact field-reduced hash for client checks. The pinned IDKit 4.6.0 bundle was inspected: non-hex strings use UTF-8, then keccak256, then a right shift of eight bits.

The v3 external nullifier is:

```text
hashToField(abi.encodePacked(hashToField(UTF8(appId)), UTF8(action)))
hashToField(bytes) = uint256(keccak256(bytes)) >> 8
```

The request's app/action must match the contract. IDKit request signing remains an external availability dependency; it does not give that server the power to create an onchain binding.

### One person, several wallets

`identityOf(wallet)` returns zero until enrollment. A nonzero identity is derived from the provider, pinned app/action scope and verified nullifier. The same human may enroll another wallet with a fresh proof bound to that wallet. Both wallets receive the same identity key.

Each wallet can bind only once. Replays and changing a wallet to another identity are rejected. There is no administrator, removal function or identity-reset function.

The hook must include **all linked wallets' earlier spending and lock commitments**, including spending before enrollment:

```solidity
identityOf(address beneficiary) returns (bytes32)
walletCount(bytes32 identity) returns (uint256)
walletAt(bytes32 identity, uint256 index) returns (address)
```

An identity supports at most 32 permanently linked wallets so this work is bounded. Their association is public onchain and cannot be removed in this version. `walletsOf(identity)` is a convenience read. `verifiedAt(wallet)` is the enrollment timestamp; the binding is a record of successful verification then, not continuous monitoring of World credentials. Lost-wallet removal and provider migration are not implemented. Unverified per-wallet limits remain splittable across wallets.

World ID v3 is officially in a sunsetting phase. This is an explicitly named legacy Orb adapter, not a World ID v4 verifier. Future protocol support needs a separately reviewed adapter and a clear cap-accounting migration policy.

## ENSDomainGate

Each gate has one immutable parent policy. A phase uses the gate address; a zero gate address disables that phase's ENS requirement.

### Gate provenance

`ENSDomainGateFactory` holds one constructor-only trust configuration. `create(parentLabels)` deploys the actual gate implementation and records it in `isGate(address)` only after its constructor succeeds. A parent namehash has one reusable gate, available through `gateForParent(namehash)`. Reuse checks that the parent route is still active and supported.

The launchpad factory must pin this gate factory and reject unknown phase gates. An arbitrary contract that returns `true` from `isEligible` is not a genuine ENS check. There is no arbitrary-registration function, config setter, owner or upgrade path in this gate factory.

`isGate` proves deployment provenance, not present participant eligibility. The gate rechecks ownership and expiry during each admission. `inspectParent()` checks whether the parent route is currently usable; it does not approve a participant.

Constructor:

```solidity
ENSDomainGate(TrustConfig config, string[] parentLabels)
```

Parent labels are root-first: `["eth", "community"]` means `community.eth`. The parent must already be active, genuinely linked from the global root, and have a supported child registry.

The hook calls:

```solidity
isEligible(address beneficiary, bytes evidence) returns (bool)
```

Evidence is `abi.encode(string[] descendantLabels)`, nearest parent first. For `alice.team.community.eth` under `community.eth`, supply `["team", "alice"]`. The parent itself is not a descendant.

### Checks made during the transaction

1. The chain and pinned runtime code still match.
2. The global root's `eth` entry points to the expected `.eth` registry.
3. Every parent and descendant entry is `Registered`, with expiry strictly greater than `block.timestamp`.
4. Every child link is followed from its actual parent. Nested child registries must be verified proxies using the pinned UserRegistry implementation.
5. The final entry's current owner equals the authenticated beneficiary.

`getState().latestOwner` can retain a former owner after expiry. It is never used alone. A transfer immediately changes which account qualifies. A resolver address record, renewal permission, administrative role or claimed backward parent pointer does not prove ownership.

Forward aliases are checked through the real root path. Canonical backward pointers are neither sufficient nor required for that forward ownership check. Implementation addresses, system registries used as nested children, unknown proxies and upgraded-to-unsupported implementations are rejected.

`isEligible` returns false on malformed evidence or failed reads. `inspect` exposes a detailed result for the interface: eligibility, reason, registry, current owner, expiry and failing path position. Malformed ABI may make `inspect` revert; callers must treat that as a failed check.

### Exact initial support

- Ethereum Sepolia's pinned ENSv2 family from commit `07e55a056f5b6a9c90119f501bdd05714e67dddd`.
- Parents strictly below `.eth`, with at most eight parent labels including `eth`.
- One to eight descendant labels, including genuine nested paths.
- Lowercase ASCII letters, digits and internal hyphens; 1–63 bytes per label. Leading/trailing hyphens and the reserved third/fourth-position double hyphen are rejected.
- Full DNS wire length at most 255 bytes, including length bytes and the terminal zero.

Unicode, uppercase input, dotted strings passed as one label, ENSv1, NameWrapper, arbitrary registry implementations and unreviewed networks are unsupported. The interface must show these limits rather than imply support for every ENS name. It should compare complete normalized label arrays against the configured parent, then reverse only the remaining descendant labels; a bare text suffix is insufficient.

The namespace's own controllers can still register names, transfer them, replace child links, or upgrade registries. The gate has no administrator and no bypass, but it cannot make ENS ownership immutable. It checks current supported state at admission, not ownership tenure or reputation.

## Local fixtures and verification

`localTestOnly=true` is accepted only on chain 31337 or 1337. Both production modules and fixture contracts enforce this boundary. Local fixtures represent test identities and a seeded name hierarchy; they are not genuine World proofs or globally registered ENS names.

The identity fixture allowlists exact Router inputs. Changing the root, signal, nullifier, external nullifier or proof words makes verification fail. It is deliberately not an imitation of World cryptography.

For a local deployment, create `LocalENSFactoryFixture`, `LocalENSImplementationFixture` and separate root/eth/community registry fixtures. Seed `root.eth -> eth`, `eth.community -> community`, and owned names inside the community; set strictly future expiries. Register each child registry's implementation in the fixture factory. For a nested name, create and register another child registry, then link it through the intermediate owned name. Calculate the actual runtime hashes of the root, eth registry, fixture factory and implementation marker, set `TrustConfig.localTestOnly=true`, then deploy the real `ENSDomainGateFactory` and call `create(["eth", "community"])`. This uses the genuine gate logic against explicitly synthetic local name state. It does not weaken the canonical Sepolia checks.

Focused tests cover multi-wallet identity, replay and identity switching, wrong action/app/signal/registry, failed verification without state changes, wallet-count bounds, active nested names, transfers, expiry at equality, historical-owner rejection, forged registries, changed implementations, root/proxy provenance, malformed evidence and label/DNS boundaries. Tests use no wallet file, RPC or environment values.

Observed verification on 2026-11-05:

```text
node scripts/forge.mjs test --match-contract "^(IdentityRegistryTest|ENSDomainGateTest|ENSDomainGateFactoryTest)$" -vv
```

| Suite | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| IdentityRegistry | 28 | 0 | 0 |
| ENSDomainGate | 46 | 0 | 0 |
| ENSDomainGateFactory | 15 | 0 | 0 |
| Total | 89 | 0 | 0 |

The two fuzz tests each ran 256 cases. The successful run compiled the full then-current set of 39 source files without build exclusions. Foundry 1.9.0 used Solidity 0.8.26, Cancun, IR compilation and 200 optimizer runs. Parameterized custom-error tests compare the complete encoded error, including its values.

| Contract | Runtime bytes | Initialization bytes |
| --- | ---: | ---: |
| IdentityRegistry | 3,402 | 4,898 |
| ENSDomainGate | 7,331 | 11,658 |
| ENSDomainGateFactory | 13,898 | 15,046 |

These are observed compiler artifact sizes, not deployed-address or external-provider verification claims.

An independent offline parity check has passed: the pinned IDKit 4.6.0 hash function was evaluated with network requests and timers disabled, and matched viem for `hoddr-launchpad-world-v3:31337:0x000000000000000000000000000000000000beef:0x00000000000000000000000000000000000a11ce`. Both produced `0x006a804e500c40d57ec6fedc91f388768925b5399f5cc207c6e2ae55bdaf0cf4`. The same fixed vector is included in the Solidity tests. This is an encoding check, not a World proof verification.

Source/public-read evidence: at Sepolia block `12072333` on 2026-11-05, the pinned root's `eth` entry was Registered, had expiry `uint64.max`, and pointed to the expected `.eth` registry. This was a read-only check, not a transaction or proof that our new gate has been deployed.

## Primary sources

- [World onchain verification and current Router addresses](https://docs.world.org/world-id/id/on-chain.md)
- [World v3 external-nullifier formula and Router semantics](https://docs.world.org/world-id/reference/contracts.md)
- [Official World ID v3 contracts and sunset notice](https://github.com/worldcoin/world-id-contracts)
- [Pinned ENS PermissionedRegistry expiry and ownership implementation](https://github.com/ensdomains/contracts-v2/blob/07e55a056f5b6a9c90119f501bdd05714e67dddd/contracts/src/registry/PermissionedRegistry.sol)
- [Pinned ENS registry state interface](https://github.com/ensdomains/contracts-v2/blob/07e55a056f5b6a9c90119f501bdd05714e67dddd/contracts/src/registry/interfaces/IPermissionedRegistry.sol)
- [Pinned ENS UserRegistry upgrade control](https://github.com/ensdomains/contracts-v2/blob/07e55a056f5b6a9c90119f501bdd05714e67dddd/contracts/src/registry/UserRegistry.sol)
- [ENS registry hierarchy](https://docs.ens.domains/ensv2/registry-hierarchy/)

All module and fixture implementation code here is new project code marked `UNLICENSED`. The interfaces are minimal ABI bindings to the cited public contracts; upstream implementations were not copied into these modules.
