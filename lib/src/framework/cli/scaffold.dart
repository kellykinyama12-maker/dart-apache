// Code generators for the `dartisan` CLI. Pure string/content functions (no
// IO) so they can be unit-tested; `bin/dartisan.dart` writes the files.

/// Converts `user-profile` / `userProfile` / `user_profile` to `UserProfile`.
String pascalCase(String s) {
  final parts = s.split(RegExp(r'[_\-\s]+')).where((p) => p.isNotEmpty);
  return parts
      .map((p) => p[0].toUpperCase() + p.substring(1))
      .join()
      .replaceAllMapped(RegExp(r'^[a-z]'), (m) => m[0]!.toUpperCase());
}

/// Converts `UserProfile` / `user-profile` to `user_profile`.
String snakeCase(String s) => s
    .replaceAllMapped(RegExp(r'[A-Z]'), (m) => '_${m[0]!.toLowerCase()}')
    .replaceAll(RegExp(r'[\-\s]+'), '_')
    .replaceAll(RegExp(r'^_+'), '')
    .replaceAll(RegExp(r'_+'), '_');

/// Converts `EnsureAdmin` / `ensure-admin` to `ensureAdmin`.
String camelCase(String s) {
  final p = pascalCase(s);
  return p.isEmpty ? p : p[0].toLowerCase() + p.substring(1);
}

/// A controller class with an `index` action.
String controllerSource(String name) {
  final cls = '${pascalCase(name)}Controller';
  return '''
import 'package:dart_apache/dart_apache.dart';

class $cls {
  Future<void> index(Request request) async {
    await request.sendJson({'controller': '$cls', 'action': 'index'});
  }
}
''';
}

/// A Dartisan Live component (reactive over WebTransport).
String componentSource(String name) {
  final cls = '${pascalCase(name)}Component';
  final slug = snakeCase(name);
  return '''
import 'package:dart_apache/dart_apache.dart';

class $cls extends LiveComponent {
  @override
  String get name => '$slug';

  @override
  Map<String, Object?> initialState() => {'count': 0};

  @override
  Map<String, Object?> update(
      String action, Map<String, Object?> state, Map<String, Object?> payload) {
    final count = (state['count'] as num?)?.toInt() ?? 0;
    return switch (action) {
      'increment' => {'count': count + 1},
      _ => state,
    };
  }

  @override
  String render(Map<String, Object?> state) =>
      '<p>$cls: \${state['count']}</p>'
      '<button data-live-click="increment">+</button>';
}
''';
}

/// A Blaze view template.
String viewSource(String name) => '''
@extends('layout')
@section('content')
<h1>${pascalCase(name)}</h1>
<p>Edit views/${snakeCase(name)}.blaze.html</p>
@endsection
''';

/// A Blaze view component (props + default slot) for `<x-$name>`.
String viewComponentSource(String name) {
  final slug = snakeCase(name);
  return '''
{{-- Use: <x-$slug title="...">body</x-$slug> --}}
<div class="$slug">
  <h2>{{ title }}</h2>
  {!! slot !!}
</div>
''';
}

