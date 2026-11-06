import { describe, expect, test } from 'bun:test';
import { renderToStaticMarkup } from 'react-dom/server';
import { CapChart } from '../src/components/Common';
import { blankAsset, draftStepForError, errorsForStep, launchMetadataUri, makeDefaultDraft, nameError, restoreDraft, toUnits, validateDraft } from '../src/ui/draft';
import { errorMessage, formatDate } from '../src/ui/format';
import { launchHref, readRoute } from '../src/ui/routes';
import type { LaunchDraft, LaunchPhase } from '../src/types';

function validDraft(): LaunchDraft {
  return { ...makeDefaultDraft(), name: 'Garden', symbol: 'GARDEN', ensDomain: 'community.eth' };
}

describe('Exact ETH amount validation', () => {
  test('keeps wei precision beyond the safe integer range', () => {
    expect(toUnits('9007199254740993.000000000000000001')).toBe(9007199254740993000000000000000001n);
    expect(toUnits('0.000000000000000001')).toBe(1n);
    expect(toUnits(' .5 ')).toBe(500000000000000000n);
    expect(toUnits('1.')).toBe(1000000000000000000n);
  });

  test('rejects exponential, signed, nonnumeric and overprecision amounts', () => {
    for (const input of ['1e-3', '-1', '+1', 'Infinity', 'NaN', '1,000', '', '.', '0.0000000000000000001']) expect(toUnits(input)).toBeNull();
    expect(toUnits('1.001', 2)).toBeNull();
    expect(toUnits('1', -1)).toBeNull();
    expect(toUnits('1', 37)).toBeNull();
  });

  test('validates minimum bids and caps without float rounding', () => {
    const draft = validDraft();
    draft.phases[0].minimumBid = '0.100000000000000001';
    draft.phases[0].verifiedCapStart = '0.1';
    draft.phases[0].verifiedCapEnd = '0.1';
    expect(validateDraft(draft)['phase.community.minimumBid']).toContain('largest limit');
  });
});

describe('Creator rules', () => {
  test('the community-first template is complete after its token and ENS name are filled', () => {
    const draft = validDraft();
    expect(draft.phases[0].requireEns).toBe(true);
    expect(draft.phases[0].requireVerified).toBe(true);
    expect(validateDraft(draft)).toEqual({});
  });

  test('all supply must go to auction plus liquidity', () => {
    const draft = validDraft();
    draft.liquidityBps = 2500;
    expect(validateDraft(draft).allocation).toContain('exactly 100%');
    draft.liquidityBps = 3500;
    expect(validateDraft(draft).allocation).toContain('exactly 100%');
    draft.saleBps = 10000; draft.liquidityBps = 0;
    expect(validateDraft(draft).liquidityBps).toBeDefined();
  });

  test('rejects launches outside the factory limits before asking for a signature', () => {
    const draft = validDraft();
    draft.minimumRaise = '0';
    draft.totalSupply = '2000000000000';
    draft.phases[1].durationBlocks = 10_000_000;
    draft.name = '🌱'.repeat(17);
    const errors = validateDraft(draft);
    for (const field of ['minimumRaise', 'totalSupply', 'phases', 'name']) expect(errors[field]).toBeDefined();
    draft.minimumRaise = '0.000000000000000001';
    expect(validateDraft(draft).minimumRaise).toContain('0.000000008589934592');
    draft.minimumRaise = '0.000000008589934592';
    expect(validateDraft(draft).minimumRaise).toBeUndefined();
    draft.totalSupply = '0.000000001';
    expect(validateDraft(draft).totalSupply).toContain('liquidity share');
    draft.totalSupply = '0.000000000000000001';
    expect(validateDraft(draft).totalSupply).toContain('subunit');
  });

  test('checks the actual UTF-8 metadata sent to the factory', () => {
    const draft = validDraft();
    draft.description = 'A 🌱 for everyone';
    const uri = launchMetadataUri(draft);
    const json = new TextDecoder().decode(Uint8Array.from(atob(uri.split(',')[1]), character => character.charCodeAt(0)));
    expect(JSON.parse(json)).toEqual({ description: draft.description, phaseNames: ['Community', 'Open launch'] });
    draft.phases = Array.from({ length: 16 }, (_, i) => ({ ...draft.phases[1], id: String(i), name: '界'.repeat(40) }));
    expect(validateDraft(draft).description).toContain('onchain size');
  });

  test('growing limits cannot shrink or put verified people below the base tier', () => {
    const draft = validDraft();
    draft.phases[1].baseCapEnd = '0.01';
    expect(validateDraft(draft)['phase.open.baseCapEnd']).toBeDefined();
    draft.phases[1].baseCapEnd = '6';
    expect(validateDraft(draft)['phase.open.verifiedCapEnd']).toBeDefined();
  });

  test('base-only launches cannot rely on an unavailable verified tier to satisfy minimum bids', () => {
    const draft = validDraft();
    draft.provider = 'none';
    draft.phases = [{ ...draft.phases[1], minimumBid: '0.5', baseCapEnd: '0.25', requireVerified: false }];
    expect(validateDraft(draft)['phase.open.minimumBid']).toBeDefined();
  });

  test('phase access cannot silently omit its provider or parent domain', () => {
    const draft = validDraft();
    draft.provider = 'none'; draft.ensDomain = '';
    const errors = validateDraft(draft);
    expect(errors['phase.community.requireVerified']).toBeDefined();
    expect(errors.ensDomain).toBeDefined();
    expect(draftStepForError('phase.community.requireVerified')).toBe(2);
    expect(errorsForStep(errors, 2)).toHaveProperty('ensDomain');
    expect(errorsForStep({ provider: 'Unavailable' }, 2)).toHaveProperty('provider');
  });

  test('allows the configured 16-phase maximum and rejects 17', () => {
    const draft = validDraft();
    draft.phases = Array.from({ length: 16 }, (_, index) => ({ ...draft.phases[1], id: 'phase-' + index }));
    expect(validateDraft(draft).phases).toBeUndefined();
    draft.phases.push({ ...draft.phases[0], id: 'extra' });
    expect(validateDraft(draft).phases).toBeDefined();
  });

  test('requires flexible first, longer durations and nondecreasing lock bonuses', () => {
    const draft = validDraft();
    draft.locks[0].durationDays = 1;
    expect(validateDraft(draft).locks).toBeDefined();
    draft.locks[0].durationDays = 0;
    draft.locks[2].durationDays = 20;
    expect(validateDraft(draft)['lock.ninety.durationDays']).toBeDefined();
    draft.locks[2].durationDays = 90; draft.locks[2].multiplierBps = 14000;
    expect(validateDraft(draft)['lock.ninety.multiplierBps']).toBeDefined();
    draft.locks[2].multiplierBps = 100001;
    expect(validateDraft(draft)['lock.ninety.multiplierBps']).toBeDefined();
  });
});

