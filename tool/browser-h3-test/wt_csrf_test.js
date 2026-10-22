// Verifies the WebTransport credential bridge: a message with an HTTP-style
// header preamble (X-CSRF-TOKEN / Cookie) is parsed by the server and forwarded
// to PHP, and the XSRF-TOKEN cookie is auto-derived into X-XSRF-TOKEN.
//
// Start the server pointing the bridge at the echo endpoint:
//   dart run bin/dart_apache.dart --root=./public --port=8443 --http3 \
//     --tls-cert=build/cert.pem --tls-key=build/key.pem --workers=1 \
//     --wt-path=/wt --wt-bridge-path=/csrf_echo.php
//
//   node wt_csrf_test.js --port 8443 --cert ../../build/cert.pem --path /wt
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
      const enc = new TextEncoder();
      const dec = new TextDecoder();
      function timeout(ms) {
        return new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), ms));
      }
      async function roundtrip(wt, bytes) {
        const s = await wt.createBidirectionalStream();
        const w = s.getWriter ? s.getWriter() : s.writable.getWriter();
        await w.write(bytes);
        await w.close();
        const r = s.readable.getReader();
        let out = '';
        for (;;) {
          const c = await Promise.race([r.read(), timeout(10000)]);
          if (c.done) break;
          out += dec.decode(c.value);
        }
        const i = out.indexOf('\r\n\r\n'); // strip the status/header envelope
        return JSON.parse(i >= 0 ? out.slice(i + 4) : out);
      }
      try {
        const wt = new WebTransport(url);
        await Promise.race([wt.ready, timeout(8000)]);
        // Drain greeting uni stream.
        const uds = wt.incomingUnidirectionalStreams.getReader();
        const g = await Promise.race([uds.read(), timeout(8000)]);
        const gr = g.value.getReader();
        for (;;) { const c = await Promise.race([gr.read(), timeout(8000)]); if (c.done) break; }

        // (1) Explicit CSRF token + cookie via preamble.
        const p1 =
          'X-CSRF-TOKEN: tok-12345\r\n' +
          'Cookie: XSRF-TOKEN=enc-abc; laravel_session=sess-xyz\r\n' +
          '\r\n';
        const explicit = await roundtrip(wt, enc.encode(p1 + JSON.stringify({ component: 'counter' })));

        // (2) Cookie only -> server derives X-XSRF-TOKEN from XSRF-TOKEN cookie.
        const p2 = 'Cookie: XSRF-TOKEN=derived%2Dtoken; laravel_session=sess2\r\n\r\n';
        const derived = await roundtrip(wt, enc.encode(p2 + JSON.stringify({ component: 'home' })));

        // (3) No preamble -> body passed through untouched (starts with '{').
        const plain = await roundtrip(wt, enc.encode(JSON.stringify({ component: 'plain' })));

        wt.close();
        return { ok: true, explicit, derived, plain };
      } catch (e) {
        return { ok: false, error: String(e && e.message ? e.message : e) };
      }
    }, `https://${origin}${WTPATH}`);

    console.log(JSON.stringify(result, null, 2));
    const pass =
      result.ok &&
      result.explicit.x_csrf_token === 'tok-12345' &&
      /laravel_session=sess-xyz/.test(result.explicit.cookie || '') &&
      JSON.parse(result.explicit.body).component === 'counter' &&
      result.derived.x_xsrf_token === 'derived-token' &&
      result.plain.cookie === null &&
      JSON.parse(result.plain.body).component === 'plain';
    process.exit(pass ? 0 : 1);
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error('ERR', e.message);
  process.exit(1);
});
