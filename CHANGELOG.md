## 1.0.0

- Apache-style web server: static file serving with MIME types, DirectoryIndex,
  and PHP execution via `php-cgi` over CGI/1.1 (environment + stdin/stdout).
- PATH_INFO splitting, directory-traversal protection, and Common Log Format
  access logging.
- Non-blocking, worker-per-core isolate supervisor: N workers share one
  listening socket (`--workers`, defaults to CPU count).
