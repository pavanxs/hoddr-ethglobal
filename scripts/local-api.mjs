import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import {worldSetup, worldRequest} from './world-requests.mjs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const port = 5193;
const origins = new Set(['http://127.0.0.1:5192', 'http://localhost:5192']);
const hosts = new Set(['127.0.0.1:5193', 'localhost:5193', '127.0.0.1:5192', 'localhost:5192']);
const endpoints = {
  local: { url: 'http://127.0.0.1:8547', chainId: 31337 },
  sepolia: { url: 'https://ethereum-sepolia-rpc.publicnode.com', chainId: 11155111 },
};
const readMethods = new Set([
  'eth_chainId', 'eth_blockNumber', 'eth_getBalance', 'eth_getCode', 'eth_call',
  'eth_estimateGas', 'eth_feeHistory', 'eth_gasPrice', 'eth_maxPriorityFeePerGas',
  'eth_getTransactionCount', 'eth_getTransactionReceipt', 'eth_getTransactionByHash',
  'eth_getBlockByNumber', 'eth_getBlockByHash', 'eth_getLogs', 'web3_clientVersion', 'net_version',
]);
const deploymentFiles = {
  local: path.join(root, '.local-chain', 'public-deployment.json'),
  sepolia: path.join(root, 'deployments', 'sepolia.json'),
};
function jsonFile(file, fallback) {
  if (!fs.existsSync(file)) return fallback;
  const stat = fs.statSync(file);
  if (stat.size > 2_000_000) throw new Error('Public configuration is too large.');
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}
function deployment(network) {
  const value = jsonFile(deploymentFiles[network], null);
  if (value && value.chainId !== endpoints[network].chainId) throw new Error('Deployment chain does not match its network.');
  return value;
}
function respond(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
    'content-length': Buffer.byteLength(data),
  });
  res.end(data);
}
async function body(req) {
  if (!/^application\/json(?:;|$)/i.test(req.headers['content-type'] || '')) throw new Error('Send a JSON request.');
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 512_000) throw new Error('Request is too large.');
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}
async function upstream(network, payload) {
  const response = await fetch(endpoints[network].url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(network === 'local' ? 15_000 : 25_000),
  });
  if (!response.ok) throw new Error('The chain RPC is unavailable.');
  const text = await response.text();
  if (text.length > 8_000_000) throw new Error('RPC response is too large. Use a smaller block range.');
  return JSON.parse(text);
}
async function chainGuard(network) {
  const answer = await upstream(network, { jsonrpc: '2.0', id: 'chain-guard', method: 'eth_chainId', params: [] });
  if (answer.error || Number(BigInt(answer.result)) !== endpoints[network].chainId) {
    throw new Error('RPC chain mismatch. Request stopped.');
  }
}
function validateRpc(network, request, config) {
  if (!request || request.jsonrpc !== '2.0' || (request.params !== undefined && !Array.isArray(request.params))
      || !['string', 'number'].includes(typeof request.id)) throw new Error('Invalid RPC request.');
  if (readMethods.has(request.method)) return;
  if (network === 'local' && request.method === 'eth_accounts') return;
  if (network === 'local' && request.method === 'eth_sendTransaction') {
    const tx = request.params?.[0];
    const accounts = new Set((config?.accounts || []).map(a => a.address.toLowerCase()));
    if (!tx || typeof tx.from !== 'string' || !accounts.has(tx.from.toLowerCase())
        || typeof tx.to !== 'string' || !/^0x[0-9a-fA-F]{40}$/.test(tx.to)) {
      throw new Error('Only configured local test accounts may submit contract calls.');
    }
    if (tx.chainId !== undefined && Number(BigInt(tx.chainId)) !== 31337) throw new Error('Local chain mismatch.');
    return;
  }
  throw new Error('This RPC method is unavailable.');
}
const server = http.createServer(async (req, res) => {
  try {
    if (!hosts.has(req.headers.host || '')) return respond(res, 403, { error: 'Unrecognized host.' });
    const url = new URL(req.url || '/', 'http://127.0.0.1:' + port);
    if (req.method === 'GET' && url.pathname === '/api/health') {
      return respond(res, 200, { ok: true, name: 'Hoddr launchpad local API', secretFree: true });
    }
    if (req.method === 'GET' && url.pathname === '/api/world/status') return respond(res, 200, worldSetup(deployment('sepolia')));
    if (req.method === 'GET' && url.pathname === '/api/runtime') {
      const abis = jsonFile(path.join(root, 'src', 'generated', 'contract-abis.json'), {});
      return respond(res, 200, {
        version: 1,
        worldConfigured: worldSetup(deployment('sepolia')).configured,
        abis,
        deployments: { local: deployment('local'), sepolia: deployment('sepolia') },
      });
    }
    if (req.method !== 'POST') return respond(res, 404, { error: 'Route not found.' });
    if (!origins.has(req.headers.origin || '') || req.headers['sec-fetch-site'] === 'cross-site') {
      return respond(res, 403, { error: 'Open the local launchpad to use this action.' });
    }
    const payload = await body(req);
    if (url.pathname === '/api/world/request') return respond(res, 200, worldRequest(deployment('sepolia'), payload));
    const match = /^\/api\/rpc\/(local|sepolia)$/.exec(url.pathname);
    if (match) {
      const network = match[1];
      const requests = Array.isArray(payload) ? payload : [payload];
      if (requests.length < 1 || requests.length > 64) throw new Error('RPC batch size is out of bounds.');
      const config = deployment(network);
      for (const request of requests) validateRpc(network, request, config);
      await chainGuard(network);
      return respond(res, 200, await upstream(network, payload));
    }
    if (url.pathname === '/api/local/advance-blocks') {
      const count = payload.count;
      if (!Number.isSafeInteger(count) || count < 1 || count > 100_000) throw new Error('Choose 1 to 100,000 blocks.');
      await chainGuard('local');
      const result = await upstream('local', { jsonrpc: '2.0', id: 1, method: 'anvil_mine', params: ['0x' + count.toString(16), '0x2'] });
      if (result.error) throw new Error(result.error.message);
      return respond(res, 200, { ok: true });
    }
    if (url.pathname === '/api/local/advance-time') {
      const seconds = payload.seconds;
      if (!Number.isSafeInteger(seconds) || seconds < 1 || seconds > 366 * 86400) throw new Error('Choose a time jump up to 366 days.');
      await chainGuard('local');
      const first = await upstream('local', { jsonrpc: '2.0', id: 1, method: 'evm_increaseTime', params: [seconds] });
      if (first.error) throw new Error(first.error.message);
      const second = await upstream('local', { jsonrpc: '2.0', id: 2, method: 'evm_mine', params: [] });
      if (second.error) throw new Error(second.error.message);
      return respond(res, 200, { ok: true });
    }
    return respond(res, 404, { error: 'Route not found.' });
  } catch (error) {
    // Never print request bodies, wallet material or verification proofs.
    const message = error instanceof Error ? error.message : 'Request failed.';
    respond(res, 400, { error: message.slice(0, 300) });
  }
});
server.on('error', error => { console.error('Local API could not start: ' + error.message); process.exitCode = 1; });
server.listen(port, '127.0.0.1', () => console.log('Hoddr local API ready at http://127.0.0.1:' + port));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));
