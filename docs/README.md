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

## Reading order

Start with [01-vision-and-goals.md](01-vision-and-goals.md), then
[02-gap-analysis.md](02-gap-analysis.md), then follow the numbered sequence.
The [10-roadmap.md](10-roadmap.md) ties every capability to a delivery phase.
