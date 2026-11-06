import fs from 'node:fs';
import {createHash} from 'node:crypto';
import {createPublicClient,createWalletClient,encodeDeployData,getCreate2Address,http,keccak256,toHex,zeroAddress} from 'viem';
import {foundry} from 'viem/chains';

const transport=http('http://127.0.0.1:8547',{retryCount:0});
const client=createPublicClient({chain:foundry,transport,pollingInterval:100});
const rpc=(method,params=[])=>client.request({method,params});
if(await client.getChainId()!==31337||!(await rpc('web3_clientVersion')).toLowerCase().includes('anvil'))throw new Error('Start the private local Anvil chain on port 8547.');
const accounts=await rpc('eth_accounts');
if(accounts.length<4)throw new Error('Four local test accounts are needed.');
const wallet=createWalletClient({chain:foundry,transport,account:accounts[0]});
const file='.local-chain/public-deployment.json';
const fingerprint=createHash('sha256');
for(const name of ['LaunchpadFactory','LaunchSettlementVault','IdentityRegistry','ENSDomainGateFactory','LBPStrategy','ContinuousClearingAuctionFactory','PoolManager','PositionManager'])fingerprint.update(artifact(name).bytecode.object);
const buildId=fingerprint.digest('hex');
if(fs.existsSync(file)){
 const old=JSON.parse(fs.readFileSync(file,'utf8'));
 if(!process.argv.includes('--fresh') && old.buildId===buildId && (await client.getCode({address:old.factory}))?.length>2){console.log('Existing local deployment is ready.');process.exit(0);}
 if(/^0x[0-9a-f]{40}$/i.test(old.factory))fs.copyFileSync(file,'.local-chain/deployment-'+old.factory+'.json');
}
function artifact(name,file=name){
 return JSON.parse(fs.readFileSync('contracts/out/'+file+'.sol/'+name+'.json','utf8'));
}
async function confirm(hash){
 const receipt=await client.waitForTransactionReceipt({hash});
 if(receipt.status!=='success')throw new Error('Local transaction failed: '+hash);
 return receipt;
}
async function deploy(name,args=[],file=name){
 const a=artifact(name,file);
 const receipt=await confirm(await wallet.deployContract({abi:a.abi,bytecode:a.bytecode.object,args}));
 if(!receipt.contractAddress)throw new Error('No address for '+name);
 return receipt.contractAddress;
}
async function write(address,name,fn,args,file=name){
 await confirm(await wallet.writeContract({address,abi:artifact(name,file).abi,functionName:fn,args}));
}
const read=(address,name,fn,args=[])=>client.readContract({address,abi:artifact(name).abi,functionName:fn,args});
const deploymentBlock=Number(await client.getBlockNumber());
const fees=await deploy('ZeroFeeController');
const poolManager=await deploy('PoolManager',[accounts[0]]);
const positionManager=await deploy('PositionManager',[poolManager,zeroAddress,100000n,zeroAddress,zeroAddress]);
const auctionFactory=await deploy('ContinuousClearingAuctionFactory',[fees]);
const deployer=await deploy('LaunchCreate2Deployer');
const lbp=artifact('LBPStrategy');
const init=encodeDeployData({abi:lbp.abi,bytecode:lbp.bytecode.object,args:[positionManager,poolManager,auctionFactory]});
const bytecodeHash=keccak256(init);
let strategy;
for(let i=0;i<1_000_000;i++){
 const salt=toHex(i,{size:32});
 const address=getCreate2Address({from:deployer,salt,bytecodeHash});
 if((parseInt(address.slice(-4),16)&0x3fff)===0x2000){
  await write(deployer,'LaunchCreate2Deployer','deploy',[salt,init]);strategy=address;break;
 }
}
if(!strategy||!(await client.getCode({address:strategy})))throw new Error('Strategy was not deployed.');
const router=await deploy('LocalWorldIDFixture');
const identityRegistry=await deploy('IdentityRegistry',[router,'app_launchpad_test','join-launchpad',true]);
const externalNullifier=await read(identityRegistry,'IdentityRegistry','externalNullifierHash');
const syntheticProofs={},seededNames={};
for(const index of [0,1,2]){
 const address=accounts[index], root=1n,nullifier=index===0?111n:222n;
 const proof=Array.from({length:8},(_,i)=>BigInt(i+1+index*8));
 const signal=await read(identityRegistry,'IdentityRegistry','expectedSignalHash',[address]);
 await write(router,'LocalWorldIDFixture','allowFixture',[root,signal,nullifier,externalNullifier,proof]);
 syntheticProofs[address.toLowerCase()]={root:String(root),nullifierHash:String(nullifier),proof:proof.map(String)};
}
const ensFile='LocalENSFixtures';
const fixture=(name)=>deploy(name,[],ensFile);
const root=await fixture('LocalENSRegistryFixture'), eth=await fixture('LocalENSRegistryFixture'), community=await fixture('LocalENSRegistryFixture');
const provenance=await fixture('LocalENSFactoryFixture'), implementation=await fixture('LocalENSImplementationFixture');
await write(provenance,'LocalENSFactoryFixture','setImplementation',[community,implementation],ensFile);
const expiry=(1n<<64n)-1n;
const setName=(registry,label,owner,child)=>write(registry,'LocalENSRegistryFixture','setName',[label,owner,expiry,child],ensFile);
await setName(root,'eth',accounts[0],eth);
await setName(eth,'community',accounts[0],community);
for(const [i,label] of ['creator','alice','alice-alt'].entries()){
 await setName(community,label,accounts[i],zeroAddress);seededNames[accounts[i].toLowerCase()]=[label+'.community.eth'];
}
const anchors=[root,eth,provenance,implementation];
const hashes=await Promise.all(anchors.map(async address=>keccak256(await client.getCode({address}))));
const ensGateFactory=await deploy('ENSDomainGateFactory',[[...anchors,...hashes,true]]);
const settlement=await deploy('LaunchSettlementVault',[strategy]);
const factory=await deploy('LaunchpadFactory',[strategy,identityRegistry,ensGateFactory,settlement]);
const wrapperFactory=await read(factory,'LaunchpadFactory','wrapperFactory');
const labels=['Creator','Community member','Linked member wallet','Open bidder'];
const config={buildId,chainId:31337,deploymentBlock,factory,identityRegistry,ensGateFactory,poolManager,positionManager,wrapperFactory,localTestOnly:true,accounts:labels.map((label,i)=>({label,address:accounts[i]})),syntheticProofs,seededNames};
fs.mkdirSync('.local-chain',{recursive:true});
fs.writeFileSync(file+'.tmp',JSON.stringify(config,null,2)+'\n');fs.renameSync(file+'.tmp',file);
console.log('Local launchpad deployed at '+factory+' with four test accounts.');
