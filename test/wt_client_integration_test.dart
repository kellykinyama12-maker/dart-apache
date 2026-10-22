@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_apache/dart_apache.dart';
import 'package:dart_apache/src/http3/h3_php_server.dart';
import 'package:test/test.dart';

/// Live, in-process end-to-end test: a real [Http3PhpServer] (dev self-signed
/// cert, no files) with WebTransport echo, driven by the pure-Dart
/// [WebTransportClient] over loopback QUIC. Tagged `e2e` and skipped by default
/// (see dart_test.yaml) because it binds a UDP socket and runs a full QUIC
/// handshake; run with: `dart test -t e2e --run-skipped`.
void main() {
  test('WebTransport client round-trips greeting + datagram + uni + bidi',
      () async {
    final port = await _freeUdpPort();
    final config = ServerConfig(
      documentRoot: 'public',
      port: port,
      devMode: true,
      wtPath: '/wt',
      accessLogEnabled: false,
    );
    final server = Http3PhpServer(config);
    await server.start();

    WebTransportClient? client;
    try {
      client = await WebTransportClient.connect(
        Uri.parse('https://127.0.0.1:$port/wt'),
      );

      final received = <String>[];
      final sub = client.incoming.listen((msg) {
        final text = String.fromCharCodes(msg.data).trim();
        if (text.isNotEmpty) received.add(text);
      });

      client.sendDatagram('ping-e2e'.codeUnits);
      client.openUniStream('uni-e2e'.codeUnits);
      client.openBidiStream('bidi-e2e'.codeUnits, fin: true);

      // Poll until all four messages arrive or the deadline passes.
      final deadline = DateTime.now().add(const Duration(seconds: 6));
      while (DateTime.now().isBefore(deadline) && received.length < 4) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await sub.cancel();

      expect(received, contains('ping-e2e'));
      expect(received, contains('uni-e2e'));
      expect(received, contains('bidi-e2e'));
      expect(
        received.any((t) => t.contains('hello from dart-apache')),
        isTrue,
        reason: 'expected the server greeting; got $received',
      );
    } finally {
      await client?.close();
      await server.stop();
    }
  });
}

/// Binds an ephemeral UDP port, reads it, and releases it for the server.
Future<int> _freeUdpPort() async {
  final probe = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  probe.close();
  return port;
}
