// Verifies the NATIVE in-process WebTransport handler (DartApp.wt): a bidi
// message is echoed back on the same stream with a "wt-native:" marker,
// proving the Dart handler path (not PHP bridge / echo) served it.
//
//   node wt_native_test.js --port 8443 --cert ../../build/cert.pem --path /wt
//
// Start the example embedder with a native WT handler:
//   dart run example/dart_app.dart --root=./public --port=8443 --http3 \
//     --tls-cert=build/cert.pem --tls-key=build/key.pem --workers=1 --wt-path=/wt
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
const WTPATH = arg('path', '/wt');
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
    await page.goto(`https://${origin}/`, { waitUntil: 'load', timeout: 15000 });

    const result = await page.evaluate(async (url) => {
      function timeout(ms) {
        return new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), ms));
      }
      const wt = new WebTransport(url);
      await Promise.race([wt.ready, timeout(8000)]);

      const bidi = await wt.createBidirectionalStream();
      const w = bidi.writable.getWriter();
      await w.write(new TextEncoder().encode('client-bidi-hello'));
      await w.close();
      const r = bidi.readable.getReader();
      let reply = '';
      for (;;) {
        const chunk = await Promise.race([r.read(), timeout(8000)]);
        if (chunk.done) break;
        reply += new TextDecoder().decode(chunk.value);
      }
      return reply;
    }, `https://${origin}${WTPATH}`);

    console.log(JSON.stringify({ reply: result }, null, 2));
    const pass = result === 'wt-native:/wt:client-bidi-hello';
    process.exit(pass ? 0 : 1);
  } finally {
    await browser.close();
  }
})();
