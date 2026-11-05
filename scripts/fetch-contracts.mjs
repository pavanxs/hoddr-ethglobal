import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
const root=fileURLToPath(new URL('..',import.meta.url));
const manifest=JSON.parse(fs.readFileSync(path.join(root,'contracts.sources.json'),'utf8'));
const lib=path.join(root,'contracts','lib'),cache=path.join(root,'.tools','source-cache'),stageRoot=path.join(root,'.tools','source-stage');
for(const p of [lib,cache,stageRoot])fs.mkdirSync(p,{recursive:true});
const digest=b=>crypto.createHash('sha256').update(b).digest('hex');
const lockFile=path.join(root,'contracts.sources.lock.json');
const old=fs.existsSync(lockFile)?JSON.parse(fs.readFileSync(lockFile,'utf8')):{dependencies:[]};
const resolved=[];
async function fetchOne(dep){
 if(!/^[a-z0-9-]+$/.test(dep.name)||!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(dep.repository)||!/^[a-f0-9]{40}$/.test(dep.commit))throw new Error('Invalid pinned source entry');
 const dest=path.join(lib,dep.name),archive=path.join(cache,dep.name+'-'+dep.commit+'.tar.gz');
 let bytes;
 if(fs.existsSync(archive))bytes=fs.readFileSync(archive);
 else{
  const response=await fetch('https://codeload.github.com/'+dep.repository+'/tar.gz/'+dep.commit,{headers:{'User-Agent':'HoddrLaunchpad/0.1'},signal:AbortSignal.timeout(90000)});
  if(!response.ok)throw new Error(dep.name+' source HTTP '+response.status);
  bytes=Buffer.from(await response.arrayBuffer());
  if(bytes.length>80000000)throw new Error('Source archive too large');
  fs.writeFileSync(archive,bytes,{flag:'wx'});
 }
 const sha256=digest(bytes),prior=old.dependencies.find(x=>x.name===dep.name&&x.commit===dep.commit);
 if(prior&&prior.sha256!==sha256)throw new Error(dep.name+' archive differs from source lock');
 const entry={...dep,sha256};
 if(fs.existsSync(dest)){
  const marker=path.join(dest,'.hoddr-source.json');
  if(!fs.existsSync(marker)||JSON.parse(fs.readFileSync(marker,'utf8')).sha256!==sha256)throw new Error('Existing source directory needs review: '+dep.name);
  resolved.push(entry);fs.unlinkSync(archive);return;
 }
 const names=execFileSync('tar.exe',['-tf',archive],{encoding:'utf8',windowsHide:true,maxBuffer:12000000}).split(/\r?\n/).filter(Boolean);
 if(!names.length||names.some(n=>/^[\\/]|^[A-Za-z]:/.test(n)||n.replaceAll('\\','/').split('/').includes('..')))throw new Error('Unsafe source archive path');
 const tops=new Set(names.map(n=>n.split('/')[0]));if(tops.size!==1)throw new Error('Unexpected source archive roots');
 const staged=path.join(stageRoot,dep.name);
 if(fs.existsSync(staged))fs.rmSync(staged,{recursive:true,force:true});
 fs.mkdirSync(staged);
 execFileSync('tar.exe',['-xzf',archive,'--strip-components','1','-C',staged],{windowsHide:true,stdio:['ignore','pipe','pipe'],maxBuffer:8000000});
 fs.writeFileSync(path.join(staged,'.hoddr-source.json'),JSON.stringify(entry,null,2)+'\n',{flag:'wx'});
 await fsp.rename(staged,dest);
 fs.unlinkSync(archive);
 resolved.push(entry);
 console.log(JSON.stringify({source:dep.name,commit:dep.commit,sha256}));
}
let index=0;
await Promise.all([0,1,2].map(async()=>{for(;;){const dep=manifest.dependencies[index++];if(!dep)return;await fetchOne(dep);}}));
resolved.sort((a,b)=>a.name.localeCompare(b.name));
fs.writeFileSync(lockFile,JSON.stringify({version:1,dependencies:resolved},null,2)+'\n');
console.log(JSON.stringify({sourcesReady:true,count:resolved.length}));