/// A typed record + repository over the [Database] (edit fields to match your
/// schema). The table name is the pluralized snake_case of [name].
String modelSource(String name, {List<FieldSpec> fields = const []}) {
  final cls = pascalCase(name);
  final table = '${snakeCase(name)}s';
  if (fields.isEmpty) {
    // Default stub with a single `name` field.
    fields = [FieldSpec('name', 'TEXT', 'String')];
  }
  final ctorParams = fields.map((f) => 'this.${f.name}').join(', ');
  final fieldDecls =
      fields.map((f) => '  final ${f.dartType}? ${f.name};').join('\n');
  final fromRow = fields
      .map((f) => "        ${f.name}: ${_fromRowExpr(f)},")
      .join('\n');
  final toMap = fields
      .map((f) => "        if (${f.name} != null) '${f.name}': ${f.name},")
      .join('\n');
  final createSql = createTableSql(table, fields);
  return '''
import 'package:dart_apache/dart_apache.dart';

/// A record for the `$table` table.
class $cls {
  $cls({this.id, $ctorParams});

  final int? id;
$fieldDecls

  factory $cls.fromRow(Map<String, Object?> row) => $cls(
        id: row['id'] as int?,
$fromRow
      );

  Map<String, Object?> toMap() => {
$toMap
      };
}

/// Query helper for [$cls] over any [Database] driver.
class ${cls}Repository {
  ${cls}Repository(this.db);

  final Database db;
  static const table = '$table';

  /// DDL for this model's table (run via SqlDatabase.execute or a migration).
  static const createTableSql = '$createSql';

  Future<List<$cls>> all() async =>
      (await db.table(table).get()).map($cls.fromRow).toList();

  Future<$cls?> find(Object id) async {
    final row = await db.table(table).where('id', id).first();
    return row == null ? null : $cls.fromRow(row);
  }

  Future<$cls> create($cls model) async =>
      $cls.fromRow(await db.table(table).insert(model.toMap()));

  Future<int> update(Object id, Map<String, Object?> values) =>
      db.table(table).where('id', id).update(values);

  Future<int> delete(Object id) => db.table(table).where('id', id).delete();
}
''';
}

/// A middleware stub; register it with `router.use(...)`.
String middlewareSource(String name) {
  final fn = camelCase(name);
  return '''
import 'package:dart_apache/dart_apache.dart';

/// Register with `router.use($fn)`.
final Middleware $fn = (request, next) async {
  // TODO: pre-processing (auth checks, headers, logging, ...).
  await next();
  // TODO: post-processing.
};
''';
}

/// A parsed `name:type` column: its SQL type and Dart type.
class FieldSpec {
  FieldSpec(this.name, this.sqlType, this.dartType);
  final String name;
  final String sqlType;
  final String dartType;
}

/// Parses `name:type` CLI specs into [FieldSpec]s (a bare `name` defaults to
/// text). A `table:<name>` spec is ignored here (callers read it separately).
List<FieldSpec> parseFields(Iterable<String> specs) {
  final out = <FieldSpec>[];
  for (final spec in specs) {
    final i = spec.indexOf(':');
    final name = i < 0 ? spec : spec.substring(0, i);
    final type = i < 0 ? 'text' : spec.substring(i + 1);
    if (name == 'table' || name.isEmpty) continue;
    out.add(_fieldSpec(name, type));
  }
  return out;
}

FieldSpec _fieldSpec(String name, String type) {
  switch (type.toLowerCase()) {
    case 'int':
    case 'integer':
      return FieldSpec(name, 'INTEGER', 'int');
    case 'real':
    case 'double':
    case 'float':
      return FieldSpec(name, 'REAL', 'double');
    case 'bool':
    case 'boolean':
      return FieldSpec(name, 'BOOLEAN', 'bool');
    default:
      return FieldSpec(name, 'TEXT', 'String');
  }
}

String _fromRowExpr(FieldSpec f) {
  switch (f.dartType) {
    case 'int':
      return "(row['${f.name}'] as num?)?.toInt()";
    case 'double':
      return "(row['${f.name}'] as num?)?.toDouble()";
    case 'bool':
      return "row['${f.name}'] as bool?";
    default:
      return "row['${f.name}'] as String?";
  }
}

/// A `CREATE TABLE IF NOT EXISTS` statement (`id` PK + the given [fields]).
String createTableSql(String table, List<FieldSpec> fields) {
  final cols = <String>[
    'id INTEGER PRIMARY KEY AUTOINCREMENT',
    for (final f in fields) '${f.name} ${f.sqlType}',
  ];
  return 'CREATE TABLE IF NOT EXISTS $table (${cols.join(', ')})';
}

