# 09 — Performance

## Targets (reference hardware, Linux, TLS on)

These are initial objectives to validate the architecture; refine after Phase 1
baselining.

| Workload | Metric | Target |
| --- | --- | --- |
| Static small file (1 KB), HTTPS/1.1 | Requests/sec/core | ≥ 60% of nginx on same box |
| Static large file (1 MB), HTTPS/1.1 | Throughput | Line-rate / disk-bound, zero-copy |
| Reverse proxy (keep-alive) | Added p99 latency vs direct | ≤ 1 ms |
| TLS 1.3 handshakes | Handshakes/sec/core | ≥ 50% of nginx |
| HTTP/3 small file | Requests/sec/core | Within target factor of HTTPS/1.1 |
| Idle memory | Resident per worker | Low, bounded |
| 24h soak | Memory growth | ~0 (no leaks) |

Pass criteria are ratios to nginx on identical hardware, measured with the same
tools, not absolute numbers.

## Measured baseline — 2026-10-22 (WSL2 Ubuntu 24.04, ext4, loopback, `wrk`)

Harness: `tool/bench_static.sh`, `tool/bench_cache.sh` (`wrk`, 4 workers each,
access logging off on both). Loopback inflates absolute numbers — read the
**"× faster"** column, not the raw rates.

**TL;DR**
- Serving **static files?** → use nginx (it's ~45–65× faster). dart-apache isn't
  built to beat C + `sendfile`; put it behind nginx/a CDN for pure static.
- Serving **cacheable dynamic (PHP)?** → dart-apache's `--cache` is **~176×
  faster** than re-running PHP every request (and 166× lower latency).

### Static files — dart-apache vs nginx (same file, same `wrk` run)

| File size | nginx | dart-apache | Result |
| --- | ---: | ---: | --- |
| 1 KiB | **948k** req/s · 83 µs | 20k req/s · 3.2 ms | 🔴 nginx **~47× faster** |
| 100 KiB | **958k** req/s · 60 µs | 15k req/s · 4.4 ms | 🔴 nginx **~65× faster** |

### Static files — three-way vs Apache httpd (`tool/bench_apache.sh`, same `wrk` run)

Apache 2.4.58 **event MPM**, 4 procs × 64 threads, access log off — apples to
apples with nginx and dart-apache. Loopback rates are noisy run-to-run; the
**within-run ratios** are the signal:

| File size | nginx | Apache httpd | dart-apache | dart vs Apache |
| --- | ---: | ---: | ---: | --- |
| 1 KiB | ~713k req/s | **~95k** req/s · 0.8 ms | ~19k req/s · 3.3 ms | 🔴 Apache **~5× faster** |
| 100 KiB | ~250k req/s | **~60k** req/s · 1.1 ms | ~14k req/s · 4.7 ms | 🔴 Apache **~4.4× faster** |

**The honest read on Apache:** it's a *far* friendlier opponent than nginx —
~5× ahead on static, not ~47×. And **our cache HIT path (~130k req/s) beats
Apache's static serving (~95k)** outright, so for hot files routed through
`--cache` we're already past httpd.

### Dynamic PHP — cache OFF vs ON (same endpoint, same dart-apache)

| Mode | Throughput | Latency | vs. OFF |
| --- | ---: | ---: | --- |
| OFF — php-cgi every request | 740 req/s | 21.6 ms | baseline |
| ON — `--cache` (`X-Cache: HIT`) | **130k** req/s | **130 µs** | 🟢 **~176× faster** |

### App logic — PHP vs compiled in-process Dart (`tool/bench_php_vs_dart.sh`, `tool/bench_fpm_vs_dart.sh`)

Same server, **same endpoints**: the PHP file (`*.php`) vs the native Dart
handler (`/parity/*`, AOT-compiled). The parity app serves both, so only the
execution model differs. PHP measured two ways — `php-cgi` (fork per request)
and `php-fpm` (persistent pool, the modern setup).

| Endpoint | php-cgi | php-fpm | Compiled Dart (in-process) |
| --- | ---: | ---: | ---: |
| index (HTML) | 425 req/s · 75 ms | 21,085 req/s · 1.6 ms | **171,240** req/s · 198 µs |
| cacheable (text) | 643 req/s · 50 ms | 18,370 req/s · 2.2 ms | **146,510** req/s · 267 µs |
| fc (JSON) | 631 req/s · 51 ms | 26,461 req/s · 1.2 ms | **158,409** req/s · 231 µs |

**Dart vs php-cgi:** ~250–365× faster. **Dart vs php-fpm:** 🟢 **~6–8× faster**
(and ~6–11× lower latency).

**Honest read:**
- `php-cgi` is slow because it **forks an interpreter per request** (CGI) —
  that's the bulk of the 250×+ gap, not the app logic. `php-fpm` (a warm pool)
  is **~30–50× faster than php-cgi**, so compare modern PHP against `php-fpm`.
- Against `php-fpm`, compiled in-process Dart is still **~6–8× faster** — the
  remaining gap is the **FastCGI process hop + interpreter overhead** vs native
  code running in the serving isolate (no IPC, no re-parse).
- Takeaway: for hot dynamic paths, **native Dart handlers win clearly even vs
  modern PHP**; if you stay on PHP, use `php-fpm` (not `php-cgi`) and lean on
  `--cache`.

### What the numbers say

- **Raw static is nginx's game** — hand-tuned C + zero-copy `sendfile` vs
  `dart:io`'s `HttpServer`. Not a close race; don't pitch dart-apache as a
  static speed demon.
- **The built-in cache is the headline** — it makes slow dynamic content fast
  (740 → 130k req/s), in-process, no sidecar. This is the `fastcgi_cache` win.
- **Room on the static path** — a cache HIT (~130k req/s) is ~6× faster than
  dart-apache's *own* static serving (~20k), because the static path pays a
  `stat()` + ETag + gzip check per request. Optimizing it could lift static
  toward that ~130k ceiling.
- **HTTP/3 + WebTransport**: WT is ~40–50% cheaper per request than
  fetch-over-h3 (see [15-webtransport-hardening-plan.md](15-webtransport-hardening-plan.md)).

## Design levers

- **Shared-nothing workers** per core (see [03-architecture.md](03-architecture.md))
  for linear scaling and no lock contention.
- **Zero-copy** static sends (`sendfile`) via FFI; avoid user-space copies.
- **Buffer pooling** and reuse to cut GC pressure on hot paths.
- **Back-pressure** end to end so memory stays bounded under load.
- **Connection & FD caching** for static and upstream paths.
- **HPACK/QPACK** reuse and header object pooling.
- **Minimal allocations** in parse/route; precompiled route matchers.

## Measurement methodology

- **Load tools**: `wrk`/`wrk2` (constant-rate for latency), `h2load` (h3),
  `vegeta`, and `quic-interop-runner` clients for h3.
- **Profilers**: Dart DevTools CPU/alloc profiler; OS tools (`perf`, `bpftrace`)
  for syscalls and FFI boundaries.
- **Flame graphs** per release to catch regressions.
- **Event-loop lag** metric as an early saturation signal.

## Benchmark harness (CI)

- Reproducible benchmark environment (pinned kernel/NIC settings, CPU pinning).
- Automated runs on a schedule and on performance-labeled PRs.
- Store results over time; **fail CI on regression** beyond a threshold.
- Compare against a pinned nginx baseline for context.

## Tuning knobs (exposed in config)

- Worker count, accept queue/backlog sizes.
- Keep-alive timeouts and max requests per connection.
- h3 window sizes and max concurrent streams.
- Buffer sizes and pool limits.
- UDP socket buffer sizes, GSO/GRO toggles, pacing (h3).
- Compression level/min-size thresholds.

## Known cost centers to watch

- **FFI boundary** (QUIC, sendfile): minimize crossings, batch work, reuse
  native buffers.
- **TLS handshake CPU**: session resumption, ticket reuse, hardware AES.
- **GC pauses**: pooling and streaming to keep allocations flat under load.

## WebTransport vs fetch (Phase 2 benchmark)

Measured with [`tool/browser-h3-test/bench_wt_vs_fetch.js`](../tool/browser-h3-test/bench_wt_vs_fetch.js):
Edge over HTTP/3 to the server on **loopback** (RTT ≈ 0, so this isolates
per-request CPU/framing overhead, not network). 434-byte JSON payload, 200
sequential round-trips + a 15-wide concurrent burst. WT = a bidi-stream echo;
fetch = a `POST` to a same-size static file. Both ride the same warm QUIC
connection.

| Metric | WebTransport | fetch (HTTP/3) | WT vs fetch |
| --- | --- | --- | --- |
| seq p50 | ~2.5–2.8 ms | ~5.1–5.8 ms | **~−51%** |
| seq p95 | ~4.8–6.0 ms | ~7.3–9.8 ms | ~−35–39% |
| burst×15 p50 | ~23–28 ms | ~47–54 ms | **~−48–50%** |

**Finding:** WebTransport is reproducibly **~40–50 % cheaper per request** than
`fetch` over HTTP/3. A Livewire update carries a small JSON body, so the HTTP/3
request/response machinery (QPACK encode/decode, HEADERS/DATA framing, header
processing) is a large fraction of the cost that WT's raw bidi stream skips. On
a real network the absolute latency is dominated by RTT (both pay ~1 RTT), so
the *relative* win shrinks — but the CPU saving is real and improves server
throughput and high-frequency interactivity. **Decision gate: proceed.**

### Critical finding surfaced by the benchmark

The run initially **stalled after ~16 requests**: the server advertised
`initial_max_streams_bidi = 16` and the vendored QUIC **does not emit
`MAX_STREAMS` to replenish credit** as streams close. Every request — WT bidi
*and* HTTP/3 fetch (an HTTP/3 request is itself a client bidi stream) — consumes
one unit, so both paths exhausted the budget and blocked. Mitigated by raising
the initial grant to 65 536 (ample for a session). The **real fixes are Phase 3**:
(1) emit `MAX_STREAMS_BIDI/UNI` as peer streams close (RFC 9000 §4.6), and
(2) collect fully-closed streams from `Connection._streams` so state doesn't grow
with cumulative stream count. A long-lived "new bidi stream per update" design
needs both; an alternative is reusing a persistent stream with message framing.

