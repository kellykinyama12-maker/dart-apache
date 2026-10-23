# dart-apache

A Dart web server that serves static files and executes PHP, following the
request-handling model of the Apache HTTP Server.

Like Apache, this server does not interpret PHP itself. It delegates PHP
execution to the `php-cgi` binary over the CGI/1.1 protocol: request metadata is
passed as environment variables, the request body is piped to the interpreter's
stdin, and the response (headers + body) is read back from its stdout.

## Why dart-apache?

**TL;DR** — Reach for it when you want **modern transport + an embedded Dart app
server in one binary**. Keep nginx when you just need to blast static files fast.

What makes it different (not just "another webserver"):

- **HTTP/3 + WebTransport in pure Dart — no C library.** The whole QUIC / HTTP/3
  / WebTransport stack is pure Dart (no OpenSSL, no `quiche.so`, no FFI).
  Bidirectional streams and datagrams work out of the box, auto-upgraded from
  HTTP/1.1 via `Alt-Svc`.
- **Native WebTransport ↔ Livewire bridge.** A drop-in Composer package lets
  browser WebTransport frames drive a Laravel/Livewire backend — a capability
  Apache and nginx don't offer at all. Measured ~40–50% cheaper per request than
  fetch-over-h3.
- **One binary: embed *or* serve.** A single executable serves PHP + static like
  a classic webserver **or** hosts native in-process Dart handlers
  (`DartApp`/`DartRoute`, optional Shelf bridge) — the same handler runs over h3
  and h1. No PHP-FPM pool or reverse-proxy sidecar for Dart apps.
- **`--cache` — ~176× on cacheable dynamic content.** An RFC 9111-style shared
  cache with stale-while-revalidate took a cacheable PHP endpoint from ~740 to
  ~130,000 req/s.
- **Standards-correct static serving.** ETags, conditional `304`, byte ranges
  (`206`/`416`), `If-Range`, gzip with `Vary`, ~70 MIME types, dotfile denial,
  directory `301`, method gating (`405`/`OPTIONS`), `413`/`414` limits.
- **PHP compatibility that doesn't break.** Byte-identical `php-cgi` behavior
  with front-controller / SPA fallback.

Honest trade-offs (so the pros stay credible):

- **Static throughput is ~47–65× slower than nginx** — we don't beat C +
  `sendfile`. If your workload is "serve static files fast," use nginx.
- **It's young** — no disk-backed cache, no `/metrics` observability yet, no
  YAML config / hot-reload (only `SIGHUP` reload today).

## Features (Apache equivalents)

- **DocumentRoot** — serves static files with correct `Content-Type` (MIME) and
  `Content-Length`.
- **DirectoryIndex** — a request for a directory serves `index.php`, then
  `index.html`.
- **PHP via CGI** — runs `php-cgi` with a full CGI environment
  (`SCRIPT_FILENAME`, `QUERY_STRING`, `REQUEST_METHOD`, `CONTENT_LENGTH`,
  `PATH_INFO`, `REMOTE_ADDR`, `SERVER_*`, all `HTTP_*` request headers, and
  `REDIRECT_STATUS`).
- **PATH_INFO** — `/info.php/a/b` runs `info.php` with `PATH_INFO=/a/b`.
- **Security** — directory traversal outside the DocumentRoot is rejected with
  `403`; missing paths return `404`.
- **Logging** — access logs in Common Log Format, like Apache's `access_log`.

## Requirements

- Dart SDK.
- `php-cgi` on your `PATH` (or point to it with `--php-cgi=`).

## Usage

```sh
dart run bin/dart_apache.dart --root=./public --port=8080
```

Flags:

