# 19 — Developing in Dart on dart-apache

How to write server-side **Dart apps** that run *inside* dart-apache — native
in-process request handlers (and WebTransport sessions) that serve over HTTP/1.1
and HTTP/3 on the same port, alongside (or instead of) PHP and static files.

No subprocess, no second socket: a Dart handler runs in the serving isolate and
the **same handler serves h1 and h3 identically**.

## 1. The mental model

- A request is a transport-agnostic [`ServerExchange`]; you reply through a
  [`ServerResponse`]. Your code never sees QUIC vs TCP.
- You register **routes** in a [`DartApp`]; the pipeline runs them **before**
  static/PHP. No route matches → it falls through to static/PHP.
- Handlers run in **worker isolates**. You hand the server a *top-level*
  `DartAppBuilder` function; it runs once inside each worker to build that
  worker's routes.

## 2. Quick start

```dart
import 'dart:io';
import 'package:dart_apache/dart_apache.dart';

// MUST be top-level (or static): it crosses the isolate boundary.
DartApp buildApp(ServerConfig config) => DartApp([
      DartRoute.exact('/api/hello', (exchange, response) async {
        final name = exchange.uri.queryParameters['name'] ?? 'world';
        await response.writeJson({'hello': name, 'via': exchange.protocol});
      }, methods: {'GET'}),
    ]);

Future<void> main(List<String> args) async {
  final config = ServerConfig.fromArgs(args);
  final server = ServerSupervisor(config, appBuilder: buildApp);
  await server.start();
}
```

```sh
dart run your_app.dart --root=./public --port=8080
# GET http://127.0.0.1:8080/api/hello?name=ada  -> {"hello":"ada","via":"http/1.1"}
```

A fuller example (routes + native WebTransport) is in
[`example/dart_app.dart`](../example/dart_app.dart).

## 3. Routing

```dart
DartRoute.exact('/health', handler);               // only /health
DartRoute.prefix('/api', handler);                 // /api and /api/**
DartRoute.exact('/submit', handler, methods: {'POST'}); // method-gated
```

- **Exact** matches one path; **prefix** matches on a segment boundary (`/api`
  matches `/api` and `/api/x`, not `/apikey`).
- `methods` (upper-case) gates the route; omit to accept any method. A method
  mismatch is treated as *no match* → the request falls through (so a `GET` to a
  `POST`-only route can still hit a static file / PHP).
- **Ordering:** exact routes win over prefix routes; among prefixes the longest
  pattern wins. Order of registration doesn't matter.

## 4. Reading the request — `ServerExchange`

```dart
exchange.method            // 'GET', 'POST', …
exchange.uri               // path + query (exchange.uri.queryParameters['name'])
exchange.scheme            // 'http' | 'https'
exchange.authority         // host[:port]
exchange.protocol          // 'h3' | 'http/1.1'  (for logs)
exchange.contentType       // request Content-Type, or null
exchange.contentLength     // declared length, or -1 if unknown (chunked)
exchange.remoteAddress     // client IP
exchange.forEachHeader((name, value) { … });   // lower-case names, values joined
```

Read the body as a byte stream:

```dart
final bytes = await exchange.body.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
final text  = utf8.decode(bytes);
final json  = jsonDecode(text);
```

Collect headers into a map when you need lookups:

```dart
final headers = <String, String>{};
exchange.forEachHeader((n, v) => headers[n.toLowerCase()] = v);
final auth = headers['authorization'];
```

## 5. Writing the response — `ServerResponse`

