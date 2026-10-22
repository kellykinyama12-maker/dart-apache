import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_apache/dart_apache.dart';
import 'package:test/test.dart';

CachedResponse _entry(String body, Duration fresh) => CachedResponse(
      statusCode: 200,
      headers: const [],
      body: Uint8List.fromList(utf8.encode(body)),
      storedAt: DateTime.now(),
      freshness: fresh,
      varyNames: const [],
      varyValues: const {},
    );

void main() {
  group('sharedCacheFreshness', () {
    Duration? f({
      String method = 'GET',
      int status = 200,
      Map<String, String> res = const {},
      Map<String, String> req = const {},
    }) =>
        sharedCacheFreshness(
          method: method,
          statusCode: status,
          responseHeaders: res,
          requestHeaders: req,
        );

    test('explicit max-age is cacheable', () {
      expect(f(res: {'cache-control': 'max-age=60'}), const Duration(seconds: 60));
    });
    test('s-maxage overrides max-age for a shared cache', () {
      expect(f(res: {'cache-control': 'max-age=10, s-maxage=99'}),
          const Duration(seconds: 99));
    });
    test('no-store / private / no-cache are not cacheable', () {
      expect(f(res: {'cache-control': 'max-age=60, no-store'}), isNull);
      expect(f(res: {'cache-control': 'private, max-age=60'}), isNull);
      expect(f(res: {'cache-control': 'no-cache'}), isNull);
    });
    test('Set-Cookie, Vary:*, Authorization, non-200, non-GET are rejected', () {
      expect(f(res: {'cache-control': 'max-age=60', 'set-cookie': 'a=b'}), isNull);
      expect(f(res: {'cache-control': 'max-age=60', 'vary': '*'}), isNull);
      expect(f(res: {'cache-control': 'max-age=60'}, req: {'authorization': 'x'}),
          isNull);
      expect(f(status: 404, res: {'cache-control': 'max-age=60'}), isNull);
      expect(f(method: 'POST', res: {'cache-control': 'max-age=60'}), isNull);
    });
    test('no explicit freshness -> not cached', () {
      expect(f(res: {'content-type': 'text/html'}), isNull);
    });
  });

  group('ResponseCache', () {
    test('get returns fresh entries and evicts stale ones', () {
      final c = ResponseCache();
      c.put('k', _entry('v', const Duration(seconds: 60)));
      expect(utf8.decode(c.get('k', const {})!.body), 'v');
      c.put('s', _entry('old', const Duration(seconds: -1)));
      expect(c.get('s', const {}), isNull); // stale -> evicted
      expect(c.length, 1);
    });

    test('LRU eviction respects the byte budget', () {
      final c = ResponseCache(maxBytes: 512 + 10 + 512 + 10); // ~2 small entries
      c.put('a', _entry('aaaaaaaaaa', const Duration(seconds: 60)));
      c.put('b', _entry('bbbbbbbbbb', const Duration(seconds: 60)));
      c.get('a', const {}); // touch a -> b is now LRU
      c.put('d', _entry('dddddddddd', const Duration(seconds: 60)));
      expect(c.get('b', const {}), isNull); // evicted
      expect(c.get('a', const {}), isNotNull);
      expect(c.get('d', const {}), isNotNull);
    });
  });

  group('pipeline caching (Dart route)', () {
    test('cacheable route: second GET is a HIT, handler not re-run', () async {
      var hits = 0;
      final app = DartApp([
        DartRoute.exact('/dyn', (e, r) async {
          hits++;
          r.setHeader('cache-control', 'max-age=60');
          await r.writeText('n=$hits');
        }),
      ]);
      final pipeline =
          RequestPipeline(ServerConfig(documentRoot: '.', cacheEnabled: true),
              app: app);

      final first = await _get(pipeline, '/dyn');
      expect(first.headers['x-cache'], 'MISS');
      expect(utf8.decode(first.body), 'n=1');

      final second = await _get(pipeline, '/dyn');
      expect(second.headers['x-cache'], 'HIT');
      expect(second.headers['age'], isNotNull);
      expect(utf8.decode(second.body), 'n=1'); // handler not re-run
      expect(hits, 1);
    });

    test('non-cacheable route is BYPASS and always re-runs', () async {
      var hits = 0;
      final app = DartApp([
        DartRoute.exact('/nc', (e, r) async {
          hits++;
          await r.writeText('n=$hits');
        }),
      ]);
      final pipeline =
          RequestPipeline(ServerConfig(documentRoot: '.', cacheEnabled: true),
              app: app);
      final a = await _get(pipeline, '/nc');
      final b = await _get(pipeline, '/nc');
      expect(a.headers['x-cache'], 'BYPASS');
      expect(utf8.decode(a.body), 'n=1');
      expect(utf8.decode(b.body), 'n=2');
      expect(hits, 2);
    });

    test('Vary keys the entry on the named request header', () async {
      var hits = 0;
      final app = DartApp([
        DartRoute.exact('/v', (e, r) async {
          hits++;
          r
            ..setHeader('cache-control', 'max-age=60')
            ..setHeader('vary', 'Accept-Encoding');
          await r.writeText('n=$hits');
        }),
      ]);
      final pipeline =
          RequestPipeline(ServerConfig(documentRoot: '.', cacheEnabled: true),
              app: app);
      final g1 = await _get(pipeline, '/v', {'accept-encoding': 'gzip'});
      final g2 = await _get(pipeline, '/v', {'accept-encoding': 'gzip'});
      final br = await _get(pipeline, '/v', {'accept-encoding': 'br'});
      expect(g1.headers['x-cache'], 'MISS');
      expect(g2.headers['x-cache'], 'HIT'); // same Vary value
      expect(br.headers['x-cache'], 'MISS'); // different Vary value
    });

    test('HEAD is served from a cached GET (headers, no body)', () async {
      var hits = 0;
      final app = DartApp([
        DartRoute.exact('/h', (e, r) async {
          hits++;
          r.setHeader('cache-control', 'max-age=60');
          await r.writeText('body');
        }, methods: {'GET'}),
      ]);
      final pipeline =
          RequestPipeline(ServerConfig(documentRoot: '.', cacheEnabled: true),
              app: app);
      await _get(pipeline, '/h'); // populate cache
      final head = await _method(pipeline, 'HEAD', '/h');
      expect(head.headers['x-cache'], 'HIT');
      expect(head.body, isEmpty);
      expect(head.headers['content-length'], '4'); // from the cached GET
      expect(hits, 1); // handler ran once
    });

    test('request Cache-Control: no-cache bypasses the hit', () async {
      var hits = 0;
      final app = DartApp([
        DartRoute.exact('/b', (e, r) async {
          hits++;
          r.setHeader('cache-control', 'max-age=60');
          await r.writeText('n=$hits');
        }),
      ]);
      final pipeline =
          RequestPipeline(ServerConfig(documentRoot: '.', cacheEnabled: true),
              app: app);
      await _get(pipeline, '/b'); // MISS, stored n=1
      final bust = await _get(pipeline, '/b', {'cache-control': 'no-cache'});
      expect(bust.headers['x-cache'], 'MISS'); // re-run + re-store
      expect(utf8.decode(bust.body), 'n=2');
      final after = await _get(pipeline, '/b');
      expect(after.headers['x-cache'], 'HIT');
      expect(utf8.decode(after.body), 'n=2'); // refreshed entry
    });

    test('stale-while-revalidate serves stale then refreshes in background',
        () async {
      var hits = 0;
      final app = DartApp([
        DartRoute.exact('/swr', (e, r) async {
          hits++;
          // Immediately stale, but serveable-stale for 60s.
          r.setHeader('cache-control', 'max-age=0, stale-while-revalidate=60');
          await r.writeText('n=$hits');
        }),
      ]);
      final pipeline =
          RequestPipeline(ServerConfig(documentRoot: '.', cacheEnabled: true),
              app: app);

      final a = await _get(pipeline, '/swr'); // MISS, stores n=1
      expect(a.headers['x-cache'], 'MISS');
      expect(utf8.decode(a.body), 'n=1');

      final b = await _get(pipeline, '/swr'); // stale -> served immediately
      expect(b.headers['x-cache'], 'STALE');
      expect(utf8.decode(b.body), 'n=1'); // the stale value, served now

      // Background revalidation refreshed the entry to n=2.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(hits, 2);

      final c = await _get(pipeline, '/swr');
      expect(c.headers['x-cache'], 'STALE');
      expect(utf8.decode(c.body), 'n=2'); // now serving the refreshed value
    });
  });
}

