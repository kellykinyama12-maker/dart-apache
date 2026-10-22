import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_apache/src/client/alt_svc_client.dart';
import 'package:test/test.dart';

/// End-to-end tests for the generalized [AltSvcHttpClient.request] over a real
/// local HTTP/1.1 server (no HTTP/3 needed): arbitrary methods, request bodies,
/// custom headers, conditional/range helpers, HEAD, and transparent gzip.
void main() {
  late HttpServer server;
  late Uri base;
  late AltSvcHttpClient client;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    unawaited(_handle(server));
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
    final echoed = jsonDecode(res.text) as Map<String, dynamic>;
    expect(echoed['method'], 'POST');
    expect(echoed['x-demo'], 'hello');
    expect(echoed['body'], 'payload-123');
  });

  test('PUT and DELETE are carried through', () async {
    expect((await client.request('PUT', base.resolve('/echo'))).statusCode, 200);
    final del = await client.request('DELETE', base.resolve('/echo'));
    expect((jsonDecode(del.text) as Map)['method'], 'DELETE');
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
    expect((jsonDecode(res.text) as Map)['range'], 'bytes=0-9');
  });

  test('HEAD returns headers with no body', () async {
    final res = await client.request('HEAD', base.resolve('/echo'));
    expect(res.statusCode, 200);
    expect(res.body, isEmpty);
  });

  test('gzip response body is transparently decoded', () async {
    final res = await client.get(base.resolve('/gzip'));
    expect(res.statusCode, 200);
    expect(res.text, 'the quick brown fox');
  });
}

Future<void> _handle(HttpServer server) async {
  await for (final req in server) {
    final res = req.response;
    switch (req.uri.path) {
      case '/echo':
        final body = await utf8.decoder.bind(req).join();
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'method': req.method,
          'x-demo': req.headers.value('x-demo'),
          'range': req.headers.value('range'),
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
      default:
        res.statusCode = HttpStatus.notFound;
    }
    await res.close();
  }
}