/// The table a migration named [name] targets (`create_posts_table` → `posts`).
String tableFromMigrationName(String name) {
  final s = snakeCase(name)
      .replaceFirst(RegExp(r'^create_'), '')
      .replaceFirst(RegExp(r'_table$'), '');
  return s.isEmpty ? snakeCase(name) : s;
}

/// A [Migration] class named [className] whose `name` is [migrationName] (the
/// timestamped id used for ordering). With [fields], `up` creates [table] and
/// `down` drops it; without fields, an editable up/down stub.
String migrationSource(String className, String migrationName,
    {required String table, List<FieldSpec> fields = const []}) {
  if (fields.isEmpty) {
    return '''
import 'package:dart_apache/dart_apache.dart';

class $className implements Migration {
  @override
  String get name => '$migrationName';

  @override
  Future<void> up(SqlDatabase db) async {
    // TODO: await db.execute('CREATE TABLE ...');
  }

  @override
  Future<void> down(SqlDatabase db) async {
    // TODO: await db.execute('DROP TABLE ...');
  }
}
''';
  }
  final createSql = createTableSql(table, fields);
  return '''
import 'package:dart_apache/dart_apache.dart';

class $className implements Migration {
  @override
  String get name => '$migrationName';

  @override
  Future<void> up(SqlDatabase db) =>
      db.execute('$createSql');

  @override
  Future<void> down(SqlDatabase db) =>
      db.execute('DROP TABLE IF EXISTS $table');
}
''';
}

