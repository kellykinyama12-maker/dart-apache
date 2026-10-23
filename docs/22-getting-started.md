# 22 — Getting started: build a Dartisan app in 10 minutes

This is the hands-on tour. In ten minutes you'll scaffold a project, add routes
and a Blaze view, validate a form, query a store, and wire up a **reactive Live
component streamed over HTTP/3 + WebTransport** — the thing a PHP stack can't do
without bolting on extra infrastructure.

> Dartisan is the app framework that ships *inside* dart-apache. Everything
> compiles into **one native binary** (server + app), and your app stays
> backward compatible with PHP, static files, and `--dart-cgi`.

## 0. Prerequisites

- Dart SDK 3.5+ (`dart --version`).
- A checkout of dart-apache (this repo). The scaffolder points a new project's
  `pubspec.yaml` at `../dart-apache` by default.

## 1. Scaffold a project (`dartisan new`)

The `dartisan` CLI is the Artisan analog. From the dart-apache checkout:

```sh
dart run bin/dartisan.dart new blog
cd ../blog     # created next to dart-apache
dart pub get
```

This generates:

```
blog/
  pubspec.yaml            # depends on dart_apache (path: ../dart-apache)
  bin/blog.dart           # the server entrypoint (top-level buildApp)
  views/
    layout.blaze.html     # @yield('content')
    home.blaze.html       # @extends('layout')
  README.md
```

Run it (dev mode — edit templates and refresh, no recompile):

```sh
dart run bin/blog.dart --root=. --port=8080
# GET http://127.0.0.1:8080/         -> Hello, world!
# GET http://127.0.0.1:8080/hello/ada -> Hello, ada!
```

## 2. Routes, controllers, and the `Request` facade

`bin/blog.dart` builds a `Router` inside a **top-level** `buildApp` (it has to
cross the worker-isolate boundary). Routes take a `Request` and return a
response via the responders:

```dart
DartApp buildApp(ServerConfig config) {
  final router = Router(views: BlazeEngine('views'));

  router.get('/', (req) => req.view('home', {'name': 'world'}));

  // :param path segments
  router.get('/hello/:name', (req) => req.view('home', {'name': req.param('name')}));

  // JSON responder
  router.get('/api/ping', (req) => req.sendJson({'ok': true}));

  // Route groups: shared prefix + middleware
  router.group('/admin', () {
    router.get('/stats', (req) => req.sendJson({'uptime': 1}));
  }, middleware: [requireAuth]);

  return router.toApp();
}
```

`Request` gives you `param(name)`, `query(name)`, `header(name)`, `body()`,
`json()`, and responders `view / html / text / sendJson / redirect`.

**Middleware** is the familiar onion — do work, then call `next()` (or don't, to
short-circuit):

```dart
FutureOr<void> requireAuth(Request req, FutureOr<void> Function() next) async {
  if (req.header('authorization') == null) {
    return req.text('Unauthorized', status: 401);
  }
  await next();
}
```

Register it globally with `router.use(requireAuth)` or per-group as above.

## 3. Blaze templating (the Blade analog)

Views live in `views/*.blaze.html`. Blaze runs under AOT (no `eval`) with a safe
mini expression language:

```html
@extends('layout')
@section('content')
  <h1>Hello, {{ name }}!</h1>        {{-- escaped output --}}

  @if(items.isEmpty)
    <p>No items yet.</p>
  @else
    <ul>
      @foreach(items as item)
        <li>{{ loop.index }}: {{ item }}</li>
      @endforeach
    </ul>
  @endif

  {!! trustedHtml !!}               {{-- raw, unescaped --}}
@endsection
```

`{{ }}` escapes, `{!! !!}` is raw, `{{-- --}}` is a comment, and `@foreach`
binds `loop.{index,first,last,count}`. `@include('partial')` pulls in another
template; dotted names map to folders (`@include('users.row')` →
`views/users/row.blaze.html`).

## 4. Validate input (`req.validate`)

Laravel-style pipe rules. On failure it throws `ValidationException` (map it to
a 422):

```dart
router.post('/users', (req) async {
  final data = await req.validate({
    'name': 'required|min:3',
    'email': 'required|email',
    'role': 'in:admin,editor,viewer',
    'age': 'numeric|max:120',
  });
  await req.sendJson({'created': data});
});
```

