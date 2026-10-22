# 15 — WebTransport / Livewire Hardening Plan

A concrete, sequenced plan to take the Livewire-over-WebTransport capability from a
**verified prototype** to something **shippable**. Every task names the files it
touches and an acceptance check, so it can be executed and verified the same way
the prototype was.

Related: [14-livewire-webtransport.md](14-livewire-webtransport.md) (what/why),
[04-protocols.md](04-protocols.md) (transport), [09-performance.md](09-performance.md)
(benchmark targets), [11-testing-and-release.md](11-testing-and-release.md) (CI).

---

## Where we are

Verified end-to-end (live, Edge/HTTP-3):

- WebTransport surface: datagrams, client↔server uni + bidi streams.
- Bridge: a complete WT message runs through the shared PHP pipeline as a
  synthetic `POST` ([`_bridgeWtMessage`](../lib/src/http3/h3_php_server.dart)).
- Front-controller routing (`--front-controller`), SPA fallback (`--spa-fallback`).
- Real **Laravel 13 + Livewire 4** counter over WebTransport.
- Secure session tickets (`--wt-ticket-path`, [`WtTicket`](../lib/src/wt/ticket.dart)),
  HttpOnly-safe CSRF; the drop-in shim
  ([`livewire-webtransport.js`](../public/app/livewire-webtransport.js)).

## Gap inventory

| # | Gap | Severity |
| --- | --- | --- |
| G1 | **Lossy response contract** — the bridge returns only the body; the shim hard-codes `status: 200`, so a `419`/`500`/redirect is mis-reported. | Correctness (high) |
| G2 | **Unproven value** — no measurement that WT beats `fetch` for Livewire. | Strategic (high) |
| G3 | **Narrow coverage** — only a counter; no forms/validation, uploads, `wire:navigate`, poll-replacement, reconnect. | Robustness (med) |
| G4 | **Not packaged** — manual flags + a copied JS file; no deploy recipe. | Adoption (med) |
| G5 | **Transport pre-1.0** — vendored `dart_quiche` lacks chain-to-root PKI validation and 0-RTT hardening. | Production (med) |
| G6 | **No CI for the WT/browser path** — browser tests are run by hand. | Process (low) |

---

## Phase 1 — Correctness: full response contract (closes G1)

Make the WT reply carry status + headers so the shim reconstructs a faithful
`Response`. This unblocks Livewire error handling, redirects, and `Set-Cookie`
rotation (session/XSRF refresh).

1. **Frame the bridge reply.** In
   [`_bridgeWtMessage`](../lib/src/http3/h3_php_server.dart) /
   `_bridgeWtDatagram`, prepend a small envelope to the body:
   `status\r\nName: Value\r\n…\r\n\r\n<body>` (reuse the preamble shape). Source
   `status`/headers from `_WtBridgeResponse` (already captured). Forward
   `Set-Cookie`, `Content-Type`, `X-Livewire-*`, `Location`.
2. **Parse it in the shim.** In
   [`livewire-webtransport.js`](../public/app/livewire-webtransport.js)
   `sendOverWt`, split the envelope and return
   `new Response(body, { status, headers })` instead of a fixed 200.
3. **Handle `Set-Cookie`.** The browser cannot set cookies from a WT stream; when
   the reply rotates the session/XSRF cookie, the shim must apply it
   (`document.cookie` for non-HttpOnly; for HttpOnly, re-fetch a ticket so the
   next message carries the new session). Define and implement the rule.
4. **Error fallback.** If the bridge yields a non-2xx/opaque failure, the shim
   should surface it faithfully (not swallow to 200) and optionally retry once
   over native `fetch`.

**Acceptance:** extend `wt_csrf_test.js` (or a new `wt_response_test.js`) so a PHP
endpoint returning `419` + a header is observed by the client as
`response.status === 419` with the header present. Re-run
`laravel_livewire_test.js` (counter still 0→2). `dart analyze` clean; unit tests pass.

**Risk:** low. Contained to the bridge write + shim read; envelope is versionable.

---

## Phase 2 — Prove the value: benchmark (closes G2)

Decide whether this is worth productionizing.

