# 08 — Observability

Every subsystem must be measurable in production.

## Logging

- **Structured access logs** (JSON by default; CLF/combined for compatibility).
  Current CLF logging in [server.dart](../lib/src/server.dart) becomes one
  pluggable formatter.
- Fields: timestamp, remote addr, host, method, target, protocol (h1/h2/h3),
  status, bytes, durations (TTFB, total), upstream, cache status, request id.
- **Error logs** with severity levels and sampling for repetitive errors.
- **Correlation**: generate/propagate a request ID (`X-Request-Id`) and trace
  context across upstreams.
- Async, non-blocking log writers with bounded buffers; never block request
  handling on I/O.

## Metrics (Prometheus)

Exposed on a dedicated endpoint (e.g., `127.0.0.1:9113/metrics`):

- **Connections**: accepted, active, by protocol, TLS handshake rate/errors.
- **Requests**: rate, in-flight, by status class, by vhost/location.
- **Latency histograms**: TTFB and total, per route and upstream.
- **Upstreams**: health state, connection pool usage, retries, ejections.
- **Cache**: hit/miss/stale/bypass ratios, size, evictions.
- **Resources**: isolate CPU/event-loop lag, memory, open FDs, buffer pool use.
- **Protocol health**: h2/h3 stream counts, flow-control stalls, GOAWAYs,
  QUIC loss/retransmit stats.

## Tracing (OpenTelemetry)

- Emit **OTLP** spans for request → routing → handler → upstream, with timing
  and status.
- Configurable sampling; propagate W3C `traceparent`.
- Useful for diagnosing tail latency across the proxy path.

## Health & readiness

- **Liveness**: process/event-loop responsive.
- **Readiness**: config loaded, sockets bound, upstreams reachable.
- Endpoints for orchestrators (Kubernetes probes) and load balancers.

## Runtime introspection

- Admin/status endpoint (secured): active connections, upstream states, config
  version/hash, uptime, reload history.
- Optional live profiling hooks (CPU/alloc) gated behind auth.

## Dashboards & alerts (ops deliverable)

- Reference Grafana dashboards for the metrics above.
- Alert rules: error-rate spikes, latency SLO breaches, upstream unhealthy,
  handshake failures, event-loop lag, memory growth.
