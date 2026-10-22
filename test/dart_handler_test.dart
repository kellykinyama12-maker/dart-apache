import 'dart:async';
import 'dart:convert';

import 'package:dart_apache/dart_apache.dart';
import 'package:test/test.dart';

void _noop(ServerExchange e, ServerResponse r) {}

void main() {
  group('DartRoute matching', () {
    test('exact matches only the exact path', () {
      const r = DartRoute.exact('/health', _noop);
      expect(r.matches('GET', '/health'), isTrue);
      expect(r.matches('GET', '/health/'), isFalse);
      expect(r.matches('GET', '/healthz'), isFalse);
    });

    test('prefix matches on a segment boundary, not a substring', () {
      const r = DartRoute.prefix('/api', _noop);
      expect(r.matches('GET', '/api'), isTrue);
      expect(r.matches('GET', '/api/users'), isTrue);
      expect(r.matches('GET', '/apikey'), isFalse); // not a boundary
    });

    test('method filter is enforced (case-insensitive)', () {
      const r = DartRoute.exact('/x', _noop, methods: {'POST'});
      expect(r.matches('post', '/x'), isTrue);
      expect(r.matches('GET', '/x'), isFalse);
    });
  });

  group('DartApp ordering', () {
    DartHandler tag(String name) =>
        (e, r) => r.setHeader('x-route', name);

    test('exact wins over prefix; longest prefix wins', () {
      final app = DartApp([
        DartRoute.prefix('/a', tag('short')),
        DartRoute.prefix('/a/b', tag('long')),
        DartRoute.exact('/a/b', tag('exact')),
      ]);
      expect(app.match('GET', '/a/b')!.pattern, '/a/b');
      // Among the two '/a/b' the exact one sorts first.
      expect(app.match('GET', '/a/b')!.exact, isTrue);
      // A deeper path falls to the longest prefix.
      expect(app.match('GET', '/a/b/c')!.pattern, '/a/b');
      expect(app.match('GET', '/a/x')!.pattern, '/a');
    });

    test('no match returns null (pipeline falls through)', () {
      final app = DartApp([DartRoute.prefix('/api', _noop)]);
      expect(app.match('GET', '/other'), isNull);
    });

    test('wt handler defaults to null and is carried when provided', () {
      expect(DartApp(const []).wt, isNull);
      final app = DartApp(const [], wt: (session, message) {});
      expect(app.wt, isNotNull);
    });
  });

  group('RequestPipeline dispatch', () {
    test('serves a matching Dart route before static/PHP', () async {
      final app = DartApp([
        DartRoute.exact('/hello', (e, r) async {
          await r.writeJson({'hi': e.uri.queryParameters['name']});
        }),
      ]);
      final pipeline = RequestPipeline(
        ServerConfig(documentRoot: '.'),
        app: app,
      );
      final ex = _FakeExchange(method: 'GET', uri: Uri.parse('/hello?name=ada'));
      await pipeline.serve(ex);
      final res = ex.response;
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], contains('application/json'));
      expect(jsonDecode(utf8.decode(res.body)), {'hi': 'ada'});
    });

    test('a method-mismatched route falls through (not served by Dart)',
        () async {
      final app = DartApp([
        DartRoute.exact('/only-post', (e, r) => r.writeText('nope'),
            methods: {'POST'}),
      ]);
      final pipeline = RequestPipeline(
        ServerConfig(documentRoot: '.'),
        app: app,
      );
      final ex = _FakeExchange(method: 'GET', uri: Uri.parse('/only-post'));
      await pipeline.serve(ex);
      // No static file at ./only-post -> 404, i.e. the Dart route did NOT run.
      expect(ex.response.statusCode, 404);
    });
  });
}

class _FakeExchange implements ServerExchange {
  _FakeExchange({required this.method, required this.uri});

  @override
  final String method;
  @override
  final Uri uri;
  final _FakeResponse response = _FakeResponse();

  @override
  String get protocolVersion => '3';
  @override
  String get scheme => 'https';
  @override
  String get authority => 'localhost';
  @override
  String get protocol => 'h3';
  @override
  String get remoteAddress => '127.0.0.1';
  @override
  int get remotePort => 12345;
  @override
  int get contentLength => 0;
  @override
  String? get contentType => null;
  @override
  void forEachHeader(void Function(String name, String value) action) {}
  @override
  Stream<List<int>> get body => const Stream.empty();
  @override
  ServerResponse respond() => response;
}

class _FakeResponse implements ServerResponse {
  int _status = 200;
  final Map<String, String> headers = {};
  final List<int> body = [];
  bool closed = false;

  @override
  int get statusCode => _status;
  @override
  void setStatus(int statusCode, [String? reasonPhrase]) => _status = statusCode;
  @override
  void setHeader(String name, String value) => headers[name.toLowerCase()] = value;
  @override
  Future<void> addStream(Stream<List<int>> body) async {
    await for (final chunk in body) {
      this.body.addAll(chunk);
    }
  }

  @override
  Future<void> close() async => closed = true;
}
