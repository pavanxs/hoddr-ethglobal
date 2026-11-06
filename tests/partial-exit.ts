import assert from 'node:assert/strict';
import {createPublicClient, decodeFunctionData, http, parseEther} from 'viem';
import {foundry} from 'viem/chains';
import {createLaunchpadClient} from '../src/chain/client';
import {makeDefaultDraft} from '../src/ui/draft';

const origin='http://127.0.0.1:5192';
const realFetch=globalThis.fetch;
globalThis.fetch=((input,init)=>{
  const url=typeof input==='string'&&input.startsWith('/')?origin+input:input;
  const headers=new Headers(init?.headers || (input instanceof Request?input.headers:undefined));
  headers.set('origin',origin);
  return realFetch(url,{...init,headers});
}) as typeof fetch;

const rpc=createPublicClient({chain:foundry,transport:http('http://127.0.0.1:8547'),cacheTime:0});
const runtime=await (await fetch('/api/runtime')).json();
const deployment=runtime.deployments.local;
assert.equal(await rpc.getChainId(),31337);
assert(deployment?.localTestOnly && deployment.chainId===31337 && deployment.accounts.length>=3);
const [seller,early,later]=deployment.accounts;
const app=createLaunchpadClient();
await app.selectAccount(seller.address);
const draft=makeDefaultDraft();
Object.assign(draft,{name:'Partial exit regression',symbol:'OUTBID',provider:'none',totalSupply:'1000',
  saleBps:8000,liquidityBps:2000,floorPrice:'0.001',minimumRaise:'0.0001',startDelayBlocks:8});
draft.phases=[{...draft.phases[1],durationBlocks:100,minimumBid:'0.01',
  baseCapStart:'10',baseCapEnd:'10',verifiedCapStart:'10',verifiedCapEnd:'10'}];
const id=(await app.createLaunch(draft)).launchId;
assert(id);
const info=(await app.getSnapshot()).launches.find(launch=>launch.id===id)!;
assert.equal(info.status,'upcoming');
await app.selectAccount(early.address);
const earlyBid={amount:'0.2',maxPrice:'0.002',lockDays:0};
assert.equal((await app.previewEligibility!(id, earlyBid)).eligible,false);
await assert.rejects(app.placeBid(id,earlyBid),/not open/i);
await app.advanceBlocks(info.startBlock-Number(await rpc.getBlockNumber()));
await app.placeBid(id,earlyBid);
await app.advanceBlocks(10);
await app.selectAccount(later.address);
await app.placeBid(id,{amount:'4',maxPrice:'0.02',lockDays:0});
await app.advanceBlocks(3);
// Mine no checkpoint transaction here. The competitor's demand will change the
// next checkpoint; a read solely of the stored checkpoint would hide the exit.
await app.selectAccount(early.address);
const before=(await app.getSnapshot()).positions.find(p=>p.id===id)!;
assert.equal(before.actions.settle,true,'A graduated bid is now outbid and can exit before the end.');
const result=await app.settle(id);
assert(result.receiptBlock!<info.endBlock);
const tx=await rpc.getTransaction({hash:result.hash});
assert.equal(tx.to?.toLowerCase(),before.wrapperAddress?.toLowerCase());
const call=decodeFunctionData({abi:runtime.abis.BidLock,data:tx.input});
assert.equal(call.functionName,'exitPartiallyFilledBid');
const args=call.args as readonly [bigint,bigint,bigint];
assert(args[1]>0n && args[2]>args[1],'Expected a last-filled hint and a later first-outbid checkpoint.');
const after=(await app.getSnapshot()).positions.find(p=>p.id===id)!;
assert.equal(after.actions.settle,false);
assert.equal(after.actions.refund,true);
assert.equal(after.actions.claim,false,'Purchased tokens must wait for the claim block.');
assert(parseEther(after.refundableAmount)>0n && parseEther(after.refundableAmount)<parseEther(earlyBid.amount));
assert(parseEther(after.allocatedTokens)>0n,'The bid purchased some tokens before losing priority.');
console.log('Passed: pre-start gate and early partial exit with real CCA checkpoints, token allocation and a partial refund. Launch '+id+'.');
