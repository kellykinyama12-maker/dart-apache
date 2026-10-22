import 'dart:async';

import 'package:dart_apache/dart_apache.dart';

/// Demonstrates the pure-Dart WebTransport client against dart-apache's native
/// WT echo endpoint.
///
/// Start the server:
///   dart run bin/dart_apache.dart --root=./public --port=8443 --http3 \
///     --tls-cert=build/cert.pem --tls-key=build/key.pem --workers=1 --wt-path=/wt
///
/// Then:
///   dart run example/wt_client.dart
Future<void> main(List<String> args) async {
  final target = args.isNotEmpty ? args[0] : 'https://127.0.0.1:8443/wt';
  final client = await WebTransportClient.connect(Uri.parse(target));
  print('WebTransport session open (stream ${client.sessionId})');

  final received = <String>[];
  final sub = client.incoming.listen((msg) {
    final kind = msg.isDatagram ? 'datagram' : 'stream ${msg.streamId}';
    final text = String.fromCharCodes(msg.data).trim();
    if (text.isNotEmpty) {
      received.add('[$kind] $text');
      print('← [$kind] $text');
    }
  });

  client.sendDatagram('ping-dart'.codeUnits);
  client.openUniStream('uni-hello'.codeUnits);
  client.openBidiStream('bidi-hello'.codeUnits, fin: true);

  // Let echoes and the greeting arrive.
  await Future<void>.delayed(const Duration(seconds: 2));

  await sub.cancel();
  await client.close();
  print('\nreceived ${received.length} message(s); session closed');
}