| Flag             | Default     | Apache equivalent |
| ---------------- | ----------- | ----------------- |
| `--address=`     | `127.0.0.1` | `Listen` address  |
| `--port=`        | `8080`      | `Listen` port     |
| `--root=`        | current dir | `DocumentRoot`    |
| `--php-cgi=`     | `php-cgi`   | CGI handler       |
| `--php-fpm=`     | (unset)     | FastCGI target `host:port` or `unix:/path` (PHP-FPM) |
| `--server-name=` | `localhost` | `ServerName`      |
| `--workers=`     | CPU count   | `worker_processes` (one isolate per core, shared socket) |
| `--advertise-h3=`| (unset)     | Advertise HTTP/3 on this UDP port via the `Alt-Svc` header |
| `--http3`        | off         | Co-locate HTTP/3 (QUIC) on the same port; auto-advertises via `Alt-Svc` (needs `--dev` or `--tls-cert`/`--tls-key`) |
| `--https`        | off         | Terminate TLS on the HTTP/1.1 (TCP) listener (needs `--dev` or `--tls-cert`/`--tls-key`) |
| `--proxy=`       | (unset)     | Reverse-proxy route `/(prefix)=http://host:port[,http://host2:port]` (repeatable, round-robin) |
| `--idle-timeout=`| `120`       | Keep-alive idle timeout in seconds (slowloris defense) |
| `--max-body=`    | `10485760`  | Max request body in bytes (`413` beyond this) |
| `--dart-cgi`     | off         | Run `.dart` files as CGI scripts via the Dart VM (edit, no compile — the Dart analog of `php-cgi`) |
| `--dart-exe=`    | `dart`      | Path to the `dart` executable used by `--dart-cgi` |
| `--static-cache` | off         | Cache hot static files in memory (bytes + ETag + gzip; `open_file_cache` analog) — ~7–8× faster static |
| `--static-cache-max-bytes=` | `1048576` | Largest file the static cache holds per entry |

Then open `http://127.0.0.1:8080/`.

## Building native binaries (incl. Linux cross-compile)

AOT-compile to a standalone native executable (faster startup/throughput than
`dart run`). Dart can **cross-compile to Linux from any host**:

```sh
# all three executables -> build/*-linux-x64
dart run tool/build_linux.dart          # or: dart run tool/build_linux.dart arm64

# or a single binary for the host OS
dart compile exe bin/dart_apache.dart -o build/dart_apache
```

## HTTP/3 (experimental)

Run HTTP/1.1 and HTTP/3 together in **one process on one port** (`--http3`). The
HTTP/1.1 responses automatically advertise the co-located HTTP/3 listener via
`Alt-Svc`, so clients discover and upgrade to QUIC. Requires a TLS certificate
(`--dev` for a generated self-signed one, or `--tls-cert`/`--tls-key`):

```sh
dart run bin/dart_apache.dart --root=./public --port=8080 --http3 --dev
```

With `--http3` the HTTP/1.1 hop is served over **HTTPS** (TLS), so browsers
honor `Alt-Svc` and upgrade to HTTP/3. The vendored Dart client can follow the
upgrade over a self-signed cert with `--insecure`:

```sh
dart run bin/dart_apache_client.dart https://127.0.0.1:8080/ --insecure
```

The standalone HTTP/3-only server is also available:

```sh
# dev: generated self-signed cert
dart run bin/dart_apache_h3.dart --root=./public --port=4433 --dev

# real certificate
dart run bin/dart_apache_h3.dart --root=./public --port=4433 \
    --tls-cert=cert.pem --tls-key=key.pem
```

Generate a local self-signed `cert.pem` / `key.pem` (no openssl needed):

```sh
dart run tool/gen_dev_cert.dart .
```

Advertise it from the HTTP/1.1 server so clients discover and upgrade to QUIC
(`Alt-Svc: h3=":4433"; ma=86400` on every response):

```sh
dart run bin/dart_apache.dart --root=./public --port=8080 --advertise-h3=4433
```

Fetch h3 directly with the vendored H3 client:

```sh
cd third_party/dart_quiche
dart run bin/interop_h3_get.dart 127.0.0.1 4433 localhost /
```

## Reverse proxy & load balancing

Forward matching request paths to one or more upstreams (round-robin), streaming
request/response bodies with back-pressure and adding `X-Forwarded-*`. Routes
work for both HTTPS/1.1 and HTTP/3. `--proxy` is repeatable; longest prefix wins:

