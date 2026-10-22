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

Harness: `tool/bench_static.sh` and `tool/bench_cache.sh`. `wrk -t4 -c<N> -d<T>`,
4 workers each, access logging off on both servers (nginx `access_log off`,
dart-apache `--no-access-log`). Loopback/WSL inflates nginx's small-file numbers
(near loopback-limited); treat these as **ratios**, not hardware limits.

| Scenario (4 threads / 64 conns) | req/s | avg latency |
| --- | ---: | ---: |
| **nginx** — static 1 KiB | ~948,000 | 83 µs |
| **nginx** — static 100 KiB | ~958,000 | 60 µs |
| **dart-apache** — static 1 KiB | ~20,200 | 3.2 ms |
| **dart-apache** — static 100 KiB | ~14,600 | 4.4 ms |

| PHP endpoint (4 threads / 16 conns) | req/s | avg latency | |
| --- | ---: | ---: | --- |
| **dart-apache** — php-cgi, **no cache** | ~740 | 21.6 ms | spawns php-cgi/req |
| **dart-apache** — php-cgi, **`--cache`** | ~129,900 | 130 µs | `X-Cache: HIT` |

**Honest reading:**
- **Raw static is nginx's game.** nginx is ~45× faster on small static files —
  hand-tuned C + `sendfile`/zero-copy vs `dart:io`'s `HttpServer`. dart-apache
  is **not** a static-file speed demon; front it with nginx/a CDN for that, or
  use the cache.
- **The built-in cache is the dynamic win.** `--cache` turns a cacheable PHP
  response from **740 → ~130,000 req/s (~176×)** and drops p-avg latency from
  21.6 ms to 130 µs — the `fastcgi_cache` value, in-process.
- **In-memory serving is fast.** The cache-HIT path (~130k req/s) is ~6× faster
  than dart-apache's own static-file path, which pays a `stat()` + ETag + gzip
  check per request — a known optimization target for the static hot path.
- WebTransport/HTTP-3 numbers (WT ~40–50% cheaper/request than fetch-over-h3)
  are in the hardening work; see [15-webtransport-hardening-plan.md](15-webtransport-hardening-plan.md).

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

