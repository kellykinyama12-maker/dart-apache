## 1.0.0

- Apache-style web server: static file serving with MIME types, DirectoryIndex,
  and PHP execution via `php-cgi` over CGI/1.1 (environment + stdin/stdout).
- PATH_INFO splitting, directory-traversal protection, and Common Log Format
  access logging.
- Non-blocking, worker-per-core isolate supervisor: N workers share one
  listening socket (`--workers`, defaults to CPU count).
- Streaming PHP with end-to-end back-pressure: request body streamed to the
  interpreter and response streamed back to the client (no full buffering).
- FastCGI backend for PHP-FPM (`--php-fpm=host:port` or `unix:/path`), with a
  unit-tested wire codec; `php-cgi` remains the default.
- Supervisor hardening: automatic worker respawn on crash and zero-downtime
  reload (SIGHUP on POSIX) that drains the old worker generation.
- Crash-loop protection: respawns use exponential backoff and give up after
  repeated rapid crashes.
- Request limits: configurable keep-alive idle timeout (`--idle-timeout`) and
  max request body (`--max-body`, returns `413`).
- Linux cross-compilation helper (`tool/build_linux.dart`) and AOT build docs.
- Unified, transport-agnostic request pipeline (`ServerExchange` / `ServerResponse`
  contract + `RequestPipeline`): HTTP/1.1 and HTTP/3 now share one set of static
  and PHP handlers via thin per-transport adapters.
- Experimental **HTTP/3 (QUIC)** server over the pure-Dart `dart_quiche` stack
  (`bin/dart_apache_h3.dart`): terminates QUIC + TLS 1.3, speaks HTTP/3, and
  serves static files and PHP via `php-cgi`.
- HTTP/3 discovery: the HTTP/1.1 server advertises HTTP/3 via the `Alt-Svc`
  header (`--advertise-h3=PORT`), so capable clients upgrade to QUIC.
- Pure-Dart `AltSvcHttpClient`: an HTTP client that discovers HTTP/3 from the
  `Alt-Svc` header and transparently upgrades subsequent requests to HTTP/3
  (with HTTP/1.1 fallback); demo in `bin/dart_apache_client.dart`.
