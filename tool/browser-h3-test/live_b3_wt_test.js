// Drives Dartisan Live B3 (nested components) over real HTTP/3 + WebTransport:
// increment a NESTED counter, then bump the PARENT — the nested counter must
// keep its own state across the parent's re-render (child = morph boundary).
//   dart run example/live_app.dart --root=./public --port=8655 --http3 \
//     --wt-path=/wt --tls-cert=build/cert.pem --tls-key=build/key.pem
//   node live_b3_wt_test.js --port 8655 --cert ../../build/cert.pem
'use strict';
const fs = require('fs');
const { X509Certificate, createHash } = require('crypto');
const { chromium } = require('playwright-core');
function arg(n, d) { const i = process.argv.indexOf(`--${n}`); return i >= 0 ? process.argv[i + 1] : d; }
const PORT = arg('port', '8655');
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
    await page.waitForSelector('#panel-bumps', { timeout: 10000 });

    const PANEL = '[data-live-component="panel"]';
    const NESTED_INCR = `${PANEL} [data-live-key="nested-counter"] [data-live-click="increment"]`;
    const nested = () => page.$eval(`${PANEL} [data-live-key="nested-counter"] #live-count`, (e) => Number(e.textContent));
    const bumps = () => page.$eval('#panel-bumps', (e) => Number(e.textContent));
    const waitNested = (n) => page.waitForFunction(
      (want) => {
        const el = document.querySelector('[data-live-component="panel"] [data-live-key="nested-counter"] #live-count');
        return el && el.textContent === String(want);
      }, n, { timeout: 6000 });

    // Increment the nested counter twice (wait between so state isn't raced).
    await page.click(NESTED_INCR);
    await waitNested(1);
    await page.click(NESTED_INCR);
    await waitNested(2);
    const nestedBefore = await nested();

    // Bump the PARENT; its re-render must not reset the nested counter.
    await page.click(`${PANEL} [data-live-click="bump"]`);
    await page.waitForFunction(() => Number(document.querySelector('#panel-bumps').textContent) >= 1, null, { timeout: 6000 });
    const nestedAfter = await nested();
    const parentBumps = await bumps();

    // The nested counter still works after the parent re-render.
    await page.click(NESTED_INCR);
    await waitNested(3);
    const nestedFinal = await nested();

    const result = {
      ok: nestedBefore === 2 && nestedAfter === 2 && parentBumps === 1 && nestedFinal === 3,
      nestedBefore, parentBumps, nestedAfterParentBump: nestedAfter, nestedFinal,
      transport: 'WebTransport over HTTP/3',
    };
    console.log(JSON.stringify(result, null, 2));
    process.exit(result.ok ? 0 : 1);
  } finally { await browser.close(); }
})();
