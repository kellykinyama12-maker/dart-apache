# 18 — Pitch: dart-apache vs. Apache & nginx

**One line:** Apache and nginx serve the web of 2010 (request → response over
HTTP/1.1). **dart-apache is HTTP/3-first**, so WebTransport and low-latency
real-time are the *native* path — not a bolt-on — while static files and PHP
still "just work."

## Pros at a glance

| What | Why it matters | Verdict |
|---|---|---|
| HTTP/3 + WebTransport in **pure Dart** | No OpenSSL / `quiche.so` / FFI; streams + datagrams out of the box | 🟢 incumbents can't match easily |
| **Livewire over WebTransport** (drop-in) | Real-time Laravel with no WebSocket server/rewrite | 🟢 unique wedge (~40–50% cheaper/req) |
| **One binary: embed *or* serve** | Same Dart handler over h3 + h1, no sidecar | 🟢 unique |
| `--cache` on dynamic content | RFC 9111 shared cache + stale-while-revalidate | 🟢 ~176× faster (740→130k req/s) |
| Standards-correct static serving | ETag/304/ranges/gzip/MIME/method-gating | ⚪ on par with nginx |
| Raw static throughput | C + `sendfile` wins | 🔴 ~47–65× slower than nginx |

**Reach for it** when you want modern transport + an embedded Dart app server in
one pure-Dart binary. **Keep nginx** when you just need to blast static files.

## The wedge: a killer app the incumbents can't do easily

**Livewire over WebTransport.** A real Laravel 13 + Livewire 4 app runs its
component updates over an HTTP/3 WebTransport stream with a **drop-in
`@webtransport` Blade tag** — no WebSocket server, no Reverb/Pusher, no app
rewrite. It falls back to `fetch` automatically. Apache and nginx can proxy
WebSockets, but neither gives you *Livewire-over-WebTransport as a one-line
install*.

- Verified live in Edge over real HTTP/3; the shim degrades gracefully with
  zero app changes.
- Measured **~40–50% cheaper per request** than fetch-over-h3 (sequential p50
  **2.5 ms vs 5.1 ms**; a 15-request burst **23 ms vs 47 ms**).

## Parity — where it already matches the incumbents

| Capability | Apache | nginx | dart-apache |
|---|:--:|:--:|:--:|
| Static (types, ETag, conditional 304, byte ranges, HEAD) | ✅ | ✅ | ✅ |
| Transparent gzip (`Vary`, size threshold) | ✅ | ✅ | ✅ |
| Method semantics (`OPTIONS`/`405` + `Allow`, dir `301`) | ✅ | ✅ | ✅ |
| PHP via php-cgi **and** FastCGI/php-fpm | ✅ | ✅ | ✅ |
| Reverse proxy + load balancing + health checks | ✅ | ✅ | ✅ |
| TLS 1.3, SNI, front-controller (`try_files`) | ✅ | ✅ | ✅ |
| Multi-core (worker-per-core, shared socket) | ✅ | ✅ | ✅ (isolates + `SO_REUSEPORT`) |
| Zero-downtime reload | ✅ | ✅ | ✅ (`SIGHUP`) |

## Differentiators — what it does that they don't

- **HTTP/3 + WebTransport as first-class**, with automatic `Alt-Svc` upgrade
  from HTTP/1.1.
- **Native in-process Dart handlers** alongside PHP — no FFI, no subprocess, no
  second socket. The *same* handler serves over h3 and h1. Optional Shelf
  bridge for `shelf_router` + middleware.
- **Native WebTransport session handler** (datagrams + uni/bidi streams) for
  Dart real-time apps — again, no sidecar.
- **Micro-cache for dynamic content** (`--cache`): an RFC 9111 in-memory
  response cache for PHP/proxy `GET`s (honors `Cache-Control`/`Expires`/`Vary`,
  `HEAD`-from-`GET`, `no-cache` bypass, and RFC 5861 **stale-while-revalidate**
  — serve stale instantly, refresh in the background) — the
  `fastcgi_cache`/`proxy_cache` win, built in.
- **One language, edge-to-app**, and a **single static binary**
  (cross-compiles to a standalone Linux ELF — no modules to assemble, no
  php-fpm orchestration required for the h1/h3 core).
- **Security that's built, not configured:** chain-to-root X.509 validation,
  single-use 0-RTT anti-replay, HttpOnly-safe WebTransport session tickets,
  fuzzed wire parsers, and hidden-dotfile denial (`.env`/`.git` never served).

## Honest gaps — where Apache/nginx still win

- **Maturity:** they're battle-tested over decades; our QUIC stack is pre-1.0
  and h3-first is novel. Run behind a trusted terminator until the PKI/soak
  items fully bake.
- **Ecosystem & config:** no `.htaccess`/mod_rewrite, no mod_security, no SSI,
  a smaller module surface, and a CLI-flag config (YAML + hot-reload is
  roadmapped).
