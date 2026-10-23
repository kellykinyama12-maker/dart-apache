// Drives the Dartisan live poll over HTTP/3 + WebTransport in Edge: votes via
// data-live-click="vote" + data-live-option (-> payloadFrom), verifying tallies
// through window.__dartisanLive. Start the server first:
//   dart run example/poll_app.dart --root=./public --port=8443 --http3 \
//       --wt-path=/wt --tls-cert=build/cert.pem --tls-key=build/key.pem
//   node poll_wt_test.js --port 8443 --cert ../../build/cert.pem
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
    await page.waitForSelector('[data-live-component="poll"]', { timeout: 10000 });

    async function voteAndWait(option, expected) {
      await page.click(`button[data-live-option="${option}"]`);
      await page.waitForFunction(
        (o) => window.__dartisanLive && window.__dartisanLive.votes[o.option] === o.n,
        { option, n: expected }, { timeout: 6000 });
    }

    await voteAndWait('Dart', 1);
    await voteAndWait('Dart', 2);
    await voteAndWait('PHP', 1);

    const s = await page.evaluate(() => window.__dartisanLive);
    const ok = s.votes.Dart === 2 && s.votes.PHP === 1 && s.votes.Go === 0;
    console.log(JSON.stringify({ ok, votes: s.votes, transport: 'WebTransport/HTTP3' }, null, 2));
    process.exit(ok ? 0 : 1);
  } finally {
    await browser.close();
  }
})();
