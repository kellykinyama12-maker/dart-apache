// Tests whether a real browser can open a WebTransport session to dart-apache
// over HTTP/3 and echo a datagram.
//
//   node wt_test.js --port 8443 --cert ../../build/cert.pem --path /wt
//
// Start the server with WebTransport enabled, e.g.:
//   dart run bin/dart_apache.dart --root=./public --port=8443 --http3 \
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
    // Load a trusted same-origin https page so WebTransport runs in a secure
    // context against our origin.
    await page.goto(`https://${origin}/`, { waitUntil: 'load', timeout: 15000 });

    const result = await page.evaluate(async (url) => {
      function timeout(ms) {
        return new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), ms));
      }
      try {
        const wt = new WebTransport(url);
        await Promise.race([wt.ready, timeout(8000)]);

        // Datagram echo round-trip.
        const writer = wt.datagrams.writable.getWriter();
        await writer.write(new TextEncoder().encode('ping-webtransport'));
        const dgReader = wt.datagrams.readable.getReader();
        const dg = await Promise.race([dgReader.read(), timeout(8000)]);
        const echoed = new TextDecoder().decode(dg.value);

        // Server-initiated unidirectional stream (greeting).
        const uds = wt.incomingUnidirectionalStreams.getReader();
        const sres = await Promise.race([uds.read(), timeout(8000)]);
        const sreader = sres.value.getReader();
        let greeting = '';
        for (;;) {
          const chunk = await Promise.race([sreader.read(), timeout(8000)]);
          if (chunk.done) break;
          greeting += new TextDecoder().decode(chunk.value);
        }

        // Client-initiated unidirectional stream: the browser opens an
        // outbound WT uni stream and writes to it; the server reads it
        // and echoes the payload back on a fresh server-initiated uni
        // stream (the next item from incomingUnidirectionalStreams).
        const outUni = await wt.createUnidirectionalStream();
        const uw = outUni.getWriter();
        await uw.write(new TextEncoder().encode('client-uni-hello'));
        await uw.close();

        const sres2 = await Promise.race([uds.read(), timeout(8000)]);
        const sreader2 = sres2.value.getReader();
        let echoUni = '';
        for (;;) {
          const chunk = await Promise.race([sreader2.read(), timeout(8000)]);
          if (chunk.done) break;
          echoUni += new TextDecoder().decode(chunk.value);
        }

        // Client-initiated bidirectional stream: the browser opens a WT
        // bidi stream, writes to it, and the server echoes the payload
        // back on the same stream (observed on its readable side).
        const bidi = await wt.createBidirectionalStream();
        const bw = bidi.writable.getWriter();
        await bw.write(new TextEncoder().encode('client-bidi-hello'));
        await bw.close();
        const br = bidi.readable.getReader();
        let echoBidi = '';
        for (;;) {
          const chunk = await Promise.race([br.read(), timeout(8000)]);
          if (chunk.done) break;
          echoBidi += new TextDecoder().decode(chunk.value);
        }

        // Large (multi-frame) bidi payload: exercises stream reassembly and
        // the message-framed echo (one FIN, not per-chunk). 64 KiB spans many
        // QUIC STREAM frames.
        const bigLen = 64 * 1024;
        const big = new Uint8Array(bigLen);
        for (let i = 0; i < bigLen; i++) big[i] = 65 + (i % 26);
        const bidi2 = await wt.createBidirectionalStream();
        const bw2 = bidi2.writable.getWriter();
        await bw2.write(big);
        await bw2.close();
        const br2 = bidi2.readable.getReader();
        let got = 0;
        let intact = true;
        for (;;) {
          const chunk = await Promise.race([br2.read(), timeout(10000)]);
          if (chunk.done) break;
          for (let i = 0; i < chunk.value.length; i++) {
            if (chunk.value[i] !== 65 + ((got + i) % 26)) { intact = false; break; }
          }
          got += chunk.value.length;
        }

        wt.close();
        return {
          ok: true,
          echoed,
          greeting: greeting.trim(),
          echoUni,
          echoBidi,
          bigEcho: { bytes: got, expected: bigLen, intact },
        };
      } catch (e) {
        return { ok: false, error: String(e && e.message ? e.message : e) };
      }
    }, `https://${origin}${WTPATH}`);

    console.log(JSON.stringify(result, null, 2));
    process.exit(result.ok ? 0 : 1);
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error('ERR', e.message);
  process.exit(1);
});
