import 'dart:io';

import 'package:dart_apache/dart_apache.dart';

/// Example: an MVC-style route that renders a Blaze template (the Blade analog)
/// over HTTP/1.1 + HTTP/3. Views live in `example/views/*.blaze.html`.
///
/// Run (dev, edit templates and refresh — no recompile):
///   dart run example/blaze_app.dart --root=./public --port=8080
///   GET http://127.0.0.1:8080/?name=ada
///
/// [buildApp] is top-level so it can cross the worker-isolate boundary.
DartApp buildApp(ServerConfig config) {
  // One engine per worker isolate; cache: false so template edits show up.
  final views = BlazeEngine('example/views', cache: false);
  return DartApp([
    DartRoute.exact('/', (e, r) async {
      final html = views.render('home', {
        'title': 'Blaze demo',
        'name': e.uri.queryParameters['name'] ?? 'world',
        'protocol': e.protocol,
        'items': ['alpha', 'beta', 'gamma'],
      });
      await r.writeText(html, contentType: 'text/html; charset=UTF-8');
    }, methods: {'GET'}),
  ]);
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
