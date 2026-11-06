import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('..',import.meta.url));
const names=['LaunchpadFactory','LaunchSettlementVault','PhaseCapHook','BidLockFactory','BidLock','LaunchToken','IdentityRegistry','ENSDomainGateFactory','ENSDomainGate','LocalWorldIDFixture','ContinuousClearingAuction','ContinuousClearingAuctionFactory','LBPStrategy','PoolManager','PositionManager'];
const abis={};
for(const name of names){
 const file=path.join(root,'contracts','out',name+'.sol',name+'.json');
 if(!fs.existsSync(file))continue;
 const artifact=JSON.parse(fs.readFileSync(file,'utf8'));
 if(!Array.isArray(artifact.abi))throw new Error('Missing ABI for '+name);
 abis[name]=artifact.abi;
}
if(!Object.keys(abis).length)throw new Error('Compile contracts before exporting ABIs.');
const target=path.join(root,'src','generated');fs.mkdirSync(target,{recursive:true});
fs.writeFileSync(path.join(target,'contract-abis.json'),JSON.stringify(abis,null,2)+'\n');
console.log(JSON.stringify({exported:Object.keys(abis),containsPrivateData:false}));
