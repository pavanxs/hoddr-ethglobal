import {ContractFunctionRevertedError,type Address} from 'viem';
import type {Engine,Context} from './engine';
import type {Bid,Checkpoint} from './protocol';

export async function exitHints(engine:Engine,ctx:Context,auction:Address,bid:Bid,block:bigint,projectedPrice?:bigint){
 const read=<T>(fn:string,args:readonly unknown[]=[])=>engine.read<T>(ctx,'ContinuousClearingAuction',auction,fn,args,block);
 const last=await read<bigint>('lastCheckpointedBlock');
 let at=bid.startBlock,lastFull=at,outbid=0n;
 while(at<=last){
  const point=await read<Checkpoint>('checkpoints',[at]);
  if(point.clearingPrice<bid.maxPrice)lastFull=at;
  if(point.clearingPrice>bid.maxPrice){outbid=at;break;}
  if(point.next<=at||point.next>last)break;
  at=point.next;
 }
 if(outbid===0n&&block>last&&projectedPrice!==undefined&&projectedPrice>bid.maxPrice)outbid=block;
 return [lastFull,outbid] as const;
}

// A bid can become outbid between recorded checkpoints. Simulate the same CCA
// exit at this block to verify both graduation and fill boundaries without a write.
export async function canExitEarly(engine:Engine,ctx:Context,auction:Address,items:{id:bigint;bid:Bid}[],block:bigint){
 if(!items.length)return false;
 const client=engine.client(ctx),abi=engine.abi(ctx,'ContinuousClearingAuction');
 const next=await client.simulateContract({address:auction,abi,functionName:'checkpoint',blockNumber:block});
 const price=(next.result as Checkpoint).clearingPrice;
 for(const item of items.filter(i=>i.bid.exitedBlock===0n&&price>i.bid.maxPrice)){
  const hints=await exitHints(engine,ctx,auction,item.bid,block,price);
  try{
   await client.simulateContract({address:auction,abi,functionName:'exitPartiallyFilledBid',args:[item.id,...hints],blockNumber:block});
   return true;
  }catch(error){
   const reason=(error as {walk?:(fn:(cause:unknown)=>boolean)=>unknown}).walk?.(e=>e instanceof ContractFunctionRevertedError);
   if(!(reason instanceof ContractFunctionRevertedError))throw error;
  }
 }
 return false;
}
