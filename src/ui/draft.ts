import type { Address, LaunchDraft, PhaseDraft } from '../types';

export const blankAsset = '0x0000000000000000000000000000000000000000' as Address;
export function makeDefaultDraft(quoteAsset: Address = blankAsset): LaunchDraft {
  return {
    name: '', symbol: '', description: '', totalSupply: '1000000', saleBps: 7000, liquidityBps: 3000,
    floorPrice: '0.0001', minimumRaise: '1', startDelayBlocks: 30, quoteAsset, provider: 'world-id', ensDomain: '',
    phases: [
      { id: 'community', name: 'Community', durationBlocks: 100, minimumBid: '0.01', baseCapStart: '0', baseCapEnd: '0', verifiedCapStart: '0.5', verifiedCapEnd: '2', requireVerified: true, requireEns: true },
      { id: 'open', name: 'Open launch', durationBlocks: 150, minimumBid: '0.01', baseCapStart: '0.05', baseCapEnd: '0.25', verifiedCapStart: '2', verifiedCapEnd: '5', requireVerified: false, requireEns: false },
    ],
    locks: [{ id: 'flexible', durationDays: 0, multiplierBps: 10000 }, { id: 'thirty', durationDays: 30, multiplierBps: 15000 }, { id: 'ninety', durationDays: 90, multiplierBps: 20000 }],
  };
}

/** Restore editable public form values without trusting the browser's stored object shape. */
export function restoreDraft(value: unknown, quoteAsset: Address): LaunchDraft | null {
  const object = (item: unknown): item is Record<string, unknown> => Boolean(item && typeof item === 'object' && !Array.isArray(item));
  const numeric = (item: unknown) => item === null || typeof item === 'number' && Number.isFinite(item);
  const number = (item: unknown) => item === null ? Number.NaN : item as number;
  if (!object(value)) return null;
  if (['name', 'symbol', 'description', 'totalSupply', 'floorPrice', 'minimumRaise', 'ensDomain'].some(key => typeof value[key] !== 'string')) return null;
  if (['saleBps', 'liquidityBps', 'startDelayBlocks'].some(key => !numeric(value[key]))) return null;
  if (!['none', 'world-id', 'zkpassport', 'ace'].includes(value.provider as string)) return null;
  if (!Array.isArray(value.phases) || !value.phases.length || value.phases.length > 16 || !Array.isArray(value.locks) || !value.locks.length || value.locks.length > 8) return null;
  if (value.phases.some(phase => !object(phase) || ['id', 'name', 'minimumBid', 'baseCapStart', 'baseCapEnd', 'verifiedCapStart', 'verifiedCapEnd'].some(key => typeof phase[key] !== 'string') || !numeric(phase.durationBlocks) || typeof phase.requireEns !== 'boolean' || typeof phase.requireVerified !== 'boolean')) return null;
  if (value.locks.some(lock => !object(lock) || typeof lock.id !== 'string' || !numeric(lock.durationDays) || !numeric(lock.multiplierBps))) return null;
  if (new Set(value.phases.map(phase => phase.id)).size !== value.phases.length || new Set(value.locks.map(lock => lock.id)).size !== value.locks.length) return null;
  const typed = value as unknown as LaunchDraft;
  return {
    name: typed.name, symbol: typed.symbol, description: typed.description, totalSupply: typed.totalSupply,
    floorPrice: typed.floorPrice, minimumRaise: typed.minimumRaise, quoteAsset, provider: typed.provider, ensDomain: typed.ensDomain,
    saleBps: number(value.saleBps), liquidityBps: 10000 - number(value.saleBps), startDelayBlocks: number(value.startDelayBlocks),
    phases: typed.phases.map(phase => ({ ...phase, durationBlocks: number(phase.durationBlocks) })),
    locks: typed.locks.map(lock => ({ ...lock, durationDays: number(lock.durationDays), multiplierBps: number(lock.multiplierBps) })),
  };
}

