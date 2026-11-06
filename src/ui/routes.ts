export type Route = { page: 'explore' | 'create' | 'positions' | 'activity' } | { page: 'launch'; id: string };
export function readRoute(hash = window.location.hash): Route {
  const parts = hash.replace(/^#\/?/, '').split('/');
  if (parts[0] === 'launch' && parts[1]) {
    try { return { page: 'launch', id: decodeURIComponent(parts.slice(1).join('/')) }; } catch { return { page: 'explore' }; }
  }
  if (parts[0] === 'create' || parts[0] === 'positions' || parts[0] === 'activity') return { page: parts[0] };
  return { page: 'explore' };
}
export function launchHref(id: string) { return '#/launch/' + encodeURIComponent(id); }
