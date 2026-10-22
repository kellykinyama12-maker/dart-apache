# 18 — Pitch: dart-apache vs. Apache & nginx

**One line:** Apache and nginx serve the web of 2010 (request → response over
HTTP/1.1). **dart-apache is HTTP/3-first**, so WebTransport and low-latency
real-time are the *native* path — not a bolt-on — while static files and PHP
still "just work."

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
- **Not yet present:** response/proxy caching and HTTP/2 (intentionally
  skipped — h3 is the multiplexed transport). Static serving now matches the
  giants on **ETag, conditional GET (304), and single byte ranges (206/416)**;
  only *multipart/byteranges* (multiple ranges in one response) is a documented
  intentional fallback to a full 200.
- **Raw static throughput** at nginx's scale isn't proven yet.

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

---

**The pitch in a sentence:** *Keep your PHP app, add real-time over HTTP/3 with
one Blade tag, and write new routes in the same language your front end uses —
from a single binary.*

> A feature-by-feature **parity methodology** (differential testing vs. Apache
> and nginx) is specified separately in [17-parity.md](17-parity.md).
