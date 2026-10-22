// Verifies the Livewire-over-WebTransport bridge: a Livewire-shaped JSON
// request sent on a WT bidi stream is routed through the PHP pipeline and the
// JSON response comes back on the same stream. A datagram carrying the same
// request is bridged too (reply as a datagram when it fits).
//
// Start the server in bridge mode first:
//   dart run bin/dart_apache.dart --root=./public --port=8443 --http3 \
//     --tls-cert=build/cert.pem --tls-key=build/key.pem --workers=1 \
//     --wt-path=/wt --wt-bridge-path=/livewire.php
//
//   node wt_livewire_test.js --port 8443 --cert ../../build/cert.pem --path /wt
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
      const enc = new TextEncoder();
      const dec = new TextDecoder();
      try {
        const wt = new WebTransport(url);
        await Promise.race([wt.ready, timeout(8000)]);

        // Drain the server's greeting uni stream so later reads line up.
        const uds = wt.incomingUnidirectionalStreams.getReader();
        const greet = await Promise.race([uds.read(), timeout(8000)]);
        const gr = greet.value.getReader();
        for (;;) { const c = await Promise.race([gr.read(), timeout(8000)]); if (c.done) break; }

        // --- Bidi bridge: Livewire-shaped request -> PHP -> JSON response ---
        const req = { component: 'counter', message: 'increment', calls: [{ method: 'inc' }] };
        const bidi = await wt.createBidirectionalStream();
        const bw = bidi.writable.getWriter();
        await bw.write(enc.encode(JSON.stringify(req)));
        await bw.close();
        const br = bidi.readable.getReader();
        let raw = '';
        for (;;) {
          const c = await Promise.race([br.read(), timeout(10000)]);
          if (c.done) break;
          raw += dec.decode(c.value);
        }
        const bidiJson = JSON.parse(raw);

        // --- Datagram bridge: same request, reply as a datagram ---
        const dw = wt.datagrams.writable.getWriter();
        await dw.write(enc.encode(JSON.stringify({ component: 'ping', message: 'hi' })));
        const dr = wt.datagrams.readable.getReader();
        const dgRes = await Promise.race([dr.read(), timeout(8000)]);
        const dgJson = JSON.parse(dec.decode(dgRes.value));

        wt.close();
        return { ok: true, bidiJson, dgJson };
      } catch (e) {
        return { ok: false, error: String(e && e.message ? e.message : e) };
      }
    }, `https://${origin}${WTPATH}`);

    console.log(JSON.stringify(result, null, 2));
    const pass =
      result.ok &&
      result.bidiJson &&
      result.bidiJson.transport === 'webtransport' &&
      result.bidiJson.component === 'counter' &&
      /increment/.test(result.bidiJson.effects.html) &&
      result.dgJson &&
      result.dgJson.component === 'ping';
    process.exit(pass ? 0 : 1);
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error('ERR', e.message);
  process.exit(1);
});
