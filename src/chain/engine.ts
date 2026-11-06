import {
 createPublicClient,createWalletClient,http,custom,getAddress,zeroAddress,
 type Abi,type Address,type Chain,type EIP1193Provider,type Hex,type PublicClient,
} from 'viem';
import {foundry,sepolia} from 'viem/chains';
import type {Activity,NetworkKey,TransactionResult} from '../types';
import type {ContractName,Deployment,Runtime} from './protocol';

const rpcUrl=(network:NetworkKey)=>new URL('/api/rpc/'+network,globalThis.location?.origin || 'http://127.0.0.1:5192').href;
const chains:Record<NetworkKey,Chain>={local:foundry,sepolia};
const clients:Record<NetworkKey,PublicClient>={
 local:createPublicClient({cacheTime:0,chain:foundry,transport:http(rpcUrl('local'),{batch:{batchSize:40,wait:8},retryCount:1})}),
 sepolia:createPublicClient({cacheTime:0,chain:sepolia,transport:http(rpcUrl('sepolia'),{batch:{batchSize:20,wait:12},retryCount:1})}),
};
type SavedActivity=Activity&{owner:Address};
export interface Context {network:NetworkKey;account?:Address;generation:number;runtime:Runtime;deployment:Deployment|null}
export interface ActionContext extends Context {account:Address;deployment:Deployment}
export const ZERO_ID=('0x'+'0'.repeat(64)) as Hex;
export const same=(left:string,right:string)=>left.toLowerCase()===right.toLowerCase();
const savedKey='hoddr-launchpad-transactions-v1';
function stored<T>(key:string,fallback:T):T{try{return JSON.parse(localStorage.getItem(key)||'null')??fallback;}catch{return fallback;}}
function save(key:string,value:unknown){try{localStorage.setItem(key,JSON.stringify(value));}catch{/* The chain remains the source of truth. */}}
export function userError(error:unknown):Error{
 const value=error as {shortMessage?:string;message?:string;walk?:(predicate:(e:unknown)=>boolean)=>unknown};
 const source=value?.shortMessage||value?.message||'The request failed. Please try again.';
 const translations:Record<string,string>={
  CapExceeded:'This bid exceeds the shared allowance for this phase.',
  HumanVerificationRequired:'Verify this wallet before joining this phase.',
  ENSNameRequired:'This wallet must currently own a qualifying subname.',
  BidBelowMinimum:'Increase the bid to this phase’s minimum.',
  InactivePhase:'Bidding is not open in this phase.',
  BidMustBeAboveClearingPrice:'Choose a bid limit above the current clearing price.',
  TickPriceNotAtBoundary:'This price does not match the auction’s price step.',
  TokensStillLocked:'The purchased tokens are still locked.',
  WalletAlreadyBound:'This wallet already has a permanent human identity link.',
  InvalidProof:'The verification proof was not accepted on chain.',
  InvalidRoot:'The verification root was not accepted.',
  NothingToWithdraw:'There is nothing to withdraw yet.',
  TreasuryReleaseBlocked:'Creator proceeds stay held until settlement is proven.',
 };
 for(const [needle,message] of Object.entries(translations))if(source.includes(needle))return new Error(message);
 if(/user rejected|user denied|rejected the request/i.test(source))return new Error('You cancelled the wallet request.');
 return new Error(source.split('Request Arguments')[0].slice(0,350));
}
export class Engine{
 network:NetworkKey=stored('hoddr-launchpad-network','local');
 account?:Address;
 generation=0;
 verification?:AbortController;
 names=new Map<string,string>();
 private runtime?:Runtime;
 private runtimeAt=0;
 private history:SavedActivity[]=stored<SavedActivity[]>(savedKey,[]).filter(x=>x&&typeof x.owner==='string'&&typeof x.title==='string').slice(0,100);
 private attached?:EIP1193Provider;
 constructor(){if(this.network!=='local'&&this.network!=='sepolia')this.network='local';this.attachProvider();}
 provider():EIP1193Provider|undefined{return typeof window==='undefined'?undefined:(window as Window&{ethereum?:EIP1193Provider}).ethereum;}
 private attachProvider(){
  const provider=this.provider();if(!provider||this.attached===provider)return;this.attached=provider;
  provider.on?.('accountsChanged',((addresses:string[])=>{
   if(this.network!=='sepolia')return;
   this.account=addresses[0]?getAddress(addresses[0]):undefined;this.invalidate();
  }) as never);
  provider.on?.('chainChanged',(()=>{if(this.network==='sepolia')this.invalidate();}) as never);
 }
 invalidate(){this.generation++;this.verification?.abort();this.verification=undefined;}
 async getRuntime(force=false):Promise<Runtime>{
  if(this.runtime&&!force&&Date.now()-this.runtimeAt<30_000)return this.runtime;
  const response=await fetch('/api/runtime',{cache:'no-store'});
  if(!response.ok)throw new Error('The local app service is unavailable.');
  const value=await response.json() as Runtime;
  if(value.version!==1||!value.abis||!value.deployments)throw new Error('The app service returned an invalid configuration.');
  for(const key of ['local','sepolia'] as const){
   const deployment=value.deployments[key];
   if(deployment&&(deployment.chainId!==chains[key].id||!/^0x[0-9a-fA-F]{40}$/.test(deployment.factory)))throw new Error('Deployment network mismatch.');
   if(key==='sepolia'&&deployment?.localTestOnly)throw new Error('A synthetic deployment cannot be used on Sepolia.');
  }
  this.runtime=value;this.runtimeAt=Date.now();return value;
 }
 async context():Promise<Context>{
  const runtime=await this.getRuntime();
  if(this.network==='local'&&!this.account){
   const accounts=runtime.deployments.local?.accounts||[];
   const previous=stored<string>('hoddr-launchpad-local-account','');
   this.account=accounts.find(x=>same(x.address,previous))?.address||accounts[1]?.address||accounts[0]?.address;
  }
  return{network:this.network,account:this.account,generation:this.generation,runtime,deployment:runtime.deployments[this.network]};
 }
 async action():Promise<ActionContext>{
  const ctx=await this.context();
  if(!ctx.deployment)throw new Error('This network has no launchpad deployment yet.');
  if(!ctx.account)throw new Error('Connect a wallet first.');
  return ctx as ActionContext;
 }
 check(ctx:Context){
  if(ctx.generation!==this.generation||ctx.network!==this.network||ctx.account!==this.account)throw new Error('The wallet or network changed. Please try again.');
 }
 client(ctx:Context){return clients[ctx.network];}
 abi(ctx:Context,name:ContractName):Abi{
  const value=ctx.runtime.abis[name];if(!value)throw new Error('The '+name+' contract interface is not ready.');return value;
 }
 async read<T>(ctx:Context,name:ContractName,address:Address,fn:string,args:readonly unknown[]=[],blockNumber?:bigint):Promise<T>{
  return await this.client(ctx).readContract({address,abi:this.abi(ctx,name),functionName:fn,args,...(blockNumber===undefined?{}:{blockNumber})}) as T;
 }
 async setNetwork(network:NetworkKey){
  if(network!=='local'&&network!=='sepolia')throw new Error('Unsupported network.');
  this.invalidate();this.network=network;this.account=undefined;save('hoddr-launchpad-network',network);
  if(network==='sepolia'){
   const provider=this.provider();
   if(provider){const accounts=await provider.request({method:'eth_accounts'});if(this.network===network)this.account=accounts[0]?getAddress(accounts[0]):undefined;}
  }
  await this.context();
 }
 async selectAccount(address:Address){
  if(this.network!=='local')throw new Error('Account selection is only available on the local test chain.');
  const ctx=await this.context();
  if(!ctx.deployment?.accounts?.some(x=>same(x.address,address)))throw new Error('Choose a configured local test account.');
  this.invalidate();this.account=getAddress(address);save('hoddr-launchpad-local-account',this.account);
 }
 async connectWallet(){
  if(this.network==='local'){await this.context();if(!this.account)throw new Error('Start the local chain and deployment first.');return;}
  const provider=this.provider();if(!provider)throw new Error('Open this page in a browser with an Ethereum wallet.');
  this.attachProvider();
  const accounts=await provider.request({method:'eth_requestAccounts'});
  if(this.network!=='sepolia')return;
  await provider.request({method:'wallet_switchEthereumChain',params:[{chainId:'0xaa36a7'}]});
  if(this.network!=='sepolia')return;
  this.invalidate();this.account=accounts[0]?getAddress(accounts[0]):undefined;
 }
 private async wallet(ctx:ActionContext){
  this.check(ctx);
  if(ctx.network==='local')return createWalletClient({chain:foundry,account:ctx.account,transport:http(rpcUrl('local'))});
  const provider=this.provider();if(!provider)throw new Error('Your wallet is unavailable.');
  const chainId=await provider.request({method:'eth_chainId'});
  if(Number(BigInt(chainId))!==11155111)throw new Error('Switch your wallet to Ethereum Sepolia.');
  const accounts=await provider.request({method:'eth_accounts'});
  if(!accounts.some(address=>same(address,ctx.account)))throw new Error('Reconnect the selected wallet.');
  this.check(ctx);return createWalletClient({chain:sepolia,account:ctx.account,transport:custom(provider)});
 }
 activity(ctx:Context):Activity[]{return this.history.filter(x=>x.chainId===chains[ctx.network].id&&ctx.account&&same(x.owner,ctx.account)).map(({owner,...item})=>item);}
 async refreshActivity(ctx:Context){
  const pending=this.history.filter(item=>item.status==='pending'&&item.hash&&item.chainId===chains[ctx.network].id&&ctx.account&&same(item.owner,ctx.account));
  await Promise.all(pending.slice(0,10).map(async item=>{
   let receipt;
   try{receipt=await this.client(ctx).getTransactionReceipt({hash:item.hash!});}catch{return;}
   if(same(receipt.from,item.owner)){
    this.add({...item,status:receipt.status==='success'?'confirmed':'failed',description:receipt.status==='success'?'Confirmed in block '+receipt.blockNumber+'.':'The transaction reverted on chain.'});
   }
  }));
 }
 private add(entry:SavedActivity){this.history=[entry,...this.history.filter(x=>x.id!==entry.id)].slice(0,100);save(savedKey,this.history);}
 async write(ctx:ActionContext,name:ContractName,address:Address,fn:string,args:readonly unknown[],label:string,value=0n,onHash?:(hash:Hex)=>void):Promise<TransactionResult>{
  try{
   this.check(ctx);
   const publicClient=this.client(ctx),wallet=await this.wallet(ctx);
   const request={address,abi:this.abi(ctx,name),functionName:fn,args,account:ctx.account,value};
   await publicClient.simulateContract(request);
   this.check(ctx);
   // CCA bid and exit calls may create a fresh checkpoint when mined in the next block.
   const checkpointSensitive=['bid','exitBid','exitPartiallyFilledBid','checkpoint','finalizeLaunch'].includes(fn);
   let gas:bigint|undefined;
   if(checkpointSensitive){
    const [estimate,block]=await Promise.all([publicClient.estimateContractGas({...request,blockTag:'pending'}),publicClient.getBlock()]);
    gas=estimate+estimate/5n+200_000n;
    if(gas>block.gasLimit)gas=block.gasLimit;
   }
   this.check(ctx);
   const hash=await wallet.writeContract({...request,gas,chain:chains[ctx.network]});
   const activity:SavedActivity={id:hash,title:label,description:'Waiting for the chain receipt.',timestamp:Math.floor(Date.now()/1000),status:'pending',hash,chainId:chains[ctx.network].id,owner:ctx.account};
   this.add(activity);onHash?.(hash);
   const receipt=await publicClient.waitForTransactionReceipt({hash,pollingInterval:1000,timeout:180_000});
   if(receipt.status!=='success'){this.add({...activity,status:'failed',description:'The transaction reverted on chain.'});throw new Error('The transaction reverted on chain.');}
   this.add({...activity,status:'confirmed',description:'Confirmed in block '+receipt.blockNumber.toString()+'.'});
   return{hash,chainId:chains[ctx.network].id,label,receiptBlock:Number(receipt.blockNumber)};
  }catch(error){throw userError(error);}
 }
 nameKey(ctx:Context,launchId:string){return ctx.network+':'+ctx.account?.toLowerCase()+':'+launchId;}
 async localAction(route:string,payload:unknown){
  if(this.network!=='local')throw new Error('Time controls are only available on the local test chain.');
  const response=await fetch('/api/local/'+route,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(payload)});
  const value=await response.json();if(!response.ok||!value.ok)throw new Error(value.error||'The local chain action failed.');
 }
}
export {zeroAddress,chains};
