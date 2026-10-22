# 12 — HTTP/3-First Integration Plan

This document records **what has been built** for HTTP/3 and lays out a
**dedicated plan to route HTTP/3 through the unified request pipeline**, with an
explicit **HTTP/3-first** posture: QUIC + HTTP/3 is the primary, first-class
transport, and HTTP/1.1/HTTP/2 are compatibility fallbacks rather than the
center of gravity.

Related: [03-architecture.md](03-architecture.md) (pipeline, isolates),
[04-protocols.md](04-protocols.md) (transport abstraction),
[10-roadmap.md](10-roadmap.md) (phases).

---

## Part A — What has been done (status)

A working **proof-of-concept** HTTP/3 server exists and is verified end-to-end.

### Delivered

- **Transport:** terminates QUIC v1 + TLS 1.3 using the vendored, pure-Dart
  [`dart_quiche`](../third_party/dart_quiche) stack (no FFI, no BoringSSL).
- **Protocol:** speaks HTTP/3 (HEADERS/DATA, QPACK) via `dart_quiche`'s
  `H3Connection.server`.
- **Application:** each request is mapped onto the same
  [`RequestResolver`](../lib/src/request_resolver.dart) (DocumentRoot,
  DirectoryIndex, PATH_INFO, traversal protection) and PHP runs through
  `php-cgi`, reusing the shared streaming CGI parser
  [`parseCgiStream`](../lib/src/php/php_backend.dart).
- **Entry point:** [`bin/dart_apache_h3.dart`](../bin/dart_apache_h3.dart);
  implementation in
  [`lib/src/http3/h3_php_server.dart`](../lib/src/http3/h3_php_server.dart).

### Verified

With `dart_quiche`'s H3 client
(`third_party/dart_quiche/bin/interop_h3_get.dart`):

| Request | Result |
| --- | --- |
| `GET /` | QUIC handshake OK (AES-128-GCM, X25519) → `index.php` → `200` **"Hello, world!"**, PHP's `x-powered-by` passed through |
| `GET /?name=HTTP3` | `QUERY_STRING` → `$_GET['name']` → **"Hello, HTTP3!"** (dynamic PHP) |

### Known limitations (to be closed by Part B)

1. **Not integrated** — a standalone binary, separate from `ApacheServer` and
   the isolate `ServerSupervisor`.
2. **Buffered response** — the PHP body is collected before `sendResponse`,
   unlike the streaming/back-pressured HTTP/1.1 path.
3. **Self-signed cert per start** — no real certificate loading, no SNI.
4. **Single event loop, single isolate** — no multi-core UDP acceptor model.
5. **No lifecycle** — no graceful drain, reload, or connection migration.
6. **Noisy** — `dart_quiche`'s cert generator prints PEM/fingerprints to stdout.
7. **Pre-1.0 dependency** — no chain-to-root PKI validation in `dart_quiche`.

---

## Part B — HTTP/3-first pipeline integration

### Principle

> One request pipeline, many transports. A request is a request regardless of
> whether it arrived over h3, h2, or h1 — handlers never know the difference.

HTTP/3 is the **reference implementation** of the transport contract; h2/h1
conform to the same contract.

### Target shape

```mermaid
flowchart TB
  subgraph Listeners
    U[(UDP :443 QUIC)]
    T[(TCP :443 TLS)]
    P[(TCP :80)]
  end
  U --> H3[Http3Transport (dart_quiche)]
  T --> ALPN{ALPN}
  ALPN -->|h2| H2[Http2Transport]
  ALPN -->|http/1.1| H1[Http1Transport]
  P -->|redirect/upgrade| H1

  H3 --> PIPE
  H2 --> PIPE
  H1 --> PIPE
  PIPE[Unified request pipeline] --> R[Router / vhost]
  R --> STATIC[Static]
  R --> PHP[PHP (CGI/FastCGI)]
  R --> PROXY[Reverse proxy]

  H3 -. Alt-Svc advertise .- T
```

### The transport contract

A single interface all transports implement (generalizes the sketch in
[04-protocols.md](04-protocols.md)):

