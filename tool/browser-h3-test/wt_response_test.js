// Phase 1 acceptance: the WebTransport bridge propagates the real response
// status + headers (not a hard-coded 200). A Livewire-style fetch whose handler
// returns 419 must surface as response.status === 419 with its custom header.
//
// Start the server (front controller routes any /livewire-*/update to the 419 endpoint):
//   dart run bin/dart_apache.dart --root=./public --port=8443 --http3 \
//     --tls-cert=build/cert.pem --tls-key=build/key.pem --workers=1 \
//     --wt-path=/wt --wt-bridge-path=/status_echo.php --front-controller=/status_echo.php
//
//   node wt_response_test.js --port 8443 --cert ../../build/cert.pem
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
    await page.goto(`https://${origin}/app/status-demo.html`, {
      waitUntil: 'load',
      timeout: 15000,
    });
    await page.waitForFunction(
      () => document.getElementById('out').textContent.includes('status'),
      { timeout: 10000 },
    );
    const out = JSON.parse(await page.textContent('#out'));
    console.log(JSON.stringify(out, null, 2));
    const pass =
      out.status === 419 &&
      out.demoHeader === 'demo-value' &&
      JSON.parse(out.body).code === 419;
    process.exit(pass ? 0 : 1);
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error('ERR', e.message);
  process.exit(1);
});
