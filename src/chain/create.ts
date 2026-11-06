import { bytesToHex, concatHex, encodeAbiParameters, keccak256, namehash, toHex, type Address, type Hex } from 'viem';
import type { LaunchDraft } from '../types';
import { launchMetadataUri, validateDraft } from '../ui/draft';
import { decimal, floorPrice } from './amounts';
import { Engine, same, zeroAddress, type ActionContext } from './engine';
import { parentLabels } from './ens';

async function hookSalt(engine: Engine, ctx: ActionContext, userSalt: Hex) {
  const factory = ctx.deployment.factory;
  const initHash = await engine.read<Hex>(ctx, 'LaunchpadFactory', factory, 'settlementInitCodeHash');
  const prefix = encodeAbiParameters([{ type: 'address' }, { type: 'bytes32' }], [ctx.account, userSalt]);
  for (let batch = 0; batch < 1024; batch++) {
    engine.check(ctx);
    for (let i = 0; i < 512; i++) {
      const salt = toHex(batch * 512 + i, { size: 32 });
      const derived = keccak256(concatHex([prefix, salt]));
      const addressHash = keccak256(concatHex(['0xff', factory, derived, initHash]));
      if ((parseInt(addressHash.slice(-4), 16) & 0x3fff) === 0x2000) return salt;
    }
    await new Promise(resolve => setTimeout(resolve, 0));
  }
  throw new Error('Could not prepare the pool address. Please try creating this launch again.');
}

export async function createLaunch(engine: Engine, draft: LaunchDraft) {
  const errors = Object.values(validateDraft(draft));
  if (errors.length) throw new Error(errors[0]);
  const ctx = await engine.action();
  if (!same(draft.quoteAsset, zeroAddress)) throw new Error('Only native ETH is supported.');
  if (draft.provider !== 'world-id' && draft.provider !== 'none') throw new Error('This identity provider is unavailable.');
  const totalSupply = decimal(draft.totalSupply);
  const reserveForLiquidity = totalSupply - totalSupply * BigInt(draft.saleBps) / 10000n;
  const requiredCurrencyRaised = decimal(draft.minimumRaise, 'Minimum raise');
  const floorPriceQ96 = floorPrice(draft.floorPrice);
  const metadataURI = launchMetadataUri(draft);
  if (metadataURI.length > 2048) throw new Error('Shorten the description or phase names.');
  const userSalt = bytesToHex(crypto.getRandomValues(new Uint8Array(32)));
  const poolHookSalt = await hookSalt(engine, ctx, userSalt);
  let gate: Address = zeroAddress;
  if (draft.phases.some(p => p.requireEns)) {
    const factory = ctx.deployment.ensGateFactory;
    const labels = parentLabels(draft.ensDomain);
    const node = namehash(draft.ensDomain.trim().toLowerCase());
    const lookup = () => engine.read<Address>(ctx, 'ENSDomainGateFactory', factory, 'gateForParent', [node]);
    gate = await lookup();
    if (same(gate, zeroAddress)) {
      await engine.write(ctx, 'ENSDomainGateFactory', factory, 'create', [labels], 'Create ENS eligibility gate');
      gate = await lookup();
      if (same(gate, zeroAddress)) throw new Error('The ENS gate was not found after creation.');
    }
  }
  let start = await engine.client(ctx).getBlockNumber({ cacheTime: 0 }) + BigInt(draft.startDelayBlocks);
  const phases = draft.phases.map(p => {
    const startBlock = start;
    start += BigInt(p.durationBlocks);
    return {
      startBlock, endBlock: start, minimumBid: decimal(p.minimumBid),
      baseCapStart: decimal(p.baseCapStart, 'Base cap', true), baseCapEnd: decimal(p.baseCapEnd, 'Base cap', true),
      verifiedCapStart: decimal(p.verifiedCapStart, 'Verified cap', true), verifiedCapEnd: decimal(p.verifiedCapEnd, 'Verified cap', true),
      verifiedOnly: p.requireVerified, ensGate: p.requireEns ? gate : zeroAddress,
    };
  });
  const config = {
    name: draft.name.trim(), symbol: draft.symbol.trim(), metadataURI, totalSupply, reserveForLiquidity,
    floorPriceQ96, priceTickSpacing: 2n, requiredCurrencyRaised, poolFee: 3000, poolTickSpacing: 60,
    liquidityAllocationMps: 5_000_000, treasury: ctx.account, identityEnabled: draft.provider === 'world-id',
    phases, lockOptions: draft.locks.map(l => ({ durationSeconds: BigInt(l.durationDays) * 86400n, multiplierBps: l.multiplierBps })),
    userSalt, poolHookSalt,
  };
  const factory = ctx.deployment.factory;
  const result = await engine.write(ctx, 'LaunchpadFactory', factory, 'createLaunch', [config], 'Create launch');
  const id = await engine.read<bigint>(ctx, 'LaunchpadFactory', factory, 'launchForSalt', [ctx.account, userSalt]);
  if (id === 0n) throw new Error('The transaction was mined but its launch ID could not be read.');
  return { ...result, launchId: id.toString() };
}
