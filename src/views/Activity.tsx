import { useState } from 'react';
import { Activity as ActivityIcon, ArrowUpRight, Check, CircleAlert, Clock3 } from 'lucide-react';
import type { AppSnapshot } from '../types';
import { since } from '../ui/format';
import { launchHref } from '../ui/routes';
import { EmptyState, Pill, TransactionLink } from '../components/Common';

export default function Activity({ snapshot }: { snapshot: AppSnapshot }) {
  const [filter, setFilter] = useState('all');
  const items = snapshot.activity.filter(item => filter === 'all' || item.status === filter);
  return <div className="page activity-page"><header className="page-heading compact-heading"><div><p className="eyebrow">FOLLOW EVERY STEP</p><h1>Activity</h1><p>Launches, bids and claims from your current network.</p></div><Pill tone="neutral">{snapshot.network.name}</Pill></header><section className="panel activity-panel"><div className="section-heading"><h2>Recent activity</h2><div className="filter-tabs small" role="group" aria-label="Filter activity">{[['all', 'All'], ['confirmed', 'Confirmed'], ['pending', 'Pending'], ['failed', 'Failed']].map(([key, label]) => <button key={key} className={filter === key ? 'selected' : ''} aria-pressed={filter === key} onClick={() => setFilter(key)}>{label}</button>)}</div></div>{items.length ? <div className="activity-list">{items.map(item => <article className="activity-row" key={item.id}><div className={'activity-icon ' + item.status}>{item.status === 'confirmed' ? <Check size={17} /> : item.status === 'pending' ? <Clock3 size={17} /> : <CircleAlert size={17} />}</div><div className="activity-copy"><h3>{item.title}{item.launchId && <a href={launchHref(item.launchId)} aria-label="Open related launch"><ArrowUpRight size={14} /></a>}</h3><p>{item.description}</p>{item.hash && <TransactionLink hash={item.hash} explorerUrl={snapshot.network.explorerUrl} />}</div><div className="activity-time"><span>{since(item.timestamp, snapshot.network.timestamp)}</span><Pill tone={item.status === 'failed' ? 'danger' : item.status === 'pending' ? 'warning' : 'success'}>{item.status}</Pill></div></article>)}</div> : <EmptyState icon={<ActivityIcon size={27} />} title="No activity to show">Your onchain actions will appear here as they are recorded.</EmptyState>}</section></div>;
}
