import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_apache/dart_apache.dart';
import 'package:test/test.dart';

void main() {
  Future<_FakeResponse> run(
    DartApp app,
    String method,
    String path, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    final uri = Uri.parse(path);
    final route = app.match(method, uri.path);
    expect(route, isNotNull, reason: 'no route for $method $path');
    final ex = _FakeExchange(method, uri, headers, body ?? const []);
    await route!.handler(ex, ex.response);
    return ex.response;
  }

  group('path params', () {
    test('captures :id and matches on segment count', () async {
      final app = (Router()
            ..get('/users/:id', (r) => r.text('id=${r.param('id')}')))
          .toApp();
      expect((await run(app, 'GET', '/users/42')).text, 'id=42');
      expect(app.match('GET', '/users'), isNull); // arity mismatch
      expect(app.match('GET', '/users/1/2'), isNull);
    });

    test('multiple params', () async {
      final app = (Router()
            ..get('/p/:a/:b', (r) => r.text('${r.param('a')}-${r.param('b')}')))
          .toApp();
      expect((await run(app, 'GET', '/p/x/y')).text, 'x-y');
    });
  });

  group('query + body + json', () {
    test('query parameter', () async {
      final app =
          (Router()..get('/s', (r) => r.text('q=${r.query('q')}'))).toApp();
      expect((await run(app, 'GET', '/s?q=hi')).text, 'q=hi');
    });

    test('queryInt + queryBool parse typed query params', () async {
      final app = (Router()
            ..get('/p',
                (r) => r.text('${r.queryInt('page', 1)}/${r.queryBool('all')}')))
          .toApp();
      expect((await run(app, 'GET', '/p?page=3&all=yes')).text, '3/true');
      expect((await run(app, 'GET', '/p')).text, '1/false');
    });

    test('named routes build URLs with urlFor', () {
      final router = Router()
        ..get('/users/:id', (r) => r.text('x'), name: 'users.show')
        ..get('/posts', (r) => r.text('x'), name: 'posts.index');
      expect(router.urlFor('users.show', {'id': 42}), '/users/42');
      expect(router.urlFor('posts.index'), '/posts');
      expect(router.urlFor('users.show', {'id': 7, 'tab': 'bio'}),
          '/users/7?tab=bio');
      expect(() => router.urlFor('missing'), throwsArgumentError);
      expect(() => router.urlFor('users.show'), throwsArgumentError);
    });

    test('group name + path prefixes compose for named routes', () {
      final router = Router();
      router.group('/admin', () {
        router.get('/users/:id', (r) => r.text('x'), name: 'users.show');
      }, name: 'admin.');
      expect(router.urlFor('admin.users.show', {'id': 9}), '/admin/users/9');
    });

    test('content negotiation + method + cookie helpers', () async {
      final app = (Router()
            ..get(
                '/n',
                (r) => r.text('${r.isMethod('get')}/${r.wantsJson}/'
                    '${r.isAjax}/${r.cookie('sid')}')))
          .toApp();
      final html = await run(app, 'GET', '/n', headers: {
        'accept': 'text/html',
        'cookie': 'sid=abc; other=1',
      });
      expect(html.text, 'true/false/false/abc');
      final ajax = await run(app, 'GET', '/n', headers: {
        'accept': 'application/json',
        'x-requested-with': 'XMLHttpRequest',
      });
      expect(ajax.text, 'true/true/true/null');
    });

    test('json body echoed', () async {
      final app = (Router()
            ..post('/echo', (r) async => r.sendJson(await r.json())))
          .toApp();
      final res = await run(app, 'POST', '/echo', body: utf8.encode('{"a":1}'));
      expect(jsonDecode(res.text), {'a': 1});
      expect(res.headers['content-type'], contains('application/json'));
    });

    test('only / except filter request input', () async {
      final app = (Router()
            ..post('/f', (r) async => r.sendJson(await r.only(['a', 'c'])))
            ..post('/g', (r) async => r.sendJson(await r.except(['b']))))
          .toApp();
      final only = await run(app, 'POST', '/f',
          body: utf8.encode('{"a":1,"b":2,"c":3}'),
          headers: {'content-type': 'application/json'});
      expect(jsonDecode(only.text), {'a': 1, 'c': 3});
      final except = await run(app, 'POST', '/g',
          body: utf8.encode('{"a":1,"b":2,"c":3}'),
          headers: {'content-type': 'application/json'});
      expect(jsonDecode(except.text), {'a': 1, 'c': 3});
    });

    test('string / integer / boolean typed input', () async {
      final app = (Router()
            ..post(
                '/t',
                (r) async => r.text('${await r.string('name')}/'
                    '${await r.integer('age', 0)}/${await r.boolean('ok')}')))
          .toApp();
      final res = await run(app, 'POST', '/t',
          body: utf8.encode('name=ada&age=30&ok=yes'),
          headers: {'content-type': 'application/x-www-form-urlencoded'});
      expect(res.text, 'ada/30/true');
      final empty = await run(app, 'POST', '/t', body: const []);
      expect(empty.text, 'null/0/false');
    });

    test('has / filled / missing input presence', () async {
      final app = (Router()
            ..post(
                '/p',
                (r) async => r.text('${await r.has('a')}/'
                    '${await r.filled('a')}/${await r.missing('z')}')))
          .toApp();
      final res = await run(app, 'POST', '/p',
          body: utf8.encode('a=&b=2'),
          headers: {'content-type': 'application/x-www-form-urlencoded'});
      expect(res.text, 'true/false/true'); // a present but empty; z missing
    });

    test('withCookie queues a Set-Cookie header', () async {
      final app = (Router()
            ..get('/c', (r) {
              r.withCookie('pref', 'dark',
                  maxAge: const Duration(hours: 1), httpOnly: true);
              return r.text('ok');
            }))
          .toApp();
      final res = await run(app, 'GET', '/c');
      final sc = res.headers['set-cookie']!;
      expect(sc, startsWith('pref=dark; Path=/'));
      expect(sc, contains('Max-Age=3600'));
      expect(sc, contains('HttpOnly'));
      expect(sc, contains('SameSite=Lax'));
    });

    test('view renders with a custom status (e.g. 404 pages)', () async {
      final dir = Directory.systemTemp.createTempSync('blaze_status');
      File('${dir.path}/missing.blaze.html').writeAsStringSync('Not here');
      final app = (Router(views: BlazeEngine(dir.path, cache: false))
            ..get('/x', (r) => r.view('missing', const {}, 404)))
          .toApp();
      final res = await run(app, 'GET', '/x');
      expect(res.statusCode, 404);
      expect(res.text, 'Not here');
    });

    test('created / noContent / back responders', () async {
      final app = (Router()
            ..post('/c', (r) => r.created({'id': 1}, location: '/c/1'))
            ..delete('/d', (r) => r.noContent())
            ..get('/b', (r) => r.back(fallback: '/home')))
          .toApp();
      final c = await run(app, 'POST', '/c');
      expect(c.statusCode, 201);
      expect(c.headers['location'], '/c/1');
      expect(jsonDecode(c.text), {'id': 1});
      expect((await run(app, 'DELETE', '/d')).statusCode, 204);
      final b = await run(app, 'GET', '/b',
          headers: {'referer': '/prev'});
      expect(b.statusCode, 302);
      expect(b.headers['location'], '/prev');
      final bf = await run(app, 'GET', '/b');
      expect(bf.headers['location'], '/home');
    });
  });

  group('middleware', () {
    test('runs before the action and can mutate the response', () async {
      final router = Router()
        ..use((req, next) {
          req.response.setHeader('x-mw', 'on');
          return next();
        })
        ..get('/', (r) => r.text('ok'));
      final res = await run(router.toApp(), 'GET', '/');
      expect(res.text, 'ok');
      expect(res.headers['x-mw'], 'on');
    });

    test('short-circuits when next is not called', () async {
      final router = Router()
        ..use((req, next) => req.text('blocked', status: 403))
        ..get('/', (r) => r.text('should not run'));
      final res = await run(router.toApp(), 'GET', '/');
      expect(res.statusCode, 403);
      expect(res.text, 'blocked');
    });
  });

  group('groups', () {
    test('prefix + group middleware', () async {
      final router = Router();
      router.group('/api', () {
        router.get('/ping', (r) => r.text('pong'));
      }, middleware: [
        (req, next) {
          req.response.setHeader('x-api', '1');
          return next();
        }
      ]);
      final res = await run(router.toApp(), 'GET', '/api/ping');
      expect(res.text, 'pong');
      expect(res.headers['x-api'], '1');
    });
  });

  group('view engine', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('router_');
      File('${dir.path}/hi.blaze.html').writeAsStringSync('Hello {{ name }}');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('req.view renders a Blaze template', () async {
      final router = Router(views: BlazeEngine(dir.path, cache: false))
        ..get('/', (r) => r.view('hi', {'name': 'ada'}));
      final res = await run(router.toApp(), 'GET', '/');
      expect(res.text, 'Hello ada');
      expect(res.headers['content-type'], contains('text/html'));
    });
  });

  group('form DX (old + @error)', () {
    late Directory dir;
    final sm = SessionManager(SessionManager.generateKey(), secure: false);
    setUp(() {
      dir = Directory.systemTemp.createTempSync('formdx_');
      File('${dir.path}/form.blaze.html').writeAsStringSync(
          "@error('name')[{{ message }}]@enderror old=[{{ old.name }}]");
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('backWithErrors flashes errors+old; view repopulates', () async {
      final app = (Router(views: BlazeEngine(dir.path, cache: false), sessions: sm)
            ..get('/form', (r) => r.view('form'))
            ..post('/submit', (r) async {
              try {
                await r.validate({'name': 'required|min:3'});
                await r.text('ok');
              } on ValidationException catch (e) {
                await r.backWithErrors(e, fallback: '/form');
              }
            }))
          .toApp();

      final posted = await run(app, 'POST', '/submit', headers: {
        'content-type': 'application/x-www-form-urlencoded',
      }, body: utf8.encode('name=A'));
      expect(posted.statusCode, 302);
      final cookie = posted.headers['set-cookie']!.split(';').first;

      final form = await run(app, 'GET', '/form', headers: {'cookie': cookie});
      expect(form.text,
          '[The name must be at least 3 characters.] old=[A]');
    });

    test('view auto-injects the flash bag ({{ flash.status }})', () async {
      File('${dir.path}/notice.blaze.html')
          .writeAsStringSync('flash=[{{ flash.status }}]');
      final app = (Router(views: BlazeEngine(dir.path, cache: false), sessions: sm)
            ..get('/notice', (r) => r.view('notice'))
            ..post('/do', (r) async {
              r.session.flash('status', 'saved');
              await r.redirect('/notice');
            }))
          .toApp();
      final posted = await run(app, 'POST', '/do');
      final cookie = posted.headers['set-cookie']!.split(';').first;
      final notice = await run(app, 'GET', '/notice', headers: {'cookie': cookie});
      expect(notice.text, 'flash=[saved]');
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
