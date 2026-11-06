import { StrictMode, Component, type ReactNode } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';
import './styles.css';

class AppBoundary extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  render() {
    if (this.state.failed) return <main className="fatal-screen"><div className="brand-symbol">h</div><h1>Let’s reconnect.</h1><p>The interface encountered an unexpected error. Your onchain positions are unchanged.</p><button className="button primary" onClick={() => window.location.reload()}>Reload launchpad</button></main>;
    return this.props.children;
  }
}
createRoot(document.getElementById('root')!).render(<StrictMode><AppBoundary><App /></AppBoundary></StrictMode>);
