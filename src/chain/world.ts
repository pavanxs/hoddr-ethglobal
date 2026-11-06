import { decodeAbiParameters, keccak256, stringToHex, type Hex } from 'viem';
import type { VerificationProgress } from '../types';
import type { ActionContext, Engine } from './engine';

interface SignedRequest {
  signal: string;
  config: {
    environment: 'staging'; app_id: string; action: string; allow_legacy_proofs: true;
    rp_context: { rp_id: string; nonce: string; created_at: number; expires_at: number; signature: string };
  };
}
interface WorldSdk {
  orbLegacy(options: { signal: string }): unknown;
  request(config: SignedRequest['config']): {
    preset(preset: unknown, options: { signal: AbortSignal; timeout: number }): Promise<{
      connectorURI: string;
      pollUntilCompletion(options: { pollInterval: number; timeout: number; signal: AbortSignal }):
        Promise<{ success: boolean; result?: unknown }>;
    }>;
  };
}
const stagingRouter = '0x469449f251692e0779667583026b5a1e99512157';
const fieldLimit = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
const record = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === 'object' && !Array.isArray(v);
function field(value: unknown): bigint {
  if (typeof value !== 'string' || !/^(?:0x[0-9a-f]{1,64}|[0-9]{1,78})$/i.test(value)) {
    throw new Error('World ID returned an invalid field.');
  }
  const n = BigInt(value);
  if (n >= fieldLimit) throw new Error('World ID returned an out-of-range field.');
  return n;
}

let loading: Promise<WorldSdk> | undefined;
function sdk(): Promise<WorldSdk> {
  if (!loading) {
    loading = new Promise<WorldSdk>((resolve, reject) => {
      const script = document.createElement('script');
      const fail = () => { clearTimeout(timer); script.remove(); reject(new Error('The World ID browser SDK could not load.')); };
      const timer = setTimeout(fail, 15_000);
      script.src = '/vendor/idkit-core-4.6.0.js';
      script.integrity = 'sha256-ah0i4hoO3l1TwvHVJn1rkEUFuzVeRM9zRabmQ7GSVE8=';
      script.async = true;
      script.onload = () => {
        const loaded = (window as Window & { IDKit?: WorldSdk }).IDKit;
        if (!loaded?.request || !loaded.orbLegacy) { fail(); return; }
        clearTimeout(timer); resolve(loaded);
      };
      script.onerror = fail;
      document.head.appendChild(script);
    }).catch(error => { loading = undefined; throw error; });
  }
  return loading;
}

export function decodeWorldProof(value: unknown, request: SignedRequest) {
  if (!record(value) || value.protocol_version !== '3.0' || value.environment !== 'staging' ||
      value.action !== request.config.action || value.nonce !== request.config.rp_context.nonce ||
      'session_id' in value || !Array.isArray(value.responses) || value.responses.length !== 1) {
    throw new Error('The proof does not match this staging request.');
  }
  const result: unknown = value.responses[0];
  if (!record(result) || result.identifier !== 'orb' ||
      field(result.signal_hash) !== (BigInt(keccak256(stringToHex(request.signal))) >> 8n)) {
    throw new Error('The Orb proof does not match this wallet and registry.');
  }
  const root = field(result.merkle_root), nullifierHash = field(result.nullifier);
  if (!root || !nullifierHash || typeof result.proof !== 'string' || !/^0x[\da-f]{512}$/i.test(result.proof)) {
    throw new Error('The Orb proof is incomplete.');
  }
  return { root, nullifierHash, proof: decodeAbiParameters([{type:'uint256[8]'}], result.proof as Hex)[0] };
}

export async function acquireWorldProof(engine: Engine, ctx: ActionContext, signal: AbortSignal,
  report: (state: VerificationProgress) => void) {
  if (ctx.network !== 'sepolia' || ctx.deployment.chainId !== 11155111 || ctx.deployment.localTestOnly !== false ||
      ctx.deployment.world?.environment !== 'staging') throw new Error('Sepolia World ID is not configured.');
  const registry = ctx.deployment.identityRegistry;
  const check = () => { engine.check(ctx); signal.throwIfAborted(); };
  check();
  report({status:'requesting', message:'Starting a wallet-bound World ID staging request.'});
  const [appId, action, expectedSignal, router, fixture, factoryIdentity] = await Promise.all([
    engine.read<string>(ctx,'IdentityRegistry',registry,'appId'),
    engine.read<string>(ctx,'IdentityRegistry',registry,'action'),
    engine.read<string>(ctx,'IdentityRegistry',registry,'expectedSignal',[ctx.account]),
    engine.read<string>(ctx,'IdentityRegistry',registry,'worldIdRouter'),
    engine.read<boolean>(ctx,'IdentityRegistry',registry,'localTestOnly'),
    engine.read<string>(ctx,'LaunchpadFactory',ctx.deployment.factory,'identityRegistry'),
  ]);
  check();
  if (fixture || router.toLowerCase() !== stagingRouter || factoryIdentity.toLowerCase() !== registry.toLowerCase() ||
      appId !== ctx.deployment.world.appId || action !== ctx.deployment.world.action) {
    throw new Error('The Sepolia launchpad, World ID registry and app settings do not match.');
  }
  const response = await fetch('/api/world/request', {method:'POST', cache:'no-store', signal,
    headers:{'content-type':'application/json'}, body: JSON.stringify({account:ctx.account, registry})});
  if (!response.ok) throw new Error('The server could not start a World ID staging request. Check its separate RP settings.');
  const request = await response.json() as SignedRequest;
  const config = request.config;
  if (request.signal !== expectedSignal || config?.environment !== 'staging' || !config.allow_legacy_proofs ||
      config.app_id !== appId || config.action !== action || !config.rp_context?.nonce ||
      !Number.isSafeInteger(config.rp_context.expires_at)) throw new Error('The signed request does not match this wallet.');
  // Forward only expected SDK fields; extra response properties cannot override the production bridge URL.
  const options = {environment:'staging', allow_legacy_proofs:true, app_id:appId, action, rp_context:config.rp_context} as const;
  const remaining = () => {
    check();
    const timeout = config.rp_context.expires_at * 1000 - Date.now();
    if (timeout <= 0 || timeout > 310_000) throw new Error('The staging request expired or has an invalid expiry. Try again.');
    return timeout;
  };
  const kit = await sdk();
  let result: unknown;
  try {
    const conn = await kit.request(options).preset(kit.orbLegacy({signal:expectedSignal}),
      {signal,timeout:Math.min(30_000,remaining())});
    const link = new URL(conn.connectorURI);
    if (link.origin !== 'https://staging.world.org' || link.username || link.password || link.pathname !== '/verify') {
      throw new Error('Invalid staging connector.');
    }
    check();
    report({status:'awaiting-user', connectorUrl:conn.connectorURI, message:'Open World ID staging and approve the Orb request.'});
    const completion = await conn.pollUntilCompletion({pollInterval:2000,timeout:remaining(),signal});
    if (!completion.success) throw new Error('World ID did not complete.');
    result = completion.result;
  } catch {
    check();
    throw new Error('World ID staging did not complete the request. Start again when ready.');
  }
  remaining();
  report({status:'checking', message:'Checking the proof before opening your wallet.'});
  return decodeWorldProof(result,request);
}
