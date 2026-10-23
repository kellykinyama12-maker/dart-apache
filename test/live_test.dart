import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_apache/dart_apache.dart';
import 'package:test/test.dart';

/// Server-side unit tests for Dartisan Live (no browser): component update/
/// render, the mount markup, and the WebTransport action handler.
class _Counter extends LiveComponent {
  @override
  String get name => 'counter';
  @override
  Map<String, Object?> initialState() => {'count': 0};
  @override
  Map<String, Object?> update(
      String action, Map<String, Object?> state, Map<String, Object?> p) {
    final c = (state['count'] as num?)?.toInt() ?? 0;
    return switch (action) {
      'increment' => {'count': c + 1},
      'decrement' => {'count': c - 1},
      _ => state,
    };
  }

  @override
  String render(Map<String, Object?> state) =>
      '<span>${state['count']}</span>';
}

/// A form component that validates on `save` — exercises the Live validation
/// round-trip (errors fold into state; input is preserved).
class _LoginForm extends LiveComponent {
  @override
  String get name => 'login';
  @override
  Map<String, Object?> initialState() => {'email': '', 'saved': false};
  @override
  bool get diffable => false;
  @override
  Map<String, Object?> update(
      String action, Map<String, Object?> state, Map<String, Object?> p) {
    if (action == 'save') {
      validate(state, {'email': 'required|email'});
      return {...state, 'saved': true, 'errors': const {}};
    }
    return state;
  }

  @override
  String render(Map<String, Object?> state) =>
      '<form>${state['saved'] == true ? 'ok' : ''}</form>';
}

class _FakeWtSession implements WtSession {
  final List<String> sent = [];
  @override
  WtConnect get connect => const WtConnect(path: '/wt', authority: 'x', headers: {});
  @override
  void send(List<int> bytes) => sent.add(utf8.decode(bytes));
  @override
  void sendUni(List<int> bytes) => sent.add(utf8.decode(bytes));
  @override
  void sendDatagram(List<int> bytes) {}
}

WtMessage _action(Map<String, Object?> body) => WtMessage(
      data: Uint8List.fromList(utf8.encode(jsonEncode(body))),
      isDatagram: false,
      sessionId: 0,
      bidiStreamId: 4,
    );

