import 'dart:io';

import 'package:dart_apache/dart_apache.dart';

/// Example: embed dart-apache and serve native in-process Dart routes
/// (over HTTP/3 + HTTP/1.1) alongside static files and PHP.
///
/// Run:
///   dart run example/dart_app.dart --root=./public --port=8080
///   dart run example/dart_app.dart --root=./public --port=443 --http3 --dev
///
/// Then: GET /api/hello?name=ada  and  POST /api/echo
///
/// [buildApp] MUST be top-level so it can cross the worker-isolate boundary;
/// it runs once inside each worker to build that isolate's route table.
DartApp buildApp(ServerConfig config) => DartApp(
      [
        DartRoute.exact('/api/hello', (exchange, response) async {
          final name = exchange.uri.queryParameters['name'] ?? 'world';
          await response.writeJson({'hello': name, 'via': exchange.protocol});
        }, methods: {'GET'}),
        DartRoute.exact('/api/echo', (exchange, response) async {
          final body = await exchange.body
              .fold<List<int>>(<int>[], (a, b) => a..addAll(b));
          await response.writeBytes(
            body,
            contentType: exchange.contentType ?? 'application/octet-stream',
          );
        }, methods: {'POST'}),
      ],
      // Native WebTransport echo — no PHP, no subprocess. Replies on the same
      // bidi stream, or a fresh uni stream, with a marker prefix.
      wt: (session, message) {
        session.send([...'wt-native:'.codeUnits, ...message.data]);
      },
    );

Future<void> main(List<String> arguments) async {
  final config = ServerConfig.fromArgs(arguments);

  if (!Directory(config.documentRoot).existsSync()) {
    stderr.writeln('DocumentRoot does not exist: ${config.documentRoot}');
    exitCode = 2;
    return;
  }

  final http3 = arguments.contains('--http3');
  if (config.tlsEnabled) {
    final hasCert = config.tlsCertPath != null && config.tlsKeyPath != null;
    if (!hasCert && !config.devMode) {
      stderr.writeln('TLS requires --tls-cert/--tls-key, or --dev.');
      exitCode = 2;
      return;
    }
  }

  final server = ServerSupervisor(
    config,
    kind: http3 ? WorkerKind.unified : WorkerKind.http1,
    appBuilder: buildApp,
  );

  ProcessSignal.sigint.watch().listen((_) async {
    await server.stop();
    exit(0);
  });
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) async {
      await server.stop();
      exit(0);
    });
    ProcessSignal.sighup.watch().listen((_) => server.reload());
  }

  await server.start();
}
