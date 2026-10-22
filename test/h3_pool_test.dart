@Tags(['e2e'])
library;

import 'dart:io';

import 'package:dart_apache/dart_apache.dart';
import 'package:dart_apache/src/http3/h3_php_server.dart';
import 'package:test/test.dart';

/// Live, in-process test that the pooled [H3Client] reuses one QUIC connection
/// across multiple requests to the same origin (serving a static file, so no
/// php-cgi is needed). Tagged `e2e` and skipped by default (see dart_test.yaml);
/// run with: `dart test -t e2e --run-skipped`.
void main() {
  test('H3Client reuses one pooled connection across requests', () async {
    final port = await _freeUdpPort();
    final server = Http3PhpServer(ServerConfig(
      documentRoot: 'public',
      port: port,
      devMode: true,
      accessLogEnabled: false,
    ));
    await server.start();

    final client = H3Client();
    final addr = InternetAddress('127.0.0.1');
    Future<ClientResponse> fetch() => client.request(
          method: 'GET',
          address: addr,
          port: port,
          authority: '127.0.0.1',
          sni: '127.0.0.1',
          path: '/static.html',
        );

    try {
      final r1 = await fetch();
      expect(r1.statusCode, 200);
      expect(client.pooledConnections, 1);

      // A second (sequential) request reuses the same connection.
      final r2 = await fetch();
      expect(r2.statusCode, 200);
      expect(client.pooledConnections, 1);

      // Concurrent requests also share the one connection (connect dedup).
      final batch = await Future.wait([fetch(), fetch(), fetch()]);
      expect(batch.every((r) => r.statusCode == 200), isTrue);
      expect(client.pooledConnections, 1);
    } finally {
      await client.close();
      await server.stop();
    }
  });
}

Future<int> _freeUdpPort() async {
  final probe = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  probe.close();
  return port;
}