```sh
dart run bin/dart_apache.dart --root=./public --port=8080 \
    --proxy=/api=http://10.0.0.11:9000,http://10.0.0.12:9000 \
    --proxy=/=http://127.0.0.1:9099
```

A failed upstream returns `502 Bad Gateway`.

## Pure-Dart client with automatic HTTP/3 upgrade

`AltSvcHttpClient` is a client for Dart apps that starts on HTTP/1.1, reads the
`Alt-Svc` header, and **transparently upgrades to HTTP/3** for later requests to
the same origin (falling back to HTTP/1.1 if QUIC fails):

```dart
import 'package:dart_apache/dart_apache.dart';

final client = AltSvcHttpClient();
final first = await client.get(Uri.parse('http://127.0.0.1:8080/')); // http/1.1
final second = await client.get(Uri.parse('http://127.0.0.1:8080/')); // h3
print('${first.protocol} then ${second.protocol}'); // http/1.1 then h3
```

Demo (run the h1 server with `--advertise-h3=4433` and the h3 server on 4433):

```sh
dart run bin/dart_apache_client.dart http://127.0.0.1:8080/
```

## Native Dart app handlers (and PHP parity)

Besides static + PHP, dart-apache can serve **in-process Dart handlers** on the
same ports (HTTP/1.1 and HTTP/3) — no subprocess, no second socket. Register
routes with a top-level `DartAppBuilder` and run them via `ServerSupervisor`:

```dart
DartApp buildApp(ServerConfig config) => DartApp([
      DartRoute.exact('/api/hello', (e, r) async {
        await r.writeJson({'hello': e.uri.queryParameters['name'] ?? 'world'});
      }, methods: {'GET'}),
    ]);
```

See [`example/dart_app.dart`](example/dart_app.dart).

> **New to writing Dart handlers here?** The full developer guide is
> [docs/19-dart-development.md](docs/19-dart-development.md) — routing, the
> request/response contract, the isolate rule, WebTransport, running, and
> testing.

### Prove the Dart app matches your PHP app

[`example/parity_app.dart`](example/parity_app.dart) re-implements the sample
PHP app (`public/*.php`) as native Dart handlers, so you can **A/B the two**:

```sh
# Dart equivalents mounted under /parity/* alongside the PHP files:
dart run example/parity_app.dart --root=./public --port=8080
#   GET /echo.php         (PHP)      vs  POST /parity/echo    (Dart)
#   GET /index.php?name=x (PHP)      vs  GET  /parity/?name=x (Dart)

# Or as a drop-in replacement: Dart handlers mounted at the real .php paths,
# so the same URLs are served by Dart instead of php-cgi:
dart run example/parity_app.dart --root=./public --port=8080 --dropin
```

[`test/parity_test.dart`](test/parity_test.dart) locks this down: it runs the
PHP and Dart versions and asserts equivalent responses (byte-identical bodies,
matching status/headers/JSON). Run it with:

```sh
dart test -t e2e --run-skipped test/parity_test.dart
```

## Project layout

- `bin/dart_apache.dart` — entry point / CLI.
- `lib/src/supervisor.dart` — worker-per-core isolate supervisor (shared socket,
  respawn, zero-downtime reload).
- `lib/src/server.dart` — HTTP server and request dispatch.
- `lib/src/request_resolver.dart` — URL-to-filesystem mapping, DirectoryIndex,
  PATH_INFO splitting, traversal protection.
- `lib/src/php/` — PHP backends: streaming `php-cgi` (CGI) and FastCGI (PHP-FPM),
  shared CGI param/response handling.
- `lib/src/http3/` — experimental HTTP/3 (QUIC) server over `dart_quiche`.
- `lib/src/client/` — Alt-Svc-aware HTTP client that auto-upgrades to HTTP/3.
- `lib/src/mime_types.dart` — MIME type table.
- `lib/src/config.dart` — server configuration.
- `bin/dart_apache_h3.dart` — experimental HTTP/3 entry point.
- `bin/dart_apache_client.dart` — Alt-Svc auto-upgrade client demo.
- `public/` — sample DocumentRoot with a PHP page and a static page.
