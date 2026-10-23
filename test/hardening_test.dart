import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_apache/dart_apache.dart';
import 'package:test/test.dart';

void main() {
  Future<_FakeResponse> run(DartApp app, String method, String path,
      {Map<String, String> headers = const {}, List<int>? body}) async {
    final uri = Uri.parse(path);
    final route = app.match(method, uri.path);
    expect(route, isNotNull, reason: 'no route for $method $path');
    final ex = _FakeExchange(method, uri, headers, body ?? const []);
    await route!.handler(ex, ex.response);
    return ex.response;
  }

  group('constantTimeEquals', () {
    test('matches equal strings, rejects differences and lengths', () {
      expect(constantTimeEquals('abc123', 'abc123'), isTrue);
      expect(constantTimeEquals('abc123', 'abc124'), isFalse);
      expect(constantTimeEquals('abc', 'abcd'), isFalse);
      expect(constantTimeEquals('', ''), isTrue);
    });
  });

  group('J1 body limits', () {
    test('body over the limit -> 413', () async {
      final app = (Router(maxBodyBytes: 10)
            ..post('/up', (r) async => r.text(await r.body())))
          .toApp();
      final small = await run(app, 'POST', '/up', body: utf8.encode('hi'));
      expect(small.statusCode, 200);
      final big = await run(app, 'POST', '/up',
          body: utf8.encode('x' * 50));
      expect(big.statusCode, 413);
    });
  });

  group('J4 error boundary', () {
    test('ValidationException -> 422 with field errors', () async {
      final app = (Router()
            ..post('/v', (r) => r.validate({'name': 'required'})))
          .toApp();
      final res = await run(app, 'POST', '/v', body: const []);
      expect(res.statusCode, 422);
      final body = jsonDecode(res.text) as Map<String, Object?>;
      expect(body['errors'], contains('name'));
    });

    test('uncaught throw -> generic 500 + onError hook, no leak', () async {
      Object? caught;
      final app = (Router(onError: (e, _) => caught = e)
            ..get('/boom', (r) => throw StateError('secret detail')))
          .toApp();
      final res = await run(app, 'GET', '/boom');
      expect(res.statusCode, 500);
      expect(res.text, 'Internal Server Error');
      expect(res.text, isNot(contains('secret detail')));
      expect(caught, isA<StateError>());
    });

    test('abort / abortIf / abortUnless -> status + message', () async {
      final app = (Router()
            ..get('/missing', (r) => abort(404))
            ..get('/custom', (r) => abort(403, 'Nope'))
            ..get('/if', (r) {
              abortIf(r.query('x') == '1', 400, 'Bad x');
              return r.text('ok');
            })
            ..get('/unless', (r) {
              abortUnless(r.query('ok') == '1', 401);
              return r.text('ok');
            }))
          .toApp();
      final nf = await run(app, 'GET', '/missing');
      expect(nf.statusCode, 404);
      expect(nf.text, 'Not Found');
      final custom = await run(app, 'GET', '/custom');
      expect(custom.statusCode, 403);
      expect(custom.text, 'Nope');
      expect((await run(app, 'GET', '/if?x=1')).statusCode, 400);
      expect((await run(app, 'GET', '/if')).statusCode, 200);
      expect((await run(app, 'GET', '/unless')).statusCode, 401);
      expect((await run(app, 'GET', '/unless?ok=1')).statusCode, 200);
    });
  });

  group('J5 rate limiting', () {
    test('allows up to max then 429 with Retry-After', () async {
      final app = (Router()
            ..use(rateLimit(2, const Duration(minutes: 1),
                keyBy: (_) => 'fixed'))
            ..get('/', (r) => r.text('ok')))
          .toApp();
      expect((await run(app, 'GET', '/')).statusCode, 200);
      expect((await run(app, 'GET', '/')).statusCode, 200);
      final blocked = await run(app, 'GET', '/');
      expect(blocked.statusCode, 429);
      expect(blocked.headers['retry-after'], isNotNull);
    });
  });

  group('J3 session hardening', () {
    test('login rotates the CSRF token and sets the user', () {
      final s = Session({}, {})..put('_csrf', 'old-token');
      Auth(s).login('u1');
      expect(s.get('_csrf'), isNull);
      expect(s.has('_auth_id'), isTrue);
    });

    test('logout clears the user and rotates the token', () {
      final s = Session({}, {})
        ..put('_auth_id', 'u1')
        ..put('_csrf', 'tok');
      Auth(s).logout();
      expect(s.has('_auth_id'), isFalse);
      expect(s.get('_csrf'), isNull);
    });

    test('SessionManager rejects a non-32-byte key', () {
      expect(() => SessionManager(Uint8List.fromList([1, 2, 3])),
          throwsA(isA<AssertionError>()));
    });
  });
}

class _FakeExchange implements ServerExchange {
  _FakeExchange(this.method, this.uri, this._headers, this._body);

  @override
  final String method;
  @override
  final Uri uri;
  final Map<String, String> _headers;
  final List<int> _body;
  final _FakeResponse response = _FakeResponse();

  @override
  String get protocolVersion => '1.1';
  @override
  String get scheme => 'http';
  @override
  String get authority => 'localhost';
  @override
  String get protocol => 'http/1.1';
  @override
  String get remoteAddress => '127.0.0.1';
  @override
  int get remotePort => 1234;
  @override
  int get contentLength => _body.length;
  @override
  String? get contentType => _headers['content-type'];
  @override
  void forEachHeader(void Function(String name, String value) action) =>
      _headers.forEach(action);
  @override
  Stream<List<int>> get body => Stream<List<int>>.value(_body);
  @override
  ServerResponse respond() => response;
}

class _FakeResponse implements ServerResponse {
  int _status = 200;
  final Map<String, String> headers = {};
  final List<int> body = [];

  String get text => utf8.decode(body);

  @override
  int get statusCode => _status;
  @override
  void setStatus(int statusCode, [String? reasonPhrase]) => _status = statusCode;
  @override
  void setHeader(String name, String value) => headers[name.toLowerCase()] = value;
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      body.addAll(chunk);
    }
  }

  @override
  Future<void> close() async {}
}