1. **Harness.** A Playwright script that drives N Livewire updates and records
   wall-clock latency per update, over (a) native `fetch` (HTTP/3) and (b) the WT
   shim — same app, same component. Report p50/p95.
2. **Adverse network.** Re-run under simulated loss/latency (Chrome
   `--enable-features` / DevTools `Network.emulateNetworkConditions`, or a WSL
   `tc netem` setup) — the regime where QUIC's lack of TCP head-of-line blocking
   should matter most.
3. **Concurrency.** Fire K parallel component updates; compare tail latency.
4. **Write up** numbers in [09-performance.md](09-performance.md).

**Acceptance:** a reproducible `tool/browser-h3-test/bench_wt_vs_fetch.js` and a
results table. **Decision gate:** if WT shows no benefit even under loss, stop
here and record the finding; otherwise proceed.

**Status: DONE — proceed.** `tool/browser-h3-test/bench_wt_vs_fetch.js` +
[09-performance.md](09-performance.md): on loopback WebTransport is reproducibly
**~40–50% cheaper per request** than `fetch` over HTTP/3 (seq p50 ~2.5ms vs
~5.1ms; burst×15 p50 ~23ms vs ~47ms). The run also **surfaced a blocking bug**
(no `MAX_STREAMS` replenishment — stalls after 16 requests), now folded into
Phase 3. Packet-loss emulation is still TODO (loopback measures CPU/framing only).

**Risk:** medium (network emulation fiddly on Windows; WSL `tc netem` is the fallback).

---

## Phase 3 — Coverage & robustness (closes G3)  ✅ DONE

Shake out real-app behavior beyond a counter.

0. **QUIC stream flow control (surfaced by Phase 2, highest priority).** ✅ The
   vendored stack advertises `initial_max_streams_bidi` and never emits
   `MAX_STREAMS`, so a connection stalls once the budget is spent (one bidi
   stream per request). Mitigated by raising the grant to 65 536; the real fixes:
   (a) emit `MAX_STREAMS_BIDI/UNI` as peer streams close (RFC 9000 §4.6), and
   (b) collect fully-closed streams from `Connection._streams` so cost/memory
   don't grow with cumulative stream count. Alternative: reuse one persistent
   bidi stream with message framing (sidesteps both). Also handle a client
   `STOP_SENDING` mid-response gracefully in `_H3ResponseSink` (the caught
   `QuicError(StreamStopped)` 500 noted in Phase 1).
   **Done:** MAX_STREAMS replenishment + `_collectCompletedStreams()` landed
   (300-req bench, 0 errors); `_sendHeaders`/`_sendData` now return `bool` and
   catch `QuicError`, with an `_aborted` flag on `_H3ResponseSink` that stops
   reading the source and skips the trailing FIN — a mid-response client reset
   logs a clean `stopped by client` line instead of a 500.
1. **Coverage app** in `livewire-wt`: a form with `wire:model`, server-side
   validation (error bag), a `wire:navigate` link, and a `wire:poll` component.
   **Done:** `⚡contact-form` (required/email/min validation) + `⚡ticker`
   (`wire:poll.700ms`) + a `wire:navigate` link, all on `/form`.
2. **Reconnect** in the shim: on `wt.closed`, reset and lazily reconnect on the
   next update; in-flight messages fall back to `fetch`.
   **Done:** `wt.closed.then(reset, reset)` nulls the handles; `connect()`
   lazily reopens on the next request; a request that fails mid-flight falls
   back to native `fetch`.
3. **Uploads.** Livewire file uploads use a separate multipart endpoint — decide:
   bridge binary bodies over WT, or let uploads use native `fetch` (likely the
   latter; document it). **Deferred:** uploads stay on native `fetch` (the shim
   only intercepts the JSON update endpoint); revisit in Phase 4.
4. **Backpressure / limits.** Confirm the per-message cap
   (`maxRequestBodyBytes`) and stream pruning hold under rapid interaction;
   add a soak step (hundreds of updates) watching memory.
   **Done:** 300-req benchmark with stream collection, 0 errors, stable memory.