export function newPhase(index: number): PhaseDraft {
  return { id: crypto.randomUUID(), name: 'Phase ' + (index + 1), durationBlocks: 100, minimumBid: '0.01', baseCapStart: '0.1', baseCapEnd: '0.5', verifiedCapStart: '2', verifiedCapEnd: '5', requireVerified: false, requireEns: false };
}
export function toUnits(value: string, decimals = 18): bigint | null {
  const text = value.trim();
  if (!/^(?:\d+(?:\.\d*)?|\.\d+)$/.test(text)) return null;
  const [whole = '0', fraction = ''] = text.split('.');
  if (fraction.length > decimals || decimals < 0 || decimals > 36) return null;
  try { return BigInt(whole || '0') * 10n ** BigInt(decimals) + BigInt(fraction.padEnd(decimals, '0') || '0'); } catch { return null; }
}
export function nameError(value: string, parent?: string): string | undefined {
  const name = value.trim().toLowerCase();
  if (!name) return 'Enter an ENS name.';
  if (name !== value.trim()) return 'Use lowercase letters in this version.';
  const labels = name.split('.');
  if (labels.some(label => !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label))) return 'Use letters, numbers and internal hyphens only.';
  if (labels.some(label => label.length > 63)) return 'Each name label must be 63 characters or fewer.';
  if (name.length + 2 > 255) return 'The full name must fit within 255 DNS bytes.';
  if (parent) {
    const suffix = '.' + parent.trim().toLowerCase();
    if (!name.endsWith(suffix)) return 'Use a subname of ' + parent + '.';
    const descendants = name.slice(0, -suffix.length).split('.');
    if (descendants.length > 8) return 'Use at most 8 subname levels.';
  } else if (labels.length < 2) return 'Include the parent ending, such as community.eth.';
  return undefined;
}
export type DraftErrors = Record<string, string>;
export function launchMetadataUri(draft: LaunchDraft): string {
  const json = JSON.stringify({ description: draft.description, phaseNames: draft.phases.map(phase => phase.name) });
  const bytes = new TextEncoder().encode(json);
  return 'data:application/json;base64,' + btoa(Array.from(bytes, byte => String.fromCharCode(byte)).join(''));
}
export function validateDraft(draft: LaunchDraft, decimals = 18, maxPhases = 16, maxLocks = 8): DraftErrors {
  const errors: DraftErrors = {};
  const checkAmount = (key: string, value: string, positive: boolean, precision = decimals) => {
    const parsed = toUnits(value, precision);
    if (parsed === null) errors[key] = 'Use a decimal amount with at most ' + precision + ' decimal places.';
    else if (positive ? parsed <= 0n : parsed < 0n) errors[key] = positive ? 'Enter an amount greater than zero.' : 'Enter zero or a positive amount.';
    else if (parsed > (1n << 128n) - 1n) errors[key] = 'This amount is too large for the auction.';
    return parsed;
  };
  if (!draft.name.trim() || new TextEncoder().encode(draft.name.trim()).length > 64) errors.name = 'Enter a name that fits within 64 UTF-8 bytes.';
  if (!/^[A-Za-z0-9]{1,10}$/.test(draft.symbol)) errors.symbol = 'Use 1–10 letters or numbers.';
  if (draft.description.length > 280) errors.description = 'Keep the description to 280 characters.';
  const supply = checkAmount('totalSupply', draft.totalSupply, true, 18);
  checkAmount('floorPrice', draft.floorPrice, true);
  const minimumRaise = checkAmount('minimumRaise', draft.minimumRaise, true);
  if (minimumRaise !== null && minimumRaise < 2n * (1n << 32n)) errors.minimumRaise = 'Set the minimum raise to at least 0.000000008589934592 ETH to fund the liquidity pool.';
  if (!Number.isInteger(draft.saleBps) || draft.saleBps <= 0 || draft.saleBps > 10000) errors.saleBps = 'Set a sale share greater than 0% and at most 100%.';
  if (!Number.isInteger(draft.liquidityBps) || draft.liquidityBps <= 0 || draft.liquidityBps > 10000) errors.liquidityBps = 'Reserve a share for liquidity.';
  if (draft.saleBps + draft.liquidityBps !== 10000) errors.allocation = 'Auction and liquidity shares must add up to exactly 100%.';
  if (supply !== null && supply > 0n && Number.isInteger(draft.saleBps) && draft.saleBps > 0 && draft.saleBps < 10000) {
    const sale = supply * BigInt(draft.saleBps) / 10000n;
    if (sale === 0n) errors.totalSupply = 'Increase supply so the auction receives at least one token subunit.';
    if (sale > 0n && supply - sale < (1n << 32n)) errors.totalSupply = 'Increase the total supply or liquidity share to reserve at least 0.000000004294967296 tokens.';
    if (sale > (1n << 100n)) errors.totalSupply = 'Reduce the token supply or the auction share to fit the auction limit.';
  }
  if (!Number.isSafeInteger(draft.startDelayBlocks) || draft.startDelayBlocks < 3 || draft.startDelayBlocks > 10000000) errors.startDelayBlocks = 'Choose between 3 and 10,000,000 blocks.';
  if (!draft.phases.length || draft.phases.length > maxPhases) errors.phases = 'Use between 1 and ' + maxPhases + ' phases.';
  else if (draft.phases.reduce((sum, phase) => sum + phase.durationBlocks, 0) > 10_000_000) errors.phases = 'All phases together must fit within 10,000,000 blocks.';
  if (launchMetadataUri(draft).length > 2048) errors.description = 'Shorten the description or phase names to fit the onchain size limit.';
  if (draft.ensDomain) { const error = nameError(draft.ensDomain); if (error) errors.ensDomain = error; }
  for (const phase of draft.phases) {
    const key = 'phase.' + phase.id + '.';
    if (!phase.name.trim() || phase.name.length > 40) errors[key + 'name'] = 'Use a phase name of 1–40 characters.';
    if (!Number.isSafeInteger(phase.durationBlocks) || phase.durationBlocks < 2 || phase.durationBlocks > 10000000) errors[key + 'durationBlocks'] = 'Choose between 2 and 10,000,000 blocks.';
    const min = checkAmount(key + 'minimumBid', phase.minimumBid, true);
    const baseStart = checkAmount(key + 'baseCapStart', phase.baseCapStart, false);
    const baseEnd = checkAmount(key + 'baseCapEnd', phase.baseCapEnd, false);
    const verifiedStart = checkAmount(key + 'verifiedCapStart', phase.verifiedCapStart, false);
    const verifiedEnd = checkAmount(key + 'verifiedCapEnd', phase.verifiedCapEnd, false);
    if (baseStart !== null && baseEnd !== null && baseEnd < baseStart) errors[key + 'baseCapEnd'] = 'The ending limit must be at least the starting limit.';
    if (verifiedStart !== null && verifiedEnd !== null && verifiedEnd < verifiedStart) errors[key + 'verifiedCapEnd'] = 'The ending limit must be at least the starting limit.';
    if (baseStart !== null && verifiedStart !== null && verifiedStart < baseStart) errors[key + 'verifiedCapStart'] = 'The verified limit cannot be lower than the base limit.';
    if (baseEnd !== null && verifiedEnd !== null && verifiedEnd < baseEnd) errors[key + 'verifiedCapEnd'] = 'The verified limit cannot be lower than the base limit.';
    if (phase.requireVerified && draft.provider === 'none') errors[key + 'requireVerified'] = 'Enable a verification provider or open this phase.';
    if (phase.requireEns && !draft.ensDomain) errors.ensDomain = 'Choose the parent domain required by this phase.';
    const highest = draft.provider === 'none' ? baseEnd : verifiedEnd;
    if (highest !== null && min !== null && highest < min) errors[key + 'minimumBid'] = 'The minimum bid is above this phase’s largest limit.';
  }
  if (!draft.locks.length || draft.locks.length > maxLocks) errors.locks = 'Use between 1 and ' + maxLocks + ' lock options.';
  const seenDurations = new Set<number>();
  if (draft.locks[0]?.durationDays !== 0 || draft.locks[0]?.multiplierBps !== 10000) errors.locks = 'The first option must be flexible with a 1× limit.';
  for (const [index, lock] of draft.locks.entries()) {
    const key = 'lock.' + lock.id + '.';
    if (!Number.isInteger(lock.durationDays) || lock.durationDays < 0 || lock.durationDays > 3650) errors[key + 'durationDays'] = 'Use a whole number between 0 and 3,650 days.';
    if (seenDurations.has(lock.durationDays)) errors[key + 'durationDays'] = 'Each lock option needs a different duration.';
    seenDurations.add(lock.durationDays);
    if (index > 0 && lock.durationDays <= draft.locks[index - 1].durationDays) errors[key + 'durationDays'] = 'Each duration must be longer than the previous option.';
    if (index > 0 && lock.multiplierBps < draft.locks[index - 1].multiplierBps) errors[key + 'multiplierBps'] = 'Longer commitments cannot use a lower multiplier.';
    if (!Number.isInteger(lock.multiplierBps) || lock.multiplierBps < 10000 || lock.multiplierBps > 100000) errors[key + 'multiplierBps'] = 'Choose a multiplier between 1× and 10×.';
    if (lock.durationDays === 0 && lock.multiplierBps !== 10000) errors[key + 'multiplierBps'] = 'Flexible claims use the base 1× limit.';
  }
  return errors;
}
export function errorsForStep(errors: DraftErrors, step: number): DraftErrors {
  const test = [
    (key: string) => ['name', 'symbol', 'description', 'totalSupply', 'saleBps', 'liquidityBps', 'allocation', 'floorPrice', 'minimumRaise', 'startDelayBlocks'].includes(key),
    (key: string) => key === 'phases' || key.startsWith('phase.') && !key.endsWith('requireVerified'),
    (key: string) => key === 'provider' || key === 'ensDomain' || key === 'locks' || key.startsWith('lock.') || key.endsWith('requireVerified'),
    () => true,
  ][step];
  return Object.fromEntries(Object.entries(errors).filter(([key]) => test(key)));
}
export function draftStepForError(key: string) {
  if (key.startsWith('phase.') || key === 'phases') return key.endsWith('requireVerified') ? 2 : 1;
  if (key.startsWith('lock.') || key === 'locks' || key === 'ensDomain' || key === 'provider') return 2;
  return 0;
}