/// All files for a fresh project named [app]. Keys are relative paths.
/// [dartApachePath] is written into the generated pubspec as the path to this
/// framework (the CLI passes an absolute path so the app builds from anywhere).
Map<String, String> newProjectFiles(String app,
    {String dartApachePath = '../dart-apache'}) {
  final slug = snakeCase(app);
  return {
    'pubspec.yaml': '''
name: $slug
description: A Dartisan app on dart-apache.
publish_to: none
environment:
  sdk: ^3.5.0
dependencies:
  # Path to your dart-apache checkout (or swap for a git ref).
  dart_apache:
    path: $dartApachePath
''',
    'bin/$slug.dart': '''
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_apache/dart_apache.dart';

/// A reactive counter streamed over WebTransport/HTTP3 (run with --http3).
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
      'decrement' => {'count': count - 1},
      _ => state,
    };
  }

  @override
  String render(Map<String, Object?> state) =>
      '<p style="font-size:1.5rem">Count: '
      '<strong id="live-count">\${state['count']}</strong></p>'
      '<button data-live-click="decrement">- 1</button> '
      '<button data-live-click="increment">+ 1</button>';
}

// Demo session key. Replace with a 32-byte secret (env var) in production.
final Uint8List _appKey =
    Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + 11) & 0xff));

/// Top-level so it crosses the worker-isolate boundary.
DartApp buildApp(ServerConfig config) {
  final wtPath = config.wtPath ?? '/wt';
  final live = liveMount(CounterComponent(),
      wtPath: wtPath, inlineRuntime: liveRuntimeSource);

  final router = Router(
    views: BlazeEngine('views'),
    sessions: SessionManager(_appKey, secure: false),
    maxBodyBytes: 1 << 20,
    onError: (error, _) => stderr.writeln('error: \$error'),
  );
  router.singleton<InMemoryDatabase>((_) => InMemoryDatabase());
  router.wt = liveWtHandler(LiveRegistry()..register(CounterComponent()));
  router.use(verifyCsrf());

  router.get('/', (req) => req.view('home', {
        'title': 'Home',
        'auth': req.auth.check,
        'user': req.auth.id,
        'name': req.query('name') ?? 'world',
      }));
  router.get('/about', (req) => req.view('about', {
        'title': 'About',
        'auth': req.auth.check,
        'user': req.auth.id,
      }));

  router.get('/login', (req) => req.view('login', {
        'title': 'Log in',
        'auth': req.auth.check,
        'error': null,
        'csrf': req.csrfToken(),
      }));
  router.post('/login', (req) async {
    try {
      final data = await req.validate({'name': 'required|min:2'});
      req.auth.login(data['name'].toString());
      await req.redirect('/dashboard');
    } on ValidationException catch (e) {
      return req.view('login', {
        'title': 'Log in',
        'auth': req.auth.check,
        'error': e.errors.values.first.first,
        'csrf': req.csrfToken(),
      });
    }
  });
  router.post('/logout', (req) async {
    req.auth.logout();
    await req.redirect('/');
  });

  router.group('', () {
    router.get('/dashboard', (req) => req.view('dashboard', {
          'title': 'Dashboard',
          'auth': true,
          'user': req.auth.id,
          'csrf': req.csrfToken(),
          'live': live,
        }));
  }, middleware: [requireAuth(redirectTo: '/login')]);

  return router.toApp();
}

Future<void> main(List<String> args) async {
  final config = ServerConfig.fromArgs(args);
  final http3 = args.contains('--http3');
  final server = ServerSupervisor(config,
      kind: http3 ? WorkerKind.unified : WorkerKind.http1,
      appBuilder: buildApp);
  ProcessSignal.sigint.watch().listen((_) async {
    await server.stop();
    exit(0);
  });
  await server.start();
}
''',
    'views/layout.blaze.html': '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{ title }} · $slug</title>
  <style>
    body { font: 16px/1.5 system-ui, sans-serif; max-width: 40rem; margin: 2rem auto; padding: 0 1rem; }
    nav a { margin-right: 1rem; }
    .error { color: #c0261a; }
  </style>
</head>
<body>
  <nav>
    <a href="/">Home</a>
    <a href="/about">About</a>
    @auth<a href="/dashboard">Dashboard</a>@endauth
    @guest<a href="/login">Log in</a>@endguest
  </nav>
  @yield('content')
</body>
</html>
''',
    'views/home.blaze.html': '''
@extends('layout')
@section('content')
<h1>Hello, {{ name }}!</h1>
<p>Your Dartisan app is running. Edit views/home.blaze.html.</p>
@auth<p>Signed in as <strong>{{ user }}</strong>.</p>@endauth
@endsection
''',
    'views/about.blaze.html': '''
@extends('layout')
@section('content')
<h1>About</h1>
<p>This starter shows routing, Blaze views, sessions + auth, CSRF, DI, and a
reactive Live component — all in one compiled binary.</p>
@endsection
''',
    'views/login.blaze.html': '''
@extends('layout')
@section('content')
<h1>Log in</h1>
@if(error)<p class="error">{{ error }}</p>@endif
<form method="post" action="/login">
  @csrf
  <label>Name <input name="name" autofocus></label>
  <button type="submit">Log in</button>
</form>
<p style="color:#888">Demo auth: any name of 2+ characters.</p>
@endsection
''',
    'views/dashboard.blaze.html': '''
@extends('layout')
@section('content')
<h1>Dashboard</h1>
<p>Welcome, <strong>{{ user }}</strong>.
  <form method="post" action="/logout" style="display:inline">@csrf<button>Log out</button></form>
</p>
<h2>Live counter</h2>
<p style="color:#888">Run with <code>--http3 --dev</code> (HTTPS) so the
WebTransport channel can connect, then click the buttons.</p>
{!! live !!}
@endsection
''',
    'README.md': '''
# $slug

A Dartisan app on dart-apache — routing, Blaze views, sessions + auth, CSRF,
DI, and a reactive Live component in one binary.

## Run

```sh
dart pub get
dart run bin/$slug.dart --root=. --port=8080
```

Open http://127.0.0.1:8080 — `/`, `/about`, `/login` (any name), `/dashboard`.

For the Live counter over WebTransport/HTTP3, run with TLS:

```sh
dart run bin/$slug.dart --root=. --port=8443 --http3 --dev --wt-path=/wt
```

## Generate more

```sh
dartisan make:controller User
dartisan make:component Counter
dartisan make:model Post
dartisan make:middleware EnsureAdmin
dartisan make:view profile
```
''',
  };
}
