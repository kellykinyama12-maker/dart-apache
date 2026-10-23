// Drives Dartisan Live B5 (dirty state) over real HTTP/3 + WebTransport: typing
// in a deferred data-live-model input shows the "unsaved" marker; a committed
// action (submit) clears it.
//   dart run example/live_app.dart --root=./public --port=8658 --http3 \
//     --wt-path=/wt --tls-cert=build/cert.pem --tls-key=build/key.pem
//   node live_b5_wt_test.js --port 8658 --cert ../../build/cert.pem
'use strict';
const fs = require('fs');
const { X509Certificate, createHash } = require('crypto');
const { chromium } = require('playwright-core');
function arg(n, d) { const i = process.argv.indexOf(`--${n}`); return i >= 0 ? process.argv[i + 1] : d; }
const PORT = arg('port', '8658');
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
    const FORM = '[data-live-component="signup"]';
    await page.waitForSelector(`${FORM} input[name="email"]`, { timeout: 10000 });

    const isDirty = () => page.evaluate(() => document.querySelector('[data-live-component="signup"]').hasAttribute('data-live-dirty'));
    const markerShown = () => page.evaluate(() => { const m = document.querySelector('[data-live-component="signup"] [data-live-dirty]'); return m && !m.hasAttribute('hidden'); });

    const dirty0 = await isDirty();                 // clean at start
    await page.fill(`${FORM} input[name="email"]`, 'ada@example.com');
    await page.waitForFunction(() => document.querySelector('[data-live-component="signup"]').hasAttribute('data-live-dirty'), null, { timeout: 4000 });
    const dirtyAfterType = await isDirty();
    const markerAfterType = await markerShown();

    await page.click(`${FORM} button[type="submit"]`);
    await page.waitForFunction(() => !document.querySelector('[data-live-component="signup"]').hasAttribute('data-live-dirty'), null, { timeout: 6000 });
    const dirtyAfterSave = await isDirty();

    const result = {
      ok: dirty0 === false && dirtyAfterType === true && markerAfterType === true && dirtyAfterSave === false,
      dirty0, dirtyAfterType, markerAfterType, dirtyAfterSave,
      transport: 'WebTransport over HTTP/3',
    };
    console.log(JSON.stringify(result, null, 2));
    process.exit(result.ok ? 0 : 1);
  } finally { await browser.close(); }
})();
