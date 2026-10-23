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

/// All files for a fresh project named [app]. Keys are relative paths.
Map<String, String> newProjectFiles(String app) {
  final slug = snakeCase(app);
  return {
    'pubspec.yaml': '''
name: $slug
description: A Dartisan app on dart-apache.
publish_to: none
environment:
  sdk: ^3.5.0
dependencies:
  # Point this at your dart-apache checkout (path) or a git ref.
  dart_apache:
    path: ../dart-apache
''',
    'bin/$slug.dart': '''
import 'dart:io';

import 'package:dart_apache/dart_apache.dart';

/// Top-level so it crosses the worker-isolate boundary.
DartApp buildApp(ServerConfig config) {
  final router = Router(views: BlazeEngine('views'));
  router.get('/', (req) => req.view('home', {'name': 'world'}));
  router.get('/hello/:name', (req) => req.view('home', {'name': req.param('name')}));
  return router.toApp();
}

Future<void> main(List<String> args) async {
  final config = ServerConfig.fromArgs(args);
  final server = ServerSupervisor(config, appBuilder: buildApp);
  ProcessSignal.sigint.watch().listen((_) async {
    await server.stop();
    exit(0);
  });
  await server.start();
}
''',
    'views/layout.blaze.html': '''
<!DOCTYPE html>
<html>
<head><title>$slug</title></head>
<body>
@yield('content')
</body>
</html>
''',
    'views/home.blaze.html': '''
@extends('layout')
@section('content')
<h1>Hello, {{ name }}!</h1>
<p>Your Dartisan app is running. Edit views/home.blaze.html.</p>
@endsection
''',
    'README.md': '''
# $slug

A Dartisan app on dart-apache.

```sh
dart pub get
dart run bin/$slug.dart --root=. --port=8080
# or: dartisan serve
```
''',
  };
}
