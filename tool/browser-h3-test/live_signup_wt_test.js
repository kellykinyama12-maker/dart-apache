// Drives the Dartisan Live SIGNUP form over real HTTP/3 + WebTransport in Edge:
// an invalid email submit should round-trip a server-side validation error; a
// valid one should save. Proves the B1 validation round-trip end-to-end.
//   dart run example/live_app.dart --root=./public --port=8651 --http3 \
//     --wt-path=/wt --tls-cert=build/cert.pem --tls-key=build/key.pem
//   node live_signup_wt_test.js --port 8651 --cert ../../build/cert.pem
'use strict';

const fs = require('fs');
const { X509Certificate, createHash } = require('crypto');
const { chromium } = require('playwright-core');

function arg(name, def) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : def;
}

const PORT = arg('port', '8651');
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

    const FORM = '[data-live-component="signup"]';
    const EMAIL = `${FORM} input[name="email"]`;
    const SUBMIT = `${FORM} button[type="submit"]`;

    await page.goto(`https://${origin}/`, { waitUntil: 'load', timeout: 15000 });
    await page.waitForSelector(EMAIL, { timeout: 10000 });

    // 1) Invalid email -> server validation error round-trips back.
    await page.fill(EMAIL, 'not-an-email');
    await page.click(SUBMIT);
    await page.waitForFunction(() => {
      const s = window.__dartisanLive;
      return s && s.errors && s.errors.email;
    }, null, { timeout: 6000 });
    const errorShown = await page.evaluate(
      () => /valid email/i.test(document.querySelector('[data-live-component="signup"]').innerHTML));
    const inputPreserved = await page.inputValue(EMAIL);

    // 2) Valid email -> saved.
    await page.fill(EMAIL, 'ada@example.com');
    await page.click(SUBMIT);
    await page.waitForFunction(() => {
      const s = window.__dartisanLive;
      return s && s.saved === true;
    }, null, { timeout: 6000 });
    const savedShown = await page.evaluate(
      () => /Signed up/i.test(document.querySelector('[data-live-component="signup"]').innerHTML));

    const result = {
      ok: errorShown && inputPreserved === 'not-an-email' && savedShown,
      errorRoundTripped: errorShown,
      inputPreservedOnError: inputPreserved,
      savedOnValid: savedShown,
      transport: 'WebTransport over HTTP/3',
    };
    console.log(JSON.stringify(result, null, 2));
    process.exit(result.ok ? 0 : 1);
  } finally {
    await browser.close();
  }
})();
