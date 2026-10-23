// Drives the Dartisan reactive to-do app over real HTTP/3 + WebTransport in
// Edge: adds two items (data-live-model + data-live-submit), toggles one and
// removes one (data-live-click + data-live-id -> payloadFrom), verifying the
// server-rendered state via window.__dartisanLive. Start the server first:
//   dart run example/todo_app.dart --root=./public --port=8443 --http3 \
//       --wt-path=/wt --tls-cert=build/cert.pem --tls-key=build/key.pem
//   node todo_wt_test.js --port 8443 --cert ../../build/cert.pem
'use strict';
const fs = require('fs');
const { X509Certificate, createHash } = require('crypto');
const { chromium } = require('playwright-core');

function arg(name, def) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : def;
}
const PORT = arg('port', '8443');
const CERT = arg('cert', '../../build/cert.pem');
const origin = `127.0.0.1:${PORT}`;

function spkiPin(p) {
  const cert = new X509Certificate(fs.readFileSync(p));
  const der = cert.publicKey.export({ type: 'spki', format: 'der' });
  return createHash('sha256').update(der).digest('base64');
}
function findBrowser() {
  return [
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  ].find((p) => fs.existsSync(p));
}

async function state(page) {
  return page.evaluate(() => window.__dartisanLive);
}

(async () => {
  const pin = spkiPin(CERT);
  const executablePath = findBrowser();
  if (!executablePath) throw new Error('no Edge/Chrome found');
  const browser = await chromium.launch({
    executablePath,
    headless: true,
    args: [
      '--no-sandbox',
      '--enable-quic',
      `--origin-to-force-quic-on=${origin}`,
      `--ignore-certificate-errors-spki-list=${pin}`,
    ],
  });
  try {
    const page = await browser.newPage();
    page.on('pageerror', (e) => console.error('[pageerror]', e.message));
    await page.goto(`https://${origin}/`, { waitUntil: 'load', timeout: 15000 });
    await page.waitForSelector('[data-live-component="todos"]', { timeout: 10000 });

    async function waitItems(n) {
      await page.waitForFunction(
        (want) => window.__dartisanLive && window.__dartisanLive.items.length === want,
        n, { timeout: 6000 });
    }

    // Add two items via the model input + submit.
    await page.fill('input[data-live-model="draft"]', 'Buy milk');
    await page.click('button[type="submit"]');
    await waitItems(1);
    await page.fill('input[data-live-model="draft"]', 'Walk dog');
    await page.click('button[type="submit"]');
    await waitItems(2);

    // Toggle item 1 (data-live-click=toggle + data-live-id=1 -> payload.id).
    await page.click('li[data-live-key="1"] input[type="checkbox"]');
    await page.waitForFunction(
      () => window.__dartisanLive.items.find((i) => i.id === 1).done === true,
      null, { timeout: 6000 });

    // Remove item 2 (data-live-click=remove + data-live-id=2).
    await page.click('li[data-live-key="2"] button[data-live-click="remove"]');
    await waitItems(1);

    const s = await state(page);
    const ok = s.items.length === 1 && s.items[0].id === 1 &&
      s.items[0].text === 'Buy milk' && s.items[0].done === true;
    console.log(JSON.stringify({ ok, state: s, transport: 'WebTransport/HTTP3' }, null, 2));
    process.exit(ok ? 0 : 1);
  } finally {
    await browser.close();
  }
})();
