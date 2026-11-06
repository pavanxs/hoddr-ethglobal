import { signRequest } from './vendor/idkit-server-1.2.0.mjs';

const isAddress = value => typeof value === 'string' && /^0x[\da-f]{40}$/i.test(value) && !/^0x0{40}$/i.test(value);
const keyOrder = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
const recent = [];

export function worldSetup(deployment, env = process.env) {
  const world = deployment?.world;
  if (deployment?.chainId !== 11155111 || deployment.localTestOnly !== false ||
      !isAddress(deployment.identityRegistry) || !isAddress(deployment.factory) || world?.environment !== 'staging') {
    return { configured: false, reason: 'The Sepolia launchpad and staging identity registry are not configured.' };
  }
  const key = env.LAUNCHPAD_WORLD_RP_SIGNING_KEY || '';
  const keyValue = /^(?:0x)?[a-f\d]{64}$/i.test(key) ? BigInt('0x' + key.replace(/^0x/i, '')) : 0n;
  if (!/^app_[a-z\d]{6,80}$/i.test(world.appId || '') || !world.action || world.action.length > 128 ||
      !/^rp_[a-z\d]{6,80}$/i.test(env.LAUNCHPAD_WORLD_RP_ID || '') ||
      world.appId !== env.LAUNCHPAD_WORLD_APP_ID || world.action !== env.LAUNCHPAD_WORLD_ACTION ||
      keyValue <= 0n || keyValue >= keyOrder) {
    return { configured: false, reason: 'Configure the separate World ID staging app, action, RP ID and RP signing key on the server.' };
  }
  return { configured: true, reason: 'The staging request signer is configured.' };
}

// Call only behind the local API's Host/Origin checks. Neither requests nor proofs are stored.
export function worldRequest(deployment, payload, env = process.env) {
  const setup = worldSetup(deployment, env);
  if (!setup.configured) throw new Error(setup.reason);
  if (!isAddress(payload?.account) || !isAddress(payload.registry) ||
      payload.registry.toLowerCase() !== deployment.identityRegistry.toLowerCase()) {
    throw new Error('Choose a wallet and the configured Sepolia registry.');
  }
  const now = Date.now();
  while (recent.length && recent[0] <= now - 60_000) recent.shift();
  if (recent.length >= 12) throw new Error('Too many recent proof requests. Wait a minute before trying again.');
  let signed;
  try { signed = signRequest({ signingKeyHex: env.LAUNCHPAD_WORLD_RP_SIGNING_KEY, action: deployment.world.action, ttl: 300 }); }
  catch { throw new Error('The staging request signer is unavailable.'); }
  recent.push(now);
  return {
    signal: 'hoddr-launchpad-world-v3:11155111:' + deployment.identityRegistry.toLowerCase() + ':' + payload.account.toLowerCase(),
    config: {
      app_id: deployment.world.appId, action: deployment.world.action, environment: 'staging', allow_legacy_proofs: true,
      rp_context: { rp_id: env.LAUNCHPAD_WORLD_RP_ID, nonce: signed.nonce, created_at: signed.createdAt,
        expires_at: signed.expiresAt, signature: signed.sig },
    },
  };
}