void main() {
  group('LiveComponent', () {
    final c = _Counter();
    test('update applies actions', () {
      expect(c.update('increment', {'count': 4}, {}), {'count': 5});
      expect(c.update('decrement', {'count': 4}, {}), {'count': 3});
      expect(c.update('noop', {'count': 4}, {}), {'count': 4});
    });
    test('render reflects state', () {
      expect(c.render({'count': 7}), contains('7'));
    });
  });

  group('liveMount', () {
    test('emits container with name + escaped state + boot + base seed', () {
      final html = liveMount(_Counter(), wtPath: '/live');
      expect(html, contains('data-live-component="counter"'));
      expect(html, contains('data-live-state='));
      expect(html, contains('window.DARTISAN_LIVE_PATH="/live"'));
      expect(html, contains('DARTISAN_LIVE_INIT'));
      expect(html, contains('<script src="/app/dartisan-live.js">'));
    });
    test('inlineRuntime embeds the runtime', () {
      final html = liveMount(_Counter(), inlineRuntime: 'CODE();');
      expect(html, contains('<script>CODE();</script>'));
      expect(html, isNot(contains('<script src=')));
    });
    test('includeRuntime:false emits the component + seed but no runtime', () {
      final html = liveMount(_Counter(), includeRuntime: false);
      expect(html, contains('data-live-component="counter"'));
      expect(html, contains('DARTISAN_LIVE_INIT'));
      expect(html, isNot(contains('<script src=')));
    });
  });

  group('liveWtHandler', () {
    test('replies with a patch that rebuilds the new html (default diff)', () {
      final registry = LiveRegistry()..register(_Counter());
      final handler = liveWtHandler(registry);
      final session = _FakeWtSession();

      handler(session, _action({
        'id': 9,
        'component': 'counter',
        'action': 'increment',
        'state': {'count': 41},
      }));

      expect(session.sent, hasLength(1));
      final reply = jsonDecode(session.sent.single) as Map<String, Object?>;
      expect(reply['id'], 9);
      expect(reply['state'], {'count': 42});
      expect(reply['html'], isNull);
      final patch = (reply['patch'] as Map).cast<String, Object?>();
      // The client applies the patch to its base (render of the old state).
      final base = _Counter().render({'count': 41});
      final rebuilt = base.substring(0, patch['s'] as int) +
          (patch['i'] as String) +
          base.substring(patch['e'] as int);
      expect(rebuilt, _Counter().render({'count': 42}));
    });

    test('diff:false replies with full html', () {
      final handler =
          liveWtHandler(LiveRegistry()..register(_Counter()), diff: false);
      final session = _FakeWtSession();
      handler(session, _action({
        'id': 1,
        'component': 'counter',
        'action': 'increment',
        'state': {'count': 41},
      }));
      final reply = jsonDecode(session.sent.single) as Map<String, Object?>;
      expect(reply['patch'], isNull);
      expect(reply['html'], contains('42'));
    });

    test('ignores unknown components and datagrams', () {
      final handler = liveWtHandler(LiveRegistry()..register(_Counter()));
      final s1 = _FakeWtSession();
      handler(s1, _action({'component': 'missing', 'action': 'x'}));
      expect(s1.sent, isEmpty);

      final s2 = _FakeWtSession();
      handler(
        s2,
        WtMessage(
          data: Uint8List.fromList(utf8.encode('{}')),
          isDatagram: true,
          sessionId: 0,
        ),
      );
      expect(s2.sent, isEmpty);
    });
  });

  group('Live validation round-trip (B1)', () {
    test('validate folds errors into the replied state, keeping input', () {
      final handler = liveWtHandler(LiveRegistry()..register(_LoginForm()),
          diff: false);
      final session = _FakeWtSession();
      handler(session, _action({
        'id': 1,
        'component': 'login',
        'action': 'save',
        'state': {'email': 'not-an-email'},
      }));
      final reply = jsonDecode(session.sent.single) as Map<String, Object?>;
      final state = (reply['state'] as Map).cast<String, Object?>();
      expect(state['email'], 'not-an-email'); // input preserved
      expect(state['saved'], isNot(true)); // not saved
      expect((state['errors'] as Map).containsKey('email'), isTrue);
    });

    test('a valid submission saves and clears errors', () {
      final handler = liveWtHandler(LiveRegistry()..register(_LoginForm()),
          diff: false);
      final session = _FakeWtSession();
      handler(session, _action({
        'id': 2,
        'component': 'login',
        'action': 'save',
        'state': {'email': 'ada@example.com'},
      }));
      final reply = jsonDecode(session.sent.single) as Map<String, Object?>;
      final state = (reply['state'] as Map).cast<String, Object?>();
      expect(state['saved'], isTrue);
      expect(state['errors'], isEmpty);
    });

    test('a non-diffable component replies with full html even under diff', () {
      final handler = liveWtHandler(LiveRegistry()..register(_LoginForm()));
      final session = _FakeWtSession();
      handler(session, _action({
        'id': 3,
        'component': 'login',
        'action': 'save',
        'state': {'email': 'ada@example.com'},
      }));
      final reply = jsonDecode(session.sent.single) as Map<String, Object?>;
      expect(reply['patch'], isNull); // _LoginForm.diffable is false
      expect(reply['html'], isNotNull);
    });

    test('LiveComponent.validate throws on failure, passes on success', () {
      final form = _LoginForm();
      expect(() => form.validate({'email': 'x'}, {'email': 'email'}),
          throwsA(isA<ValidationException>()));
      expect(() => form.validate({'email': 'a@b.co'}, {'email': 'email'}),
          returnsNormally);
    });
  });

  group('computeHtmlPatch', () {
    test('minimal splice rebuilds the new string', () {
      final p = computeHtmlPatch('<span>41</span>', '<span>42</span>');
      expect(p.insert, '2');
      expect(p.applyTo('<span>41</span>'), '<span>42</span>');
    });
    test('identical strings yield an empty patch', () {
      final p = computeHtmlPatch('abc', 'abc');
      expect(p.isEmpty, isTrue);
      expect(p.applyTo('abc'), 'abc');
    });
    test('handles pure insertion and deletion', () {
      expect(computeHtmlPatch('<b></b>', '<b>hi</b>').applyTo('<b></b>'),
          '<b>hi</b>');
      expect(computeHtmlPatch('<b>hi</b>', '<b></b>').applyTo('<b>hi</b>'),
          '<b></b>');
    });
  });
}