```dart
abstract interface class ServerTransport {
  /// Each inbound request as it becomes routable (headers known).
  Stream<ServerExchange> get exchanges;
  Future<void> close({bool graceful});
}

abstract interface class ServerExchange {
  String get method;
  Uri get uri;                     // path + query
  String get authority;            // :authority / Host
  String get scheme;               // https for h3
  ServerHeaders get headers;
  Stream<List<int>> get body;      // request body (back-pressure in)
  InternetAddress get remoteAddress;
  String get protocol;             // "h3" | "h2" | "http/1.1"

  ServerResponseSink respond(int status, ServerHeaders headers);
}

abstract interface class ServerResponseSink {
  /// Streamed, back-pressure-aware writes.
  Future<void> add(List<int> chunk);
  Future<void> close();
}
```

The existing handlers (static, PHP) already consume an `HttpRequest`-like shape
and return a streamed `PhpResponse`; they will be rewritten against
`ServerExchange` / `ServerResponseSink` once, then reused by every transport.

### Mapping `dart_quiche` → the contract

- `H3HeadersEvent` → construct a `ServerExchange` (decode pseudo-headers
  `:method`, `:path`, `:scheme`, `:authority`; regular headers into
  `ServerHeaders`).
- `H3DataEvent` chunks → feed the exchange's `body` stream (with flow-control
  back-pressure propagated to QUIC).
