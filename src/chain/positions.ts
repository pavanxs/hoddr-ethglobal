import {canExitEarly,exitHints} from './exit';
import type {Address} from 'viem';
import type {BidInput} from '../types';
import {bidPrice,decimal} from './amounts';
import {Engine,same,zeroAddress,type ActionContext} from './engine';
import {ensEvidence} from './ens';
import type {Bid,Checkpoint} from './protocol';
import {ChainViews} from './views';

export class Positions {
 constructor(private engine:Engine,private views:ChainViews){}
 private wrapper(ctx:ActionContext,auction:Address){
  return this.engine.read<Address>(ctx,'BidLockFactory',ctx.deployment.wrapperFactory,'wrapperFor',[auction,ctx.account]);
 }
 async bid(id:string,input:BidInput){
  const ctx=await this.engine.action(),bundle=await this.views.bundle(ctx,id),{record}=bundle;
  const amount=decimal(input.amount),limit=bidPrice(input.maxPrice,record.priceTickSpacing);
  const index=this.views.lockIndex(bundle,input.lockDays);
  const eligibility=await this.views.allowance(ctx,id,input.lockDays,input.ensName);
  if(!eligibility.eligible)throw new Error(eligibility.reason||'This account is ineligible.');
  if(amount<decimal(eligibility.minimumBid)||amount>decimal(eligibility.remaining,'Allowance',true))throw new Error('Use an amount between the minimum and the remaining allowance.');
  if(limit<=await this.engine.read<bigint>(ctx,'ContinuousClearingAuction',record.auction,'clearingPrice'))throw new Error('Enter a maximum price above the clearing price.');
  const name=input.ensName||this.engine.names.get(this.engine.nameKey(ctx,id));
  const evidence=eligibility.ensRequired&&name&&bundle.parent?ensEvidence(name,bundle.parent):'0x';
  let wrapper=await this.wrapper(ctx,record.auction);
  if(same(wrapper,zeroAddress)){
   await this.engine.write(ctx,'LaunchpadFactory',ctx.deployment.factory,'createPosition',[record.id,BigInt(index),BigInt(input.requestedUnlockAt||0)],'Open bid position');
   wrapper=await this.wrapper(ctx,record.auction);
  }
  if(Number(await this.engine.read<number>(ctx,'BidLock',wrapper,'lockOptionIndex'))!==index)throw new Error('Your existing position has a fixed lock duration.');
  const result=await this.engine.write(ctx,'BidLock',wrapper,'bid',[limit,amount,record.floorPriceQ96,evidence],'Place bid',amount);
  return {...result,launchId:id,positionId:id};
 }
 private async existing(id:string){
  const ctx=await this.engine.action(),{record}=await this.views.bundle(ctx,id),wrapper=await this.wrapper(ctx,record.auction);
  if(same(wrapper,zeroAddress))throw new Error('This account has no position in this launch.');
  return {ctx,record,wrapper};
 }
 async withdraw(id:string,kind:'refund'|'unlock'){
  const {ctx,wrapper}=await this.existing(id);
  return this.engine.write(ctx,'BidLock',wrapper,kind==='refund'?'withdrawRefunds':'withdrawTokens',[ctx.account],kind==='refund'?'Withdraw refund':'Collect unlocked tokens');
 }
 async finish(id:string,claim:boolean){
  const {ctx,record,wrapper}=await this.existing(id);
  const read=<T>(name:string,args:readonly unknown[]=[])=>this.engine.read<T>(ctx,'ContinuousClearingAuction',record.auction,name,args);
  const ids=await this.engine.read<bigint[]>(ctx,'BidLock',wrapper,'bidIds');
  const bids=await Promise.all(ids.map(async id=>({id,bid:await read<Bid>('bids',[id])})));
  if(claim){
   const ready=bids.filter(b=>b.bid.tokensFilled>0n).slice(0,64).map(b=>b.id);
   if(!ready.length)throw new Error('No purchased tokens are ready to claim.');
   return this.engine.write(ctx,'BidLock',wrapper,'claimBids',[ready],'Claim purchased tokens');
  }
  const height=await this.engine.client(ctx).getBlockNumber({cacheTime:0}),over=height>=record.endBlock;
  if(over&&await read<bigint>('lastCheckpointedBlock')<record.endBlock)await this.engine.write(ctx,'ContinuousClearingAuction',record.auction,'checkpoint',[],'Record final price');
  if(!over && await canExitEarly(this.engine,ctx,record.auction,bids,height) && await read<bigint>('lastCheckpointedBlock')<height){
   await this.engine.write(ctx,'ContinuousClearingAuction',record.auction,'checkpoint',[],'Record outbid price');
  }
  const [graduated,latest]=await Promise.all([read<boolean>('isGraduated'),read<Checkpoint>('latestCheckpoint')]);
  const item=bids.find(b=>b.bid.exitedBlock===0n&&(over||(graduated&&latest.clearingPrice>b.bid.maxPrice)));
  if(!item)throw new Error('No bid can be settled yet.');
  const {bid,id:bidId}=item;
  if(over&&(!graduated||bid.maxPrice>latest.clearingPrice))return this.engine.write(ctx,'BidLock',wrapper,'exitBid',[bidId],'Settle bid #'+bidId);
  const block=await this.engine.client(ctx).getBlockNumber({cacheTime:0});
  const [lastFull,outbid]=await exitHints(this.engine,ctx,record.auction,bid,block);
  return this.engine.write(ctx,'BidLock',wrapper,'exitPartiallyFilledBid',[bidId,lastFull,outbid],'Settle bid #'+bidId);
 }
}
