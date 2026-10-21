# 01 — Vision and Goals

## Vision

A high-performance, protocol-complete web server and reverse proxy written in
Dart, suitable for production edge and origin workloads. It serves static
content, runs application backends (PHP via FastCGI, plus generic
HTTP/FastCGI/uWSGI upstreams), and terminates modern transport protocols up to
**HTTP/3 over QUIC**, with the operational maturity expected of nginx: hot
config reload, zero-downtime restarts, observability, and predictable tail
latency.

## Primary goals

1. **HTTP/3-first protocol support** — QUIC + HTTP/3 over TLS 1.3 is the
   primary, reference transport; HTTP/2 and HTTP/1.1 are conformant
   compatibility fallbacks with ALPN negotiation and `Alt-Svc` discovery. See
   [12-http3-integration-plan.md](12-http3-integration-plan.md).
2. **Reverse proxy & load balancing** — upstream pools, health checks, multiple
   balancing strategies, connection reuse/keep-alive to upstreams.
3. **Static serving at scale** — sendfile/zero-copy where possible, byte-range
   requests, conditional requests, compression, and caching.
4. **Application gateways** — FastCGI (PHP-FPM), SCGI/uWSGI, and HTTP upstreams.
5. **Operability** — declarative config, hot reload without dropped
   connections, structured logs, Prometheus metrics, OpenTelemetry tracing.
6. **Security by default** — modern TLS, sane headers, rate limiting, request
   limits, and WAF extension points.
7. **Horizontal scalability** — multi-core via isolates with a shared listening
   socket (SO_REUSEPORT-style acceptor model).

## Non-goals (initially)

- Being a general application framework. It is a server and gateway, not a web
  app runtime.
- Full nginx config-language compatibility. We will provide a clean, typed
  config model, with an optional importer later.
- Windows-first kernel optimizations. Linux is the primary production target;
  Windows/macOS remain supported for development.

## Success criteria

- **Correctness:** passes HTTP/1.1, HTTP/2 (h2spec), and HTTP/3 (quic-interop)
  conformance suites for implemented features.
- **Performance:** within a defined factor of nginx for static file throughput
  and reverse-proxy latency on identical hardware (targets in
  [09-performance.md](09-performance.md)).
- **Reliability:** zero dropped connections during config reload and rolling
  restart; no memory growth under 24h soak tests.
- **Operability:** a single binary/deployable, config validated before apply,
  first-class metrics and logs.

## Guiding principles

- **Standards first:** implement to the RFCs; validate with public conformance
  suites.
- **Safe by default, fast by design:** secure defaults; performance from
  architecture, not micro-hacks.
- **Observable:** every subsystem emits metrics and structured logs.
- **Incremental:** each phase ships a usable, tested server.