describe('Supported ENS input boundary', () => {
  test('requires a true descendant rather than a suffix lookalike', () => {
    expect(nameError('alice.team.community.eth', 'community.eth')).toBeUndefined();
    for (const name of ['community.eth', 'alice.badcommunity.eth', 'community.eth.evil', '.community.eth', 'alice..community.eth']) expect(nameError(name, 'community.eth')).toBeDefined();
  });

  test('accepts at most eight descendant labels', () => {
    expect(nameError(Array(8).fill('a').join('.') + '.community.eth', 'community.eth')).toBeUndefined();
    expect(nameError(Array(9).fill('a').join('.') + '.community.eth', 'community.eth')).toContain('8 subname');
  });

  test('rejects unsupported Unicode, uppercase, spaces and edge hyphens', () => {
    for (const name of ['álîce.community.eth', 'Alice.community.eth', 'alice smith.community.eth', '-alice.community.eth', 'alice-.community.eth']) expect(nameError(name, 'community.eth')).toBeDefined();
    expect(nameError('alice-team.community.eth', 'community.eth')).toBeUndefined();
  });

  test('enforces DNS label and total wire length limits', () => {
    expect(nameError('a'.repeat(64) + '.community.eth', 'community.eth')).toContain('63');
    const tooLong = ['a'.repeat(63), 'b'.repeat(63), 'c'.repeat(63), 'd'.repeat(63), 'eth'].join('.');
    expect(nameError(tooLong)).toContain('255');
  });
});

describe('Local draft recovery', () => {
  test('rejects malformed shapes instead of crashing forms or trusting truthy flags', () => {
    const draft = validDraft();
    expect(restoreDraft({ ...draft, phases: [null] }, blankAsset)).toBeNull();
    expect(restoreDraft({ ...draft, phases: [{ ...draft.phases[0], requireVerified: 'false' }] }, blankAsset)).toBeNull();
    expect(restoreDraft({ ...draft, provider: 'unreviewed-adapter' }, blankAsset)).toBeNull();
    expect(restoreDraft({ ...draft, locks: [{ id: 'bad', durationDays: '90', multiplierBps: 10000 }] }, blankAsset)).toBeNull();
    expect(restoreDraft({ ...draft, phases: [draft.phases[0], draft.phases[0]] }, blankAsset)).toBeNull();
  });

  test('keeps other form fields when an empty number was stored as null', () => {
    const draft = validDraft();
    const recovered = restoreDraft({ ...draft, startDelayBlocks: null }, blankAsset);
    expect(recovered?.name).toBe('Garden');
    expect(Number.isNaN(recovered?.startDelayBlocks)).toBe(true);
    expect(validateDraft(recovered!).startDelayBlocks).toBeDefined();
  });

  test('uses the current network asset and makes the supply split complementary', () => {
    const asset = '0x1234567890123456789012345678901234567890';
    const recovered = restoreDraft({ ...validDraft(), liquidityBps: 1000, unknownData: 'omit' }, asset);
    expect(recovered?.quoteAsset).toBe(asset);
    expect(recovered?.liquidityBps).toBe(3000);
    expect(recovered).not.toHaveProperty('unknownData');
  });
});

describe('Safe previews and navigation', () => {
  test('does not emit invalid SVG coordinates while numbers are being edited', () => {
    const draft = validDraft();
    const phases: LaunchPhase[] = draft.phases.map((phase, index) => ({ ...phase, startBlock: index * 100, endBlock: (index + 1) * 100 }));
    phases[0].durationBlocks = Number.NaN;
    const rendered = renderToStaticMarkup(<CapChart phases={phases} />);
    expect(rendered).toContain('Add valid phase limits');
    expect(rendered).not.toContain('NaN');
    phases[0].durationBlocks = 100; phases[1].verifiedCapEnd = '';
    expect(renderToStaticMarkup(<CapChart phases={phases} />)).not.toContain('<svg');
  });

  test('encodes a launch identifier as one route and rejects malformed escaping', () => {
    const id = 'network:launch/one?x=#';
    expect(readRoute(launchHref(id))).toEqual({ page: 'launch', id });
    expect(readRoute('#/launch/%E0%A4%A')).toEqual({ page: 'explore' });
  });

  test('does not invent an unlock date or assert that a rejected multi-step request sent nothing', () => {
    expect(formatDate()).toBe('Set after first claim');
    expect(errorMessage(new Error('User rejected the request'))).toBe('The wallet request was cancelled.');
  });
});
