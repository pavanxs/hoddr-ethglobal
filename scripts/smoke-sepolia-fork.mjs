// bun run scripts/smoke-sepolia-fork.mjs — writes only to the isolated Anvil Sepolia fork.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createPublicClient, getAddress, http, parseAbi, parseEther, toHex } from 'viem';
import { sepolia } from 'viem/chains';
import { createLaunchpadClient } from '../src/chain/client.ts';
import { makeDefaultDraft } from '../src/ui/draft.ts';

const url = 'http://127.0.0.1:8548';
const transport = http(url, { fetchOptions: { redirect: 'error' }, retryCount: 0, timeout: 30_000 });
const fork = createPublicClient({ chain: sepolia, transport, cacheTime: 0 });
const version = await fork.request({ method: 'web3_clientVersion' });
assert.match(version, /anvil/i);
assert.equal(await fork.getChainId(), 11155111);
const node = await fork.request({ method: 'anvil_nodeInfo' });
assert(node.forkConfig?.forkBlockNumber, 'Anvil must be running with a Sepolia fork.');
const json = path => JSON.parse(readFileSync(new URL(path, import.meta.url), 'utf8'));
const deployment = json('../.local-chain/sepolia-fork.json');
assert(deployment.forkOnly === true && deployment.localTestOnly === false && deployment.chainId === sepolia.id);
const abis = json('../src/generated/contract-abis.json');
const read = (address, abi, functionName, args = []) => fork.readContract({ address, abi, functionName, args });
const getter = (address, functionName) => read(address, parseAbi(['function ' + functionName + '() view returns (address)']), functionName);
// Canonical Sepolia CCA v2.1.0 + Uniswap v4, verified from the strategy actually used by the factory.
const strategy = await getter(deployment.factory, 'strategy');
const [cca, manager, positions] = await Promise.all(['initializerFactory', 'poolManager', 'positionManager'].map(fn => getter(strategy, fn)));
assert.equal(getAddress(cca), getAddress('0x000000001F26a0044BaA66024e7b6599c61963F8'));
assert.equal(getAddress(manager), getAddress('0xE03A1074c86CFeDd5C142C4F04F1a1536e203543'));
assert.equal(getAddress(positions), getAddress('0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4'));
const [seller, buyer] = await fork.request({ method: 'eth_accounts' });
assert(seller && buyer && seller !== buyer);
let account = seller;
const actualFetch = globalThis.fetch;
globalThis.fetch = (input, init) => {
  const path = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
  if (path === '/api/runtime') return Promise.resolve(Response.json({
    version: 1, worldConfigured: false, abis, deployments: { local: null, sepolia: deployment },
  }));
  if (![url, url + '/', '/api/rpc/sepolia', 'http://127.0.0.1:5192/api/rpc/sepolia'].includes(path)) throw new Error('Fork smoke rejected unexpected fetch target.');
  return actualFetch(url, { ...init, redirect: 'error' });
};
const sent = [];
globalThis.window = { ethereum: { request: async request => {
  if (request.method === 'eth_accounts') return [account];
  if (request.method === 'eth_sendTransaction') assert.equal(getAddress(request.params[0].from), getAddress(account));
  const response = await fork.request(request);
  if (request.method === 'eth_sendTransaction') sent.push(response);
  return response;
} } };
async function switchAccount(selected) {
  account = selected;
  const app = createLaunchpadClient();
  await app.setNetwork('sepolia');
  return app;
}
async function mineUntil(height) {
  const count = height - await fork.getBlockNumber();
  if (count > 0n) await fork.request({ method: 'anvil_mine', params: [toHex(count), '0x2'] });
}
const creator = await switchAccount(seller);
const draft = makeDefaultDraft();
Object.assign(draft, { name: 'Fork sale', symbol: 'FORK', totalSupply: '1000', minimumRaise: '0.05',
  floorPrice: '0.001', startDelayBlocks: 6, provider: 'none', saleBps: 8000, liquidityBps: 2000,
  phases: [{ ...draft.phases[1], durationBlocks: 32, baseCapStart: '1', baseCapEnd: '1' }] });
const { launchId: id } = await creator.createLaunch(draft);
const record = await read(deployment.factory, abis.LaunchpadFactory, 'launchAt', [BigInt(id)]);
assert.equal(record.identityEnabled, false);
await mineUntil(record.startBlock);
const bidder = await switchAccount(buyer);
await bidder.placeBid(id, { amount: '0.2', maxPrice: '0.01', lockDays: 0 });
await mineUntil(record.claimBlock + 1n);
await bidder.migrate(id);
const [price, liquidity, ownedLiquidity] = await read(record.settlement, abis.LaunchSettlementVault, 'poolState');
assert(price > 0n && liquidity > 0n && ownedLiquidity > 0n, 'Missing spot price or deposited liquidity.');
const lpId = await read(record.settlement, abis.LaunchSettlementVault, 'positionId');
assert(lpId > 0n);
const owner = () => read(positions, parseAbi(['function ownerOf(uint256) view returns (address)']), 'ownerOf', [lpId]);
assert.equal(getAddress(await owner()), getAddress(record.settlement));
await bidder.settle(id);
await bidder.claim(id);
await bidder.unlock(id);
const bought = await read(record.token, abis.LaunchToken, 'balanceOf', [buyer]);
assert(bought > 0n, 'Buyer did not receive purchased tokens.');
const treasury = await switchAccount(seller);
await treasury.releasePosition(id);
assert.equal(getAddress(await owner()), getAddress(seller));
const raised = await read(record.auction, abis.ContinuousClearingAuction, 'currencyRaised');
assert(raised >= parseEther(draft.minimumRaise));
const receipts = await Promise.all(sent.map(hash => fork.getTransactionReceipt({ hash })));
assert(receipts.length >= 7 && receipts.every(tx => tx.status === 'success'));
console.log(JSON.stringify({ confirmedTransactions: receipts.length, forkOnly: true, forkBlock: String(node.forkConfig.forkBlockNumber),
  factory: deployment.factory, ccaFactory: cca, manager, positions, auction: record.auction,
  raisedWei: String(raised), tokensClaimedRaw: String(bought), sqrtPriceX96: String(price),
  liquidity: String(liquidity), ownedLiquidity: String(ownedLiquidity), lpId: String(lpId), lpOwner: await owner() }, null, 2));
