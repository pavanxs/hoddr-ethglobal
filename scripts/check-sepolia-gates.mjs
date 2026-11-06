// Read-only. Optional arguments: the address of a user registry and one label inside it.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createPublicClient, getAddress, http, keccak256, parseAbi, stringToHex } from 'viem';
import { sepolia } from 'viem/chains';

const args = process.argv.slice(2);
if (args.length !== 0 && args.length !== 2) throw new Error('Usage: node scripts/check-sepolia-gates.mjs [registry label]');
const source = readFileSync(new URL('../contracts/src/libraries/ENSV2SepoliaPins.sol', import.meta.url), 'utf8');
function pin(name) {
  const value = source.match(new RegExp('constant\\s+' + name + '\\s*=\\s*(0x[0-9a-fA-F]+);'))?.[1];
  assert(value, 'Missing contract pin ' + name);
  return value;
}
// Published World ID v3 router table: https://docs.world.org/world-id/id/on-chain.md
const worldRouter = '0x469449f251692E0779667583026b5A1E99512157';
const client = createPublicClient({ chain: sepolia, transport: http('https://ethereum-sepolia-rpc.publicnode.com', { timeout: 15_000 }) });
assert.equal(await client.getChainId(), sepolia.id, 'Unexpected chain');
const block = await client.getBlock({ blockTag: 'safe' });
const registryAbi = parseAbi([
  'function getState(uint256) view returns ((uint8 status,uint64 expiry,address latestOwner,uint256 tokenId,uint256 resource))',
  'function getOwner(uint256) view returns (address)',
  'function getSubregistry(string) view returns (address)',
  'function getResolver(string) view returns (address)',
  'function getParent() view returns (address, string)',
  'function verifyContract(address) view returns (address)',
]);
const read = (address, functionName, args = []) => client.readContract({ address, abi: registryAbi, functionName, args, blockNumber: block.number });
const hashLabel = label => BigInt(keccak256(stringToHex(label)));
async function runtime(address) {
  const code = await client.getCode({ address, blockNumber: block.number });
  assert(code && code !== '0x', 'No deployed code at ' + address);
  return { address, bytes: (code.length - 2) / 2, codeHash: keccak256(code) };
}
const pins = await Promise.all([
  ['ROOT', 'SYSTEM_CODE_HASH'], ['ETH_REGISTRY', 'SYSTEM_CODE_HASH'],
  ['FACTORY', 'FACTORY_CODE_HASH'], ['USER_IMPLEMENTATION', 'USER_CODE_HASH'],
].map(async ([name, hash]) => {
  const result = await runtime(pin(name));
  assert.equal(result.codeHash, pin(hash), 'Unexpected ' + name + ' runtime');
  return { name, ...result };
}));
const [ethRegistry, ethState, router] = await Promise.all([
  read(pin('ROOT'), 'getSubregistry', ['eth']), read(pin('ROOT'), 'getState', [hashLabel('eth')]), runtime(worldRouter),
]);
assert.equal(getAddress(ethRegistry), getAddress(pin('ETH_REGISTRY')), 'Root .eth route mismatch');
assert(ethState.status === 2 && ethState.expiry > block.timestamp, 'Inactive .eth entry');

let sample;
if (args.length) {
  const registry = getAddress(args[0]), label = args[1], id = hashLabel(label);
  const [implementation, state, owner, parent, resolver, subregistry] = await Promise.all([
    read(pin('FACTORY'), 'verifyContract', [registry]), read(registry, 'getState', [id]),
    read(registry, 'getOwner', [id]), read(registry, 'getParent'), read(registry, 'getResolver', [label]),
    read(registry, 'getSubregistry', [label]),
  ]);
  assert.equal(getAddress(implementation), getAddress(pin('USER_IMPLEMENTATION')), 'Unexpected sample registry implementation');
  sample = { registry, implementation, label, active: state.status === 2 && state.expiry > block.timestamp,
    owner, expiry: String(state.expiry), parent: parent[0], parentLabel: parent[1], resolver, subregistry };
}
console.log(JSON.stringify({ chainId: sepolia.id, block: String(block.number), blockHash: block.hash,
  observedBlockTime: new Date(Number(block.timestamp) * 1000).toISOString(), pins, ethRegistry, worldV3Router: router, sample }, null, 2));
