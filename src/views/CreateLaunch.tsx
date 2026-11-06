import { useEffect, useRef, useState } from 'react';
import { ArrowLeft, ArrowRight, Check, CheckCircle2, CircleAlert, Layers3, Rocket, ShieldCheck } from 'lucide-react';
import type { AppSnapshot, LaunchDraft, LaunchPhase, LaunchpadClient } from '../types';
import type { LaunchpadController } from '../ui/controller';
import { draftStepForError, errorsForStep, makeDefaultDraft, restoreDraft, validateDraft, type DraftErrors } from '../ui/draft';
import { amount, compact, integer, percent } from '../ui/format';
import { launchHref } from '../ui/routes';
import { CapChart, Field, Pill, Spinner, TokenMark } from '../components/Common';
import PhaseEditor from '../components/PhaseEditor';
import AccessEditor from '../components/AccessEditor';
import LaunchReview from '../components/LaunchReview';

const steps = [{ name: 'The basics', sub: 'Token & allocation' }, { name: 'Auction phases', sub: 'Timing & limits' }, { name: 'Access & locks', sub: 'Who can participate' }, { name: 'Review & launch', sub: 'Make it official' }];
function loadDraft(snapshot: AppSnapshot): LaunchDraft {
  const fallback = makeDefaultDraft(snapshot.quoteAsset.address);
  try {
    const parsed: unknown = JSON.parse(localStorage.getItem('hoddr.launchpad.draft.v1.' + snapshot.network.key) || 'null');
    return restoreDraft(parsed, snapshot.quoteAsset.address) ?? fallback;
  } catch { return fallback; }
}
export default function CreateLaunch({ snapshot, client, controller, onConnect }: { snapshot: AppSnapshot; client: LaunchpadClient; controller: LaunchpadController; onConnect: () => void }) {
  const [draft, setDraft] = useState<LaunchDraft>(() => loadDraft(snapshot));
  const [step, setStep] = useState(0);
  const [errors, setErrors] = useState<DraftErrors>({});
  const [saved, setSaved] = useState(false);
  const heading = useRef<HTMLDivElement>(null);
  useEffect(() => { try { localStorage.setItem('hoddr.launchpad.draft.v1.' + snapshot.network.key, JSON.stringify(draft)); setSaved(true); } catch { setSaved(false); } }, [draft, snapshot.network.key]);
  const patch = (value: Partial<LaunchDraft>) => { setDraft(current => ({ ...current, ...value })); setErrors({}); };
  const go = (index: number) => { setStep(index); setErrors({}); window.requestAnimationFrame(() => heading.current?.scrollIntoView({ behavior: 'smooth', block: 'start' })); };
  const validate = () => { const found = validateDraft(draft, snapshot.quoteAsset.decimals, snapshot.limits?.maxPhases ?? 16, snapshot.limits?.maxLocks ?? 8); if (draft.provider !== 'none' && !snapshot.providers.some(provider => provider.key === draft.provider && ['ready', 'local-fixture'].includes(provider.status))) found.provider = 'Choose a configured verification provider, or use base limits only.'; return found; };
  const submit = async () => {
    if (controller.isBusy || step === 3 && (controller.actionsBlocked || snapshot.launchpadDeployed === false)) return;
    const allErrors = validate();
    const relevant = errorsForStep(allErrors, step);
    setErrors(relevant);
    if (Object.keys(relevant).length) {
      window.requestAnimationFrame(() => document.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus());
      return;
    }
    if (step < 3) { go(step + 1); return; }
    if (!snapshot.account) { onConnect(); return; }
    const result = await controller.run('Create launch', () => client.createLaunch(structuredClone({ ...draft, quoteAsset: snapshot.quoteAsset.address })));
    if (result?.launchId) {
      try { localStorage.removeItem('hoddr.launchpad.draft.v1.' + snapshot.network.key); } catch { /* The confirmed launch does not depend on draft storage. */ }
      window.location.hash = launchHref(result.launchId).slice(1);
    }
  };
  return <div className="page create-page"><header className="page-heading compact-heading" ref={heading}><div><p className="eyebrow">LAUNCH SETUP</p><h1>Create a launch</h1><p>Set the token supply, bidding limits and eligibility for your auction.</p></div><span className="draft-status">{saved ? <CheckCircle2 size={15} /> : <Layers3 size={15} />}{saved ? 'Draft saved locally' : 'Draft in this tab'}</span></header><div className="wizard-steps" role="group" aria-label="Launch creation steps">{steps.map((item, index) => <button key={item.name} type="button" className={(index === step ? 'active' : index < step ? 'complete' : '')} aria-current={index === step ? 'step' : undefined} onClick={() => go(index)} disabled={controller.isBusy}><span>{index < step ? <Check size={16} /> : index + 1}</span><strong>{item.name}<small>{item.sub}</small></strong>{index < steps.length - 1 && <i />}</button>)}</div>
    <div className={'create-layout' + (step === 3 ? ' review-layout' : '')}><form className="create-form panel" noValidate onSubmit={event => { event.preventDefault(); void submit(); }}>
      {step === 0 && <BasicsStep draft={draft} patch={patch} errors={errors} disabled={controller.isBusy} symbol={snapshot.quoteAsset.symbol} />}
      {step === 1 && <PhaseEditor phases={draft.phases} onChange={phases => patch({ phases })} errors={errors} maximum={snapshot.limits?.maxPhases ?? 16} disabled={controller.isBusy} symbol={snapshot.quoteAsset.symbol} />}
      {step === 2 && <AccessEditor draft={draft} onChange={patch} errors={errors} providers={snapshot.providers} maxLocks={snapshot.limits?.maxLocks ?? 8} disabled={controller.isBusy} />}
      {step === 3 && <LaunchReview draft={draft} snapshot={snapshot} onEdit={go} />}
      {step === 3 && Object.keys(errors).length > 0 && <div className="error-summary" role="alert"><CircleAlert size={18} /><div><strong>A few things need attention.</strong>{Object.entries(errors).map(([key, error]) => <button type="button" key={key} onClick={() => { setStep(draftStepForError(key)); }}>{error}<ArrowRight size={12} /></button>)}</div></div>}
      <div className="wizard-footer"><button type="button" className="button ghost" disabled={controller.isBusy || step === 0} onClick={() => go(step - 1)}><ArrowLeft size={16} />Back</button><span>Step {step + 1} of {steps.length}</span><button className="button primary" type="submit" disabled={controller.isBusy || step === 3 && (controller.actionsBlocked || snapshot.launchpadDeployed === false)}>{controller.isBusy ? <Spinner label="Waiting for confirmation" /> : step < 3 ? <>Continue<ArrowRight size={16} /></> : snapshot.launchpadDeployed === false ? 'Launchpad unavailable on this network' : !snapshot.account ? 'Connect wallet to launch' : <>Create launch<Rocket size={16} /></>}</button></div>
    </form>{step !== 3 && <aside className="creation-aside"><DraftPreview draft={draft} snapshot={snapshot} /><div className="creation-aside-note"><ShieldCheck size={20} /><div><strong>How the limits work</strong><p>Limits are cumulative within each phase. Linked wallets share the verified allowance.</p></div></div></aside>}</div></div>;
}
function BasicsStep({ draft, patch, errors, disabled, symbol }: { draft: LaunchDraft; patch: (patch: Partial<LaunchDraft>) => void; errors: DraftErrors; disabled: boolean; symbol: string }) {
  return <div><div className="step-intro"><span className="step-kicker">01 / YOUR COMMUNITY</span><h2>Token and funding</h2><p>A name, a token and a plan for the initial supply.</p></div><fieldset disabled={disabled} className="plain-fieldset"><div className="form-grid two"><Field label="Community name" placeholder="Your community" value={draft.name} maxLength={64} onChange={event => patch({ name: event.target.value })} error={errors.name} autoComplete="off" /><Field label="Token symbol" placeholder="TOKEN" value={draft.symbol} maxLength={10} onChange={event => patch({ symbol: event.target.value.toUpperCase() })} error={errors.symbol} autoComplete="off" /></div><div className="field"><label htmlFor="launch-description">A short description<span className="label-aside">{draft.description.length}/280</span></label><textarea id="launch-description" placeholder="What are you building together?" value={draft.description} maxLength={280} rows={3} onChange={event => patch({ description: event.target.value })} aria-invalid={Boolean(errors.description)} />{errors.description && <small className="field-error">{errors.description}</small>}</div><div className="form-divider" /><Field label="Total token supply" inputMode="decimal" value={draft.totalSupply} suffix={draft.symbol || 'tokens'} onChange={event => patch({ totalSupply: event.target.value })} error={errors.totalSupply} /><div className="form-grid two"><Field label="Auction allocation" type="number" min={0.01} max={100} step={0.1} value={Number.isFinite(draft.saleBps) ? draft.saleBps / 100 : ''} suffix="%" onChange={event => { const saleBps = Math.round(event.target.valueAsNumber * 100); patch({ saleBps, liquidityBps: 10000 - saleBps }); }} error={errors.saleBps} /><Field label="Liquidity reserve" type="number" value={Number.isFinite(draft.liquidityBps) ? draft.liquidityBps / 100 : ''} suffix="%" readOnly error={errors.liquidityBps} hint="The rest of the supply is reserved for liquidity." /></div>{errors.allocation ? <p className="field-error">{errors.allocation}</p> : <p className="form-note">The full supply is split between the auction and its liquidity reserve.</p>}<div className="form-divider" /><div className="form-grid two"><Field label="Price floor per token" inputMode="decimal" value={draft.floorPrice} suffix={symbol} onChange={event => patch({ floorPrice: event.target.value })} error={errors.floorPrice} /><Field label="Minimum raise" inputMode="decimal" value={draft.minimumRaise} suffix={symbol} onChange={event => patch({ minimumRaise: event.target.value })} error={errors.minimumRaise} /></div><Field label="Start after launch creation" type="number" min={3} step={1} value={Number.isFinite(draft.startDelayBlocks) ? draft.startDelayBlocks : ''} suffix="blocks" onChange={event => patch({ startDelayBlocks: event.target.valueAsNumber })} error={errors.startDelayBlocks} hint="The final start block is calculated when you create the launch." /></fieldset></div>;
}
function DraftPreview({ draft, snapshot }: { draft: LaunchDraft; snapshot: AppSnapshot }) {
  let cursor = 0; const phases: LaunchPhase[] = draft.phases.map(phase => { const startBlock = cursor; cursor += Number.isFinite(phase.durationBlocks) ? phase.durationBlocks : 0; return { ...phase, startBlock, endBlock: cursor }; });
  return <div className="draft-preview panel"><div className="draft-preview-top"><span className="eyebrow">LIVE PREVIEW</span><Pill>{snapshot.network.key === 'local' ? 'Local chain' : 'Sepolia'}</Pill></div><TokenMark symbol={draft.symbol || 'NEW'} large /><h3>{draft.name || 'Your community'}</h3><p>{draft.description || 'Your community’s story starts here.'}</p><dl><div><dt>Auction supply</dt><dd>{compact(Number(draft.totalSupply) * draft.saleBps / 10000)} <small>{draft.symbol || 'tokens'}</small></dd></div><div><dt>Minimum raise</dt><dd>{amount(draft.minimumRaise)} <small>{snapshot.quoteAsset.symbol}</small></dd></div><div><dt>Auction length</dt><dd>{integer(cursor)} <small>blocks</small></dd></div></dl><CapChart phases={phases} symbol={snapshot.quoteAsset.symbol} /><div className="preview-badges"><Pill>{draft.phases.length} phases</Pill>{draft.provider !== 'none' && <Pill tone="success">Human limits</Pill>}{draft.ensDomain && <Pill tone="accent">ENS community</Pill>}</div></div>;
}
