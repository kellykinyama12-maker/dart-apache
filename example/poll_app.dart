import 'dart:convert';
import 'dart:io';

import 'package:dart_apache/dart_apache.dart';

/// A live poll over WebTransport/HTTP3: click an option and every connected
/// view's tallies + bars update from server-rendered state. Richer state than
/// the counter, so the server-side diff saves more on each vote.
///
/// Run (Live needs TLS for WebTransport):
///   dart run example/poll_app.dart --root=./public --port=8443 --http3 --dev --wt-path=/wt
class PollComponent extends LiveComponent {
  static const _options = ['Dart', 'PHP', 'Go', 'Rust'];

  @override
  String get name => 'poll';

  @override
  Map<String, Object?> initialState() =>
      {'votes': {for (final o in _options) o: 0}};

  @override
  Map<String, Object?> update(
      String action, Map<String, Object?> state, Map<String, Object?> payload) {
    final votes = {
      ...(state['votes'] as Map).cast<String, Object?>().map(
          (k, v) => MapEntry(k, (v as num?)?.toInt() ?? 0)),
    };
    if (action == 'vote') {
      final option = '${payload['option']}';
      if (votes.containsKey(option)) votes[option] = votes[option]! + 1;
    } else if (action == 'reset') {
      for (final k in votes.keys) {
        votes[k] = 0;
      }
    }
    return {'votes': votes};
  }

  @override
  String render(Map<String, Object?> state) {
    final votes = (state['votes'] as Map).cast<String, Object?>();
    final total =
        votes.values.fold<int>(0, (a, v) => a + ((v as num?)?.toInt() ?? 0));
    final b = StringBuffer('<div>');
    for (final option in _options) {
      final n = (votes[option] as num?)?.toInt() ?? 0;
      final pct = total == 0 ? 0 : (100 * n / total).round();
      final safe = const HtmlEscape().convert(option);
      b
        ..write('<p data-live-key="$safe" style="margin:.4rem 0">')
        ..write('<button data-live-click="vote" data-live-option="$safe">'
            'Vote $safe</button> ')
        ..write('<span style="display:inline-block;height:1rem;'
            'width:${pct * 2}px;background:#4a7;vertical-align:middle"></span> ')
        ..write('<strong>$n</strong> ($pct%)</p>');
    }
    b
      ..write('<p>$total total · '
          '<button data-live-click="reset">reset</button></p>')
      ..write('</div>');
    return b.toString();
  }
}

DartApp buildApp(ServerConfig config) {
  final wtPath = config.wtPath ?? '/wt';
  final page = '<!DOCTYPE html><html><head><meta charset="utf-8">'
      '<title>Dartisan · Poll</title>'
      '<style>body{font:16px/1.5 system-ui;max-width:32rem;margin:2rem auto}'
      'button{cursor:pointer}</style>'
      '</head><body><h1>Favourite language?</h1>'
      '${liveMount(PollComponent(), wtPath: wtPath, inlineRuntime: liveRuntimeSource)}'
      '</body></html>';
  return DartApp(
    [
      DartRoute.exact('/', (e, r) async {
        await r.writeText(page, contentType: 'text/html; charset=UTF-8');
      }, methods: {'GET'}),
    ],
    wt: liveWtHandler(LiveRegistry()..register(PollComponent())),
  );
}

Future<void> main(List<String> arguments) async {
  final config = ServerConfig.fromArgs(arguments);
  final http3 = arguments.contains('--http3');
  final server = ServerSupervisor(config,
      kind: http3 ? WorkerKind.unified : WorkerKind.http1,
      appBuilder: buildApp);
  ProcessSignal.sigint.watch().listen((_) async {
    await server.stop();
    exit(0);
  });
  await server.start();
}