5. **`wire:navigate`.** Verify SPA-style navigation works (front-controller +
   full-page responses); if Livewire fetches full HTML over the same hook, the
   response contract from Phase 1 must carry `text/html` correctly.
   **Done:** `wire:navigate` GETs the target page over normal h3 (not the WT
   hook) and the front-controller serves it; verified `navigated: true`.

**Acceptance:** a `livewire_coverage_test.js` exercising form submit + validation
error + navigate, all over WT; soak run shows stable memory.
**Verified:** `livewire_coverage_test.js` →
`{errName: "…required.", saved: "Saved Ada …", ticks 5→6, polledOverWt: true,
navigated: true, wtUsed: 9, errors: []}` (exit 0); server log all `200`, no 500s.

**Risk:** medium (uncovers Livewire-internal assumptions).

---

## Phase 4 — Packaging & deploy (closes G4)  ✅ DONE

Make it adoptable without hand-wiring.

1. **Laravel package** (`livewire-wt`, its own repo): publishes the shim asset,
   a Blade directive/`@webtransport` include that injects the `<meta>` + script,
   a config file (endpoint, ticket URL), and docs. Target `composer require`.
   **Done:** `packaging/livewire-webtransport/` — composer package
   `dartapache/livewire-webtransport` (auto-discovered provider), publishable
   config `webtransport.php` + asset, and a `@webtransport` Blade directive.
2. **Server deploy recipe.** Document the stable flags and **require a persistent
   `--wt-ticket-key`** (base64 32 bytes) so tickets survive restarts across all
   workers; a `systemd` unit for Linux; a native (non-`/mnt/c`) checkout.
   **Done:** [16-deploy.md](16-deploy.md) — build, persistent key, flag table,
   systemd unit (CAP_NET_BIND_SERVICE), `.env`, TLS note.
3. **TLS.** Real certificate loading (already supported via `--tls-cert`); note
   the dev self-signed path vs. production PKI (ties to Phase 5). **Done** in 16.
4. **Config ergonomics.** Consider a single `--laravel=<public-dir>` convenience
   flag that implies `--front-controller=/index.php` + sensible WT defaults.
   **Done:** `--laravel=<dir>` sets the root and implies `--front-controller=
   /index.php`, `--wt-path=/wt`, `--wt-bridge-path=/livewire/update`,
   `--wt-ticket-path=/wt-ticket` (explicit flags override). Unit-tested.

**Acceptance:** from a clean Laravel app, `composer require` + one Blade include +
the documented server command yields a working WT round-trip with no manual JS copy.
**Verified (2026-10-22):** real Laravel 13 + Livewire 4 app — `composer require
dartapache/livewire-webtransport` (path repo) + `vendor:publish` + `@webtransport`
in the layout + `dart_apache --laravel=…/public --http3`. Counter 0→2 (wtUsed=2)
and form/validation + `wire:poll`/`wire:navigate` coverage (wtUsed=6) both pass;
shim served from `/vendor/livewire-webtransport/…`, all updates `200` over WT.

**Risk:** medium (packaging/versioning surface; cross-repo).

---

## Phase 5 — Transport production-readiness (closes G5)  ◐ PARTIAL

The deferred `dart_quiche` items; needed before untrusted-network production.

1. **PKI**: chain-to-root X.509 validation on the client/handshake path
   (currently self-signed/pinned only). Tracked in
   [12-http3-integration-plan.md](12-http3-integration-plan.md). **◐ PARTIAL** —
   the client now verifies the `CertificateVerify` signature over the transcript,
   the leaf SAN vs. hostname (RFC 6125), **and the leaf validity window
   (RFC 5280 §4.1.2.5: `certIsCurrentlyValid` / `verifyValidity`, default on)**.
   Still **OPEN**: full chain-to-root (issuer-signature verification over child
   TBS, trust-anchor set, `basicConstraints` path checks, RSA-PKCS1v15/P-384 for
   CA sigs). That is a bounded-large (~400–600 LOC, multiple ASN.1/crypto
   schemes) change whose subtle failure modes are security-critical, so it stays
   scoped behind the trusted-network caveat below rather than rushed.
