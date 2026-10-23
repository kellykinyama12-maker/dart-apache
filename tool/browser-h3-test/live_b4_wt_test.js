// Drives Dartisan Live B4 (component events) over real HTTP/3 + WebTransport:
// clicking "ping" on the Pinger emits a `ping` event; the Inbox (listening via
// data-live-listen) runs its own round-trip and its received count goes up.
//   dart run example/live_app.dart --root=./public --port=8657 --http3 \
//     --wt-path=/wt --tls-cert=build/cert.pem --tls-key=build/key.pem
//   node live_b4_wt_test.js --port 8657 --cert ../../build/cert.pem
'use strict';
const fs = require('fs');
const { X509Certificate, createHash } = require('crypto');
const { chromium } = require('playwright-core');
function arg(n, d) { const i = process.argv.indexOf(`--${n}`); return i >= 0 ? process.argv[i + 1] : d; }
const PORT = arg('port', '8657');
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
    await page.waitForSelector('#pings-received', { timeout: 10000 });

    const received = () => page.$eval('#pings-received', (e) => Number(e.textContent));
    const sent = () => page.$eval('#pings-sent', (e) => Number(e.textContent));
    const PING = '[data-live-component="pinger"] [data-live-click="ping"]';

    await page.click(PING);
    await page.waitForFunction(() => Number(document.querySelector('#pings-received').textContent) === 1, null, { timeout: 6000 });
    await page.click(PING);
    await page.waitForFunction(() => Number(document.querySelector('#pings-received').textContent) === 2, null, { timeout: 6000 });

    const result = {
      ok: (await sent()) === 2 && (await received()) === 2,
      sent: await sent(), received: await received(),
      transport: 'WebTransport over HTTP/3',
    };
    console.log(JSON.stringify(result, null, 2));
    process.exit(result.ok ? 0 : 1);
  } finally { await browser.close(); }
})();
