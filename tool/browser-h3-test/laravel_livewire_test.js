// End-to-end: a real Laravel + Livewire counter, served by dart-apache over
// HTTP/3, whose component update travels over WebTransport (via the shim +
// bridge) instead of fetch. Proves the full stack.
//
// Start the server against the Laravel app first:
//   dart run bin/dart_apache.dart --root=C:\projects\webserver\livewire-wt\public \
//     --port=8443 --http3 --tls-cert=build/cert.pem --tls-key=build/key.pem \
//     --workers=1 --wt-path=/wt --wt-bridge-path=/livewire/update --front-controller=/index.php
//
//   node laravel_livewire_test.js --port 8443 --cert ../../build/cert.pem
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
    const errors = [];
    page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
    await page.goto(`https://${origin}/`, { waitUntil: 'load', timeout: 20000 });

    // Wait for Livewire to boot and the counter to be interactive.
    await page.waitForSelector('#inc', { timeout: 15000 });
    await page.waitForFunction(() => window.Livewire !== undefined, { timeout: 15000 });

    const before = await page.textContent('#count');

    // Click +1 twice; each click is a Livewire update that the shim routes
    // over WebTransport.
    await page.click('#inc');
    await page.waitForFunction(() => document.getElementById('count').textContent === '1', { timeout: 15000 });
    await page.click('#inc');
    await page.waitForFunction(() => document.getElementById('count').textContent === '2', { timeout: 15000 });

    const after = await page.textContent('#count');
    const wtUsed = await page.evaluate(() => window.__livewireWtUsed || 0);

    const result = { before, after, wtUsed, errors };
    console.log(JSON.stringify(result, null, 2));
    const pass = before === '0' && after === '2' && wtUsed >= 2;
    process.exit(pass ? 0 : 1);
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error('ERR', e.message);
  process.exit(1);
});
