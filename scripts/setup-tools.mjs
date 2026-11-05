import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';

const root=fileURLToPath(new URL('..',import.meta.url));
const directory=path.join(root,'.tools');
const lock=JSON.parse(fs.readFileSync(path.join(root,'toolchain.lock.json'),'utf8'));
if(process.platform!=='win32'||process.arch!=='x64')throw new Error('This installer targets Windows x64. Use Foundry 1.9.0 and solc 0.8.26 on other platforms.');
if(!fs.existsSync(path.join(root,'contracts','foundry.toml')))throw new Error('Missing isolated Foundry configuration.');
fs.mkdirSync(directory,{recursive:true});
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
async function fileHash(file){const hash=crypto.createHash('sha256');for await(const chunk of fs.createReadStream(file))hash.update(chunk);return hash.digest('hex');}
const readyFile=path.join(directory,'toolchain-ready.json');
if(fs.existsSync(readyFile)){
 const previous=JSON.parse(fs.readFileSync(readyFile,'utf8'));
 if(previous.archiveSha256===lock.foundry.sha256&&previous.solcSha256===lock.solc.sha256&&previous.files){
  let valid=true;
  for(const [relative,expected] of Object.entries(previous.files)){
   const file=path.join(directory,relative);
   if(!fs.existsSync(file)||await fileHash(file)!==expected){valid=false;break;}
  }
  if(valid&&Object.keys(previous.files).length===3){console.log(JSON.stringify({toolchainReady:true,cached:true,versions:previous.versions}));process.exit(0);}
 }
}
async function download(item,limit){
 console.log('Downloading verified tool: '+new URL(item.url).pathname.split('/').pop());
 const response=await fetch(item.url,{headers:{'User-Agent':'HoddrLaunchpad/0.1'},signal:AbortSignal.timeout(240_000)});
 if(!response.ok||!response.body)throw new Error('Tool download failed: HTTP '+response.status);
 if(Number(response.headers.get('content-length')||0)>limit)throw new Error('Tool archive exceeds size bound.');
 const chunks=[];let count=0;
 for await(const chunk of response.body){count+=chunk.length;if(count>limit)throw new Error('Tool archive exceeds size bound.');chunks.push(chunk);}
 const bytes=Buffer.concat(chunks);
 if(sha(bytes)!==item.sha256)throw new Error('Official tool checksum mismatch.');
 return bytes;
}
const solc=path.join(directory,'solc-0.8.26.exe');
if(!fs.existsSync(solc)){
 const bytes=await download(lock.solc,40_000_000);
 fs.writeFileSync(solc,bytes,{flag:'wx'});
}else if(await fileHash(solc)!==lock.solc.sha256)throw new Error('Existing solc checksum mismatch.');
// Use an in-memory, checksummed archive so installation does not require an extra
// 120 MB disk copy. Parse only ordinary ZIP entries with bounded sizes and CRC checks.
const legacyArchive=path.join(directory,'foundry-v1.9.0-win32-amd64.zip');
let archive;
if(fs.existsSync(legacyArchive)){
 archive=fs.readFileSync(legacyArchive);
 if(sha(archive)!==lock.foundry.sha256)throw new Error('Existing Foundry archive checksum mismatch.');
 fs.unlinkSync(legacyArchive);
}else archive=await download(lock.foundry,150_000_000);
const crcTable=Array.from({length:256},(_,n)=>{for(let k=0;k<8;k++)n=(n&1)?0xedb88320^(n>>>1):n>>>1;return n>>>0;});
function crc32(bytes){let crc=0xffffffff;for(const byte of bytes)crc=crcTable[(crc^byte)&255]^(crc>>>8);return(crc^0xffffffff)>>>0;}
let end=-1;
for(let i=archive.length-22;i>=Math.max(0,archive.length-65557);i--)if(archive.readUInt32LE(i)===0x06054b50){end=i;break;}
if(end<0||archive.readUInt16LE(end+4)!==0||archive.readUInt16LE(end+6)!==0)throw new Error('Unsupported ZIP archive.');
const count=archive.readUInt16LE(end+10),centralSize=archive.readUInt32LE(end+12);
let offset=archive.readUInt32LE(end+16);
if(count!==5||offset+centralSize>end)throw new Error('Unexpected Foundry archive structure.');
const allowed=new Set(['anvil.exe','cast.exe','chisel.exe','forge.exe','solar.exe']);
const wanted=new Set(['anvil.exe','forge.exe']);
const extracted={};
const foundry=path.join(directory,'foundry');fs.mkdirSync(foundry,{recursive:true});
for(let index=0;index<count;index++){
 if(archive.readUInt32LE(offset)!==0x02014b50)throw new Error('Invalid ZIP central directory.');
 const flags=archive.readUInt16LE(offset+8),method=archive.readUInt16LE(offset+10),crc=archive.readUInt32LE(offset+16);
 const compressedSize=archive.readUInt32LE(offset+20),size=archive.readUInt32LE(offset+24);
 const nameLength=archive.readUInt16LE(offset+28),extraLength=archive.readUInt16LE(offset+30),commentLength=archive.readUInt16LE(offset+32);
 const localOffset=archive.readUInt32LE(offset+42);
 const name=archive.subarray(offset+46,offset+46+nameLength).toString('utf8').replace(/^\.\//,'');
 offset+=46+nameLength+extraLength+commentLength;
 if(!allowed.delete(name)||flags&1||![0,8].includes(method)||size>150_000_000)throw new Error('Unexpected or unsafe tool archive entry.');
 if(!wanted.has(name))continue;
 if(archive.readUInt32LE(localOffset)!==0x04034b50)throw new Error('Invalid ZIP entry header.');
 const start=localOffset+30+archive.readUInt16LE(localOffset+26)+archive.readUInt16LE(localOffset+28);
 if(start+compressedSize>archive.length)throw new Error('ZIP entry exceeds archive.');
 const input=archive.subarray(start,start+compressedSize);
 const bytes=method===8?zlib.inflateRawSync(input,{maxOutputLength:size}):input;
 if(bytes.length!==size||crc32(bytes)!==crc)throw new Error('Tool entry size or CRC mismatch.');
 const file=path.join(foundry,name),hash=sha(bytes);
 if(!fs.existsSync(file)||await fileHash(file)!==hash){
  const temporary=file+'.partial';fs.writeFileSync(temporary,bytes);
  await fsp.rename(temporary,file);
  try{execFileSync('compact.exe',['/C','/EXE:LZX','/I',file],{windowsHide:true,stdio:'ignore'});}catch{}
 }
 extracted['foundry/'+name]=hash;
}
if(Object.keys(extracted).length!==2||allowed.size!==0)throw new Error('Required tools missing from verified archive.');
const env={};
for(const key of ['PATH','Path','SystemRoot','SYSTEMROOT','WINDIR','COMSPEC','PATHEXT','NUMBER_OF_PROCESSORS'])if(process.env[key])env[key]=process.env[key];
const temporary=path.join(directory,'tmp');fs.mkdirSync(temporary,{recursive:true});env.TEMP=temporary;env.TMP=temporary;
const versions={};
for(const name of ['forge','anvil'])versions[name]=execFileSync(path.join(foundry,name+'.exe'),['--version'],{cwd:path.join(root,'contracts'),env,encoding:'utf8',windowsHide:true}).trim();
versions.solc=execFileSync(solc,['--version'],{env,encoding:'utf8',windowsHide:true}).trim();
const result={verifiedAt:new Date().toISOString(),archiveSha256:lock.foundry.sha256,solcSha256:lock.solc.sha256,files:{...extracted,'solc-0.8.26.exe':lock.solc.sha256},versions};
fs.writeFileSync(readyFile,JSON.stringify(result,null,2)+'\n');
console.log(JSON.stringify({toolchainReady:true,versions}));
