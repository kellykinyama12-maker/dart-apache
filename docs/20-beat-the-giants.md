# 20 — Beat the giants: compiled dart-apache + compiled Dart app

**Goal.** A *single compiled binary* — the dart-apache server **with your Dart
app baked in** — that beats nginx and Apache httpd for a **real application
workload**, while staying **backward compatible**: it still serves PHP
(`php-cgi`/`php-fpm`) and static files unchanged.

This is deliberately *not* "beat nginx at raw static" (we can't — C + `sendfile`)
and *not* "proxy PHP faster than nginx" (we don't). It's: **move the app's hot
paths into native in-process Dart**, where we already win, and **stop losing** on
the paths that drag a whole-app number down.

## 1. Measured baseline (see [09-performance.md](09-performance.md))

Same machine, same `wrk`, 4 workers. Where we stand today:

| Workload | dart-apache | giants | Verdict |
| --- | --- | --- | --- |
| **Native Dart app logic** | **111–182k** req/s | nginx+fpm 31–40k | 🟢 **we win ~3.5–4×** |
| Dynamic PHP via php-fpm | 16–21k req/s | nginx 31k / apache 27k | 🔴 lose ~1.6–2× |
| Static files | ~15–20k req/s | nginx ~950k / apache ~95k | 🔴 lose badly |
| Cacheable dynamic (`--cache`) | ~130k req/s HIT | (fpm cache) | 🟢 strong |

**Read:** the native Dart path is the weapon. Two liabilities can sink a
whole-app benchmark: (a) **static** serving, (b) the **PHP-via-FastCGI** hop.
The plan neutralizes both without giving up compatibility.

## 2. Strategy

1. **Play to the win** — the app's own routes are native in-process Dart
   handlers (`DartApp`), compiled into the binary. Already ~3.5–4× nginx+fpm.
2. **Neutralize static** — a static hot-path cache (an `open_file_cache`
   analog) so repeated static assets serve from memory, not a `stat()` +
   `open()` + gzip-check per request. Lifts static from ~20k toward the ~130k
   in-memory ceiling.
3. **Keep PHP for legacy, don't rely on it for speed** — PHP stays available
   (compat), but the "fast" story is native Dart; if a route must stay PHP, use
   `php-fpm` + `--cache`.
4. **Ship one binary** — `dart compile exe` the server+app together;
   cross-compile to Linux via `tool/build_linux.dart`.

## 3. Work items (prioritized)

- [x] **S1 — Static hot-path cache.** `--static-cache` (`lib/src/pipeline/
      static_cache.dart`): caches `(bytes, ETag, Last-Modified, precomputed
      gzip)` per file, re-`stat`s at most once per second (nginx
      `open_file_cache` analog); conditional GET / ranges / gzip answered from
      memory. Off by default → zero behavior change. **Measured (WSL, wrk):**
      1 KiB 19.7k → **138.9k** req/s (~7×); 100 KiB 12.5k → **99.4k** (~7.9×).
      The nginx gap collapsed from ~36× → ~5× (1 KiB) and ~18× → ~2.2×
      (100 KiB); now **beats Apache static (~95k)**. ✅
- [ ] **S2 — Blended app benchmark.** A realistic mix (native Dart dynamic
      routes + a few static assets) served by the *compiled* dart-apache binary
      vs nginx+php-fpm serving the equivalent PHP app. **Target:** compiled
      dart-apache ≥ nginx+fpm on aggregate throughput *and* latency.
- [ ] **S3 — Single-binary blueprint + docs.** An `example/` app that embeds
      `DartApp` routes + static + (optional) PHP, a one-command compile, and a
      short "ship one binary" guide section.
- [ ] **S4 (stretch) — raw static via `sendfile` (FFI).** Only if S1 isn't
      enough and static throughput is the actual product. Costs the pure-Dart
      property; gated behind a flag. Likely unnecessary once S1 lands.

## 4. Backward-compatibility invariants (must hold at every step)

- PHP via `php-cgi` **and** `php-fpm` keeps working, byte-for-byte.
- Static serving semantics unchanged when the cache is **off** (default) and,
  when on, identical responses (same ETag/range/304/gzip) — just faster.
- The Dart app is **additive** (routes run before static/PHP; no match falls
  through). `--dart-cgi` (edit-no-compile) still works for dev.
- Every existing test stays green; new behavior is opt-in and tested.

## 5. Definition of "beat the giants"

For a representative **application** workload (not micro-static), the
*compiled* dart-apache binary with a native Dart app delivers **higher
aggregate throughput and lower p99 latency than nginx + php-fpm** serving the
equivalent PHP app — on the same hardware, same `wrk`, measured by
`tool/bench_*` — while still able to serve the PHP app unchanged when asked.

We **concede** raw static micro-benchmarks to nginx and say so; the product
claim is *application* performance, not `sendfile` drag races.
