// Verifies the opaque WebTransport session-ticket flow: the browser fetches a
// ticket over HTTPS (where cookies are sent), then carries ONLY the ticket over
// WebTransport. The server decrypts it and forwards the recovered session cookie
// to PHP — the cookie never travels in cleartext over WT.
//
// Start the server with the ticket + bridge + echo endpoints:
//   dart run bin/dart_apache.dart --root=./public --port=8443 --http3 \
//     --tls-cert=build/cert.pem --tls-key=build/key.pem --workers=1 \
//     --wt-path=/wt --wt-bridge-path=/csrf_echo.php --wt-ticket-path=/wt-ticket
//
//   node wt_ticket_test.js --port 8443 --cert ../../build/cert.pem --path /wt
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

    const result = await page.evaluate(async (args) => {
      const [wtUrl, ticketUrl] = args;
      const enc = new TextEncoder();
      const dec = new TextDecoder();
      function timeout(ms) {
        return new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), ms));
      }
      // Stand in for the (normally HttpOnly) session cookie the browser holds.
      document.cookie = 'laravel_session=sess-secret; path=/';
      document.cookie = 'XSRF-TOKEN=xtok-123; path=/';
      try {
        // 1) Fetch a ticket over HTTPS — cookies are sent automatically.
        const tj = await (await fetch(ticketUrl, { credentials: 'same-origin' })).json();
        const ticket = tj.ticket;
        var cookieSet = document.cookie;

        const wt = new WebTransport(wtUrl);
        await Promise.race([wt.ready, timeout(8000)]);
        const uds = wt.incomingUnidirectionalStreams.getReader();
        const g = await Promise.race([uds.read(), timeout(8000)]);
        const gr = g.value.getReader();
        for (;;) { const c = await Promise.race([gr.read(), timeout(8000)]); if (c.done) break; }

        async function roundtrip(preamble) {
          const s = await wt.createBidirectionalStream();
          const w = s.writable.getWriter();
          await w.write(enc.encode(preamble + JSON.stringify({ component: 'x' })));
          await w.close();
          const r = s.readable.getReader();
          let out = '';
          for (;;) { const c = await Promise.race([r.read(), timeout(8000)]); if (c.done) break; out += dec.decode(c.value); }
          return JSON.parse(out);
        }

        // 2) Carry ONLY the ticket over WT (no raw Cookie line).
        const viaTicket = await roundtrip('X-WT-Ticket: ' + ticket + '\r\n\r\n');
        // 3) A bogus ticket must recover no cookie.
        const viaBad = await roundtrip('X-WT-Ticket: not-a-real-ticket\r\n\r\n');

        wt.close();
        return { ok: true, ticketLen: (ticket || '').length, cookieSet, viaTicket, viaBad };
      } catch (e) {
        return { ok: false, error: String(e && e.message ? e.message : e) };
      }
    }, [`https://${origin}${WTPATH}`, `https://${origin}/wt-ticket`]);

    console.log(JSON.stringify(result, null, 2));
    const pass =
      result.ok &&
      result.ticketLen > 20 &&
      /laravel_session=sess-secret/.test(result.viaTicket.cookie || '') &&
      result.viaTicket.x_xsrf_token === 'xtok-123' &&
      (result.viaBad.cookie === null || result.viaBad.cookie === '');
    process.exit(pass ? 0 : 1);
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error('ERR', e.message);
  process.exit(1);
});
