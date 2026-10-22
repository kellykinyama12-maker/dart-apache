# 14 — Livewire over WebTransport

What the WebTransport bridge in this server means for the **next generation of
Livewire** — and what Livewire itself would need to adopt it.

Related: [04-protocols.md](04-protocols.md) (transport abstraction),
[12-http3-integration-plan.md](12-http3-integration-plan.md) (HTTP/3-first
pipeline). Implementation:
[`lib/src/http3/h3_php_server.dart`](../lib/src/http3/h3_php_server.dart),
[`public/livewire.php`](../public/livewire.php),
[`tool/browser-h3-test/wt_livewire_test.js`](../tool/browser-h3-test/wt_livewire_test.js).

---

## TL;DR

This server can carry Livewire's server round-trips over **WebTransport (HTTP/3 /
QUIC)** instead of `fetch()` over HTTP/1.1 or HTTP/2. A complete WebTransport
message is routed through the **same PHP pipeline** that serves ordinary HTTP, so
Laravel + Livewire process it **exactly like the `/livewire/update` XHR they
replace** — no PHP changes required. The browser side needs a small transport
shim; the server side is already built and verified end-to-end in a real browser.

The payoff for a future Livewire: **one persistent connection**, **no
head-of-line blocking**, **sub-RTT interactivity**, **server-initiated pushes**,
and a **built-in unreliable channel** for ephemeral UI state — all without a
separate WebSocket/Echo server.

---

## How Livewire works today

Livewire is a server-driven UI framework. Each interaction follows a
request/response loop:

1. The browser serializes the component's **snapshot** (state) plus the
   **updates** (dirty properties) and **calls** (method invocations) into JSON.
2. It `POST`s that JSON to a single endpoint (`/livewire/update`) as an XHR.
3. The server re-hydrates the component, applies updates, runs the calls, and
   **re-renders**, returning an **effects** envelope (HTML diff, dispatched
   browser events, redirects, etc.).
4. The browser **morphs** the DOM from the returned HTML and applies effects.

Two structural costs come with this model:

- **Transport is HTTP request/response.** Every interaction is a fresh
  `fetch()`. Over HTTP/1.1 that is a connection/round-trip tax; over HTTP/2 it
  shares a connection but still suffers **TCP head-of-line blocking** — one lost
  segment stalls every multiplexed stream.
- **Realtime is a separate stack.** `wire:poll` approximates liveness by
  **polling on a timer** (wasteful, laggy). True push needs **Laravel Echo +
  a WebSocket server** (Reverb/Pusher/Soketi) — a second connection, second
  protocol, second scaling story.

---

## What the WebTransport pipeline provides

WebTransport runs over **HTTP/3 (QUIC over UDP)** and gives a web page three
primitives on **one** connection:

| Primitive | Semantics | Natural Livewire use |
| --- | --- | --- |
| **Bidirectional streams** | Reliable, ordered, independently flow-controlled, **no cross-stream HOL blocking** | A component **update round-trip** (request in, effects out) |
| **Unidirectional streams** | Reliable, one-way; either side can open | **Server push** — broadcasts, lazy-loaded fragments, streamed effects |
| **Datagrams** | Unreliable, unordered, single-frame, size-capped | **Ephemeral signals** — presence, typing, cursor position |

Because QUIC streams are independent, a slow or lost packet on one interaction
does **not** stall the others — the structural win HTTP/2 can't offer.

### What this server already implements (verified)

- **Session**: WebTransport Extended `CONNECT` accepted on a configurable path
  (`--wt-path`), with `SETTINGS_ENABLE_WEBTRANSPORT` + `SETTINGS_WT_MAX_SESSIONS`
  advertised.
- **Inbound streams**: client→server **uni** and **bidi** streams are surfaced,
  reassembled across QUIC frames, and **buffered to FIN** as one message
  (`_handleWtMessage`), capped at `maxRequestBodyBytes`.
- **Datagrams**: drained and dispatched (`_handleWtDatagram`), with a
  send path that **drops-with-log** instead of throwing on oversize.