Rules: `required`, `email`, `numeric`, `integer`, `boolean`, `url`, `alpha`,
`alphanum`, `min:N`, `max:N`, `in:a,b,c`, `confirmed`. Optional fields that are
absent skip their rules; every failing rule is collected per field.

## 5. Store and query data (the Eloquent-lite layer)

The data layer is a chainable query API over a pluggable `Database`. The default
`InMemoryDatabase` is pure Dart — zero dependencies, no FFI — great for tests,
prototypes, and small apps. A real driver (e.g. a pure-Dart Postgres) can
implement the same `Database` interface later with no API change.

```dart
final db = InMemoryDatabase();

// insert() auto-assigns an `id` and returns the stored row
await db.table('users').insert({'name': 'ada', 'age': 36});
await db.table('users').insert({'name': 'grace', 'age': 85});

// chainable filters + terminal operations
final adults = await db.table('users')
    .where('age', '>=', 18)
    .orderBy('name')
    .get();

final ada = await db.table('users').where('name', 'ada').first();

await db.table('users').where('name', 'ada').update({'age': 37});
await db.table('users').where('age', '>', 100).delete();

final total = await db.table('users').count();
```

Operators: `where(field, value)` for equality, `where(field, op, value)` for
`= != < > <= >= like`, and `whereIn(field, [...])`. Returned rows are copies, so
reads can't accidentally mutate the store.

> One `InMemoryDatabase` lives per worker isolate — fine for demos and
> read-mostly data. For shared, persistent state across workers, use a wire
> driver (coming) that talks to an external database.

## 6. The differentiator: a reactive Live component over HTTP/3

This is the part PHP can't match natively. A `LiveComponent` renders server-side
and streams updates over a **native WebTransport session** on HTTP/3 — same
binary, no WebSocket tier, no second process.

Generate one:

```sh
dart run bin/dartisan.dart make:component Counter
```

That writes a component like:

```dart
class CounterComponent extends LiveComponent {
  @override
  String get name => 'counter';

  @override
  Map<String, Object?> initialState() => {'count': 0};

  @override
  Map<String, Object?> update(String action, Map<String, Object?> state,
      Map<String, Object?> payload) {
    final count = (state['count'] as num?)?.toInt() ?? 0;
    return switch (action) {
      'increment' => {'count': count + 1},
      _ => state,
    };
  }

  @override
  String render(Map<String, Object?> state) =>
      '<p>Count: ${state['count']}</p>'
      '<button data-live-click="increment">+</button>';
}
```

Wire it into the server (register the component for the WT channel, and mount it
into a page). The client runtime opens a WebTransport stream per action, sends
the state, and morphs the returned HTML in place:

```dart
DartApp buildApp(ServerConfig config) {
  final registry = LiveRegistry()..register(CounterComponent());
  final router = Router(views: BlazeEngine('views'));
  router.wt = liveWtHandler(registry);

  router.get('/counter', (req) => req.html(liveMount(
        CounterComponent(),
        // Inline the runtime so it loads reliably alongside an h3 page.
        inlineRuntime: File('public/app/dartisan-live.js').readAsStringSync(),
      )));

  return router.toApp();
}
```

Run it over HTTP/3 (TLS + QUIC) and click the button — the count updates over
WebTransport, server-rendered, with no page reload. See
[14-livewire-webtransport.md](14-livewire-webtransport.md) for how the WT bridge
works and [example/live_app.dart](../example/live_app.dart) for a complete,
browser-verified example.

## 7. Ship one binary

When you're ready, compile the whole thing — server **and** app — into a single
native executable:

```sh
dart compile exe bin/blog.dart -o build/blog
# cross-compile for Linux from any host:
dart compile exe bin/blog.dart -o build/blog-linux-x64 \
  --target-os linux --target-arch x64
```

Copy that one file plus your `views/` and `public/` to the server and run it.
No PHP-FPM, no nginx, no WebSocket tier — one process.

## Where to go next

- [21-framework.md](21-framework.md) — the full framework plan and the Laravel /
  Flutter parity maps.
- [20-beat-the-giants.md](20-beat-the-giants.md) — the measured benchmarks (why
  this wins dynamic app workloads 2–3.8× over nginx+php-fpm).
- [19-dart-development.md](19-dart-development.md) — writing low-level Dart
  handlers and WebTransport sessions directly on the pipeline.
- [16-deploy.md](16-deploy.md) — production deploy (systemd, TLS, WT ticket key).
