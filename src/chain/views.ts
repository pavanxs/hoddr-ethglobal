import {canExitEarly} from './exit';
import type {Address,Hex} from 'viem';
import type {AccountState,AppSnapshot,Asset,EligibilityState,Launch,Position,ProviderState} from '../types';
import type {Allowance,Bid,ChainLock,ChainPhase,Checkpoint,EnsInspection,LaunchRecord} from './protocol';
import {Engine,ZERO_ID,chains,same,zeroAddress,type Context} from './engine';
import {amount,priceFromQ96,Q96,safeNumber} from './amounts';
import {ensEvidence,ensReasons} from './ens';

export const ETH:Asset={address:zeroAddress,symbol:'ETH',name:'Ether',decimals:18,native:true};
export interface Bundle {record:LaunchRecord;phases:ChainPhase[];locks:ChainLock[];parent?:string;description:string;phaseNames:string[]}
function metadata(uri:string):{description:string;phaseNames:string[]}{
 try{
  const prefix='data:application/json;base64,';
  if(!uri.startsWith(prefix)||uri.length>24_000)return{description:'',phaseNames:[]};
  const bytes=Uint8Array.from(atob(uri.slice(prefix.length)),c=>c.charCodeAt(0));
  const value=JSON.parse(new TextDecoder().decode(bytes));
  return{
   description:typeof value.description==='string'?value.description.slice(0,2000):'',
   phaseNames:Array.isArray(value.phaseNames)?value.phaseNames.map((x:unknown)=>typeof x==='string'?x.slice(0,60):'') :[],
  };
 }catch{return{description:'',phaseNames:[]};}
}
export class ChainViews{
 private bundles=new Map<string,Bundle>();
 constructor(readonly engine:Engine){}
 async bundle(ctx:Context,id:string,blockNumber?:bigint):Promise<Bundle>{
  if(!/^[1-9]\d*$/.test(id)||!ctx.deployment)throw new Error('Unknown launch.');
  const record=await this.engine.read<LaunchRecord>(ctx,'LaunchpadFactory',ctx.deployment.factory,'launchAt',[BigInt(id)],blockNumber);
  const key=ctx.network+':'+ctx.deployment.factory+':'+record.token+':'+record.validationHook;
  const cached=this.bundles.get(key);if(cached)return cached;
  const [phases,locks]=await Promise.all([
   this.engine.read<ChainPhase[]>(ctx,'PhaseCapHook',record.validationHook,'phases',[],blockNumber),
   this.engine.read<ChainLock[]>(ctx,'PhaseCapHook',record.validationHook,'lockOptions',[],blockNumber),
  ]);
  const gate=phases.find(phase=>!same(phase.ensGate,zeroAddress))?.ensGate;
  const parent=gate?await this.engine.read<string>(ctx,'ENSDomainGate',gate,'parentDomain',[],blockNumber):undefined;
  const value={record,phases,locks,parent,...metadata(record.metadataURI)};this.bundles.set(key,value);return value;
 }
 lockIndex(bundle:Bundle,days:number):number{
  const index=bundle.locks.findIndex(option=>Number(option.durationSeconds)===days*86400);
  if(index<0)throw new Error('Choose one of this launch’s lock durations.');return index;
 }
 async allowance(ctx:Context,id:string,days:number,name?:string,blockNumber?:bigint):Promise<EligibilityState>{
  if(!ctx.account||!ctx.deployment)throw new Error('Connect a wallet first.');
  const bundle=await this.bundle(ctx,id,blockNumber),index=this.lockIndex(bundle,days);
  const selected=name??this.engine.names.get(this.engine.nameKey(ctx,id));
  let evidence:Hex='0x',nameError:string|undefined;
  if(selected&&bundle.parent){try{evidence=ensEvidence(selected,bundle.parent);}catch(error){nameError=(error as Error).message;}}
  const [preview,ensSatisfied,eligible]=await this.engine.read<[Allowance,boolean,boolean]>(
   ctx,'PhaseCapHook',bundle.record.validationHook,'previewWithEvidence',[ctx.account,BigInt(index),evidence],blockNumber,
  );
  const linkedWalletCount=preview.verified?safeNumber(await this.engine.read<bigint>(
   ctx,'IdentityRegistry',ctx.deployment.identityRegistry,'walletCount',[preview.identity],blockNumber,
  ),'Linked wallet count'):0;
  let reason:string|undefined;
  if(!preview.active)reason='Bidding is not open right now.';
  else if(!preview.identityAllowed)reason='Verify your wallet to enter this phase.';
  else if(preview.ensRequired&&!ensSatisfied)reason=nameError||'Own an active subname under '+bundle.parent+'.';
  else if(preview.remaining<preview.minimumBid)reason='The remaining shared allowance is below this phase’s minimum bid.';
  const effective=bundle.locks[Number(preview.effectiveLockOptionIndex)];
  return{
   eligible:eligible&&!nameError,verified:preview.verified,syntheticIdentity:preview.verified&&ctx.deployment.localTestOnly,
   identitySource:preview.verified?(ctx.deployment.localTestOnly?'Local World ID fixture':'World ID v3 Orb'):undefined,
   tier:preview.verified?'verified':'base',ensRequired:preview.ensRequired,ensName:selected,
   ensSatisfied,reason,currentCap:amount(preview.cap),cumulativeSpend:amount(preview.committed),
   remaining:amount(preview.remaining),minimumBid:amount(preview.minimumBid),linkedWalletCount,
   effectiveMultiplierBps:Number(preview.effectiveMultiplierBps),effectiveLockDays:Number(effective.durationSeconds)/86400,
   priorSpendIncluded:preview.verified&&preview.committed>0n,
  };
 }
 async inspectName(ctx:Context,id:string,name:string){
  if(!ctx.account)throw new Error('Connect a wallet first.');
  const bundle=await this.bundle(ctx,id);
  if(!bundle.parent)throw new Error('This launch does not require an ENS subname.');
  const evidence=ensEvidence(name,bundle.parent);
  const gate=bundle.phases.find(phase=>!same(phase.ensGate,zeroAddress))!.ensGate;
  const result=await this.engine.read<EnsInspection>(ctx,'ENSDomainGate',gate,'inspect',[ctx.account,evidence]);
  return{name:name.trim().toLowerCase(),valid:result.eligible,owner:same(result.owner,zeroAddress)?undefined:result.owner,reason:ensReasons[Number(result.reason)]||'Name ownership could not be confirmed.'};
 }
 async position(ctx:Context,bundle:Bundle,blockNumber:bigint,timestamp:bigint,currentPrice:bigint,graduated:boolean):Promise<Position|undefined>{
  if(!ctx.account||!ctx.deployment)return;
  const {record}=bundle,id=record.id.toString();
  const wrapper=await this.engine.read<Address>(ctx,'BidLockFactory',ctx.deployment.wrapperFactory,'wrapperFor',[record.auction,ctx.account],blockNumber);
  if(same(wrapper,zeroAddress))return;
  const read=<T>(fn:string,args:readonly unknown[]=[])=>this.engine.read<T>(ctx,'BidLock',wrapper,fn,args,blockNumber);
  const [bidIds,received,released,refund,unlockAt,duration]=await Promise.all([
   read<bigint[]>('bidIds'),read<bigint>('purchasedReceived'),read<bigint>('purchasedReleased'),
   this.engine.client(ctx).getBalance({address:wrapper,blockNumber}),read<bigint>('unlockAt'),read<bigint>('lockDuration'),
  ]);
  const bids=await Promise.all(bidIds.map(bid=>this.engine.read<Bid>(ctx,'ContinuousClearingAuction',record.auction,'bids',[bid],blockNumber)));
  const committed=bids.reduce((sum,bid)=>sum+bid.amountQ96/Q96,0n);
  const highest=bids.reduce((price,bid)=>bid.maxPrice>price?bid.maxPrice:price,0n);
  const claimable=bids.reduce((sum,bid)=>sum+bid.tokensFilled,0n);
  const held=received-released;
  const ready=held>0n&&timestamp>=unlockAt;
  const active=bids.filter(bid=>bid.exitedBlock===0n);
  const canSettle=active.some(bid=>blockNumber>=record.endBlock||(graduated&&currentPrice>bid.maxPrice)) || (active.length>0 && blockNumber>=record.startBlock && blockNumber<record.endBlock && await canExitEarly(this.engine,ctx,record.auction,bids.map((bid,i)=>({id:bidIds[i],bid})),blockNumber));
  const canClaim=claimable>0n&&blockNumber>=record.claimBlock;
  const status=claimable>0n?'ready':held>0n&&!ready?'locked':refund>0n?'refundable':active.length||!bids.length?'active':held>0n?'ready':'complete';
  return{
   id,launchId:id,launchName:record.name,symbol:record.symbol,owner:ctx.account,beneficiary:ctx.account,wrapperAddress:wrapper,
   bidCount:bids.length,amount:amount(committed),maxPrice:priceFromQ96(highest),quoteAsset:ETH,
   allocatedTokens:amount(received+claimable),claimableTokens:amount(claimable),refundableAmount:amount(refund),
   lockedTokens:amount(ready?0n:held),unlockedTokens:amount(ready?held:0n),lockDays:Number(duration)/86400,
   unlockAt:received>0n?safeNumber(unlockAt,'Unlock time'):undefined,status,
   actions:{settle:canSettle,claim:canClaim,refund:refund>0n,unlock:ready},
   unavailableReason:active.length&&!canSettle?'The auction must finish, or this bid must be outbid after graduation.':undefined,
  };
 }
 async launch(ctx:Context,id:string,blockNumber:bigint,timestamp:bigint):Promise<{launch:Launch;position?:Position}>{
  const bundle=await this.bundle(ctx,id,blockNumber),{record,phases,locks}=bundle;
  const read=<T>(name:'ContinuousClearingAuction'|'LaunchSettlementVault',fn:string,args:readonly unknown[]=[])=>this.engine.read<T>(
   ctx,name,name==='ContinuousClearingAuction'?record.auction:record.settlement,fn,args,blockNumber,
  );
  const [raised,nextBidId,checkpoint,lastCheckpoint,graduated,state,poolId,positionId,positionReleased,treasuryEth,treasuryTokens]=await Promise.all([
   read<bigint>('ContinuousClearingAuction','currencyRaised'),read<bigint>('ContinuousClearingAuction','nextBidId'),
   read<Checkpoint>('ContinuousClearingAuction','latestCheckpoint'),read<bigint>('ContinuousClearingAuction','lastCheckpointedBlock'),
   read<boolean>('ContinuousClearingAuction','isGraduated'),read<number>('LaunchSettlementVault','status'),
   read<Hex>('LaunchSettlementVault','poolId'),read<bigint>('LaunchSettlementVault','positionId'),
   read<boolean>('LaunchSettlementVault','positionReleased'),this.engine.client(ctx).getBalance({address:record.settlement,blockNumber}),
   this.engine.read<bigint>(ctx,'LaunchToken',record.token,'balanceOf',[record.settlement],blockNumber),
  ]);
  const currentPrice=checkpoint.clearingPrice||record.floorPriceQ96;
  const status=state===3?'graduated':state===4||(lastCheckpoint>=record.endBlock&&!graduated)?'failed':blockNumber<record.startBlock?'upcoming':blockNumber<record.endBlock?'live':'settling';
  const phaseIndex=phases.findIndex(phase=>blockNumber>=phase.startBlock&&blockNumber<phase.endBlock);
  const position=await this.position(ctx,bundle,blockNumber,timestamp,currentPrice,graduated);
  const eligibility=ctx.account?await this.allowance(ctx,id,position?.lockDays||0,undefined,blockNumber):undefined;
  const isTreasury=!!ctx.account&&same(ctx.account,record.treasury);
  const releaseReady=state===3||state===4;
  return{
   position,
   launch:{
    id,name:record.name,symbol:record.symbol,description:bundle.description,creator:record.creator,
    tokenAddress:record.token,auctionAddress:record.auction,hookAddress:record.validationHook,
    poolAddress:state===3?ctx.deployment!.poolManager:undefined,poolId:state===3?poolId:undefined,status,
    totalSupply:amount(record.totalSupply),saleSupply:amount(record.totalSupply-record.reserveForLiquidity),liquiditySupply:amount(record.reserveForLiquidity),
    raised:amount(raised),minimumRaise:amount(record.requiredCurrencyRaised),floorPrice:priceFromQ96(record.floorPriceQ96),
    currentPrice:priceFromQ96(currentPrice),totalBids:safeNumber(nextBidId,'Bid count'),startBlock:Number(record.startBlock),endBlock:Number(record.endBlock),
    currentPhaseIndex:phaseIndex<0?null:phaseIndex,
    phases:phases.map((phase,index)=>({
     id:String(index),name:bundle.phaseNames[index]||(index===0?'Community phase':'Open phase '+(index+1)),
     durationBlocks:Number(phase.endBlock-phase.startBlock),startBlock:Number(phase.startBlock),endBlock:Number(phase.endBlock),
     minimumBid:amount(phase.minimumBid),baseCapStart:amount(phase.baseCapStart),baseCapEnd:amount(phase.baseCapEnd),
     verifiedCapStart:amount(phase.verifiedCapStart),verifiedCapEnd:amount(phase.verifiedCapEnd),requireVerified:phase.verifiedOnly,requireEns:!same(phase.ensGate,zeroAddress),
    })),
    locks:locks.map((option,index)=>({id:String(index),durationDays:Number(option.durationSeconds)/86400,multiplierBps:Number(option.multiplierBps)})),
    provider:record.identityEnabled?'world-id':'none',ensDomain:bundle.parent,quoteAsset:ETH,eligibility,
    canMigrate:blockNumber>=record.endBlock+1n&&state!==3&&state!==4,
    migrationUnavailableReason:blockNumber<record.endBlock+1n?'Settlement opens one block after the auction ends.':state===3?'Liquidity is settled.':state===4?'This launch did not reach its minimum raise.':undefined,
    accent:(['mint','violet','peach','blue'] as const)[Number(record.id-1n)%4],
    treasury:{
     address:record.treasury,nativeAmount:amount(treasuryEth),tokenAmount:amount(treasuryTokens),
     positionId:positionId>0n?positionId.toString():undefined,positionReleased,
     canReleaseProceeds:isTreasury&&releaseReady&&(treasuryEth>0n||treasuryTokens>0n),
     canReleasePosition:isTreasury&&state===3&&positionId>0n&&!positionReleased,
    },
   },
  };
 }
 providers(ctx:Context):ProviderState[]{
  const local=ctx.deployment?.localTestOnly,worldReady=ctx.network==='sepolia'&&ctx.runtime.worldConfigured;
  return[
   {key:'none',name:'Open participation',status:'ready',description:'Wallet limits only. One person can use several unverified wallets.'},
   {key:'world-id',name:'World ID',status:local?'local-fixture':worldReady?'ready':'not-configured',
    description:local?'Synthetic local proofs for testing. No real human verification.':worldReady?'World ID v3 Orb, verified by the Sepolia router.':'World ID v3 Orb requires a configured request signer and a fresh wallet-bound proof.'},
   {key:'zkpassport',name:'ZKPassport',status:'unavailable',description:'This launchpad has no reviewed ZKPassport adapter yet.'},
   {key:'ace',name:'ACE',status:'unavailable',description:'This launchpad has no verified ACE integration yet.'},
  ];
 }
 async snapshot():Promise<AppSnapshot>{
  const ctx=await this.engine.context(),chain=chains[ctx.network];
  await this.engine.refreshActivity(ctx);
  const base:AppSnapshot={
   launchpadDeployed:!!ctx.deployment,
   network:{key:ctx.network,name:ctx.network==='local'?'Local test chain':'Ethereum Sepolia',chainId:chain.id,blockNumber:0,timestamp:0,connected:false,explorerUrl:ctx.network==='sepolia'?'https://sepolia.etherscan.io':undefined},
   quoteAsset:ETH,launches:[],positions:[],activity:this.engine.activity(ctx),providers:this.providers(ctx),
   localAccounts:ctx.network==='local'?ctx.deployment?.accounts:undefined,limits:{maxPhases:16,maxLocks:8,maxLinkedWallets:32},notices:[],
  };
  let block;
  try{block=await this.engine.client(ctx).getBlock();}catch{return{...base,notices:['The '+base.network.name+' RPC is unavailable.']};}
  if(block.number===null)throw new Error('The chain did not return a block number.');
  base.network={...base.network,blockNumber:safeNumber(block.number,'Block'),timestamp:safeNumber(block.timestamp,'Timestamp'),connected:true};
  if(!ctx.deployment)return{...base,notices:['A launchpad has not been deployed on this network yet.']};
  if(ctx.account){
   const [balance,identity]=await Promise.all([
    this.engine.client(ctx).getBalance({address:ctx.account,blockNumber:block.number}),
    this.engine.read<Hex>(ctx,'IdentityRegistry',ctx.deployment.identityRegistry,'identityOf',[ctx.account],block.number),
   ]);
   const verified=identity!==ZERO_ID;
   const account:AccountState={
    address:ctx.account,nativeBalance:amount(balance),quoteBalance:amount(balance),mode:ctx.network==='local'?'local':'wallet',verified,
    syntheticIdentity:verified&&ctx.deployment.localTestOnly,identitySource:verified?(ctx.deployment.localTestOnly?'Local World ID fixture':'World ID v3 Orb'):undefined,
    linkedWalletCount:verified?Number(await this.engine.read<bigint>(ctx,'IdentityRegistry',ctx.deployment.identityRegistry,'walletCount',[identity],block.number)):0,
    ensName:ctx.deployment.seededNames?.[ctx.account.toLowerCase()]?.[0],
   };
   base.account=account;
  }
  const count=safeNumber(await this.engine.read<bigint>(ctx,'LaunchpadFactory',ctx.deployment.factory,'launchCount',[],block.number),'Launch count');
  const ids=Array.from({length:Math.min(count,250)},(_,index)=>(count-index).toString());
  const results:{launch:Launch;position?:Position}[]=[];
  for(let index=0;index<ids.length;index+=4){
   results.push(...await Promise.all(ids.slice(index,index+4).map(id=>this.launch(ctx,id,block.number!,block.timestamp))));
   this.engine.check(ctx);
  }
  base.launches=results.map(result=>result.launch);base.positions=results.flatMap(result=>result.position?[result.position]:[]);
  if(count>250)base.notices!.push('Showing the latest 250 launches.');
  if(ctx.deployment.localTestOnly)base.notices!.push('Local test chain. ETH, identity proofs and seeded ENS names are test fixtures.');
  this.engine.check(ctx);return base;
 }
}
