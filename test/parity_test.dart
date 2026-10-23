@Tags(['e2e'])
library;

import 'dart:io';

import 'package:dart_apache/dart_apache.dart';
import 'package:test/test.dart';

import '../example/parity_app.dart';

/// Parity tests: the native-Dart app (`example/parity_app.dart`, mounted under
/// `/parity/`) must produce responses equivalent to the PHP sample app in
/// `public/*.php`. Runs one in-process HTTP/1.1 server serving both, hits each
/// pair, and compares (normalizing volatile timestamps). Tagged `e2e` and
/// skipped by default; also skipped when php-cgi is unavailable.
void main() {
  final php = _phpAvailable();

  group('PHP vs Dart parity', () {
    late ApacheServer server;
    late Uri base;
    late AltSvcHttpClient client;

    setUp(() async {
      final port = await _freeTcpPort();
      final config = ServerConfig(
        documentRoot: 'public',
        port: port,
        accessLogEnabled: false,
      );
      server = ApacheServer(config, app: buildParityApp(config));
      await server.start();
      base = Uri.parse('http://127.0.0.1:$port');
      client = AltSvcHttpClient();
    });

    tearDown(() async {
      client.close();
      await server.stop();
    });

    test('echo.php == /parity/echo', () async {
      final headers = {'content-type': 'application/x-www-form-urlencoded'};
      final body = 'name=ada'.codeUnits;
      final p = await client.post(base.resolve('/echo.php'),
          body: body, headers: headers);
      final d = await client.post(base.resolve('/parity/echo'),
          body: body, headers: headers);
      expect(p.statusCode, 200);
      expect(d.statusCode, 200);
      expect(d.text, p.text);
      expect(d.text, 'method=POST\nname=ada\nlen=8\n');
    });

    test('status_echo.php == /parity/status', () async {
      final p = await client.get(base.resolve('/status_echo.php'));
      final d = await client.get(base.resolve('/parity/status'));
      expect(d.statusCode, p.statusCode);
      expect(d.statusCode, 419);
      expect(d.headers['x-demo-header'], p.headers['x-demo-header']);
      expect(d.headers['x-demo-header'], 'demo-value');
      expect(d.json, p.json);
      expect(d.json, {'msg': 'page-expired', 'code': 419});
    });

    test('csrf_echo.php == /parity/csrf', () async {
      final headers = {
        'content-type': 'application/json',
        'cookie': 'sess=abc; XSRF-TOKEN=tok',
        'x-csrf-token': 'csrf-1',
        'x-xsrf-token': 'xsrf-1',
        'authorization': 'Bearer z',
        'x-requested-with': 'XMLHttpRequest',
      };
      final body = '{"a":1}'.codeUnits;
      final p = await client.post(base.resolve('/csrf_echo.php'),
          body: body, headers: headers);
      final d = await client.post(base.resolve('/parity/csrf'),
          body: body, headers: headers);
      expect(d.json, p.json);
    });

    test('cacheable.php == /parity/cacheable (headers + shape)', () async {
      final p = await client.get(base.resolve('/cacheable.php'));
      final d = await client.get(base.resolve('/parity/cacheable'));
      expect(d.statusCode, p.statusCode);
      expect(d.headers['cache-control'], p.headers['cache-control']);
      expect(d.headers['cache-control'], 'max-age=60');
      expect(d.text, startsWith('generated-at='));
      expect(p.text, startsWith('generated-at='));
    });

    test('index.php == /parity/ (normalized HTML)', () async {
      final p = await client.get(base.resolve('/index.php?name=ada'));
      final d = await client.get(base.resolve('/parity/?name=ada'));
      expect(d.statusCode, p.statusCode);
      expect(_normalizeHtml(d.text), _normalizeHtml(p.text));
      expect(_normalizeHtml(d.text), contains('<h1>Hello, ada!</h1>'));
    });
  }, skip: php ? null : 'php-cgi not found on PATH');
}

/// Drops blank lines and the volatile "The time is …" line, trims each line.
String _normalizeHtml(String html) => html
    .split('\n')
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty && !l.contains('The time is'))
    .join('\n');

bool _phpAvailable() {
  try {
    final r = Process.runSync('php-cgi', ['--version']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<int> _freeTcpPort() async {
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}
