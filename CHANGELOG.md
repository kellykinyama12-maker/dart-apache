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
