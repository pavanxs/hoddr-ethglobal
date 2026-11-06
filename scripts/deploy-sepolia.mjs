import assert from 'node:assert/strict';
import fs from 'node:fs';
import {createPublicClient,createWalletClient,encodeDeployData,formatEther,getAddress,http,keccak256,parseAbi,parseEther,zeroAddress} from 'viem';
import {privateKeyToAccount} from 'viem/accounts';
import {sepolia} from 'viem/chains';

const mode=process.argv[2] || '--fork';
assert(['--fork','--broadcast'].includes(mode),'Use --fork or --broadcast');
const fork=mode==='--fork';
const rpc=fork?'http://127.0.0.1:8548':'https://ethereum-sepolia-rpc.publicnode.com';
const transport=http(rpc,{timeout:30000,retryCount:2});
const client=createPublicClient({chain:sepolia,transport,cacheTime:0,pollingInterval:fork?100:3000});
assert.equal(await client.getChainId(),11155111);
const appId=process.env.LAUNCHPAD_WORLD_APP_ID || (fork?'app_localfork':'');
const action=process.env.LAUNCHPAD_WORLD_ACTION || (fork?'join-launchpad':'');
assert(/^app_[a-z0-9]+$/i.test(appId)&&action,'Configure the registered World ID app and action.');
let account,address;
if(fork){
 const info=await client.request({method:'anvil_nodeInfo'});
 assert((info.forkConfig || info.fork_config)?.forkBlockNumber,'Expected an Anvil fork on loopback.');
 const accounts=await client.request({method:'eth_accounts'});
 account=address=getAddress(accounts[0]);
}else{
 assert.equal(process.env.SEPOLIA_CHAIN_ID,'11155111','Expected the dedicated Ethereum Sepolia test wallet.');
 const key=process.env.SEPOLIA_TEST_WALLET_PRIVATE_KEY;
 assert(/^0x[0-9a-f]{64}$/i.test(key||''),'Expected a dedicated Sepolia signing key.');
 account=privateKeyToAccount(key);
 address=account.address;
 assert.equal(address,getAddress(process.env.SEPOLIA_TEST_WALLET_ADDRESS),'Test-wallet address mismatch.');
}
const wallet=createWalletClient({chain:sepolia,account,transport});
const canonical={
 strategy:'0x95434E898Af471945Cab33D5064d2aC1A6Ba2000',
 poolManager:'0xE03A1074c86CFeDd5C142C4F04F1a1536e203543',
 positionManager:'0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4',
 auctionFactory:'0x000000001F26a0044BaA66024e7b6599c61963F8',
 worldRouter:'0x469449f251692E0779667583026b5A1E99512157',
};
const links=parseAbi(['function poolManager() view returns(address)','function positionManager() view returns(address)','function initializerFactory() view returns(address)','function protocolFeeController() view returns(address)']);
const link=(contract,name)=>client.readContract({address:contract,abi:links,functionName:name});
for(const [name,ref] of [['poolManager','poolManager'],['positionManager','positionManager'],['initializerFactory','auctionFactory']]){
 assert.equal(getAddress(await link(canonical.strategy,name)),getAddress(canonical[ref]),'Unexpected strategy wiring.');
}
assert.equal(await link(canonical.auctionFactory,'protocolFeeController'),zeroAddress);
assert((await client.getCode({address:canonical.worldRouter}))?.length>2,'World router unavailable.');
const source=fs.readFileSync('contracts/src/libraries/ENSV2SepoliaPins.sol','utf8');
const pin=name=>{const value=source.match(new RegExp('constant\\s+'+name+'\\s*=\\s*(0x[0-9a-fA-F]+)'))?.[1];assert(value);return value;};
const anchors=['ROOT','ETH_REGISTRY','FACTORY','USER_IMPLEMENTATION'].map(pin);
const hashes=['SYSTEM_CODE_HASH','SYSTEM_CODE_HASH','FACTORY_CODE_HASH','USER_CODE_HASH'].map(pin);
for(const [i,anchor] of anchors.entries())assert.equal(keccak256(await client.getCode({address:anchor})),hashes[i]);
const budget=fork?undefined:parseEther(process.env.SEPOLIA_DEPLOY_MAX_ETH||'0');
if(!fork)assert(budget>0n,'Set SEPOLIA_DEPLOY_MAX_ETH to a total ETH fee limit before broadcasting.');
const output=fork?'.local-chain/sepolia-fork.json':'deployments/sepolia.json';
fs.mkdirSync('.local-chain',{recursive:true});fs.mkdirSync('deployments',{recursive:true});
const checkpoint=fork?'.local-chain/fork-deploy-progress.json':'.local-chain/public-deploy-progress.json';
if(!fork && fs.existsSync(output) && !fs.existsSync(checkpoint))throw new Error('A public deployment already exists. Inspect it before starting another.');
const state=fs.existsSync(checkpoint)?JSON.parse(fs.readFileSync(checkpoint,'utf8')):{sender:address,appId,action,transactions:[]};
assert.equal(state.sender,address);assert.equal(state.appId,appId);assert.equal(state.action,action);
const artifacts=n=>JSON.parse(fs.readFileSync('contracts/out/'+n+'.sol/'+n+'.json','utf8'));
let gasTotal=0n,feeTotal=0n;
const write=(file,value)=>{fs.writeFileSync(file+'.tmp',JSON.stringify(value,null,2)+'\n');fs.renameSync(file+'.tmp',file);};
async function deploy(name,args){
 const a=artifacts(name);
 let prior=state.transactions.find(t=>t.name===name);
 if(fork&&prior){
  const existing=await client.request({method:'eth_getTransactionByHash',params:[prior.hash]});
  if(!existing){state.transactions=state.transactions.filter(t=>t!==prior);prior=undefined;}
 }
 const request={abi:a.abi,bytecode:a.bytecode.object,args,account};
 const data=encodeDeployData(request),inputHash=keccak256(data);
 let tx=prior?.hash;
 if(prior)assert.equal(prior.inputHash,inputHash,'Deployment inputs changed; inspect prior checkpoint.');
 if(!tx){
  const gas=await client.estimateGas({account:address,data});
  const limit=gas+gas/5n,fees=await client.estimateFeesPerGas();
  if(!fork){
   assert(feeTotal+limit*fees.maxFeePerGas<=budget,'Remaining deployment would exceed the ETH fee limit.');
   assert(await client.getBalance({address})>=limit*fees.maxFeePerGas,'Fund the Ethereum Sepolia test wallet.');
  }
  tx=await wallet.deployContract({...request,gas:limit,...fees});
  state.transactions.push({name,hash:tx,inputHash});write(checkpoint,state);
 }
 const receipt=await client.waitForTransactionReceipt({hash:tx,confirmations:fork?1:2});
 assert(receipt.status==='success'&&receipt.contractAddress,'Deployment failed for '+name);
 assert((await client.getCode({address:receipt.contractAddress}))?.length>2,'No deployed contract code for '+name);
 gasTotal+=receipt.gasUsed;feeTotal+=receipt.gasUsed*receipt.effectiveGasPrice;
 console.log(name,receipt.contractAddress,'gas',String(receipt.gasUsed));
 return receipt.contractAddress;
}
const identityRegistry=await deploy('IdentityRegistry',[canonical.worldRouter,appId,action,false]);
const ensGateFactory=await deploy('ENSDomainGateFactory',[[...anchors,...hashes,false]]);
const settlement=await deploy('LaunchSettlementVault',[canonical.strategy]);
const factory=await deploy('LaunchpadFactory',[canonical.strategy,identityRegistry,ensGateFactory,settlement]);
const wrapperFactory=await client.readContract({abi:artifacts('LaunchpadFactory').abi,address:factory,functionName:'wrapperFactory'});
const first=await client.getTransactionReceipt({hash:state.transactions[0].hash});
write(output,{chainId:11155111,deploymentBlock:Number(first.blockNumber),factory,identityRegistry,ensGateFactory,wrapperFactory,poolManager:canonical.poolManager,positionManager:canonical.positionManager,localTestOnly:false,world:{appId,action,environment:'staging'},...(fork?{forkOnly:true}:{}),transactions:state.transactions.map(({name,hash})=>({name,hash}))});
console.log(fork?'Local Sepolia fork complete':'Public Sepolia deployment complete','gas',String(gasTotal),'ETH fees',formatEther(feeTotal));
