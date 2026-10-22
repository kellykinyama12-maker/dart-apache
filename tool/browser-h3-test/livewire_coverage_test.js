// Coverage: a real Livewire form over WebTransport — exercises wire:model,
// server-side validation (error bag re-rendered over WT), and a successful save.
// Depends on the Phase 1 response contract (the validation re-render + 200 must
// travel back faithfully).
//
// Start the server against the Laravel app:
//   dart run bin/dart_apache.dart --root=C:\projects\webserver\livewire-wt\public \
//     --port=8443 --http3 --tls-cert=build/cert.pem --tls-key=build/key.pem \
//     --workers=1 --wt-path=/wt --wt-bridge-path=/livewire/update \
//     --front-controller=/index.php --wt-ticket-path=/wt-ticket
//
//   node livewire_coverage_test.js --port 8443 --cert ../../build/cert.pem
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
    await page.goto(`https://${origin}/form`, { waitUntil: 'load', timeout: 20000 });
    await page.waitForSelector('#save', { timeout: 15000 });
    await page.waitForFunction(() => window.Livewire !== undefined, { timeout: 15000 });

    // 1) Submit empty → server-side validation errors re-rendered over WT.
    await page.click('#save');
    await page.waitForSelector('#err-name', { timeout: 15000 });
    const errName = (await page.textContent('#err-name')).trim();
    const errEmail = (await page.textContent('#err-email').catch(() => '')) || '';

    // 2) Invalid email only → name ok, email error.
    await page.fill('#name', 'Ada');
    await page.fill('#email', 'not-an-email');
    await page.click('#save');
    await page.waitForFunction(
      () => !document.getElementById('err-name') && !!document.getElementById('err-email'),
      { timeout: 15000 },
    );

    // 3) Valid → saved.
    await page.fill('#email', 'ada@example.com');
    await page.click('#save');
    await page.waitForSelector('#saved', { timeout: 15000 });
    const saved = (await page.textContent('#saved')).trim();

    const wtUsed = await page.evaluate(() => window.__livewireWtUsed || 0);
    const result = { errName, errEmailPresent: errEmail.length > 0, saved, wtUsed, errors };
    console.log(JSON.stringify(result, null, 2));
    const pass =
      /required/i.test(errName) &&
      /ada@example\.com/.test(saved) &&
      /Ada/.test(saved) &&
      wtUsed >= 3 &&
      errors.length === 0;
    process.exit(pass ? 0 : 1);
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error('ERR', e.message);
  process.exit(1);
});
