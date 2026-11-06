import {type Address} from 'viem';
import type {LaunchpadClient} from '../types';
import {Engine} from './engine';
import {createLaunch} from './create';
import {Positions} from './positions';
import {ChainViews} from './views';

export function createLaunchpadClient():LaunchpadClient {
 const engine=new Engine(), views=new ChainViews(engine), positions=new Positions(engine,views);
 return {
  getSnapshot:()=>views.snapshot(),
  setNetwork:n=>engine.setNetwork(n),
  connectWallet:()=>engine.connectWallet(),
  selectAccount:a=>engine.selectAccount(a),
  createLaunch:d=>createLaunch(engine,d),
  placeBid:(id,input)=>positions.bid(id,input),
  previewEligibility:async(id,input)=>views.allowance(await engine.context(),id,input.lockDays,input.ensName),
  checkEns:async(id,name)=>{
   const ctx=await engine.action(),result=await views.inspectName(ctx,id,name);
   engine.check(ctx);
   if(result.valid)engine.names.set(engine.nameKey(ctx,id),result.name);
   return result;
  },
  cancelVerification:()=>{engine.verification?.abort();},
  verifyHuman:async report=>{
   const ctx=await engine.action();
   const synthetic=ctx.deployment.localTestOnly;
   const controller=new AbortController();
   engine.verification?.abort();engine.verification=controller;
   try{
    let proof;
    if(synthetic){
     const fixture=ctx.deployment.syntheticProofs?.[ctx.account.toLowerCase()];
     if(!fixture)throw new Error('This local account has no synthetic identity fixture.');
     report({status:'checking',synthetic,message:'Checking the local test proof.'});
     proof={root:BigInt(fixture.root),nullifierHash:BigInt(fixture.nullifierHash),proof:fixture.proof.map(BigInt)};
    }else{
     if(!ctx.runtime.worldConfigured)throw new Error('World ID staging is not configured on this network.');
     const {acquireWorldProof}=await import('./world');
     proof=await acquireWorldProof(engine,ctx,controller.signal,report);
    }
    engine.check(ctx);controller.signal.throwIfAborted();
    const result=await engine.write(ctx,'IdentityRegistry',ctx.deployment.identityRegistry,'verifyAndBind',
      [ctx.account,proof.root,proof.nullifierHash,proof.proof],synthetic?'Bind local test identity':'Verify World ID onchain',0n,
      hash=>report({status:'submitting',synthetic,hash,message:'Waiting for the contract receipt.'}));
    const key=await engine.read<Address>(ctx,'IdentityRegistry',ctx.deployment.identityRegistry,'identityOf',[ctx.account]);
    if(BigInt(key)===0n)throw new Error('No confirmed identity binding was found.');
    engine.check(ctx);
    report({status:'confirmed',synthetic,hash:result.hash,message:synthetic?'Local test identity confirmed on chain.':'World ID confirmed on chain.'});
    return result;
   }catch(error){
    if(controller.signal.aborted)throw new Error('World ID request cancelled.');
    if(!synthetic)throw new Error('World ID verification was not confirmed. Check the connected wallet and retry.');
    throw error;
   }finally{if(engine.verification===controller)engine.verification=undefined;}
  },
  settle:id=>positions.finish(id,false),claim:id=>positions.finish(id,true),
  refund:id=>positions.withdraw(id,'refund'),unlock:id=>positions.withdraw(id,'unlock'),
  checkpoint:async (id:string)=>{
   const ctx=await engine.action(),{record}=await views.bundle(ctx,id);
   return engine.write(ctx,'ContinuousClearingAuction',record.auction,'checkpoint',[],'Update auction price');
  },
  migrate:async id=>{
   const ctx=await engine.action(),{record}=await views.bundle(ctx,id);
   const status=await engine.read<number>(ctx,'LaunchSettlementVault',record.settlement,'status');
   if(status===3||status===4)throw new Error('This sale has already settled.');
   return engine.write(ctx,'LaunchpadFactory',ctx.deployment.factory,status===2?'recoverLiquidity':'finalizeLaunch',
     [record.id],status===2?'Recover pool liquidity':'Settle sale');
  },
  releaseProceeds:async id=>{
   const ctx=await engine.action(),{record}=await views.bundle(ctx,id);
   return engine.write(ctx,'LaunchSettlementVault',record.settlement,'releaseProceeds',[ctx.account],'Collect sale proceeds');
  },
  releasePosition:async id=>{
   const ctx=await engine.action(),{record}=await views.bundle(ctx,id);
   return engine.write(ctx,'LaunchSettlementVault',record.settlement,'releasePosition',[ctx.account],'Collect liquidity position');
  },
  advanceBlocks:count=>engine.localAction('advance-blocks',{count}),
  advanceTime:seconds=>engine.localAction('advance-time',{seconds}),
 };
}