Future<_FakeResponse> _method(RequestPipeline p, String method, String path,
    [Map<String, String> headers = const {}]) async {
  final ex = _FakeExchange(method, Uri.parse(path), headers);
  await p.serve(ex);
  return ex.response;
}

Future<_FakeResponse> _get(RequestPipeline p, String path,
    [Map<String, String> headers = const {}]) async {
  final ex = _FakeExchange('GET', Uri.parse(path), headers);
  await p.serve(ex);
  return ex.response;
}

class _FakeExchange implements ServerExchange {
  _FakeExchange(this.method, this.uri, this._headers);
  @override
  final String method;
  @override
  final Uri uri;
  final Map<String, String> _headers;
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
  int get remotePort => 1;
  @override
  int get contentLength => 0;
  @override
  String? get contentType => null;
  @override
  void forEachHeader(void Function(String name, String value) action) =>
      _headers.forEach(action);
  @override
  Stream<List<int>> get body => const Stream.empty();
  @override
  ServerResponse respond() => response;
}

class _FakeResponse implements ServerResponse {
  int _status = 200;
  final Map<String, String> headers = {};
  final List<int> body = [];

  @override
  int get statusCode => _status;
  @override
  void setStatus(int statusCode, [String? reasonPhrase]) => _status = statusCode;
  @override
  void setHeader(String name, String value) => headers[name.toLowerCase()] = value;
  @override
  Future<void> addStream(Stream<List<int>> body) async {
    await for (final c in body) {
      this.body.addAll(c);
    }
  }

  @override
  Future<void> close() async {}
}