- `respond()` → `H3Connection.sendResponse` for headers, then **streamed**
  `sendData` calls for the body (replaces today's buffered send).
- `H3FinishedEvent` → close the body stream.

This is the piece that turns the PoC's buffered `_send` into a true streaming
`ServerResponseSink`.

### Multi-core UDP acceptor (HTTP/3-first scaling)

QUIC is connectionless at the socket layer, so the h1/h2 `shared: true` TCP
accept model does not directly apply. Plan:

- Bind one `RawDatagramSocket` **per worker isolate** with `reuseAddress` /
  `SO_REUSEPORT` so the kernel fans datagrams across workers.
- **Connection-ID affinity:** each worker owns the connections whose Destination
  Connection ID it issued. Because QUIC CIDs are server-chosen, encode a
  worker/routing tag in the CID so stray datagrams (post-migration, or kernel
  mis-steer) can be forwarded to the owning worker via the supervisor.
- Reuse the existing [`ServerSupervisor`](../lib/src/supervisor.dart) for
  respawn and reload; add UDP binding alongside the TCP path.

### Lifecycle

- **Graceful drain:** stop accepting new QUIC connections, send HTTP/3 `GOAWAY`,
  finish in-flight streams, then close — wired into the supervisor's existing
  drain/reload.
- **Connection migration:** accept client address changes (path validation is
  already in `dart_quiche`); keep the CID→worker mapping stable across migration.

### TLS & certificates

- Load real certificates (PEM) with **SNI** selection; stop generating a
  self-signed cert except in an explicit `--dev` mode.
- Share TLS session/ticket keys across workers so 0-RTT/resumption works in the
  multi-isolate model (see the resumption gap in the open questions).
- Gate **0-RTT** early data to idempotent, replay-safe requests only.

### Fallback & discovery (still HTTP/3-first)

> **Status:** basic discovery is **implemented** — the HTTP/1.1 server emits
> `Alt-Svc: h3=":<port>"; ma=<ttl>` on every response (`--advertise-h3=PORT`,
> [`ServerConfig.altSvcHeader`](../lib/src/config.dart)).

- Run the TCP listener (h1/h2) primarily to **advertise** HTTP/3 via `Alt-Svc`
  and to serve clients that cannot do QUIC yet.
- Next: tie the advertised port to the actual running h3 listener, add `HSTS`,
  and support `Alt-Svc` on the h2 path too.

### Observability

- Per-transport metrics/labels (`protocol="h3"`), QUIC stats from
  `dart_quiche` (loss, RTT, congestion window), and **qlog** export (the
  library emits qvis-compatible traces) behind a flag.

---

## Delivery steps

| Step | Outcome | Exit criteria |
| --- | --- | --- |
| H3-1 ✅ | Define `ServerExchange` / `ServerResponse` contract | `lib/src/pipeline/server_exchange.dart`; handlers compile against it |
| H3-2 ✅ | Port static + PHP handlers to the contract | `RequestPipeline` serves static + PHP; HTTP/1.1 runs via it; tests green |
| H3-3 ✅ | HTTP/3 server adapts `dart_quiche` to the contract | h3 serves static + PHP through the **same** pipeline (verified) |
| H3-4 ✅ | **Streaming** h3 responses (per-chunk DATA + flush) | Large static (200 KB) + PHP streamed over h3 without full-body buffering |
| H3-5 ✅ | Real certs + SNI + `--dev` self-signed; silence cert debug | PEM cert/key loaded (`--tls-cert`/`--tls-key`); `--dev` self-signed; vendored cert/TLS debug output silenced |
| H3-6 🟡 | Multi-isolate UDP acceptor + CID affinity via supervisor | h3 runs N workers on a shared UDP port (SO_REUSEPORT) under the supervisor; CID worker-tag in place; cross-worker forwarding for migration pending |
| H3-7 🟡 | GOAWAY drain, migration, Alt-Svc advertisement | Sessions routed by DCID (migration-safe, address adopted); graceful drain sends GOAWAY + waits for in-flight + CONNECTION_CLOSE; **Alt-Svc↔listener coupling done** via the unified process |
| H3-8 | quic-interop + load/soak; qlog + metrics | Interop targets pass; metrics/qlog available |

> **Status:** H3-1..H3-5 done; **H3-6 and H3-7 in progress**. HTTP/3 runs under
> the shared [`ServerSupervisor`](../lib/src/supervisor.dart) as N worker
> isolates (`--workers`), each binding the UDP port with `reusePort`
> (SO_REUSEPORT on Linux/BSD). Sessions are keyed by **Destination Connection
> ID** (not source address), so a migrating client keeps its session and its new
> address is adopted. Graceful `stop` sends **GOAWAY**, waits for in-flight
> requests (bounded), then **CONNECTION_CLOSE**. Remaining: cross-worker
> datagram **forwarding** after migration (a migrated datagram may land on a
> different worker via SO_REUSEPORT), and tying the advertised `Alt-Svc` port to
> an actually-running h3 listener (needs h1+h3 in one process). SO_REUSEPORT is
> Linux-only; Windows runs a single effective acceptor.

> **Status:** H3-1..H3-5 are **done**. HTTP/3 loads a real PEM certificate
> (`--tls-cert`/`--tls-key`) or a generated self-signed one (`--dev`), and the
> vendored cert/TLS debug `print()` noise is suppressed via a forked zone.
> Remaining for H3-5: **SNI-based multi-certificate selection** (one cert per
> hostname) — currently a single server certificate is used.

> **Status:** H3-1..H3-4 are **done** — both HTTP/1.1 and HTTP/3 run through the
> single [`RequestPipeline`](../lib/src/pipeline/request_pipeline.dart), and the
> h3 response body now **streams** (HEADERS on first chunk, a DATA frame per
> chunk flushed to the socket, FIN on close). Remaining: request-body streaming
> into PHP (h3 still collects the request body before dispatch) and true
> window-aware write back-pressure.

## Risks

| Risk | Mitigation |
| --- | --- |
| `dart_quiche` pre-1.0 maturity / no chain-to-root PKI | Pin/vendor (done); add validation; keep the transport seam swappable |
| UDP fan-out + CID routing complexity | CID-encoded worker tag; supervisor-forwarded stray datagrams |
| TLS resumption across isolates | Shared ticket keys distributed by the master |
| Per-request CPU (QPACK/crypto in Dart) | Pool buffers; measure early; `dart compile exe` (AOT) |

## Definition of done (integration)

HTTP/3 serves static + PHP **through the same pipeline and handlers** as h1/h2,
streamed with back-pressure, across all cores, with graceful reload, real
certs, Alt-Svc discovery, metrics/qlog, and passing interop — at which point
HTTP/3 is the server's primary transport, not a side binary.
