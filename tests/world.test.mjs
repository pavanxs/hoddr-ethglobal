import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { encodeAbiParameters, keccak256, stringToHex } from 'viem';
import { worldRequest, worldSetup } from '../scripts/world-requests.mjs';
import { acquireWorldProof, decodeWorldProof } from '../src/chain/world.ts';

const registry = '0x' + 'ab'.repeat(20);
const account = '0x' + 'bc'.repeat(20);
const factory = '0x' + 'cd'.repeat(20);
const deployment = {chainId:11155111, factory, identityRegistry:registry, localTestOnly:false,
  world:{appId:'app_localtest',action:'link-wallet',environment:'staging'}};
// Ephemeral signer for the test process; never use a wallet or a Portal secret in tests.
const env = {LAUNCHPAD_WORLD_RP_ID:'rp_localtest', LAUNCHPAD_WORLD_APP_ID:'app_localtest',
  LAUNCHPAD_WORLD_ACTION:'link-wallet', LAUNCHPAD_WORLD_RP_SIGNING_KEY:randomBytes(32).toString('hex')};
const signal = 'hoddr-launchpad-world-v3:11155111:' + registry + ':' + account;
const ctx = {network:'sepolia',account,deployment};
const engine = { check() {}, async read(_c,_n,_r,k) { return {
  'appId':'app_localtest','action':'link-wallet', 'expectedSignal':signal,
  'localTestOnly':false, 'worldIdRouter':'0x469449f251692e0779667583026b5a1e99512157','identityRegistry':registry
}[k]; } };
const proofWords = [1n,2n,3n,4n,5n,6n,7n,8n];
const makeResult = request => ({protocol_version:'3.0',environment:'staging',action:deployment.world.action,
  nonce:request.config.rp_context.nonce, responses:[{identifier:'orb',merkle_root:'0x10',nullifier:'0x20',
    signal_hash:(BigInt(keccak256(stringToHex(request.signal))) >> 8n).toString(),
    proof:encodeAbiParameters([{type:'uint256[8]'}],[proofWords])}]});

test('server fails closed without matching Sepolia deployment, RP settings, and beneficiary', () => {
  for (const [d,e] of [[null,env],[{...deployment,localTestOnly:true},env],[{...deployment,chainId:1},env],
      [deployment,{}],[deployment,{...env,LAUNCHPAD_WORLD_ACTION:'other'}]]) assert.equal(worldSetup(d,e).configured,false);
  assert.throws(()=>worldRequest(deployment,{account,registry:factory},env));
  assert.throws(()=>worldRequest(deployment,{account:'0x'+'0'.repeat(40),registry},env));
});
test('server returns only signed staging context and wallet signal', () => {
  const req = worldRequest(deployment,{account,registry},env);
  assert.equal(req.signal,signal);assert.equal(req.config.rp_context.expires_at-req.config.rp_context.created_at,300);
  assert.match(req.config.rp_context.signature,/^0x[\da-f]{130}$/i);
  assert.equal(JSON.stringify(req).includes(env.LAUNCHPAD_WORLD_RP_SIGNING_KEY),false);
  assert.equal(req.config.allow_legacy_proofs,true);
});
test('Orb proof decodes to eight EVM words; unrelated wallet and request results fail closed', () => {
  const req=worldRequest(deployment,{account,registry},env);
  assert.deepEqual(decodeWorldProof(makeResult(req),req),{root:16n,nullifierHash:32n,proof:proofWords});
  for (const patch of [{protocol_version:'4.0'},{environment:'production'},{nonce:'wrong'},
    {action:'wrong'},{session_id:'session'},{responses:[]}]) assert.throws(()=>decodeWorldProof({...makeResult(req),...patch},req));
  for(const patch of [{identifier:'device'},{signal_hash:'0x1'},{nullifier:'0x0'},{merkle_root:'NaN'},{proof:'0x11'}]) {
    const response=makeResult(req);Object.assign(response.responses[0],patch);assert.throws(()=>decodeWorldProof(response,req));
  }
});
test('acquisition passes exact contract signal to pinned SDK and returns proof only to caller', async t => {
  const request=worldRequest(deployment,{account,registry},env), progress=[];
  let calls=0;
  const oldWindow=globalThis.window, oldDocument=globalThis.document, oldFetch=globalThis.fetch;
  t.after(()=>{if(oldWindow===undefined)delete globalThis.window;else globalThis.window=oldWindow;
    if(oldDocument===undefined)delete globalThis.document;else globalThis.document=oldDocument;globalThis.fetch=oldFetch;});
  globalThis.window={IDKit:{orbLegacy:v=>v,request:cfg=>{
    assert.equal(cfg.action,request.config.action);return {async preset(options){
      assert.equal(options.signal,signal);
      return {connectorURI:'https://staging.world.org/verify?t=test',async pollUntilCompletion(){
        return {success:true,result:makeResult(request)};}};
    }};
  }}};
  globalThis.document={createElement:()=>({}),head:{appendChild(script){
    assert.equal(script.integrity,'sha256-'+createHash('sha256').update(readFileSync(new URL('../public'+script.src,import.meta.url))).digest('base64'));
    queueMicrotask(()=>script.onload());
  }}};
  globalThis.fetch=async(path,options)=>{
    calls++;assert.equal(path,'/api/world/request');assert.deepEqual(JSON.parse(options.body),{account,registry});
    return Response.json(request);
  };
  assert.deepEqual(await acquireWorldProof(engine,ctx,new AbortController().signal,s=>progress.push(s)),
    {root:16n,nullifierHash:32n,proof:proofWords});
  assert.equal(calls,1);
  assert.deepEqual(progress.map(x=>x.status),['requesting','awaiting-user','checking']);
  assert.equal(JSON.stringify(progress).includes(makeResult(request).responses[0].proof),false);
  const bad={...engine,async read(...args){return args[3]==='identityRegistry'?factory:engine.read(...args);}};
  await assert.rejects(acquireWorldProof(bad,ctx,new AbortController().signal,()=>{}),/do not match/);
  const cancelled=new AbortController();cancelled.abort();
  await assert.rejects(acquireWorldProof(engine,ctx,cancelled.signal,()=>{}));
  assert.equal(calls,1);
});
