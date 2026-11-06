import { spawn } from 'node:child_process';
import net from 'node:net';
import { createRequire } from 'node:module';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('..', import.meta.url));
const require = createRequire(import.meta.url);
const children = new Set();
let stopping = false;
function stop(code) {
  if (stopping) return;
  stopping = true;
  for (const child of children) child.kill();
  process.exitCode = code;
}
process.on('SIGINT', () => stop(0));
process.on('SIGTERM', () => stop(0));
function run(binary, args, persistent = false) {
  const child = spawn(binary, args, {cwd: root, stdio: 'inherit', windowsHide: true});
  children.add(child);
  const complete = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', code => {
      children.delete(child);
      if (stopping || code === 0) resolve();
      else reject(new Error('Local process exited with code ' + code));
    });
  });
  if (persistent) complete.then(() => stop(0), error => {console.error(error.message); stop(1);});
  return complete;
}
const available = port => new Promise(resolve => {
  const server = net.createServer();
  server.once('error', () => resolve(false));
  server.listen(port, '127.0.0.1', () => server.close(() => resolve(true)));
});
try {
  const binary = path.join(root, '.tools/foundry', process.platform === 'win32' ? 'anvil.exe' : 'anvil');
  if (!existsSync(binary) || !existsSync(path.join(root, 'contracts/out/LaunchpadFactory.sol/LaunchpadFactory.json'))) {
    throw new Error('Build the pinned contracts first. See the setup steps in README.md.');
  }
  for (const port of [8547,5193,5192]) {
    if (!await available(port)) throw new Error('Port ' + port + ' is already in use. If the launchpad is running, open http://127.0.0.1:5192.');
  }
  run(binary, ['--host','127.0.0.1','--port','8547','--chain-id','31337','--hardfork','cancun','--silent'], true);
  let online = false;
  for (let i=0; i<50 && !stopping; i++) {
    try {
      const result = await fetch('http://127.0.0.1:8547',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'eth_chainId',params:[]})});
      if ((await result.json()).result === '0x7a69') { online = true; break; }
    } catch {}
    await new Promise(resolve => setTimeout(resolve,200));
  }
  if (!online) throw new Error('Local chain did not start.');
  await run(process.execPath,['scripts/deploy-local.mjs']);
  if (!stopping) {
    run(process.execPath,['scripts/local-api.mjs'],true);
    run(process.execPath,[path.join(path.dirname(require.resolve('vite/package.json')),'bin/vite.js'),'--configLoader','runner'],true);
  }
} catch (error) { console.error(error.message); stop(1); }
