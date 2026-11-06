import { useState } from 'react';
import { ArrowDownToLine, ArrowRight, CheckCircle2, ChevronDown, Coins, LockKeyhole, Wallet } from 'lucide-react';
import type { AppSnapshot, LaunchpadClient, Position } from '../types';
import type { LaunchpadController } from '../ui/controller';
import { amount, formatDate, shortAddress } from '../ui/format';
import { launchHref } from '../ui/routes';
import { CopyButton, EmptyState, Pill, TokenMark } from '../components/Common';

export default function Positions({ snapshot, client, controller, onConnect }: { snapshot: AppSnapshot; client: LaunchpadClient; controller: LaunchpadController; onConnect: () => void }) {
  const [filter, setFilter] = useState('all');
  const actionable = snapshot.positions.filter(position => Object.values(position.actions).some(Boolean));
  const locked = snapshot.positions.filter(position => Number(position.lockedTokens) > 0);
  const shown = snapshot.positions.filter(position => filter === 'all' || filter === 'ready' && Object.values(position.actions).some(Boolean) || filter === 'locked' && Number(position.lockedTokens) > 0);
  return <div className="page positions-page"><header className="page-heading compact-heading"><div><p className="eyebrow">YOUR LAUNCHES, IN ONE PLACE</p><h1>My positions</h1><p>Follow your bids, collect refunds and unlock your tokens.</p></div><a className="button secondary" href="#/explore">Explore launches<ArrowRight size={16} /></a></header>
    {!snapshot.account ? <EmptyState icon={<Wallet size={28} />} title="Connect to see your positions" action={<button className="button primary" onClick={onConnect} disabled={controller.isBusy}>Connect wallet</button>}>Your bids and token locks will appear here after connecting.</EmptyState> : <>
      <div className="position-summary"><div><Coins size={20} /><small>All positions</small><strong>{snapshot.positions.length}</strong></div><div><ArrowDownToLine size={20} /><small>Action available</small><strong>{actionable.length}</strong></div><div><LockKeyhole size={20} /><small>Locked positions</small><strong>{locked.length}</strong></div></div>
      <div className="section-heading"><h2>Your participation</h2><div className="filter-tabs small" role="group" aria-label="Filter positions">{[['all', 'All'], ['ready', 'Action needed'], ['locked', 'Locked']].map(([key, label]) => <button key={key} aria-pressed={filter === key} className={filter === key ? 'selected' : ''} onClick={() => setFilter(key)}>{label}</button>)}</div></div>
      {shown.length ? <div className="position-list">{shown.map(position => <PositionCard key={position.id} position={position} client={client} controller={controller} />)}</div> : <EmptyState icon={<Coins size={27} />} title={filter === 'all' ? 'Your first bid is waiting' : 'Nothing here yet'} action={filter === 'all' ? <a className="button primary" href="#/explore">Find a launch<ArrowRight size={16} /></a> : <button className="button secondary" onClick={() => setFilter('all')}>Show all positions</button>}>{filter === 'all' ? 'Participate in a launch to follow your allocation, refunds and token lock here.' : 'Positions matching this filter will appear as your launches progress.'}</EmptyState>}
    </>}
  </div>;
}
function PositionCard({ position, client, controller }: { position: Position; client: LaunchpadClient; controller: LaunchpadController }) {
  const actions = position.actions;
  const hasAction = Object.values(actions).some(Boolean);
  const status = position.status === 'complete' ? 'Complete' : position.status === 'locked' ? 'Tokens locked' : position.status === 'refundable' ? 'Refund available' : hasAction ? 'Action available' : 'In auction';
  return <article className="position-card"><header><div className="position-identity"><TokenMark symbol={position.symbol} /><div><h3><a href={launchHref(position.launchId)}>{position.launchName}</a></h3><p>{position.phaseName || 'Auction position'}{(position.bidCount ?? 0) > 1 ? <span> · {position.bidCount} bids</span> : position.bidId && <span> · Bid #{position.bidId}</span>}</p></div></div><Pill tone={hasAction ? 'success' : position.status === 'locked' ? 'accent' : 'neutral'}>{status}</Pill></header>
    <dl className="position-metrics"><div><dt>Committed</dt><dd>{amount(position.amount)} <small>{position.quoteAsset.symbol}</small></dd></div><div><dt>Purchased</dt><dd>{amount(position.allocatedTokens)} <small>{position.symbol}</small></dd></div><div><dt>Locked</dt><dd>{amount(position.lockedTokens)} <small>{position.symbol}</small></dd></div><div><dt>{position.lockDays ? 'Unlock date' : 'Holding period'}</dt><dd className="date-value">{position.lockDays ? formatDate(position.unlockAt) : 'Flexible'}{position.lockDays > 0 && !position.unlockAt && <small>{position.lockDays} days after first claim</small>}</dd></div></dl>
    <div className="position-actions"><div>{Number(position.refundableAmount) > 0 ? <span className="refund-available"><ArrowDownToLine size={15} />{amount(position.refundableAmount)} {position.quoteAsset.symbol} refundable</span> : <span className="muted">{position.unavailableReason || (position.status === 'complete' ? 'All available assets collected.' : position.status === 'active' ? 'Your bid remains active in the auction.' : 'Unused ETH is separate from your token lock.')}</span>}</div><div className="button-row">
      {actions.settle && <button className="button secondary small-button" disabled={controller.actionsBlocked} onClick={() => void controller.run('Settle bid', () => client.settle(position.id))}>{(position.bidCount ?? 0) > 1 ? 'Settle next bid' : 'Settle bid'}</button>}
      {actions.refund && <button className="button secondary small-button" disabled={controller.actionsBlocked} onClick={() => void controller.run('Collect refund', () => client.refund(position.id))}><ArrowDownToLine size={15} />Collect refund</button>}
      {actions.claim && <button className="button primary small-button" disabled={controller.actionsBlocked} onClick={() => void controller.run('Claim tokens', () => client.claim(position.id))}><Coins size={15} />Claim tokens</button>}
      {actions.unlock && <button className="button primary small-button" disabled={controller.actionsBlocked} onClick={() => void controller.run('Unlock tokens', () => client.unlock(position.id))}><LockKeyhole size={15} />Unlock tokens</button>}
      {position.status === 'complete' && !hasAction && <span className="complete-mark"><CheckCircle2 size={17} />Collected</span>}
    </div></div>
    <details className="position-details"><summary>Position details<ChevronDown size={14} /></summary><dl className="address-list"><div><dt>Recipient</dt><dd><code title={position.beneficiary}>{shortAddress(position.beneficiary, 8)}</code><CopyButton value={position.beneficiary} /></dd></div><div><dt>Bid owner</dt><dd><code title={position.owner}>{shortAddress(position.owner, 8)}</code><CopyButton value={position.owner} /></dd></div>{position.wrapperAddress && <div><dt>Lock contract</dt><dd><code title={position.wrapperAddress}>{shortAddress(position.wrapperAddress, 8)}</code><CopyButton value={position.wrapperAddress} /></dd></div>}<div><dt>{(position.bidCount ?? 0) > 1 ? 'Highest bid limit' : 'Maximum price'}</dt><dd>{amount(position.maxPrice, 8)} {position.quoteAsset.symbol} / token</dd></div></dl></details>
  </article>;
}
