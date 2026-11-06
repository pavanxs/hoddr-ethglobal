import {createLaunchpadClient} from '../src/chain/client';
import {makeDefaultDraft} from '../src/ui/draft';

const origin = 'http://127.0.0.1:5192';
const originalFetch = globalThis.fetch;
globalThis.fetch = ((input, init) => {
  const url = typeof input === 'string' && input.startsWith('/') ? origin + input : input;
  const headers = new Headers(init?.headers || (input instanceof Request ? input.headers : undefined));
  headers.set('origin', origin);
  return originalFetch(url, {...init, headers});
}) as typeof fetch;
const app = createLaunchpadClient();
const config = (await (await fetch('/api/runtime')).json()).deployments.local;
if (config?.chainId !== 31337 || !config.localTestOnly) throw new Error('Local demo chain required.');
await app.selectAccount(config.accounts[0].address);
const state = await app.getSnapshot();
const name = 'HODDR Community Launch';
const existing = state.launches.find(launch => launch.name === name);
if (existing) {
  console.log('Local example already exists: ' + origin + '/#/launch/' + existing.id);
} else {
  const draft = makeDefaultDraft();
  Object.assign(draft, {name, symbol:'HODR', description:'A local community token sale. Community members bid first, then bidding opens to everyone.',totalSupply:'1000',saleBps:8000,liquidityBps:2000,minimumRaise:'0.05',floorPrice:'0.001',ensDomain:'community.eth',startDelayBlocks:5});
  draft.phases[0].durationBlocks=32;
  draft.phases[1].durationBlocks=48;
  const tx=await app.createLaunch(draft);
  const launch=(await app.getSnapshot()).launches.find(l=>l.id===tx.launchId)!;
  const current=(await app.getSnapshot()).network.blockNumber;
  if (current<launch.startBlock) await app.advanceBlocks(launch.startBlock-current);
  console.log('Local example open: '+origin+'/#/launch/'+tx.launchId);
}
