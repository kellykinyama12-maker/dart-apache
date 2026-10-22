// Verifies the Livewire→WebTransport shim: a Livewire-style fetch('/livewire/update')
// is transparently rerouted over WebTransport to the bridge, which forwards the
// CSRF token to PHP. Run the server with the bridge pointed at the echo endpoint:
//   dart run bin/dart_apache.dart --root=./public --port=8443 --http3 \
//     --tls-cert=build/cert.pem --tls-key=build/key.pem --workers=1 \
//     --wt-path=/wt --wt-bridge-path=/csrf_echo.php
//
//   node lw_wt_test.js --port 8443 --cert ../../build/cert.pem
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
    await page.goto(`https://${origin}/app/lw-demo.html`, {
      waitUntil: 'load',
      timeout: 15000,
    });
    await page.waitForFunction(
      () => document.getElementById('out').textContent.includes('x_csrf_token'),
      { timeout: 10000 },
    );
    const out = JSON.parse(await page.textContent('#out'));
    console.log(JSON.stringify(out, null, 2));
    // The shim must have sent the request over WebTransport (method POST at the
    // bridge), forwarded the CSRF token from the fetch header, and preserved the
    // Livewire payload.
    const pass =
      out.method === 'POST' &&
      out.x_csrf_token === 'header-token-abc' &&
      out.x_requested_with === 'XMLHttpRequest' &&
      JSON.parse(out.body).component === 'counter';
    process.exit(pass ? 0 : 1);
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error('ERR', e.message);
  process.exit(1);
});
