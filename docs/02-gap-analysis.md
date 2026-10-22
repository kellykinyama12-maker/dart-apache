# 02 — Gap Analysis

Assessment of the current prototype against the enterprise target. The
prototype lives in `lib/src/` and `bin/dart_apache.dart`.

## What exists today

| Capability | Status | Location |
| --- | --- | --- |
| HTTP/1.1 serving | ✅ via `dart:io` `HttpServer` | `lib/src/server.dart` |
| Static files + MIME | ✅ basic | `lib/src/server.dart`, `lib/src/mime_types.dart` |
| DirectoryIndex | ✅ | `lib/src/request_resolver.dart` |
| PHP execution | ✅ CGI via `php-cgi` | `lib/src/php_handler.dart` |
| PATH_INFO splitting | ✅ | `lib/src/request_resolver.dart` |
| Traversal protection | ✅ | `lib/src/request_resolver.dart` |
| Access logging (CLF) | ✅ basic | `lib/src/server.dart` |
| Multi-core isolates | ✅ worker-per-core, shared socket | `lib/src/supervisor.dart` |
| Worker respawn + reload | ✅ respawn + zero-downtime SIGHUP reload | `lib/src/supervisor.dart` |
| Streaming PHP (back-pressure) | ✅ request + response streamed | `lib/src/php/` |
| FastCGI (PHP-FPM) | ✅ `--php-fpm=host:port` or `unix:/path` | `lib/src/php/fastcgi.dart` |
| HTTP/3 + PHP (PoC) | ✅ QUIC/TLS 1.3 + h3, static + `php-cgi` | `lib/src/http3/h3_php_server.dart` |
| Unified request pipeline | ✅ h1 + h3 share one transport-agnostic pipeline | `lib/src/pipeline/` |
| Unified h1+h3 listener | ✅ `--http3`: one process/port, auto `Alt-Svc` | `lib/src/unified_server.dart` |
| Config via CLI flags | ✅ minimal | `lib/src/config.dart` |

## Gaps to close

| Area | Current | Target |
| --- | --- | --- |
| **Concurrency** | ✅ multi-isolate acceptors over a shared port | Add master supervisor + rolling restart |
| **HTTP/2** | None | Full h2 (streams, HPACK, flow control, priorities) |
| **HTTP/3 / QUIC** | ✅ experimental PoC: static + PHP over h3 (`dart_quiche`) | Harden, integrate into main pipeline, conformance |
| **TLS** | h3 uses TLS 1.3 (self-signed, via `dart_quiche`) | TLS 1.3 for h1/h2, ALPN, SNI, OCSP, cert rotation |
| **Reverse proxy** | None | HTTP/FastCGI/SCGI upstreams, keep-alive pools |
| **Load balancing** | None | round-robin, least-conn, hashing, health checks |
| **WebSocket** | None | Origin upgrade (RFC 6455/8441) + proxy passthrough (Phase 2–3) |
| **WebTransport** | None | Origin over HTTP/3 via `dart_quiche` (Phase 4) |
| **PHP integration** | ✅ CGI (`php-cgi`) **and** FastCGI (PHP-FPM) | Connection pooling to FPM |
| **Static perf** | `openRead` stream | zero-copy/sendfile, ranges, caching, compression |
| **Caching** | None | Response cache + reverse-proxy cache |
| **Config** | CLI flags | Declarative file, validation, hot reload |
| **Observability** | stdout logs | Structured logs, Prometheus metrics, OTel tracing |
| **Security** | Traversal guard | TLS, rate limits, header policy, request limits |
| **Graceful lifecycle** | ✅ drain + zero-downtime reload (SIGHUP), worker respawn | Config-validated reload |
| **Testing** | Unit tests | Conformance suites, load, soak, fuzz |

## Key architectural decision

`dart:io` `HttpServer` handles HTTP/1.1 well but does **not** expose HTTP/2 or
HTTP/3. To reach the target we must own more of the stack:

- **HTTP/1.1 & HTTP/2:** terminate TLS with `dart:io` `SecureServerSocket`, read
  the ALPN-selected protocol, and run our own h2 framing layer (or a vetted
  package) on raw sockets. HTTP/1.1 can reuse `dart:io` parsing initially.
- **HTTP/3/QUIC:** QUIC runs over UDP and is not in `dart:io`. The plan adopts
  the pure-Dart **[`dart_quiche`](https://pub.dev/packages/dart_quiche)** stack
  (QUIC + HTTP/3 + QPACK, no FFI); options and caveats are evaluated in
  [04-protocols.md](04-protocols.md).

This gap analysis drives the phased roadmap in [10-roadmap.md](10-roadmap.md).
