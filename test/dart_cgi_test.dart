@Tags(['e2e'])
library;

import 'dart:io';

import 'package:dart_apache/dart_apache.dart';
import 'package:test/test.dart';

/// Verifies the Dart script backend (`--dart-cgi`): a `.dart` file under the
/// document root is executed by the Dart VM per request (CGI-style), so edits
/// run without a compile — the Dart analog of `php-cgi`. Tagged `e2e` (starts a
/// server + spawns `dart run`); run with `dart test -t e2e --run-skipped`.
void main() {
  late ApacheServer server;
  late Uri base;
  late AltSvcHttpClient client;

  setUp(() async {
    final port = await _freeTcpPort();
    final config = ServerConfig(
      documentRoot: 'public',
      port: port,
      accessLogEnabled: false,
      dartCgiEnabled: true,
    );
    server = ApacheServer(config);
    await server.start();
    base = Uri.parse('http://127.0.0.1:$port');
    client = AltSvcHttpClient();
  });

  tearDown(() async {
    client.close();
    await server.stop();
  });

  test('GET runs the .dart script with query + method', () async {
    final r = await client.get(base.resolve('/hello.dart?name=ada'));
    expect(r.statusCode, 200);
    expect(r.headers['content-type'], contains('text/plain'));
    expect(r.headers['x-powered-by'], 'dart-cgi');
    expect(r.text, contains('Hello, ada!'));
    expect(r.text, contains('method=GET'));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('POST streams the request body to the script stdin', () async {
    final r = await client.post(base.resolve('/hello.dart'),
        body: 'payload!'.codeUnits);
    expect(r.statusCode, 200);
    expect(r.text, contains('method=POST'));
    expect(r.text, contains('body=payload!'));
  }, timeout: const Timeout(Duration(seconds: 60)));
}

Future<int> _freeTcpPort() async {
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}