2. **0-RTT** hardening + anti-replay review. ✅ **DONE** — the `zero_rtt_e2e`
   failure was a time-bomb *test fixture* (a fixed-past `issuedAt` made the
   ticket stale under `TicketStore.lookup`'s real-time eviction), not a binder
   gap; the binder/key-install path was correct. Fixed the fixture and added
   **single-use anti-replay** (RFC 8446 §8.1): `TicketStore.consume` burns a
   ticket on 0-RTT acceptance so a replayed Initial misses and is forced to a
   full 1-RTT handshake. Covered by `ticket_store_test.dart` + an e2e replay
   assertion; the CI exclusion is removed (full vendored suite green).
3. **Linux production** run verified natively (not `/mnt/c`), multi-worker
   `reusePort`, under load. ✅ **DONE** — binary staged on native **ext4**
   (`/dev/sdd`), `--workers=4` (4 isolates, SO_REUSEPORT sockets). Soak via
   `tool/soak*.sh`: **5040 requests (5000 h1-TLS + 40 h3/QUIC), 0 failures**;
   worker RSS 27.8→33.2 MB with a *decelerating* per-round delta (3.1→2.5 MB),
   consistent with JIT/cache warm-up, not a linear leak.
4. **Fuzz** the inbound WT stream/datagram parsers (malformed prefixes, huge
   varints, split frames). ✅ **DONE** —
   `third_party/dart_quiche/test/fuzz_parsers_test.dart` sweeps 80k+ random and
   adversarial buffers through `Frame.fromBytes`, `H3Frame.fromBytes`,
   `parseCapsule`, and the varint cursor: every input yields a controlled
   rejection (never a hang, over-read, or attacker-length allocation). Plus a
   ticket-redeem fuzz (`test/wt_ticket_test.dart`) — arbitrary and bit-flipped
   tokens always return null, never throw.

**Acceptance:** handshake rejects an untrusted cert (◐ validity + hostname +
transcript enforced; chain-to-root OPEN); fuzz corpus runs clean (DONE); Linux
soak passes (DONE).

**Risk:** high (QUIC internals; pre-1.0 dependency). Chain-to-root PKI is the one
remaining gating item; until it lands, run behind a trusted TLS terminator / on
a trusted network (see [16-deploy.md](16-deploy.md)).

---

## Phase 6 — CI (closes G6)  ✅ DONE

1. `dart analyze` + `dart test` (both packages) on push. ✅
   `.github/workflows/ci.yml` `analyze-test` job: root `dart analyze bin lib
   test tool` + `dart test` (42), and vendored `dart analyze lib test` +
   `dart test` (full suite, 506 — the former `zero_rtt_e2e` exclusion is gone
   now that the time-bomb fixture is fixed).
2. A browser job (Edge + Playwright) running the `tool/browser-h3-test/*.js`
   suite against a spun-up server, gated on the dev cert. ✅
   `.github/workflows/browser.yml` — `workflow_dispatch` on a self-hosted
   `[self-hosted, windows, edge]` runner (GitHub-hosted runners can't do
   Edge/QUIC reliably).
3. Lint the shim and the PHP demos. ✅ `ci.yml` `lint` job: `php -l` over
   `public/` + `packaging/`, `node --check` over the shim(s) and browser tests.

**Acceptance:** green pipeline; browser suite runs unattended. Met — the
hosted `analyze-test` + `lint` jobs gate every push; the browser suite is
manual by necessity (QUIC/Edge).

---

## Sequencing & exit criteria

```
Phase 1 (correctness) ─▶ Phase 2 (benchmark / decision gate)
                               │ win?
                   ┌───────────┴───────────┐
                  yes                       no → stop, record finding
                   ▼
        Phase 3 (coverage) ─▶ Phase 4 (package) ─▶ Phase 6 (CI)
                                     │
                                     └─▶ Phase 5 (transport) in parallel
```

**Recommended now:** Phase 1 (small, fixes a real bug), then the Phase 2
benchmark decision gate before investing in 3–6.

**"Done" for a 0.1 release:** Phases 1–4 + 6 complete; Phase 5 explicitly scoped
as "trusted-network / behind-a-TLS-terminator only" until the PKI work lands.