The handler **owns the full response lifecycle**: set status/headers, stream the
body, and `close()`. The `DartResponseWrite` conveniences do all of that at
once (and you can't forget to close):

```dart
await response.writeText('hello');                       // 200 text/plain
await response.writeJson({'ok': true}, status: 201);     // 201 application/json
await response.writeBytes(bytes, contentType: 'image/png');
```

Set extra headers **before** the write call (the write sets status +
content-type + content-length, then closes — your earlier headers persist):

```dart
response.setHeader('cache-control', 'max-age=60');
await response.writeText('cacheable');
```

Low-level streaming (for large/streamed bodies):

```dart
response.setStatus(200);
response.setHeader('content-type', 'text/plain');
await response.addStream(someByteStream);
await response.close();
```

## 6. The isolate rule (read this once)

Workers are **isolates**, and `ServerConfig` is *copied* across the boundary.
So:

- The `DartAppBuilder` you pass to `ServerSupervisor` **must be top-level or
  static** — closures can't cross the isolate boundary.
- It is invoked **inside each worker** with that worker's `config`, so handler
  closures you create in the builder are fine (they live in the worker).
- You may capture `config` in a handler (it's built per-worker). Do **not** try
  to share mutable cross-request state by riding on `config`; use a per-worker
  object constructed inside the builder instead.

```dart
DartApp buildApp(ServerConfig config) {
  final store = InMemoryStore();              // one per worker isolate
  return DartApp([
    DartRoute.exact('/count', (e, r) => r.writeText('${store.next()}')),
  ]);
}
```

If you need a single shared store across all workers, run `--workers=1`, or put
the shared state behind the server (a DB, the reverse proxy, etc.).

## 7. WebTransport handlers (real-time, HTTP/3)

Register a native WebTransport session handler via `DartApp(wt: …)`. It owns
every inbound WT message (datagrams + uni/bidi streams) and replies in-process —
no PHP bridge, no subprocess:

```dart
DartApp buildApp(ServerConfig config) => DartApp(
      [/* http routes */],
      wt: (session, message) {
        // message.data, message.isDatagram, message.bidiStreamId
        // session.connect.path / .cookie / .headers
        session.send(message.data);          // echo on the originating stream
        // session.sendUni(bytes) / session.sendDatagram(bytes)
      },
    );
```

Run with WebTransport enabled:

```sh
dart run your_app.dart --root=./public --port=8443 --http3 --dev --wt-path=/wt
```

See the WT types: [`WtMessage`], [`WtSession`], [`WtConnect`] in
[`lib/src/wt/wt_handler.dart`](../lib/src/wt/wt_handler.dart).

## 8. Running your app

Use `ServerSupervisor` (worker-per-core isolates, shared socket, graceful
reload):

```dart
final server = ServerSupervisor(
  config,
  kind: WorkerKind.unified, // http1 | http3 | unified (h1 + h3 one port)
  appBuilder: buildApp,
);
await server.start();
```

- `WorkerKind.http1` — HTTP/1.1 (TLS with `--https`).
- `WorkerKind.http3` — HTTP/3 only.
- `WorkerKind.unified` — HTTP/1.1 **and** HTTP/3 on one port (pass `--http3`);
  h1 responses advertise h3 via `Alt-Svc`.

Common flags (all via `ServerConfig.fromArgs`): `--root`, `--port`, `--workers`,
`--http3`, `--dev` (self-signed cert) / `--tls-cert` + `--tls-key`,
`--cache`, `--wt-path`, `--front-controller`, `--spa-fallback`. Full list in
[06-configuration.md](06-configuration.md) and the README.

## 9. Reusing Shelf handlers (optional)

If you already have `shelf`/`shelf_router` code, bridge it to a `DartHandler`
with the dev-only adapter (keeps `shelf` out of the core deps):

```dart
import '../example/shelf_adapter.dart'; // fromShelf(shelf.Handler) -> DartHandler

DartRoute.prefix('/shelf', fromShelf(router.call));
```

Note this reuses only Shelf's *handler contract*, not its server — so it serves
over h3 + h1 like any native handler. (WebTransport stays native; Shelf has no
vocabulary for datagrams/streams.)

## 10. Testing your handlers

- **Unit** — construct a fake `ServerExchange`/`ServerResponse` and call the
  pipeline or handler directly (no sockets). See
  [`test/dart_handler_test.dart`](../test/dart_handler_test.dart).
- **End-to-end** — start an in-process `ApacheServer(config, app: buildApp())`
  on a free port and hit it with `AltSvcHttpClient`. Tag socket/e2e tests
  `@Tags(['e2e'])` so the default `dart test` stays socket-free (run them with
  `dart test -t e2e --run-skipped`).
- **Parity vs PHP** — [`example/parity_app.dart`](../example/parity_app.dart) +
  [`test/parity_test.dart`](../test/parity_test.dart) show how to assert a Dart
  app matches a PHP app response-for-response (see [17-parity.md](17-parity.md)).

## 11. Talking to it from Dart

The matching client ([`AltSvcHttpClient`], [`WebTransportClient`]) speaks the
same stack: HTTP/1.1 with automatic HTTP/3 upgrade (pooled), interceptors,
retry, timeout/cancel, JSON/query/multipart, and native WebTransport. See the
README "Pure-Dart client" section.

## 12. Gotchas checklist

- `DartAppBuilder` **must be top-level/static**; build per-worker state inside
  it, not on `config`.
- A handler **must `close()`** the response — prefer `writeText`/`writeJson`/
  `writeBytes`.
- Set custom headers **before** the `write…` call.
- `methods` mismatch = fall-through (not 405); gate deliberately if you want a
  hard 405.
- The **same handler runs over h1 and h3** — don't assume a transport.
- Don't block the event loop; offload heavy CPU to an `Isolate`.

[`ServerExchange`]: ../lib/src/pipeline/server_exchange.dart
[`ServerResponse`]: ../lib/src/pipeline/server_exchange.dart
[`DartApp`]: ../lib/src/pipeline/dart_handler.dart
[`WtMessage`]: ../lib/src/wt/wt_handler.dart
[`WtSession`]: ../lib/src/wt/wt_handler.dart
[`WtConnect`]: ../lib/src/wt/wt_handler.dart
[`AltSvcHttpClient`]: ../lib/src/client/alt_svc_client.dart
[`WebTransportClient`]: ../lib/src/client/wt_client.dart
