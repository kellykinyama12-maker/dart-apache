@Tags(['e2e'])
library;

import 'dart:io';

import 'package:dart_apache/dart_apache.dart';
import 'package:test/test.dart';

import '../example/parity_app.dart';

/// Parity tests: the native-Dart app (`example/parity_app.dart`) must produce
/// responses equivalent to the PHP sample app in `public/*.php`. Two styles:
///  1. one server serving both (PHP at `*.php`, Dart under `/parity/*`);
///  2. A/B — two servers (one PHP, one Dart drop-in) at *identical* `.php`
///     paths, which lets even path-sensitive endpoints (fc, index) match
///     strictly. Tagged `e2e`, skipped by default and when php-cgi is absent.
void main() {
  final php = _phpAvailable();

  group('PHP vs Dart (one server: *.php vs /parity/*)', () {
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
      expect(d.text, p.text);
      expect(d.text, 'method=POST\nname=ada\nlen=8\n');
    });

    test('status_echo.php == /parity/status', () async {
      final p = await client.get(base.resolve('/status_echo.php'));
      final d = await client.get(base.resolve('/parity/status'));
      expect(d.statusCode, p.statusCode);
      expect(d.statusCode, 419);
      expect(d.headers['x-demo-header'], p.headers['x-demo-header']);
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

    test('swr.php == /parity/swr (headers + shape)', () async {
      final p = await client.get(base.resolve('/swr.php'));
      final d = await client.get(base.resolve('/parity/swr'));
      expect(d.statusCode, p.statusCode);
      expect(d.headers['cache-control'], p.headers['cache-control']);
      expect(d.headers['cache-control'], 'max-age=0, stale-while-revalidate=30');
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

  group('PHP vs Dart drop-in (A/B, identical .php paths)', () {
    late ApacheServer phpServer;
    late ApacheServer dartServer;
    late Uri phpBase;
    late Uri dartBase;
    late AltSvcHttpClient client;

    setUp(() async {
      final phpPort = await _freeTcpPort();
      final phpConfig = ServerConfig(
          documentRoot: 'public', port: phpPort, accessLogEnabled: false);
      phpServer = ApacheServer(phpConfig); // no app -> serves PHP
      await phpServer.start();
      phpBase = Uri.parse('http://127.0.0.1:$phpPort');

      final dartPort = await _freeTcpPort();
      final dartConfig = ServerConfig(
          documentRoot: 'public', port: dartPort, accessLogEnabled: false);
      // Dart handlers mounted at the .php paths shadow the PHP files.
      dartServer = ApacheServer(dartConfig, app: buildDropInApp(dartConfig));
      await dartServer.start();
      dartBase = Uri.parse('http://127.0.0.1:$dartPort');

      client = AltSvcHttpClient();
    });

    tearDown(() async {
      client.close();
      await phpServer.stop();
      await dartServer.stop();
    });

    Future<(ClientResponse, ClientResponse)> both(
      String method,
      String path, {
      Map<String, String> headers = const {},
      List<int>? body,
    }) async {
      final p = await client.request(method, phpBase.resolve(path),
          headers: headers, body: body);
      final d = await client.request(method, dartBase.resolve(path),
          headers: headers, body: body);
      return (p, d);
    }

    test('/index.php — normalized HTML matches', () async {
      final (p, d) = await both('GET', '/index.php?name=ada');
      expect(d.statusCode, p.statusCode);
      expect(_normalizeHtml(d.text), _normalizeHtml(p.text));
    });

    test('/echo.php — byte-identical', () async {
      final (p, d) = await both('POST', '/echo.php',
          headers: {'content-type': 'application/x-www-form-urlencoded'},
          body: 'name=ada'.codeUnits);
      expect(d.text, p.text);
      expect(d.text, 'method=POST\nname=ada\nlen=8\n');
    });

    test('/cacheable.php — headers + shape', () async {
      final (p, d) = await both('GET', '/cacheable.php');
      expect(d.headers['cache-control'], p.headers['cache-control']);
      expect(d.text, startsWith('generated-at='));
    });

    test('/swr.php — headers + shape', () async {
      final (p, d) = await both('GET', '/swr.php');
      expect(d.headers['cache-control'], p.headers['cache-control']);
      expect(d.headers['cache-control'], 'max-age=0, stale-while-revalidate=30');
    });

    test('/status_echo.php — status + header + JSON', () async {
      final (p, d) = await both('GET', '/status_echo.php');
      expect(d.statusCode, p.statusCode);
      expect(d.statusCode, 419);
      expect(d.headers['x-demo-header'], p.headers['x-demo-header']);
      expect(d.json, p.json);
    });

    test('/csrf_echo.php — JSON matches', () async {
      final (p, d) = await both('POST', '/csrf_echo.php', headers: {
        'content-type': 'application/json',
        'cookie': 'sess=abc',
        'x-csrf-token': 'csrf-1',
        'authorization': 'Bearer z',
      }, body: '{"a":1}'.codeUnits);
      expect(d.json, p.json);
    });

    test('/fc.php — strict JSON (same path -> request_uri/script_name match)',
        () async {
      final (p, d) = await both('GET', '/fc.php');
      expect(d.statusCode, p.statusCode);
      expect(d.json, p.json);
      expect(d.json, {
        'front_controller': true,
        'request_uri': '/fc.php',
        'method': 'GET',
        'script_name': '/fc.php',
      });
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
