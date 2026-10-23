import 'dart:io';

import 'package:dart_apache/dart_apache.dart';

/// Dartisan Live demo: a reactive counter whose +/- actions run over a native
/// **WebTransport (HTTP/3)** session — no WebSocket, no polling, one binary.
///
/// Run (needs TLS for HTTP/3; --dev makes a self-signed cert):
///   dart run example/live_app.dart --root=./public --port=8443 --http3 --dev --wt-path=/wt
///
/// Open https://127.0.0.1:8443/ in an HTTP/3 browser and click +/-; each click
/// streams the action over WebTransport and morphs the counter in place.

/// A stateless-on-the-server reactive counter. State round-trips to the client.
class CounterComponent extends LiveComponent {
  @override
  String get name => 'counter';

  @override
  Map<String, Object?> initialState() => {'count': 0};

  @override
  Map<String, Object?> update(
    String action,
    Map<String, Object?> state,
    Map<String, Object?> payload,
  ) {
    final count = (state['count'] as num?)?.toInt() ?? 0;
    return switch (action) {
      'increment' => {'count': count + 1},
      'decrement' => {'count': count - 1},
      'reset' => {'count': 0},
      _ => state,
    };
  }

  @override
  String render(Map<String, Object?> state) =>
      '<p style="font-size:2rem">Count: '
      '<strong id="live-count">${state['count']}</strong></p>'
      '<button data-live-click="decrement">− 1</button> '
      '<button data-live-click="increment">+ 1</button> '
      '<button data-live-click="reset">reset</button>';
}

DartApp buildApp(ServerConfig config) {
  final registry = LiveRegistry()..register(CounterComponent());
  final wtPath = config.wtPath ?? '/wt';
  // Inline the client runtime so the demo needs no extra h3 request.
  final runtime = File('public/app/dartisan-live.js').readAsStringSync();
  return DartApp(
    [
      DartRoute.exact('/', (e, r) async {
        final page = '<!DOCTYPE html><html><head><meta charset="utf-8">'
            '<title>Dartisan Live</title></head><body>'
            '<h1>Dartisan Live — counter over WebTransport (HTTP/3)</h1>'
            '${liveMount(CounterComponent(), wtPath: wtPath, inlineRuntime: runtime)}'
            '</body></html>';
        await r.writeText(page, contentType: 'text/html; charset=UTF-8');
      }, methods: {'GET'}),
    ],
    wt: liveWtHandler(registry),
  );
}

Future<void> main(List<String> arguments) async {
  final config = ServerConfig.fromArgs(arguments);
  if (!Directory(config.documentRoot).existsSync()) {
    stderr.writeln('DocumentRoot does not exist: ${config.documentRoot}');
    exitCode = 2;
    return;
  }
  final http3 = arguments.contains('--http3');
  final server = ServerSupervisor(
    config,
    kind: http3 ? WorkerKind.unified : WorkerKind.http1,
    appBuilder: buildApp,
  );
  ProcessSignal.sigint.watch().listen((_) async {
    await server.stop();
    exit(0);
  });
  await server.start();
}
