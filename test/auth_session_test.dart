import 'dart:async';
import 'dart:convert';

import 'package:dart_apache/dart_apache.dart';
import 'package:test/test.dart';

void main() {
  group('SessionManager (encrypted cookie)', () {
    final sm = SessionManager(SessionManager.generateKey(), secure: false);

    String cookieValue(String setCookie) => setCookie.split(';').first;

    test('round-trips session data through the cookie', () {
      final s = sm.load(null)..put('user', 'ada');
      final setCookie = sm.setCookie(s)!;
      expect(setCookie, contains('HttpOnly'));
      expect(setCookie, contains('SameSite=Lax'));
      expect(setCookie, isNot(contains('Secure'))); // secure:false

      final reloaded = sm.load(cookieValue(setCookie));
      expect(reloaded.get('user'), 'ada');
    });

    test('unchanged session writes no cookie', () {
      final s = sm.load(null);
      expect(sm.setCookie(s), isNull);
    });

    test('tampered cookie is rejected (fresh session)', () {
      final s = sm.load(null)..put('role', 'admin');
      final token = cookieValue(sm.setCookie(s)!).split('=')[1];
      final tampered = 'dartisan_session=${token.substring(0, token.length - 2)}AA';
      final reloaded = sm.load(tampered);
      expect(reloaded.has('role'), isFalse);
    });

    test('a cookie signed with another key is rejected', () {
      final other = SessionManager(SessionManager.generateKey(), secure: false);
      final s = other.load(null)..put('role', 'admin');
      final cookie = other.setCookie(s)!.split(';').first;
      expect(sm.load(cookie).has('role'), isFalse);
    });

    test('flash is readable next request then gone', () {
      final s = sm.load(null)..flash('status', 'saved');
      final cookie = sm.setCookie(s)!.split(';').first;

      final next = sm.load(cookie);
      expect(next.flashed('status'), 'saved');
      // Re-persisting without re-flashing drops it.
      next.put('x', 1);
      final after = sm.load(sm.setCookie(next)!.split(';').first);
      expect(after.flashed('status'), isNull);
    });
  });

  group('Session', () {
    test('put/get/has/forget/pull/flush', () {
      final s = Session({}, {});
      expect(s.has('a'), isFalse);
      s.put('a', 1);
      expect(s.get('a'), 1);
      expect(s.get('missing', 'def'), 'def');
      expect(s.pull('a'), 1);
      expect(s.has('a'), isFalse);
      s.put('b', 2);
      s.flush();
      expect(s.has('b'), isFalse);
    });
  });

  group('Auth', () {
    test('login / check / id / logout', () {
      final s = Session({}, {});
      final auth = Auth(s);
      expect(auth.check, isFalse);
      expect(auth.guest, isTrue);
      auth.login('u1');
      expect(auth.check, isTrue);
      expect(auth.id, 'u1');
      auth.logout();
      expect(auth.check, isFalse);
    });
  });

  group('Blaze @auth / @guest', () {
    final engine = BlazeEngine('.', cache: false);
    test('@auth renders when auth is truthy, @guest otherwise', () {
      const tpl = '@auth YES @endauth@guest NO @endguest';
      expect(engine.renderString(tpl, {'auth': true}).trim(), 'YES');
      expect(engine.renderString(tpl, {'auth': false}).trim(), 'NO');
    });
  });

  group('@csrf + verifyCsrf', () {
    final engine = BlazeEngine('.', cache: false);

    test('@csrf renders a hidden field with the escaped token', () {
      final html = engine.renderString('@csrf', {'csrf': 'a&b"c'});
      expect(html,
          '<input type="hidden" name="_token" value="a&amp;b&quot;c">');
    });

    final sm = SessionManager(SessionManager.generateKey(), secure: false);

    Future<_FakeResponse> run(DartApp app, String method, String path,
        {Map<String, String> headers = const {}, List<int>? body}) async {
      final uri = Uri.parse(path);
      final route = app.match(method, uri.path);
      expect(route, isNotNull, reason: 'no route for $method $path');
      final ex = _FakeExchange(method, uri, headers, body ?? const []);
      await route!.handler(ex, ex.response);
      return ex.response;
    }

    test('safe methods pass; unsafe without token -> 419; with token -> ok',
        () async {
      String? issuedCookie;
      final app = (Router(sessions: sm)
            ..use(verifyCsrf())
            ..get('/form', (r) {
              // Issue a token (stored in the session cookie).
              return r.text(r.csrfToken());
            })
            ..post('/save', (r) => r.text('saved')))
          .toApp();

      // GET issues a token + Set-Cookie.
      final form = await run(app, 'GET', '/form');
      expect(form.statusCode, 200);
      final token = form.text;
      issuedCookie = form.headers['set-cookie']!.split(';').first;

      // POST with no token is rejected.
      final blocked = await run(app, 'POST', '/save',
          headers: {'cookie': issuedCookie});
      expect(blocked.statusCode, 419);

      // POST with the matching token (form field) passes.
      final okForm = await run(app, 'POST', '/save', headers: {
        'cookie': issuedCookie,
        'content-type': 'application/x-www-form-urlencoded',
      }, body: utf8.encode('_token=${Uri.encodeQueryComponent(token)}'));
      expect(okForm.statusCode, 200);
      expect(okForm.text, 'saved');

      // POST with the matching token (header) also passes.
      final okHeader = await run(app, 'POST', '/save',
          headers: {'cookie': issuedCookie, 'x-csrf-token': token});
      expect(okHeader.statusCode, 200);
    });
  });

  group('requireAuth + session end-to-end', () {
    final sm = SessionManager(SessionManager.generateKey(), secure: false);

    Future<_FakeResponse> run(DartApp app, String method, String path,
        {Map<String, String> headers = const {}}) async {
      final uri = Uri.parse(path);
      final route = app.match(method, uri.path);
      expect(route, isNotNull, reason: 'no route for $method $path');
      final ex = _FakeExchange(method, uri, headers, const []);
      await route!.handler(ex, ex.response);
      return ex.response;
    }

    test('login sets a cookie; it unlocks a requireAuth route', () async {
      final app = (Router(sessions: sm)
            ..get('/login', (r) {
              r.auth.login('u1');
              return r.text('logged-in');
            }))
          .toApp();

      // A separate router whose routes are all behind requireAuth.
      final guarded = (Router(sessions: sm)
            ..use(requireAuth(redirectTo: '/login'))
            ..get('/dash', (r) => r.text('secret')))
          .toApp();

      // 1) no session -> redirected
      final anon = await run(guarded, 'GET', '/dash');
      expect(anon.statusCode, 302);
      expect(anon.headers['location'], '/login');

      // 2) log in -> cookie issued
      final login = await run(app, 'GET', '/login');
      final setCookie = login.headers['set-cookie'];
      expect(setCookie, isNotNull);
      final cookie = setCookie!.split(';').first;

      // 3) present the cookie -> allowed through
      final ok = await run(guarded, 'GET', '/dash', headers: {'cookie': cookie});
      expect(ok.statusCode, 200);
      expect(ok.text, 'secret');
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
  bool closed = false;

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
  Future<void> close() async => closed = true;
}
