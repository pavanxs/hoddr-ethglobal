import { useEffect, useId, useRef, useState, type CSSProperties, type ReactNode, type InputHTMLAttributes } from 'react';
import { ArrowUpRight, Check, CheckCircle2, Copy, ExternalLink, Loader2, X } from 'lucide-react';
import type { Launch, LaunchPhase, LaunchStatus, Tone } from '../types';
import { amount, explorerLink, integer, phaseProgress, statusLabels } from '../ui/format';
import { launchHref } from '../ui/routes';

export function Brand({ small = false }: { small?: boolean }) {
  return <a className={'brand' + (small ? ' small' : '')} href="#/explore" aria-label="HODDR launchpad home"><span className="brand-symbol" aria-hidden="true">h<span>·</span></span><span className="brand-word">hoddr<span>launchpad</span></span></a>;
}
export function TokenMark({ symbol, accent = 'mint', large = false }: { symbol: string; accent?: string; large?: boolean }) {
  return <span className={'token-mark ' + accent + (large ? ' large' : '')} aria-hidden="true"><span>{symbol.slice(0, 2).toUpperCase() || 'H'}</span><i /></span>;
}
export function Pill({ children, tone = 'neutral', dot = false }: { children: ReactNode; tone?: Tone; dot?: boolean }) { return <span className={'pill ' + tone}>{dot && <i aria-hidden="true" />}{children}</span>; }
export function LaunchBadge({ status }: { status: LaunchStatus }) {
  const tone: Tone = status === 'live' || status === 'graduated' ? 'success' : status === 'failed' ? 'warning' : 'neutral';
  return <Pill tone={tone} dot={status === 'live'}>{statusLabels[status]}</Pill>;
}
export function Spinner({ label }: { label?: string }) { return <span className="spinner-wrap"><Loader2 className="spin" size={16} aria-hidden="true" />{label}</span>; }
export function EmptyState({ icon, title, children, action }: { icon: ReactNode; title: string; children: ReactNode; action?: ReactNode }) {
  return <div className="empty-state"><div className="empty-state-icon" aria-hidden="true">{icon}</div><h2>{title}</h2><p>{children}</p>{action}</div>;
}
export function Field({ label, hint, error, suffix, className = '', ...props }: InputHTMLAttributes<HTMLInputElement> & { label: string; hint?: string; error?: string; suffix?: ReactNode }) {
  const generated = useId(); const id = props.id ?? generated;
  return <div className={'field ' + className}><label htmlFor={id}>{label}</label><div className={'input-wrap' + (suffix ? ' with-suffix' : '') + (error ? ' invalid' : '')}><input {...props} id={id} aria-invalid={Boolean(error)} aria-describedby={error || hint ? id + '-hint' : undefined} />{suffix && <span className="input-suffix">{suffix}</span>}</div>{(error || hint) && <small className={error ? 'field-error' : 'field-hint'} id={id + '-hint'}>{error || hint}</small>}</div>;
}
export function Toggle({ checked, onChange, children, description, disabled = false }: { checked: boolean; onChange: (checked: boolean) => void; children: ReactNode; description?: ReactNode; disabled?: boolean }) {
  return <button type="button" role="switch" aria-checked={checked} className={'toggle-row' + (checked ? ' checked' : '')} disabled={disabled} onClick={() => onChange(!checked)}><span><strong>{children}</strong>{description && <small>{description}</small>}</span><span className="switch-track" aria-hidden="true"><span /></span></button>;
}
export function Dialog({ open, title, children, onClose, wide = false }: { open: boolean; title: string; children: ReactNode; onClose: () => void; wide?: boolean }) {
  const titleId = useId(); const panel = useRef<HTMLDivElement>(null); const close = useRef(onClose); close.current = onClose;
  useEffect(() => {
    if (!open) return;
    const previous = document.activeElement as HTMLElement | null; const overflow = document.body.style.overflow; document.body.style.overflow = 'hidden';
    const timer = window.setTimeout(() => panel.current?.querySelector<HTMLElement>('button, input, select, [tabindex="0"]')?.focus(), 0);
    const keydown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') { event.preventDefault(); close.current(); }
      if (event.key !== 'Tab' || !panel.current) return;
      const items = Array.from(panel.current.querySelectorAll<HTMLElement>('button:not(:disabled), a[href], input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex="0"]')).filter(item => item.getClientRects().length > 0);
      const first = items[0]; const last = items[items.length - 1];
      if (!first) { event.preventDefault(); return; }
      if (event.shiftKey && (document.activeElement === first || !panel.current.contains(document.activeElement))) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    };
    document.addEventListener('keydown', keydown);
    return () => { window.clearTimeout(timer); document.body.style.overflow = overflow; document.removeEventListener('keydown', keydown); previous?.focus(); };
  }, [open]);
  if (!open) return null;
  return <div className="dialog-backdrop" onMouseDown={event => { if (event.target === event.currentTarget) onClose(); }}><div ref={panel} role="dialog" aria-modal="true" aria-labelledby={titleId} className={'dialog' + (wide ? ' wide' : '')}><header className="dialog-header"><h2 id={titleId}>{title}</h2><button className="icon-button" aria-label="Close dialog" onClick={onClose}><X size={20} /></button></header>{children}</div></div>;
}
export function CopyButton({ value, label = 'Copy address' }: { value: string; label?: string }) {
  const [copied, setCopied] = useState(false); const [failed, setFailed] = useState(false); const timer = useRef<number | undefined>(undefined);
  useEffect(() => () => window.clearTimeout(timer.current), []);
  return <button type="button" className="copy-button" aria-label={copied ? 'Copied' : label} title={failed ? 'Copy unavailable in this browser' : copied ? 'Copied' : label} onClick={async () => {
    try { await navigator.clipboard.writeText(value); setCopied(true); setFailed(false); window.clearTimeout(timer.current); timer.current = window.setTimeout(() => setCopied(false), 1800); }
    catch { setFailed(true); }
  }}>{copied ? <Check size={15} /> : <Copy size={15} />}{copied && <span>Copied</span>}{failed && <span>Copy unavailable</span>}</button>;
}
export function TransactionLink({ hash, explorerUrl, children }: { hash: string; explorerUrl?: string; children?: ReactNode }) {
  const href = explorerLink(explorerUrl, hash);
  return href ? <a className="text-link" href={href} target="_blank" rel="noreferrer">{children ?? 'View transaction'}<ExternalLink size={13} /></a> : <span className="transaction-reference"><code title={hash}>{hash.slice(0, 10)}…{hash.slice(-6)}</code><CopyButton value={hash} label="Copy transaction hash" /></span>;
}
export function ProgressBar({ value, label }: { value: number; label: string }) { return <div className="progress-track" role="progressbar" aria-label={label} aria-valuenow={Math.round(value)} aria-valuemin={0} aria-valuemax={100}><span style={{ width: Math.max(0, Math.min(100, value)) + '%' }} /></div>; }
export function PhaseTimeline({ phases, currentBlock, compact = false }: { phases: LaunchPhase[]; currentBlock: number; compact?: boolean }) {
  return <div className={'phase-timeline' + (compact ? ' compact' : '')}>{phases.map((phase, index) => {
    const completed = currentBlock >= phase.endBlock; const active = currentBlock >= phase.startBlock && !completed;
    return <div key={phase.id} className={'timeline-phase' + (active ? ' active' : '') + (completed ? ' completed' : '')}><div className="timeline-rail"><span>{completed ? <Check size={12} /> : index + 1}</span><i style={{ '--phase-progress': phaseProgress(phase.startBlock, phase.endBlock, currentBlock) + '%' } as CSSProperties} /></div><strong>{phase.name}</strong>{!compact && <small>{active ? integer(phase.endBlock - currentBlock) + ' blocks left' : completed ? 'Complete' : integer(phase.durationBlocks) + ' blocks'}</small>}</div>;
  })}</div>;
}
export function CapChart({ phases, currentBlock, symbol = 'ETH' }: { phases: LaunchPhase[]; currentBlock?: number; symbol?: string }) {
  if (!phases.length || phases.some(phase => !Number.isFinite(phase.durationBlocks) || phase.durationBlocks <= 0 || [phase.baseCapStart, phase.baseCapEnd, phase.verifiedCapStart, phase.verifiedCapEnd].some(value => !value.trim() || !Number.isFinite(Number(value)) || Number(value) < 0))) return <div className="chart-placeholder">Add valid phase limits to preview the curve.</div>;
  const width = 620, height = 156, left = 48, right = 12, top = 16, bottom = 31;
  const total = Math.max(1, phases.reduce((sum, phase) => sum + phase.durationBlocks, 0));
  const peak = Math.max(.0000001, ...phases.flatMap(phase => [Number(phase.baseCapEnd), Number(phase.verifiedCapEnd), Number(phase.baseCapStart), Number(phase.verifiedCapStart)]));
  const x = (offset: number) => left + offset / total * (width - left - right);
  const y = (value: number) => top + (1 - value / peak) * (height - top - bottom);
  const points = (tier: 'base' | 'verified') => { let cursor = 0; return phases.flatMap(phase => { const pair = [[x(cursor), y(Number(tier === 'base' ? phase.baseCapStart : phase.verifiedCapStart))], [x(cursor + phase.durationBlocks), y(Number(tier === 'base' ? phase.baseCapEnd : phase.verifiedCapEnd))]]; cursor += phase.durationBlocks; return pair; }); };
  const path = (tier: 'base' | 'verified') => points(tier).map((point, index) => (index ? 'L' : 'M') + point.join(',')).join(' ');
  const cursor = currentBlock !== undefined && phases.length ? x(Math.max(0, Math.min(total, currentBlock - phases[0].startBlock))) : undefined;
  return <div className="cap-chart"><div className="chart-legend"><span><i className="verified-line" />Verified limit</span><span><i className="base-line" />Base limit</span><small>{symbol} per phase, before lock bonus</small></div><svg viewBox={'0 0 ' + width + ' ' + height} role="img" aria-label={'Base and verified spending limits over ' + phases.length + ' auction phases'}>{[0, .5, 1].map(mark => <g key={mark}><line x1={left} y1={y(peak * mark)} x2={width - right} y2={y(peak * mark)} className="chart-grid" /><text x={left - 9} y={y(peak * mark) + 4} textAnchor="end">{amount(peak * mark, 2)}</text></g>)}<path d={path('verified') + ' L' + x(total) + ',' + y(0) + ' L' + x(0) + ',' + y(0) + ' Z'} className="chart-fill" /><path d={path('verified')} className="chart-verified" /><path d={path('base')} className="chart-base" />{phases.map((phase, index) => { const offset = phases.slice(0, index).reduce((sum, item) => sum + item.durationBlocks, 0); return <g key={phase.id}>{index > 0 && <line x1={x(offset)} y1={top} x2={x(offset)} y2={height - bottom} className="chart-divider" />}<text x={x(offset + phase.durationBlocks / 2)} y={height - 8} textAnchor="middle">{phases.length > 4 ? 'P' + (index + 1) : phase.name.length > 19 ? phase.name.slice(0, 17) + '…' : phase.name}</text></g>; })}{cursor !== undefined && <line x1={cursor} y1={top - 4} x2={cursor} y2={height - bottom + 3} className="chart-now" />}</svg></div>;
}
export function LaunchIdentity({ launch, large = false }: { launch: Launch; large?: boolean }) {
  return <div className={'launch-identity' + (large ? ' large' : '')}><TokenMark symbol={launch.symbol} accent={launch.accent} large={large} /><div><span className="eyebrow">{'$'}{launch.symbol}</span><h2>{large ? launch.name : <a href={launchHref(launch.id)}>{launch.name}</a>}</h2></div></div>;
}
export function DetailLink({ id, children = 'View launch' }: { id: string; children?: ReactNode }) { return <a className="detail-link" href={launchHref(id)}>{children}<ArrowUpRight size={17} /></a>; }
export function ConfirmedIcon() { return <span className="confirmed-icon"><CheckCircle2 size={20} /></span>; }
