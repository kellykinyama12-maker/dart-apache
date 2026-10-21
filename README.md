# dart-apache

A Dart web server that serves static files and executes PHP, following the
request-handling model of the Apache HTTP Server.

Like Apache, this server does not interpret PHP itself. It delegates PHP
execution to the `php-cgi` binary over the CGI/1.1 protocol: request metadata is
passed as environment variables, the request body is piped to the interpreter's
stdin, and the response (headers + body) is read back from its stdout.

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

Then open `http://127.0.0.1:8080/`.

## HTTP/3 (experimental)

A proof-of-concept HTTP/3 (QUIC) server serves the same static files and PHP
over the pure-Dart [`dart_quiche`](third_party/dart_quiche) transport (QUIC +
TLS 1.3, self-signed cert):

```sh
dart run bin/dart_apache_h3.dart --root=./public --port=4433
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
