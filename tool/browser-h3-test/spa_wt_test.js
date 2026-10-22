// Loads the static SPA shell at a deep-link URL (exercising the server's SPA
// fallback) and confirms its in-page WebTransport bridge round-trip renders.
//   node spa_wt_test.js --port 8443 --cert ../../build/cert.pem
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
    // Deep link into the SPA: the server has no such file, so the SPA fallback
    // must serve /app/index.html, and the shell's script runs the WT round-trip.
    await page.goto(`https://${origin}/app/dashboard/live`, {
      waitUntil: 'load',
      timeout: 15000,
    });
    // Wait for the bridge output to arrive.
    await page.waitForFunction(
      () => document.getElementById('out').textContent.includes('webtransport'),
      { timeout: 10000 },
    );
    const route = await page.textContent('#route');
    const status = await page.textContent('#status');
    const out = await page.textContent('#out');
    const json = JSON.parse(out);
    console.log(JSON.stringify({ route, status, bridged: json }, null, 2));
    const pass =
      route === '/app/dashboard/live' &&
      /connected/.test(status) &&
      json.transport === 'webtransport' &&
      json.component === 'home';
    process.exit(pass ? 0 : 1);
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error('ERR', e.message);
  process.exit(1);
});