- **The bridge**: when `--wt-bridge-path` is set, each complete message is run
  through the PHP pipeline as a synthetic `POST` and the response is returned on
  the same stream (or as a datagram) — see below.
- **Hygiene**: finished streams are pruned from the H3 layer so a long-lived
  interactive session doesn't leak.

All of the above is browser-verified in Edge over HTTP/3 (datagram echo, uni/bidi
echo, a 64 KiB multi-frame round-trip, and the Livewire JSON round-trip).

---

## The bridge architecture

```
browser                          dart-apache (this server)                 PHP / Laravel
───────                          ─────────────────────────                 ─────────────
WebTransport                     H3Connection (dart_quiche)
  bidi stream  ──JSON request──▶  _handleWtMessage ──▶ _WtBridgeExchange ──▶ RequestPipeline
                                   (buffered to FIN)     (synthetic POST       │ (resolver,
                                                          application/json,     │  php-cgi /
                                                          X-Requested-With,     │  PHP-FPM)
                                                          X-Livewire)           ▼
  bidi stream  ◀──JSON effects──  _WtBridgeResponse ◀──────────────────────  /livewire/update
                                   (captured in memory)
```

Key properties:

- **No new PHP contract.** The bridge presents the message as an ordinary
  `POST … application/json` with AJAX headers, so the existing Livewire endpoint
  handles it unmodified. Point `--wt-bridge-path=/livewire/update` at a Laravel
  front controller and it "just works."
- **Transport-agnostic reuse.** The bridge builds a `ServerExchange`
  (`_WtBridgeExchange`) — the same contract HTTP/1.1 and HTTP/3 requests use —
  so handlers, PATH_INFO resolution, and the CGI/FastCGI backends are shared.
- **Size-aware datagram replies.** A datagram request is answered with a
  datagram **when the response fits** the negotiated `max_datagram_frame_size`,
  otherwise it falls back to a uni stream so a larger effects payload is never
  lost.
- **Bounded + pruned.** Messages are capped (`maxRequestBodyBytes`); finished
  streams are released.

### Demo

[`public/livewire.php`](../public/livewire.php) emulates a Livewire effects
envelope. Start the server in bridge mode:

```
dart run bin/dart_apache.dart --root=./public --port=8443 --http3 \
  --tls-cert=build/cert.pem --tls-key=build/key.pem --workers=1 \
  --wt-path=/wt --wt-bridge-path=/livewire.php
```

A bidi-stream request `{component:"counter", message:"increment", calls:[…]}`
returns the PHP-rendered JSON envelope (`transport: webtransport`) on the same
stream; a datagram carrying the same shape returns its envelope as a datagram.
Server log shows `POST /livewire.php HTTP/3 200` per message.

---

## What Livewire (next version) would need

The server side is done. Adopting it is almost entirely a **client-side transport
swap** plus two optional server conventions.

### 1. A browser transport shim (required)

Livewire already abstracts "how a message reaches the server" behind a request
hook. A WebTransport driver would:

1. Open one `WebTransport(url)` to the `--wt-path` endpoint on first use and keep
   it alive for the page's lifetime.
2. For each component commit, open a **bidi stream**, write the same JSON
   Livewire sends today, read the effects JSON back, and resolve the commit.
3. Fall back to `fetch()` automatically when `WebTransport` is unavailable
   (feature-detect `window.WebTransport` + secure context).

Sketch:

```js
// Replaces Livewire's fetch-based message send with a WT bidi round-trip.
async function sendOverWebTransport(wt, payloadJson) {
  const stream = await wt.createBidirectionalStream();
  const w = stream.writable.getWriter();
  await w.write(new TextEncoder().encode(payloadJson));
  await w.close();
  const r = stream.readable.getReader();
  let out = '';
  for (;;) { const { value, done } = await r.read(); if (done) break;
             out += new TextDecoder().decode(value); }
  return out; // the Livewire effects JSON
}
```

(The verified reference is
[`wt_livewire_test.js`](../tool/browser-h3-test/wt_livewire_test.js).)

### 2. Server push via uni streams (optional, high value)

