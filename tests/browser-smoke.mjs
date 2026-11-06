// Run against the local app. --write-local also creates a test auction and places one bid.
import assert from 'node:assert/strict';
import { existsSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { chromium } from '@playwright/test';

const base = 'http://127.0.0.1:5192';
const output = resolve(import.meta.dirname, '../.cache/browser-smoke');
mkdirSync(output, { recursive: true });
process.env.TMP = process.env.TEMP = process.env.TMPDIR = output;
const localSale = process.argv.includes('--write-local');
const local = (await (await fetch(base + '/api/runtime')).json()).deployments.local;
assert(local?.chainId === 31337 && local.localTestOnly, 'Start the local fixture deployment first.');
const browser = await chromium.launch({
  ...(existsSync(chromium.executablePath()) ? {} : { channel: 'chrome' }),
  timeout: 30_000,
});
async function checkWidth(page, view) {
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - innerWidth);
  assert(overflow <= 1, view + ' overflows by ' + overflow + ' px');
}

try {
  for (const [name, viewport] of [['desktop', { width: 1440, height: 950 }], ['phone', { width: 390, height: 844 }]]) {
    const context = await browser.newContext({ viewport, reducedMotion: 'reduce' });
    await context.route('**/*', route => {
      const url = new URL(route.request().url());
      if (!['data:', 'blob:'].includes(url.protocol) && (url.origin !== base || url.pathname === '/api/rpc/sepolia')) return route.abort();
      return route.continue();
    });
    const page = await context.newPage();
    page.setDefaultTimeout(20_000);
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('response', async response => {
      if (!response.ok() && response.url().includes('/api/')) {
        const payload = response.request().postDataJSON();
        const methods = [payload].flat().map(item => item?.method ?? 'local action');
        console.error('API failure', response.status(), methods, (await response.json()).error);
      }
    });
    await page.goto(base);
    await page.getByRole('heading', { name: 'Community launches' }).waitFor();
    await page.getByRole('button', { name: 'Local chain' }).waitFor();
    await checkWidth(page, name + ' explore');
    await page.getByRole('main').getByRole('link', { name: 'Create a launch', exact: true }).click();
    const tokenName = 'Garden ' + Date.now().toString().slice(-7);
    await page.getByRole('button', { name: 'Continue', exact: true }).click();
    await page.getByLabel('Community name').fill(tokenName);
    await page.getByLabel('Token symbol').fill('GARDEN');
    await page.getByLabel('Start after launch creation').fill('5');
    await page.getByRole('button', { name: 'Continue', exact: true }).click();
    const gatedSale = name === 'desktop';
    if (!gatedSale) await page.getByRole('button', { name: 'Remove Community', exact: true }).click();
    await page.getByRole('button', { name: 'Continue', exact: true }).click();
    if (gatedSale) await page.getByLabel('ENS parent domain').fill('community.eth');
    else await page.getByRole('button', { name: /Base limits only/ }).click();
    await page.getByRole('button', { name: 'Continue', exact: true }).click();
    await page.getByRole('heading', { name: 'Review your launch' }).waitFor();
    await checkWidth(page, name + ' review');
    await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'instant' }));
    await page.screenshot({ path: resolve(output, name + '-review.png') });

    if (localSale && name === 'desktop') {
      await page.getByRole('main').getByRole('button', { name: 'Create launch', exact: true }).click();
      await Promise.race([
        page.waitForURL('**/#/launch/**', { timeout: 45_000 }),
        page.locator('.toast.danger, .error-summary').first().waitFor({ timeout: 45_000 }).then(async () => { throw new Error(await page.locator('.toast.danger, .error-summary').first().innerText()); }),
      ]);
      const launchUrl = page.url();
      await page.getByRole('heading', { name: tokenName, exact: true }).waitFor();
      await page.getByRole('tab', { name: 'Bid', exact: true }).click();
      await page.locator('.sidebar').getByRole('button', { name: 'Local tools' }).click();
      await page.getByLabel('Blocks to mine').fill('6');
      await page.getByRole('button', { name: 'Mine blocks' }).click();
      await page.getByText('Local blocks advanced', { exact: true }).waitFor();
      await page.getByRole('button', { name: 'Close dialog' }).click();
      await page.getByRole('tab', { name: 'Overview', exact: true }).click();
      await page.getByRole('button', { name: 'Update auction price' }).click();
      await page.getByText('Auction price updated', { exact: true }).waitFor();
      await page.getByRole('tab', { name: 'Bid', exact: true }).click();
      await page.getByLabel('Your community subname').waitFor();
      if (await page.getByRole('button', { name: 'Verify to participate' }).isVisible()) {
        await page.getByRole('button', { name: 'Verify to participate' }).click();
        await page.getByRole('button', { name: 'Enroll local test identity' }).click();
        await page.getByRole('button', { name: 'Continue to launchpad' }).click();
      }
      await page.getByLabel('Your community subname').fill('alice.community.eth');
      await page.getByRole('button', { name: 'Check name' }).click();
      await page.getByText('This name belongs to your connected wallet.').waitFor();
      await page.getByLabel('Your bid').fill('0.02');
      await page.getByLabel('Maximum price per token').fill('0.0001');
      await page.getByRole('button', { name: 'Place bid', exact: true }).click();
      await page.getByText(/^Enter a maximum price above/).waitFor();
      await page.getByLabel('Maximum price per token').fill('0.001');
      await page.getByRole('button', { name: 'Place bid', exact: true }).click();
      await page.locator('.existing-position-link').click({ timeout: 45_000 });
      const position = page.locator('.position-card').filter({ hasText: tokenName });
      await position.waitFor();
      await page.locator('.sidebar').getByRole('button', { name: 'Local tools' }).click();
      await page.getByLabel('Blocks to mine').fill('260');
      await page.getByRole('button', { name: 'Mine blocks' }).click();
      await page.getByText('Local blocks advanced', { exact: true }).waitFor();
      await page.getByRole('button', { name: 'Close dialog' }).click();
      await position.getByRole('button', { name: 'Settle bid', exact: true }).click();
      await position.getByText('0.02 ETH refundable').waitFor({ timeout: 45_000 });
      await position.getByRole('button', { name: 'Collect refund' }).click();
      await position.getByText('Collected', { exact: true }).waitFor();
      await page.goto(launchUrl);
      await page.getByRole('tab', { name: 'Seller collection' }).click();
      await page.getByRole('button', { name: 'Settle auction' }).click();
      await page.getByRole('button', { name: 'Recover unsold tokens' }).click({ timeout: 45_000 });
      await page.getByRole('button', { name: 'Recover unsold tokens' }).waitFor({ state: 'detached' });
      await page.getByRole('link', { name: 'Buyer claims' }).click();
      console.log('Confirmed local gated creation, ENS check, verified bid, 0.02 ETH buyer refund and seller token recovery.');
    } else {
      if (name === 'phone') {
        await page.getByRole('button', { name: 'Open navigation' }).click();
        await page.getByRole('navigation', { name: 'Mobile navigation' }).getByRole('link', { name: 'My positions' }).click();
      } else await page.getByRole('navigation', { name: 'Main navigation' }).getByRole('link', { name: 'My positions' }).click();
    }
    await page.getByRole('heading', { name: 'My positions' }).waitFor();
    await page.getByRole('button', { name: 'Locked', exact: true }).click();
    assert.equal(await page.getByRole('button', { name: 'Locked', exact: true }).getAttribute('aria-pressed'), 'true');
    await checkWidth(page, name + ' positions');
    assert.deepEqual(errors, [], 'Browser errors');
    await context.close();
    console.log(name + ' passed: explore, creator review, navigation, position filters and layout.');
  }
} finally {
  await browser.close();
}
