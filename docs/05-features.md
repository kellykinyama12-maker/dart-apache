# 05 — Features

## Static file serving

- **Zero-copy** delivery via `sendfile`/`TransmitFile` through FFI where the OS
  supports it; fall back to streamed `openRead` otherwise.
- **Byte-range requests** (`Range`/`Content-Range`, multipart ranges) for media
  and resumable downloads.
- **Conditional requests**: `ETag` (strong, content/mtime+size based),
  `Last-Modified`, `If-None-Match`, `If-Modified-Since` → `304`.
- **Compression**: on-the-fly `gzip`/`br` with `Accept-Encoding` negotiation,
  plus precompressed `.gz`/`.br` sidecar files when present (nginx
  `gzip_static` style). Skip already-compressed types.
- **Caching**: open-file descriptor cache + metadata cache; optional in-memory
  small-file cache.
- **Index + autoindex**: `DirectoryIndex` equivalent, optional directory
  listing.
- **MIME**: full type map with charset defaults and override rules.
- **Security**: path normalization, traversal prevention, symlink policy,
  dotfile denial.

## Reverse proxy

```mermaid
flowchart LR
  C[Client] --> S[dart-apache]
  S --> LB{Balancer}
  LB --> U1[(Upstream 1)]
  LB --> U2[(Upstream 2)]
  LB --> U3[(Upstream 3)]
  S --- CA[(Proxy cache)]
```

- **Upstream protocols**: HTTP/1.1 and HTTP/2 to backends; keep-alive
  connection pools per upstream.
- **Header handling**: `X-Forwarded-For`, `X-Forwarded-Proto`, `Forwarded`,
  `Host` override, hop-by-hop header stripping.
- **Streaming**: full-duplex streaming with back-pressure; no full buffering of
  large bodies.
- **Timeouts & retries**: connect/read/write timeouts; safe retries on
  idempotent methods and connection errors; circuit breaking.
- **WebSocket & upgrades**: transparent `Upgrade` passthrough.

## Load balancing

- **Strategies**: round-robin, weighted round-robin, least-connections,
  IP-hash, consistent hashing (for cache affinity).
- **Health checks**: active (periodic probes) and passive (eject on errors),
  with slow-start re-introduction.
- **Session affinity**: cookie or hash based, optional.

## FastCGI (PHP, upgraded from CGI)

The prototype uses one-shot `php-cgi` per request. Enterprise PHP uses
**PHP-FPM over FastCGI** with persistent worker processes.

- Implement a **FastCGI client** (`handlers/fastcgi/`): multiplexed records
  (`BEGIN_REQUEST`, `PARAMS`, `STDIN`, `STDOUT`, `STDERR`, `END_REQUEST`) over
  a pooled TCP/Unix-socket connection to PHP-FPM.
- Map requests to FastCGI params exactly like the current CGI env mapping
  (`SCRIPT_FILENAME`, `QUERY_STRING`, `HTTP_*`, etc.) — the
  [php_handler.dart](../lib/src/php_handler.dart) CGI env logic ports directly.
- Benefits: persistent workers (no per-request process spawn), opcode cache
  reuse, dramatically higher PHP throughput.
- Keep the one-shot CGI handler as a fallback/compat mode.

## Additional gateways

- **SCGI** and **uWSGI** protocols for Python/other app servers.
- **Generic HTTP upstream** covers Node, Go, etc.

## Caching layer

- **Response cache** keyed by method+URI+Vary, honoring `Cache-Control`,
  `Expires`, `ETag`.
- **Proxy cache** for upstream responses with stale-while-revalidate and
  stale-if-error.
- **Storage**: in-memory tier + optional disk tier; LRU/TTL eviction.
- **Purge API** for invalidation.

## Content transforms

- Response compression (above), optional decompression for cache normalization,
  and range handling that cooperates with compression (compress-then-range
  rules).

## Routing & virtual hosts

- **Server blocks** matched by SNI/Host + port.
- **Location matching**: exact, prefix, and regex, with priority ordering.
- **Rewrites & redirects**: internal rewrites, external 3xx, canonical host/SSL
  redirects.
- **Try-files** style fallback chains (file → file → named handler).
