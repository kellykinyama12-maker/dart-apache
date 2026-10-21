import 'dart:io';

import 'package:dart_apache/src/client/alt_svc_client.dart';
import 'package:dart_apache/src/client/client_response.dart';

/// Demonstrates an Alt-Svc-aware Dart client: the first request goes over
/// HTTP/1.1 and discovers HTTP/3 via the `Alt-Svc` header; the second request
/// upgrades to HTTP/3 automatically.
///
///   dart run bin/dart_apache_client.dart http://127.0.0.1:8080/
Future<void> main(List<String> arguments) async {
  final target = arguments.isNotEmpty ? arguments[0] : 'http://127.0.0.1:8080/';
  final url = Uri.parse(target);

  final client = AltSvcHttpClient(verbose: true);
  try {
    stdout.writeln('=== Request 1 (discovery) ===');
    final first = await client.get(url);
    _printResponse(first);

    stdout.writeln('\nHTTP/3 discovered for origin: ${client.knowsH3For(url)}');

    stdout.writeln('\n=== Request 2 (auto-upgrade) ===');
    final second = await client.get(url);
    _printResponse(second);
  } finally {
    client.close();
  }
}

void _printResponse(ClientResponse response) {
  stdout.writeln('served over: ${response.protocol}  '
      'status: ${response.statusCode}  bytes: ${response.body.length}');
  final preview = response.text;
  stdout.writeln(preview.length > 240
      ? '${preview.substring(0, 240)}…'
      : preview);
}
