// Phase 2 benchmark: WebTransport bidi round-trip vs native fetch, both on the
// same warm HTTP/3 connection, so the comparison isolates transport overhead
// (no PHP in the loop — WT echoes the payload; fetch POSTs to a static file of
// the same size). Reports p50/p95/mean for sequential and a concurrent burst.
//
// Start the server in echo mode (serves static + WT echo, no bridge):
//   dart run bin/dart_apache.dart --root=./public --port=8443 --http3 \
//     --tls-cert=build/cert.pem --tls-key=build/key.pem --workers=1 --wt-path=/wt
//
//   node bench_wt_vs_fetch.js --port 8443 --cert ../../build/cert.pem --n 300 --burst 25
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
const N = parseInt(arg('n', '300'), 10);
const BURST = parseInt(arg('burst', '25'), 10);
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
      const [wtBase, fetchUrl, N, BURST] = args;
      function timeout(ms) {
        return new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), ms));
      }
      function stats(t) {
        if (!t.length) return { n: 0, p50: 0, p95: 0, p99: 0, mean: 0, min: 0, max: 0 };
        t = t.slice().sort((a, b) => a - b);
        const q = (p) => t[Math.min(t.length - 1, Math.floor(t.length * p))];
        return {
          n: t.length,
          p50: +q(0.5).toFixed(3),
          p95: +q(0.95).toFixed(3),
          p99: +q(0.99).toFixed(3),
          mean: +(t.reduce((a, b) => a + b, 0) / t.length).toFixed(3),
          min: +t[0].toFixed(3),
          max: +t[t.length - 1].toFixed(3),
        };
      }
      const payload = new TextEncoder().encode(JSON.stringify({ c: 'counter', m: 'inc', pad: 'y'.repeat(400) }));

      const wt = new WebTransport(wtBase);
      await Promise.race([wt.ready, timeout(8000)]);

      async function wtRT() {
        const s = await wt.createBidirectionalStream();
        const w = s.writable.getWriter();
        await w.write(payload);
        await w.close();
        const r = s.readable.getReader();
        for (;;) { const c = await r.read(); if (c.done) break; }
      }
      async function fetchRT() {
        const res = await fetch(fetchUrl, { method: 'POST', body: payload, cache: 'no-store' });
        await res.arrayBuffer();
      }

      // Measure one call; return latency ms, or null on failure/timeout.
      async function timed(fn) {
        const s = performance.now();
        try { await Promise.race([fn(), timeout(5000)]); return performance.now() - s; }
        catch (e) { return null; }
      }

      // Warmup (tolerant).
      for (let i = 0; i < 10; i++) { await timed(wtRT); await timed(fetchRT); }

      // Sequential latency, tolerating occasional failures.
      const wtSeq = []; let wtErr = 0;
      for (let i = 0; i < N; i++) { const t = await timed(wtRT); if (t === null) wtErr++; else wtSeq.push(t); }
      const fSeq = []; let fErr = 0;
      for (let i = 0; i < N; i++) { const t = await timed(fetchRT); if (t === null) fErr++; else fSeq.push(t); }

      // Concurrent burst: wall time for BURST in flight at once (tail matters).
      async function burst(fn) {
        const s = performance.now();
        const r = await Promise.allSettled(
          Array.from({ length: BURST }, () => Promise.race([fn(), timeout(8000)])),
        );
        const fails = r.filter((x) => x.status === 'rejected').length;
        return { ms: performance.now() - s, fails };
      }
      const wtBurst = []; let wtBurstErr = 0;
      const fBurst = []; let fBurstErr = 0;
      const burstRounds = BURST > 0 ? 15 : 0;
      for (let i = 0; i < burstRounds; i++) {
        const a = await burst(wtRT); wtBurst.push(a.ms); wtBurstErr += a.fails;
        const b = await burst(fetchRT); fBurst.push(b.ms); fBurstErr += b.fails;
      }

      wt.close();
      return {
        payloadBytes: payload.length,
        seq: { wt: stats(wtSeq), fetch: stats(fSeq), wtErrors: wtErr, fetchErrors: fErr },
        burst: {
          size: BURST, wt: stats(wtBurst), fetch: stats(fBurst),
          wtErrors: wtBurstErr, fetchErrors: fBurstErr,
        },
      };
    }, [`https://${origin}/wt`, `https://${origin}/bench.txt`, N, BURST]);

    const r = result;
    const d = (a, b) => `${(((a - b) / b) * 100).toFixed(1)}%`;
    console.log(JSON.stringify(result, null, 2));
    console.log('\n--- summary (lower is better) ---');
    console.log(`payload: ${r.payloadBytes}B   iterations: ${N}`);
    console.log(`seq ok:   WT ${r.seq.wt.n}/${N} (err ${r.seq.wtErrors})   fetch ${r.seq.fetch.n}/${N} (err ${r.seq.fetchErrors})`);
    console.log(`seq p50:  WT ${r.seq.wt.p50}ms  vs fetch ${r.seq.fetch.p50}ms   (WT ${d(r.seq.wt.p50, r.seq.fetch.p50)} vs fetch)`);
    console.log(`seq p95:  WT ${r.seq.wt.p95}ms  vs fetch ${r.seq.fetch.p95}ms   (WT ${d(r.seq.wt.p95, r.seq.fetch.p95)} vs fetch)`);
    console.log(`burst x${r.burst.size} p50: WT ${r.burst.wt.p50}ms vs fetch ${r.burst.fetch.p50}ms  (WT ${d(r.burst.wt.p50, r.burst.fetch.p50)} vs fetch)  [err WT ${r.burst.wtErrors} / fetch ${r.burst.fetchErrors}]`);
    process.exit(0);
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error('ERR', e.message);
  process.exit(1);
});