Today's `wire:poll` could be replaced by **server-initiated unidirectional
streams**: when server state changes (a broadcast, a background job completing),
push an effects envelope to subscribed clients. This server already opens
server→client uni streams; wiring a Livewire broadcast to one is a small
addition on top of the existing `_handleWtMessage` extension point.

### 3. Ephemeral state via datagrams (optional)

Presence, typing indicators, and cursor/selection sync are **lossy by nature** —
perfect for datagrams. Livewire could expose a `wire:signal`-style API that maps
to `wt.datagrams`, keeping these high-frequency, low-value updates **off** the
reliable stream path entirely.

---

## Benefits for a future Livewire

| Dimension | Today (HTTP/1.1 or HTTP/2 + Echo) | With this pipeline (WebTransport) |
| --- | --- | --- |
| Connection | New `fetch()` per interaction (or shared H2) | **One** persistent QUIC connection |
| Head-of-line blocking | TCP-level (stalls all H2 streams) | **None** — independent QUIC streams |
| Interactivity latency | ≥ 1 RTT + TCP/TLS setup amortized | **Sub-RTT** on a warm connection; 0-RTT possible |
| Realtime / push | Polling or a separate WebSocket server | **Native** server uni streams — no Echo/Reverb |
| Ephemeral UI (presence/typing) | Extra WebSocket traffic, reliable | **Datagrams** — unreliable, cheap, out-of-band |
| Connection migration | Breaks on network change | QUIC **survives** IP/NAT changes |
| Infra | App server **+** WebSocket server | **One** HTTP/3 origin |
| PHP changes | — | **None** (same endpoint, same payload) |

---

## Compatibility and fallback

- **Progressive enhancement.** WebTransport is used only when
  `window.WebTransport` exists in a secure context; otherwise Livewire uses its
  existing `fetch()` path. The **wire format is identical**, so a single backend
  serves both.
- **HTTP/3-first, HTTP/1.1 fallback.** This server advertises HTTP/3 via
  `Alt-Svc`; browsers upgrade automatically and downgrade gracefully. (HTTP/2 is
  explicitly out of scope here — see [04-protocols.md](04-protocols.md).)
- **Same handlers, one doc root.** Because the bridge reuses `ServerExchange`,
  reverse-proxy routes, PATH_INFO resolution, and CGI/FastCGI all apply
  unchanged.

---

## Limitations and open questions

- **Session/auth propagation.** The bridge forwards the message body and AJAX
  headers; it does **not** yet forward cookies / CSRF from the WebTransport
  `CONNECT` to the synthetic `POST`. A production bridge must carry the session
  cookie and `X-CSRF-TOKEN` from the WT session so Laravel auth/CSRF behave as on
  the XHR path. **(Next step.)**
- **Multi-session datagram demux.** The current datagram receive path assumes a
  single WT session per connection; multiplexing several sessions needs a
  peek/queue by Quarter-Stream-ID.
- **Backpressure semantics.** Bridge responses are captured fully in memory
  (bounded by `maxRequestBodyBytes`) rather than streamed; streaming effects back
  as they render is a future optimization.
- **Dependency maturity.** The transport is the vendored, pre-1.0 pure-Dart
  `dart_quiche`; PKI chain validation and 0-RTT hardening are tracked in
  [12-http3-integration-plan.md](12-http3-integration-plan.md).
- **Livewire side is not upstream.** The client shim and push/signal APIs
  described here are **proposals**; nothing in Livewire core ships them yet.

---

## Status

| Piece | State |
| --- | --- |
| WT session + inbound uni/bidi streams + datagrams | **Done, browser-verified** |
| PHP-pipeline bridge (`--wt-bridge-path`) | **Done, browser-verified** |
| Demo endpoint + live test | **Done** (`public/livewire.php`, `wt_livewire_test.js`) |
| Cookie/CSRF propagation into the bridge | **Not done** (next step) |
| Livewire browser transport shim | **Proposal** (reference sketch above) |
| Server-push / datagram-signal Livewire APIs | **Proposal** |

The transport and server-side bridge are ready. The remaining work to make a
real Laravel + Livewire app run over WebTransport is (a) cookie/CSRF forwarding
in the bridge and (b) a client-side Livewire transport driver — both scoped
above.
