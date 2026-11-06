import type { Launch, LaunchStatus } from '../types';

export function shortAddress(value?: string, size = 5) {
  if (!value) return 'Connect wallet';
  return value.length > size * 2 + 3 ? value.slice(0, size + 2) + '…' + value.slice(-size) : value;
}
export function amount(value: string | number | undefined, maximumFractionDigits = 4) {
  if (value === undefined || value === '') return '—';
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) return '—';
  if (numeric > 0 && numeric < 10 ** -maximumFractionDigits) return '<' + (10 ** -maximumFractionDigits).toFixed(maximumFractionDigits);
  return new Intl.NumberFormat('en-US', { maximumFractionDigits }).format(numeric);
}
export function compact(value: string | number) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) return '—';
  return new Intl.NumberFormat('en-US', { notation: 'compact', maximumFractionDigits: 1 }).format(numeric);
}
export function integer(value: number) { return new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 }).format(value); }
export function percent(value: number) { return new Intl.NumberFormat('en-US', { maximumFractionDigits: 1 }).format(value) + '%'; }
export function multiplier(value: number) { return new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 }).format(value / 10_000) + '×'; }
export function formatDate(timestamp?: number, includeTime = false) {
  if (!timestamp) return 'Set after first claim';
  return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', ...(includeTime ? { timeStyle: 'short' as const } : {}) }).format(new Date(timestamp * 1000));
}
export function since(timestamp: number, now = Date.now() / 1000) {
  const seconds = Math.max(0, now - timestamp);
  if (seconds < 60) return 'Just now';
  if (seconds < 3600) return Math.floor(seconds / 60) + 'm ago';
  if (seconds < 86400) return Math.floor(seconds / 3600) + 'h ago';
  return Math.floor(seconds / 86400) + 'd ago';
}
export function phaseProgress(start: number, end: number, current: number) {
  return Math.max(0, Math.min(100, ((current - start) / Math.max(1, end - start)) * 100));
}
export function raiseProgress(launch: Launch) {
  const target = Number(launch.minimumRaise);
  return target > 0 ? Math.max(0, Math.min(100, Number(launch.raised) / target * 100)) : launch.status === 'upcoming' ? 0 : 100;
}
export const statusLabels: Record<LaunchStatus, string> = {
  upcoming: 'Upcoming', live: 'Live now', settling: 'Auction ended', graduated: 'Pool live', failed: 'Refunds available',
};
export function remainingBlocks(launch: Launch, current: number) {
  if (launch.status === 'upcoming') return 'Starts in ' + integer(Math.max(0, launch.startBlock - current)) + ' blocks';
  if (launch.status === 'live') return integer(Math.max(0, launch.endBlock - current)) + ' blocks left';
  if (launch.status === 'graduated') return 'Liquidity pool created';
  if (launch.status === 'failed') return 'Launch did not graduate';
  return 'Ready for settlement';
}
export function explorerLink(base: string | undefined, hash: string, kind: 'tx' | 'address' = 'tx') {
  return base ? base.replace(/\/$/, '') + '/' + kind + '/' + hash : undefined;
}
export function errorMessage(error: unknown) {
  const value = error instanceof Error ? error.message : typeof error === 'string' ? error : 'Something went wrong. Please try again.';
  if (/user rejected|user denied|rejected the request/i.test(value)) return 'The wallet request was cancelled.';
  return value.length > 500 ? value.slice(0, 497) + '…' : value;
}
