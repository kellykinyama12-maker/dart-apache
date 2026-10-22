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
