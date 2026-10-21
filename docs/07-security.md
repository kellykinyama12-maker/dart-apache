# 07 — Security

Security is a cross-cutting concern enforced in the pipeline and by defaults.

## Transport security

- **TLS 1.3** preferred; TLS 1.2 only for legacy HTTP/1.1. No TLS < 1.2.
- Strong cipher suites only; disable renegotiation and compression (CRIME).
- **HSTS** by default for TLS vhosts (`Strict-Transport-Security`).
- **OCSP stapling**; certificate chain validation; automatic rotation.
- **ACME/Let's Encrypt** integration for issuance and renewal (later phase).
- QUIC 0-RTT early data restricted to replay-safe, idempotent requests.

## Request hardening (limits)

Enforced before routing so abusive requests are cheap to reject:

- Max request line / header count / total header bytes.
- Max body size (global and per-location overrides).
- Header and connection **timeouts** (slowloris defense).
- HTTP/2 stream limits + RST-flood protection (Rapid Reset, CVE-2023-44487).
- HTTP/3 stream and flow-control limits.
- URI normalization and rejection of malformed/ambiguous targets (request
  smuggling defense: strict `Content-Length`/`Transfer-Encoding` handling).

## Rate limiting & access control

- **Rate limiting**: token-bucket per key (IP, header, cookie); burst + sustain.
  Node-local by default; cluster-wide via shared store (Redis) when configured.
- **Connection limiting** per client.
- **Allow/deny** by IP/CIDR; optional GeoIP.
- **Auth hooks**: Basic/Bearer at the edge; forward-auth (subrequest to an auth
  service) for delegated decisions.

## Response & content security

- Secure default headers (configurable): `X-Content-Type-Options: nosniff`,
  `Referrer-Policy`, `X-Frame-Options`/CSP passthrough, `Permissions-Policy`.
- Strip hop-by-hop and sensitive upstream headers.
- Dotfile and backup-file denial; directory traversal already enforced in
  [request_resolver.dart](../lib/src/request_resolver.dart) and extended for
  symlink policy.

## WAF extension points

- Pluggable request/response inspection middleware (the pipeline stage model in
  [03-architecture.md](03-architecture.md) makes this a first-class extension).
- Optional ModSecurity-style rule engine integration via a clean interface
  (out-of-core; later phase).

## Supply chain & process

- Minimal, audited native FFI dependencies (e.g., the QUIC library); pin and
  verify versions.
- Run workers with least privilege; drop capabilities after binding low ports.
- Reproducible builds; SBOM generation in CI.
- Fuzzing of parsers (h1/h2/h3 framing, HPACK/QPACK, URI) — see
  [11-testing-and-release.md](11-testing-and-release.md).

## Secrets

- Private keys and upstream credentials loaded from files or a secrets manager;
  never logged. Redaction enforced in structured logging.
