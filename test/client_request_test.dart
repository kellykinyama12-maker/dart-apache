import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_apache/dart_apache.dart';
import 'package:test/test.dart';

/// End-to-end tests for [AltSvcHttpClient] over a real local HTTP/1.1 server:
/// methods, bodies, headers, conditional/range, HEAD, gzip, plus the general-
/// use features (convenience verbs, query, JSON, interceptors, retry, timeout,
/// cancellation, multipart).
void main() {
  late HttpServer server;
  late Uri base;
  late AltSvcHttpClient client;
  late _ServerState state;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    state = _ServerState();
    unawaited(_handle(server, state));
    client = AltSvcHttpClient();
  });

  tearDown(() async {
    client.close();
    await server.close(force: true);
  });

  test('arbitrary method + body + custom header round-trips', () async {
    final res = await client.request(
      'POST',
      base.resolve('/echo'),
      headers: {'X-Demo': 'hello'},
      body: utf8.encode('payload-123'),
    );
    expect(res.statusCode, 200);
    final echoed = res.json as Map<String, dynamic>;
    expect(echoed['method'], 'POST');
    expect(echoed['x-demo'], 'hello');
    expect(echoed['body'], 'payload-123');
  });

  test('PUT and DELETE are carried through', () async {
    expect((await client.put(base.resolve('/echo'))).statusCode, 200);
    final del = await client.delete(base.resolve('/echo'));
    expect((del.json as Map)['method'], 'DELETE');
  });

  test('ifNoneMatch helper yields a 304', () async {
    final res = await client.get(
      base.resolve('/conditional'),
      ifNoneMatch: '"abc"',
    );
    expect(res.statusCode, 304);
    expect(res.body, isEmpty);
  });

  test('range helper is sent to the server', () async {
    final res = await client.get(base.resolve('/echo'), range: 'bytes=0-9');
    expect((res.json as Map)['range'], 'bytes=0-9');
  });

  test('HEAD returns headers with no body', () async {
    final res = await client.head(base.resolve('/echo'));
    expect(res.statusCode, 200);
    expect(res.body, isEmpty);
  });

  test('gzip response body is transparently decoded', () async {
    final res = await client.get(base.resolve('/gzip'));
    expect(res.statusCode, 200);
    expect(res.text, 'the quick brown fox');
  });

  test('post(json:) encodes JSON + content-type; response.json decodes',
      () async {
    final res = await client.post(base.resolve('/echo'), json: {'a': 1});
    final echoed = res.json as Map<String, dynamic>;
    expect(echoed['method'], 'POST');
    expect(echoed['content-type'], contains('application/json'));
    expect(jsonDecode(echoed['body'] as String), {'a': 1});
  });

  test('query parameters are merged into the URL', () async {
    final res =
        await client.get(base.resolve('/echo'), query: {'x': '1', 'y': '2'});
    expect((res.json as Map)['query'], 'x=1&y=2');
  });

  test('interceptors mutate the request and observe the response', () async {
    ClientResponse? seen;
    final c = AltSvcHttpClient(interceptors: [
      InterceptorCallbacks(
        onRequest: (o) => o.headers['x-demo'] = 'from-interceptor',
        onResponse: (r) => seen = r,
      ),
      BearerAuthInterceptor('tok123'),
    ]);
    try {
      final res = await c.get(base.resolve('/echo'));
      final echoed = res.json as Map<String, dynamic>;
      expect(echoed['x-demo'], 'from-interceptor');
      expect(echoed['authorization'], 'Bearer tok123');
      expect(seen, isNotNull);
    } finally {
      c.close();
    }
  });

  test('retry recovers after transient 503s', () async {
    state.flakyFailuresLeft = 2;
    final c = AltSvcHttpClient(
      retryPolicy: RetryPolicy(maxRetries: 3, backoff: (_) => Duration.zero),
    );
    try {
      final res = await c.get(base.resolve('/flaky'));
      expect(res.statusCode, 200);
      expect(state.flakyHits, 3); // two 503s + one 200
    } finally {
      c.close();
    }
  });

  test('timeout throws when the server is too slow', () async {
    await expectLater(
      client.get(base.resolve('/slow'),
          timeout: const Duration(milliseconds: 100)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('cancellation aborts the request', () async {
    final token = CancelToken();
    final future = client.get(base.resolve('/slow'), cancelToken: token);
    token.cancel('user navigated away');
    await expectLater(future, throwsA(isA<RequestCancelledException>()));
  });

  test('multipart body is encoded with a boundary and parts', () async {
    final res = await client.post(
      base.resolve('/multipart'),
      multipart: MultipartBody(
        fields: {'name': 'ada'},
        files: [
          MultipartFile('file', utf8.encode('file-bytes'),
              filename: 'a.txt', contentType: 'text/plain'),
        ],
      ),
    );
    final echoed = res.json as Map<String, dynamic>;
    expect(echoed['content-type'], contains('multipart/form-data; boundary='));
    expect(echoed['hasNameField'], isTrue);
    expect(echoed['hasFilePart'], isTrue);
  });
}

class _ServerState {
  int flakyFailuresLeft = 0;
  int flakyHits = 0;
}

Future<void> _handle(HttpServer server, _ServerState state) async {
  await for (final req in server) {
    final res = req.response;
    switch (req.uri.path) {
      case '/echo':
        final body = await utf8.decoder.bind(req).join();
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'method': req.method,
          'x-demo': req.headers.value('x-demo'),
          'authorization': req.headers.value('authorization'),
          'content-type': req.headers.value('content-type'),
          'range': req.headers.value('range'),
          'query': req.uri.query,
          'body': body,
        }));
      case '/conditional':
        if (req.headers.value('if-none-match') != null) {
          res.statusCode = HttpStatus.notModified;
        } else {
          res.write('full');
        }
      case '/gzip':
        res.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
        res.add(gzip.encode(utf8.encode('the quick brown fox')));
      case '/flaky':
        state.flakyHits++;
        if (state.flakyFailuresLeft > 0) {
          state.flakyFailuresLeft--;
          res.statusCode = HttpStatus.serviceUnavailable;
        } else {
          res.write('ok');
        }
      case '/slow':
        await Future<void>.delayed(const Duration(milliseconds: 500));
        res.write('late');
      case '/multipart':
        final body = await utf8.decoder.bind(req).join();
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'content-type': req.headers.value('content-type'),
          'hasNameField': body.contains('name="name"'),
          'hasFilePart': body.contains('filename="a.txt"') &&
              body.contains('file-bytes'),
        }));
      default:
        res.statusCode = HttpStatus.notFound;
    }
    await res.close();
  }
}
