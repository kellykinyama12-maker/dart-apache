// Verifies a real browser connects to dart-apache over HTTP/3 (QUIC).
//
// Uses playwright-core to drive an already-installed Edge or Chrome (no browser
// download). The self-signed dev certificate is accepted via certificate
// pinning: the cert's SPKI SHA-256 is passed to Chromium's
// --ignore-certificate-errors-spki-list. QUIC is forced on the origin so we
// test the h3 datapath directly.
//
// Usage:
//   npm install
//   node h3_test.js --port 8443 --cert ../../build/cert.pem [--no-force]
//
// Start the server first, e.g.:
//   dart run bin/dart_apache.dart --root=./public --port=8443 --http3 \
//     --tls-cert=build/cert.pem --tls-key=build/key.pem --workers=1
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
const FORCE = !process.argv.includes('--no-force');
const origin = `127.0.0.1:${PORT}`;

// SPKI pin = base64( SHA-256( DER SubjectPublicKeyInfo ) ).
function spkiPin(certPath) {
  const cert = new X509Certificate(fs.readFileSync(certPath));
  const der = cert.publicKey.export({ type: 'spki', format: 'der' });
  return createHash('sha256').update(der).digest('base64');
}

// First installed Chromium-family browser we can find.
function findBrowser() {
  const candidates = [
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
  ];
  return candidates.find((p) => fs.existsSync(p));
}

(async () => {
  const pin = spkiPin(CERT);
  const executablePath = findBrowser();
  if (!executablePath) throw new Error('no Edge/Chrome found');

  const args = [
    '--no-sandbox',
    '--enable-quic',
    `--ignore-certificate-errors-spki-list=${pin}`,
  ];
  if (FORCE) args.push(`--origin-to-force-quic-on=${origin}`);

  const browser = await chromium.launch({ executablePath, headless: true, args });
  try {
    const page = await browser.newPage();
    const resp = await page.goto(`https://${origin}/?name=Browser`, {
      waitUntil: 'load',
      timeout: 15000,
    });
    const nextHopProtocol = await page.evaluate(
      () => performance.getEntriesByType('navigation')[0].nextHopProtocol,
    );
    const h1 = await page.evaluate(
      () => (document.querySelector('h1') || {}).textContent || '',
    );
    const result = {
      forcedQuic: FORCE,
      spkiPin: pin,
      status: resp.status(),
      nextHopProtocol,
      altSvc: resp.headers()['alt-svc'] || '',
      h1,
    };
    console.log(JSON.stringify(result, null, 2));
    process.exit(nextHopProtocol === 'h3' || !FORCE ? 0 : 1);
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error('ERR', e.message);
  process.exit(1);
});
