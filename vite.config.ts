import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { createRequire } from 'node:module';
import { dirname, resolve, sep } from 'node:path';

const root = import.meta.dirname;
const reactDirectory = dirname(createRequire(import.meta.url).resolve('react/package.json'));
const pnpmMarker = sep + '.pnpm' + sep;
const dependencyStore = reactDirectory.includes(pnpmMarker)
  ? reactDirectory.slice(0, reactDirectory.indexOf(pnpmMarker) + pnpmMarker.length - 1)
  : dirname(reactDirectory);
const proxy = { '/api': { target: 'http://127.0.0.1:5193', changeOrigin: false } };

export default defineConfig({
  root,
  plugins: [react()],
  cacheDir: resolve(root, '.cache/vite'),
  envDir: false,
  envPrefix: 'LAUNCHPAD_PUBLIC_',
  resolve: { preserveSymlinks: false },
  server: {
    host: '127.0.0.1', port: 5192, strictPort: true,
    allowedHosts: ['127.0.0.1', 'localhost'],
    proxy,
    fs: {
      allow: [root, resolve(root, '../node_modules'), dependencyStore],
      deny: ['.env', '.env.*', '**/.env*', '*.{crt,pem,key}', '**/.git/**', '**/.tools/**', '**/.local-state/**', '**/.local-chain/**', '**/broadcast/**', '**/scripts/**', '**/test-wallet.public.json', '**/.cache/browser-smoke/**'],
    },
  },
  preview: { host: '127.0.0.1', port: 5192, strictPort: true, proxy },
  build: { outDir: resolve(root, 'dist'), target: 'es2022', sourcemap: false },
});
