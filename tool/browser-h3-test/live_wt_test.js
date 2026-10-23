// Drives the Dartisan Live counter over real HTTP/3 + WebTransport in Edge:
// loads the page, clicks "+ 1" a few times, and verifies the count updates via
// WebTransport (no HTTP POST). Start the server first:
//   dart run example/live_app.dart --root=./public --port=8443 --http3 --dev --wt-path=/wt
// Then:
//   node live_wt_test.js --port 8443 --cert ../../build/cert.pem
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

function spkiPin(certPath) {
  const cert = new X509Certificate(fs.readFileSync(certPath));
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
    page.on('console', (m) => console.error('[page]', m.type(), m.text()));
    page.on('pageerror', (e) => console.error('[pageerror]', e.message));
    const INCR = '[data-live-click="increment"]';
    const DECR = '[data-live-click="decrement"]';

    await page.goto(`https://${origin}/`, { waitUntil: 'load', timeout: 15000 });
    await page.waitForSelector('#live-count', { timeout: 10000 });

    console.error('[diag] WebTransport =', await page.evaluate(() => typeof WebTransport));
    console.error('[diag] live path =', await page.evaluate(() => window.DARTISAN_LIVE_PATH));
    console.error('[diag] incr buttons =', await page.evaluate(
      () => document.querySelectorAll('[data-live-component]').length));

    const initial = Number(await page.textContent('#live-count'));

    // Three increments, each confirmed via the Live WebTransport round-trip.
    for (let i = 1; i <= 3; i++) {
      await page.click(INCR);
      await page.waitForFunction(
        (n) => window.__dartisanLive && window.__dartisanLive.count === n,
        initial + i,
        { timeout: 6000 },
      );
    }
    // One decrement to prove both directions.
    await page.click(DECR);
    await page.waitForFunction(
      (n) => window.__dartisanLive && window.__dartisanLive.count === n,
      initial + 2,
      { timeout: 6000 },
    );

    const finalCount = Number(await page.textContent('#live-count'));
    await page.screenshot({ path: 'live_result.png' });
    const result = {
      ok: finalCount === initial + 2,
      initial,
      afterThreeIncrAndOneDecr: finalCount,
      expected: initial + 2,
      lastState: await page.evaluate(() => window.__dartisanLive),
      transport: 'WebTransport over HTTP/3',
    };
    console.log(JSON.stringify(result, null, 2));
    process.exit(result.ok ? 0 : 1);
  } finally {
    await browser.close();
  }
})();
