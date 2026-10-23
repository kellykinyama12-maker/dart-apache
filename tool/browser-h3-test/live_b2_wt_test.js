// Drives Dartisan Live B2 (polling + live-search model) over real HTTP/3 + WT:
// the clock ticks on its own (data-live-poll) and the search box filters as you
// type (data-live-model-live) — all over WebTransport, no HTTP.
//   dart run example/live_app.dart --root=./public --port=8654 --http3 \
//     --wt-path=/wt --tls-cert=build/cert.pem --tls-key=build/key.pem
//   node live_b2_wt_test.js --port 8654 --cert ../../build/cert.pem
'use strict';
const fs = require('fs');
const { X509Certificate, createHash } = require('crypto');
const { chromium } = require('playwright-core');
function arg(n, d) { const i = process.argv.indexOf(`--${n}`); return i >= 0 ? process.argv[i + 1] : d; }
const PORT = arg('port', '8654');
const CERT = arg('cert', '../../build/cert.pem');
const origin = `127.0.0.1:${PORT}`;
function spkiPin(p) { const c = new X509Certificate(fs.readFileSync(p)); return createHash('sha256').update(c.publicKey.export({ type: 'spki', format: 'der' })).digest('base64'); }
function findBrowser() { return ['C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe', 'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe'].find((p) => fs.existsSync(p)); }

(async () => {
  const browser = await chromium.launch({ executablePath: findBrowser(), headless: true, args: ['--no-sandbox', '--enable-quic', `--origin-to-force-quic-on=${origin}`, `--ignore-certificate-errors-spki-list=${spkiPin(CERT)}`] });
  try {
    const page = await browser.newPage();
    page.on('pageerror', (e) => console.error('[pageerror]', e.message));
    await page.goto(`https://${origin}/`, { waitUntil: 'load', timeout: 15000 });
    await page.waitForSelector('#tick-count', { timeout: 10000 });

    // Polling: ticks advance with zero user interaction (1s interval).
    const t0 = Number(await page.textContent('#tick-count'));
    await page.waitForFunction(
      (n) => Number(document.querySelector('#tick-count').textContent) >= n,
      t0 + 2, { timeout: 8000 });
    const t1 = Number(await page.textContent('#tick-count'));

    // Live search: typing filters the list over WT (eager model, debounced).
    const SEARCH = '[data-live-component="search"] input';
    await page.fill(SEARCH, 'ch');
    await page.waitForFunction(
      () => /^1 /.test(document.querySelector('#search-count').textContent),
      null, { timeout: 6000 });
    const chResults = await page.$$eval('#search-results li', (els) => els.map((e) => e.textContent));
    await page.fill(SEARCH, 'a');
    await page.waitForFunction(
      () => /^4 /.test(document.querySelector('#search-count').textContent),
      null, { timeout: 6000 });
    const aCount = (await page.textContent('#search-count'));

    const result = {
      ok: t1 >= t0 + 2 && chResults.length === 1 && chResults[0] === 'cherry' && /^4 /.test(aCount),
      polledFrom: t0, polledTo: t1,
      searchCh: chResults, searchACount: aCount,
      transport: 'WebTransport over HTTP/3',
    };
    console.log(JSON.stringify(result, null, 2));
    process.exit(result.ok ? 0 : 1);
  } finally { await browser.close(); }
})();