- **Not yet present:** HTTP/2 (intentionally skipped — h3 is the multiplexed
  transport). Static serving now matches the giants on **ETag, conditional GET
  (304), and single byte ranges (206/416)**; only *multipart/byteranges*
  (multiple ranges in one response) is a documented intentional fallback to a
  full 200. A dynamic-response **micro-cache** ships (`--cache`) with
  stale-while-revalidate; only *disk-backed* caching is still roadmap.
- **Raw static throughput** at nginx's scale: a loopback `wrk` benchmark
  (`tool/bench_static.sh`) puts nginx **~47× ahead** on small static files
  (~948k vs ~20k req/s) — expected for hand-tuned C + `sendfile`. Front
  dart-apache with nginx/a CDN for pure static, or lean on the cache.

## Against Apache httpd specifically

> Architectural comparison (our harness measured *nginx*, not httpd). Apache is
> a **friendlier opponent than nginx**: it isn't a zero-copy speed demon, so the
> static gap is far narrower, and we're level on the modern PHP path.

| Dimension | Apache httpd | dart-apache | Who wins |
|---|---|---|---|
| Static raw throughput | event MPM, ~50–150k typical | ~20k (pure-Dart floor); ~130k from the in-mem cache | 🔴 Apache on cold/large; ⚪ par-to-us on hot files via `--cache` |
| Static correctness (ETag/ranges/304/gzip) | ✅ mature | ✅ standards-correct | ⚪ par |
| PHP — classic | `mod_php` (in-process, fast cold) | `php-cgi` | 🔴 Apache cold |
| PHP — modern (php-fpm/FastCGI) | ✅ | ✅ (`--php-fpm=`) | ⚪ par |
| Cacheable dynamic | `mod_cache` (capable, fiddly) | `--cache`, one flag, ~176× | 🟢 us (simpler + ~130k req/s) |
| HTTP/3 | experimental, build-flag gated | first-class | 🟢 us |
| WebTransport | ❌ none | ✅ native | 🟢 us |
| Livewire-over-WebTransport | ❌ | ✅ drop-in | 🟢 us |
| Config model | `httpd.conf` + `.htaccess` (powerful, verbose) | flags today (YAML/hot-reload roadmap) | ⚪ Apache more featureful, us simpler |
| Module ecosystem | 🏆 vast (25+ yrs) | small/young | 🔴 Apache |
| Zero-downtime reload | ✅ graceful | ✅ `SIGHUP` | ⚪ par |
| Single static binary | ❌ (dynamic libs/modules) | ✅ cross-compiled ELF | 🟢 us |

**Verdict vs httpd:** we lose only on **raw static** (and by much less than vs
nginx — our cache path already overtakes a typical Apache static setup for hot
files) and on **ecosystem maturity**. We're **level on modern PHP** (`php-fpm`),
and we win decisively on **HTTP/3, WebTransport, the Livewire bridge, one-flag
caching, and single-binary deployment** — things Apache either lacks or makes
you fight its config for.

## Who it's for (ICP)

- **Laravel/Livewire teams** who want real-time over HTTP/3 without standing up
  a WebSocket tier.
- **Dart shops** who want one toolchain from the browser to the server.
- **Teams who value a single self-contained binary** over assembling Apache
  modules or an nginx + php-fpm + WS-gateway stack.

## Proof it's real (not slideware)

Real Laravel/Livewire over WebTransport; **518 passing transport tests**;
chain-to-root cert validation + parser fuzzing; a native-ext4 **multi-worker
soak of 5,040 requests with 0 failures**; all six hardening phases complete
(see [15-webtransport-hardening-plan.md](15-webtransport-hardening-plan.md)).

**Benchmarked** (WSL2, ext4, loopback `wrk`, 4 workers; full table in
[09-performance.md](09-performance.md)). Read the **"× faster"** column:

| Workload | dart-apache | vs. | the other | Verdict |
| --- | --- | --- | --- | --- |
| Static 1 KiB | 20k req/s | → | nginx 948k req/s | nginx **~47× faster** |
| Cacheable PHP, no cache | 740 req/s | → | — | baseline |
| Cacheable PHP, **`--cache`** | **130k req/s** | → | 740 req/s | **~176× faster** |

- **Static files:** use nginx (or a CDN) in front — we don't beat hand-tuned C.
- **Cacheable dynamic:** the in-process cache is **~176×** faster than
  re-running PHP (latency 21.6 ms → 130 µs). That's the win.

---

**The pitch in a sentence:** *Keep your PHP app, add real-time over HTTP/3 with
one Blade tag, and write new routes in the same language your front end uses —
from a single binary.*

> A feature-by-feature **parity methodology** (differential testing vs. Apache
> and nginx) is specified separately in [17-parity.md](17-parity.md).
