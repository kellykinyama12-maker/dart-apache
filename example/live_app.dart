import 'dart:convert';
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

/// A reactive signup form: `save` validates the email server-side; on failure
/// the error folds into the state and renders inline (input preserved). The
/// `data-live-loading` span appears for the duration of the round-trip.
class SignupComponent extends LiveComponent {
  static final _attr = const HtmlEscape(HtmlEscapeMode.attribute);
  static final _text = const HtmlEscape();

  @override
  String get name => 'signup';

  @override
  Map<String, Object?> initialState() => {'email': '', 'saved': false};

  // Render depends on client-only model input, so send full HTML (not a diff).
  @override
  bool get diffable => false;

  @override
  Map<String, Object?> update(
    String action,
    Map<String, Object?> state,
    Map<String, Object?> payload,
  ) {
    if (action == 'save') {
      validate(state, {'email': 'required|email'});
      return {...state, 'saved': true, 'errors': const <String, Object?>{}};
    }
    return state;
  }

  @override
  String render(Map<String, Object?> state) {
    final email = '${state['email'] ?? ''}';
    final errors = (state['errors'] as Map?) ?? const {};
    final emailErr = (errors['email'] as List?)?.cast<String>() ?? const [];
    final saved = state['saved'] == true;
    return '<form data-live-submit="save" novalidate>'
        '<input name="email" type="email" placeholder="you@example.com" '
        'data-live-model="email" value="${_attr.convert(email)}"> '
        '<button type="submit" data-live-loading-class="busy">Sign up</button> '
        '<span data-live-loading hidden>…</span>'
        '${emailErr.isNotEmpty ? '<p style="color:#c00">${_text.convert(emailErr.first)}</p>' : ''}'
        '${saved ? '<p style="color:#070">Signed up ✓</p>' : ''}'
        '</form>';
  }
}

/// A clock whose `tick` action is driven by the client on a 1s poll interval —
/// the server stays stateless; the tick count round-trips like any other state.
class ClockComponent extends LiveComponent {
  @override
  String get name => 'clock';

  @override
  Map<String, Object?> initialState() => {'ticks': 0};

  @override
  Map<String, Object?> update(
    String action,
    Map<String, Object?> state,
    Map<String, Object?> payload,
  ) {
    final ticks = (state['ticks'] as num?)?.toInt() ?? 0;
    return action == 'tick' ? {'ticks': ticks + 1} : state;
  }

  @override
  String render(Map<String, Object?> state) =>
      '<p>Server ticks: <strong id="tick-count">${state['ticks'] ?? 0}</strong></p>'
      '<span hidden data-live-poll="tick" data-live-poll-interval="1000"></span>';
}

/// A live-search box: each keystroke re-renders the filtered list over
/// WebTransport (eager `data-live-model-live`, so no explicit action needed).
class SearchComponent extends LiveComponent {
  static const _fruits = ['apple', 'banana', 'cherry', 'date', 'grape'];
  static final _attr = const HtmlEscape(HtmlEscapeMode.attribute);
  static final _text = const HtmlEscape();

  @override
  String get name => 'search';

  @override
  bool get diffable => false;

  @override
  Map<String, Object?> initialState() => {'q': ''};

  @override
  Map<String, Object?> update(
    String action,
    Map<String, Object?> state,
    Map<String, Object?> payload,
  ) =>
      state; // model-live re-renders with the folded query; no named actions

  @override
  String render(Map<String, Object?> state) {
    final q = '${state['q'] ?? ''}'.toLowerCase();
    final matches = _fruits.where((f) => f.contains(q)).toList();
    return '<input type="text" placeholder="filter fruit…" '
        'data-live-model-live="q" value="${_attr.convert('${state['q'] ?? ''}')}">'
        '<ul id="search-results">'
        '${matches.map((f) => '<li>${_text.convert(f)}</li>').join()}</ul>'
        '<small id="search-count">${matches.length} match(es)</small>';
  }
}

/// A parent component that embeds a nested, independent counter. Bumping the
/// parent re-renders it, but the nested counter keeps its own state (the client
/// treats a bound child component as a morph boundary).
class PanelComponent extends LiveComponent {
  @override
  String get name => 'panel';

  @override
  bool get diffable => false;

  @override
  Map<String, Object?> initialState() => {'bumps': 0};

  @override
  Map<String, Object?> update(
    String action,
    Map<String, Object?> state,
    Map<String, Object?> payload,
  ) {
    final bumps = (state['bumps'] as num?)?.toInt() ?? 0;
    return action == 'bump' ? {'bumps': bumps + 1} : state;
  }

  @override
  String render(Map<String, Object?> state) =>
      '<p>Parent bumps: <strong id="panel-bumps">${state['bumps'] ?? 0}</strong> '
      '<button data-live-click="bump">bump parent</button></p>'
      '<div style="margin-left:1rem;border-left:2px solid #ccc;padding-left:.5rem">'
      '${liveMount(CounterComponent(), wtPath: '/wt', includeRuntime: false, key: 'nested-counter')}'
      '</div>';
}

DartApp buildApp(ServerConfig config) {
  final registry = LiveRegistry()
    ..register(CounterComponent())
    ..register(SignupComponent())
    ..register(ClockComponent())
    ..register(SearchComponent())
    ..register(PanelComponent());
  final wtPath = config.wtPath ?? '/wt';
  // Inline the client runtime so the demo needs no extra h3 request.
  final runtime = File('public/app/dartisan-live.js').readAsStringSync();
  return DartApp(
    [
      DartRoute.exact('/', (e, r) async {
        final page = '<!DOCTYPE html><html><head><meta charset="utf-8">'
            '<title>Dartisan Live</title>'
            '<style>.busy{opacity:.5}</style></head><body>'
            '<h1>Dartisan Live — reactive over WebTransport (HTTP/3)</h1>'
            '<h2>Counter</h2>'
            '${liveMount(CounterComponent(), wtPath: wtPath, inlineRuntime: runtime)}'
            '<h2>Signup (server-side validation + loading state)</h2>'
            '${liveMount(SignupComponent(), wtPath: wtPath, includeRuntime: false)}'
            '<h2>Clock (polling every 1s over WebTransport)</h2>'
            '${liveMount(ClockComponent(), wtPath: wtPath, includeRuntime: false)}'
            '<h2>Live search (eager data-live-model-live)</h2>'
            '${liveMount(SearchComponent(), wtPath: wtPath, includeRuntime: false)}'
            '<h2>Nested components (child counter keeps state across parent bumps)</h2>'
            '${liveMount(PanelComponent(), wtPath: wtPath, includeRuntime: false)}'
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
