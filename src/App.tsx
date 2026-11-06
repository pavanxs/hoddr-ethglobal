import { useEffect, useState, type ReactNode } from 'react';
import { Activity as ActivityIcon, ArrowRight, ArrowUpRight, Bell, CheckCircle2, ChevronDown, CircleAlert, Compass, FlaskConical, CodeXml, Layers3, Menu, MoreHorizontal, Plus, RefreshCw, ShieldCheck, Wallet, WifiOff, X } from 'lucide-react';
import type { LaunchpadClient } from './types';
import { createLaunchpadClient } from './chain/client';
import { useLaunchpad } from './ui/controller';
import { integer, shortAddress } from './ui/format';
import { readRoute, type Route } from './ui/routes';
import { Brand, Dialog, EmptyState, Pill, Spinner, TransactionLink } from './components/Common';
import AppDialogs, { type DialogName } from './components/AppDialogs';
import Explore from './views/Explore';
import CreateLaunch from './views/CreateLaunch';
import LaunchDetail from './views/LaunchDetail';
import Positions from './views/Positions';
import Activity from './views/Activity';

const defaultClient = createLaunchpadClient();
const navigation = [{ page: 'explore', label: 'Explore', icon: Compass }, { page: 'create', label: 'Create launch', icon: Plus }, { page: 'positions', label: 'My positions', icon: Layers3 }, { page: 'activity', label: 'Activity', icon: ActivityIcon }];
export default function App({ client = defaultClient }: { client?: LaunchpadClient }) {
  const controller = useLaunchpad(client);
  const { snapshot, operation, toast, verification } = controller;
  const [route, setRoute] = useState<Route>(() => readRoute());
  const [modal, setModal] = useState<DialogName>(null);
  useEffect(() => { const changed = () => { setRoute(readRoute()); window.scrollTo({ top: 0, behavior: 'instant' }); }; window.addEventListener('hashchange', changed); return () => window.removeEventListener('hashchange', changed); }, []);
  useEffect(() => {
    if (!toast || toast.tone === 'danger') return;
    const timer = window.setTimeout(controller.dismissToast, 6500);
    return () => window.clearTimeout(timer);
  }, [toast?.id]);
  useEffect(() => { document.title = (route.page === 'launch' ? snapshot?.launches.find(launch => launch.id === route.id)?.name ?? 'Launch' : route.page === 'create' ? 'Create a launch' : route.page === 'positions' ? 'My positions' : route.page === 'activity' ? 'Activity' : 'Community launches') + ' · HODDR'; }, [route, snapshot?.launches]);
  const currentNav = route.page === 'launch' ? 'explore' : route.page;
  const onConnect = () => setModal('wallet');
  const onVerify = () => setModal('verification');
  const verifying = verification && ['requesting', 'awaiting-user', 'checking', 'submitting'].includes(verification.status);
  let content: ReactNode;
  if (!snapshot) content = <div className="page startup-state">{controller.readError ? <EmptyState icon={<WifiOff size={29} />} title="Let’s reconnect to the chain." action={<div className="button-row"><button className="button primary" disabled={controller.reading} onClick={() => void controller.refresh(true)}>{controller.reading ? <Spinner label="Connecting" /> : <>Try again<RefreshCw size={16} /></>}</button><button className="button secondary" disabled={controller.isBusy} onClick={() => setModal('network')}>Change network</button></div>}>{controller.readError}</EmptyState> : <div className="loading-workspace"><div className="brand-symbol">h<span>·</span></div><Spinner label="Opening the launchpad…" /><p>Reading the latest state from your network.</p></div>}</div>;
  else if (route.page === 'create') content = <CreateLaunch key={snapshot.network.key} snapshot={snapshot} client={client} controller={controller} onConnect={onConnect} />;
  else if (route.page === 'positions') content = <Positions snapshot={snapshot} client={client} controller={controller} onConnect={onConnect} />;
  else if (route.page === 'activity') content = <Activity snapshot={snapshot} />;
  else if (route.page === 'launch') {
    const launch = snapshot.launches.find(item => item.id === route.id);
    content = launch ? <LaunchDetail key={snapshot.network.key + ':' + launch.id + ':' + (snapshot.account?.address ?? '')} launch={launch} snapshot={snapshot} client={client} controller={controller} onConnect={onConnect} onVerify={onVerify} /> : <div className="page"><EmptyState icon={<Compass size={28} />} title="This launch is not on this network." action={<a className="button primary" href="#/explore">Explore launches<ArrowRight size={16} /></a>}>Choose another network or return to the launch directory.</EmptyState></div>;
  } else content = <Explore snapshot={snapshot} />;
  return <div className="app-shell"><a className="skip-link" href="#main-content" onClick={event => { event.preventDefault(); const main = document.getElementById('main-content'); main?.focus(); main?.scrollIntoView(); }}>Skip to content</a><aside className="sidebar"><Brand /><div className="sidebar-section-label">YOUR WORKSPACE</div><nav aria-label="Main navigation"><NavLinks active={currentNav} /></nav><div className="sidebar-spacer" /><div className="sidebar-community-card"><div><span className="community-orb"><i /><i /><i /></span><ArrowUpRight size={17} /></div><h3>Start an auction</h3><p>Set your sale amount, phases and community rules.</p><a href="#/create">Create a launch<ArrowRight size={14} /></a></div><div className="sidebar-footer">{snapshot?.network.key === 'local' && <button disabled={controller.isBusy} onClick={() => setModal('tools')}><FlaskConical size={17} />Local tools<ChevronDown size={13} /></button>}<a href="https://github.com/pavanxs/hoddr-ethglobal" target="_blank" rel="noreferrer"><CodeXml size={16} />View source<ArrowUpRight size={13} /></a><span className="sidebar-environment"><i />TESTNET WORKSPACE</span></div></aside>
    <div className="main-shell"><header className="topbar"><div className="topbar-left"><button className="icon-button mobile-navigation-button" aria-label="Open navigation" onClick={() => setModal('navigation')}><Menu size={21} /></button><span className="breadcrumb">Launchpad<span>/</span><strong>{route.page === 'launch' ? 'Launch details' : navigation.find(item => item.page === currentNav)?.label}</strong></span></div><div className="topbar-actions"><span className="block-indicator" title="Latest observed block"><span className={controller.readError || !snapshot?.network.connected ? 'small-dot offline' : 'small-dot'} />{snapshot?.network.connected ? 'Block ' + integer(snapshot.network.blockNumber) : snapshot ? 'Offline' : 'Connecting'}</span><button className="network-control" disabled={controller.isBusy} onClick={() => setModal('network')}><span className={snapshot?.network.key === 'sepolia' ? 'eth-diamond' : 'network-square'} />{snapshot?.network.key === 'sepolia' ? 'Sepolia' : snapshot?.network.key === 'local' ? 'Local chain' : 'Network'}<ChevronDown size={13} /></button><button className={'wallet-control' + (snapshot?.account ? ' connected' : '')} disabled={controller.isBusy} onClick={onConnect}><Wallet size={16} /><span>{snapshot?.account ? shortAddress(snapshot.account.address, 4) : 'Connect wallet'}</span>{snapshot?.account?.verified && <ShieldCheck size={15} className="wallet-verified" />}</button><details className="more-menu"><summary aria-label="More options"><MoreHorizontal size={20} /></summary><div><button disabled={controller.reading} onClick={event => { event.currentTarget.closest('details')?.removeAttribute('open'); void controller.refresh(true); }}><RefreshCw size={15} />Refresh data</button><a href="#/activity" onClick={event => event.currentTarget.closest('details')?.removeAttribute('open')}><ActivityIcon size={15} />Activity</a>{snapshot?.network.key === 'local' && <button disabled={controller.isBusy} onClick={event => { event.currentTarget.closest('details')?.removeAttribute('open'); setModal('tools'); }}><FlaskConical size={15} />Local tools</button>}</div></details></div></header>
      <main id="main-content" tabIndex={-1}>{snapshot && controller.readError && <div className="connection-banner" role="alert"><WifiOff size={18} /><div><strong>Showing the last successful read.</strong><p>{controller.readError}</p></div><button className="text-button" disabled={controller.reading} onClick={() => void controller.refresh(true)}>Retry</button></div>}{snapshot?.notices?.map(notice => <div className="workspace-notice" key={notice}><CircleAlert size={16} /><p>{notice}</p></div>)}{content}</main><footer className="app-footer"><span>HODDR Launchpad</span><span><i />{snapshot?.network.connected && !controller.readError ? 'Connected to ' + snapshot.network.name : 'Connection unavailable'}</span></footer>
    </div>
    {operation && <div className="operation-banner" role="status"><Spinner /><span><strong>{operation}</strong><small>{verifying ? verification.message : 'Confirm any wallet requests, then wait for the receipt.'}</small></span>{verifying && <button className="text-button" onClick={() => setModal('verification')}>View request</button>}</div>}
    {toast && <div className={'toast ' + toast.tone} role={toast.tone === 'danger' ? 'alert' : 'status'}>{toast.tone === 'danger' ? <CircleAlert size={20} /> : toast.tone === 'success' ? <CheckCircle2 size={20} /> : <Bell size={20} />}<div><strong>{toast.title}</strong>{toast.message && <p>{toast.message}</p>}{toast.hash && <TransactionLink hash={toast.hash} explorerUrl={toast.chainId === snapshot?.network.chainId ? snapshot?.network.explorerUrl : undefined} />}</div><button className="icon-button" aria-label="Dismiss notification" onClick={controller.dismissToast}><X size={16} /></button></div>}
    <AppDialogs modal={modal} setModal={setModal} snapshot={snapshot} client={client} controller={controller} />
    <Dialog open={modal === 'navigation'} title="Navigation" onClose={() => setModal(null)}><div className="mobile-nav"><Brand small /><nav aria-label="Mobile navigation"><NavLinks active={currentNav} onNavigate={() => setModal(null)} /></nav></div></Dialog>
  </div>;
}
function NavLinks({ active, onNavigate }: { active: string; onNavigate?: () => void }) { return <>{navigation.map(item => <a key={item.page} href={'#/' + item.page} className={active === item.page ? 'active' : ''} aria-current={active === item.page ? 'page' : undefined} onClick={onNavigate}><item.icon size={19} /><span>{item.label}</span>{item.page === 'create' && <small>NEW</small>}</a>)}</>; }
