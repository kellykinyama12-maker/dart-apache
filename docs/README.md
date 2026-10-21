# dart-apache → Enterprise Web Server Plan

This folder contains the plan to evolve the current CGI-based `dart-apache`
prototype into an enterprise-grade web server comparable to **nginx**, with a
path to **HTTP/3 (QUIC)**, TLS, reverse proxying, and horizontal scalability.

## Documents

| Document | Purpose |
| --- | --- |
| [01-vision-and-goals.md](01-vision-and-goals.md) | Product vision, non-goals, success criteria |
| [02-gap-analysis.md](02-gap-analysis.md) | Where the prototype stands today vs. the target |
| [03-architecture.md](03-architecture.md) | Core runtime: isolates, event loop, connection lifecycle |
| [04-protocols.md](04-protocols.md) | HTTP/1.1, HTTP/2, HTTP/3 (QUIC), TLS, ALPN |
| [05-features.md](05-features.md) | Reverse proxy, load balancing, caching, FastCGI, static serving |
| [06-configuration.md](06-configuration.md) | Declarative config model and hot reload |
| [07-security.md](07-security.md) | TLS, hardening, rate limiting, WAF hooks |
| [08-observability.md](08-observability.md) | Logging, metrics, tracing, health checks |
| [09-performance.md](09-performance.md) | Benchmarks, zero-copy, tuning, capacity targets |
| [10-roadmap.md](10-roadmap.md) | Phased delivery plan with milestones and exit criteria |
| [11-testing-and-release.md](11-testing-and-release.md) | Test strategy, CI, compliance, release process |
| [12-http3-integration-plan.md](12-http3-integration-plan.md) | **HTTP/3-first**: status of the h3 PoC + plan to route HTTP/3 through the unified pipeline |

## Reading order

Start with [01-vision-and-goals.md](01-vision-and-goals.md), then
[02-gap-analysis.md](02-gap-analysis.md), then follow the numbered sequence.
The [10-roadmap.md](10-roadmap.md) ties every capability to a delivery phase.

## Current status (snapshot)

Implemented in the prototype today:

- Non-blocking HTTP/1.1 server, **worker-per-core isolates** over a shared
  socket, with **respawn** and **zero-downtime reload** (SIGHUP on POSIX).
- Static file serving (MIME, DirectoryIndex) and **directory-traversal**
  protection.
- **PHP** via streaming `php-cgi` (CGI/1.1) and **FastCGI/PHP-FPM**
  (`--php-fpm=`), with end-to-end **back-pressure**.
- **Experimental HTTP/3 (QUIC)** server over pure-Dart `dart_quiche`: serves
  static + PHP (proof-of-concept, not yet pipeline-integrated — see
  [12-http3-integration-plan.md](12-http3-integration-plan.md)).
- Common Log Format access logging.

Planned (see [10-roadmap.md](10-roadmap.md)):

- HTTP/2, HTTP/3 (QUIC via vendored `dart_quiche`), TLS 1.3.
- Reverse proxy + load balancing, WebSocket (origin + proxy), WebTransport.
- Caching, declarative config, observability (metrics/tracing), security
  hardening, benchmarking/soak → GA.

> Note: FastCGI and SIGHUP reload are POSIX-oriented and not yet exercised
> end-to-end on Windows (no PHP-FPM / no SIGHUP there). See
> [02-gap-analysis.md](02-gap-analysis.md).
