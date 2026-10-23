import 'dart:convert';
import 'dart:io';

import 'package:dart_apache/dart_apache.dart';

/// A reactive to-do list over WebTransport/HTTP3. State (the item list + draft)
/// round-trips to the client; the server re-renders and streams a diff. Shows
/// `data-live-model` input binding, keyed `<li>` morphing, and per-item actions
/// via `data-live-*` params.
///
/// Run (Live needs TLS for WebTransport):
///   dart run example/todo_app.dart --root=./public --port=8443 --http3 --dev --wt-path=/wt
class TodoComponent extends LiveComponent {
  @override
  String get name => 'todos';

  @override
  Map<String, Object?> initialState() =>
      {'items': <Map<String, Object?>>[], 'draft': '', 'seq': 0};

  @override
  Map<String, Object?> update(
      String action, Map<String, Object?> state, Map<String, Object?> payload) {
    final items = [
      for (final e in (state['items'] as List).cast<Map<String, Object?>>())
        Map<String, Object?>.of(e)
    ];
    var seq = (state['seq'] as num?)?.toInt() ?? 0;
    final draft = (state['draft'] as String?) ?? '';
    final id = int.tryParse('${payload['id']}');

    switch (action) {
      case 'add':
        final text = draft.trim();
        if (text.isNotEmpty) {
          items.add({'id': ++seq, 'text': text, 'done': false});
        }
        return {'items': items, 'draft': '', 'seq': seq};
      case 'toggle':
        for (final it in items) {
          if (it['id'] == id) it['done'] = !(it['done'] == true);
        }
        return {'items': items, 'draft': draft, 'seq': seq};
      case 'remove':
        items.removeWhere((it) => it['id'] == id);
        return {'items': items, 'draft': draft, 'seq': seq};
      case 'clearCompleted':
        items.removeWhere((it) => it['done'] == true);
        return {'items': items, 'draft': draft, 'seq': seq};
      default:
        return state;
    }
  }

  @override
  String render(Map<String, Object?> state) {
    final items = (state['items'] as List).cast<Map<String, Object?>>();
    final draft = const HtmlEscape().convert((state['draft'] as String?) ?? '');
    final remaining = items.where((e) => e['done'] != true).length;
    final b = StringBuffer()
      ..write('<form data-live-submit="add">')
      ..write('<input name="draft" data-live-model="draft" value="$draft" '
          'placeholder="What needs doing?" autocomplete="off"> ')
      ..write('<button type="submit">Add</button></form>');
    if (items.isEmpty) {
      b.write('<p>Nothing yet — add your first task.</p>');
    } else {
      b.write('<ul style="list-style:none;padding:0">');
      for (final it in items) {
        final id = it['id'];
        final done = it['done'] == true;
        final text = const HtmlEscape().convert('${it['text']}');
        b
          ..write('<li data-live-key="$id" style="margin:.25rem 0">')
          ..write('<label><input type="checkbox"${done ? ' checked' : ''} '
              'data-live-click="toggle" data-live-id="$id"> ')
          ..write(done ? '<s>$text</s>' : text)
          ..write('</label> ')
          ..write('<button data-live-click="remove" data-live-id="$id" '
              'title="remove">✕</button></li>');
      }
      b
        ..write('</ul>')
        ..write('<p>$remaining left · '
            '<button data-live-click="clearCompleted">Clear completed</button></p>');
    }
    return b.toString();
  }
}

DartApp buildApp(ServerConfig config) {
  final wtPath = config.wtPath ?? '/wt';
  final page = '<!DOCTYPE html><html><head><meta charset="utf-8">'
      '<title>Dartisan · Todos</title>'
      '<style>body{font:16px/1.5 system-ui;max-width:32rem;margin:2rem auto}</style>'
      '</head><body><h1>Todos</h1>'
      '${liveMount(TodoComponent(), wtPath: wtPath, inlineRuntime: liveRuntimeSource)}'
      '</body></html>';
  return DartApp(
    [
      DartRoute.exact('/', (e, r) async {
        await r.writeText(page, contentType: 'text/html; charset=UTF-8');
      }, methods: {'GET'}),
    ],
    wt: liveWtHandler(LiveRegistry()..register(TodoComponent())),
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
