import 'dart:io';

import 'package:dart_apache/src/client/alt_svc_client.dart';
import 'package:dart_apache/src/client/client_response.dart';

/// Demonstrates an Alt-Svc-aware Dart client: the first request goes over
/// HTTP/1.1 and discovers HTTP/3 via the `Alt-Svc` header; the second request
/// upgrades to HTTP/3 automatically.
///
///   dart run bin/dart_apache_client.dart http://127.0.0.1:8080/
///   dart run bin/dart_apache_client.dart https://127.0.0.1:8080/ --insecure
///   dart run bin/dart_apache_client.dart https://host/ --ca-bundle=roots.pem
Future<void> main(List<String> arguments) async {
  final positional = arguments.where((a) => !a.startsWith('--')).toList();
  final target =
      positional.isNotEmpty ? positional[0] : 'http://127.0.0.1:8080/';
  final url = Uri.parse(target);

  // --ca-bundle=<pem> enables chain-to-root validation (h3 + h1); otherwise
  // trust is pin/transcript based (use --insecure for dev self-signed certs).
  String? caBundlePem;
  final caArg = arguments.firstWhere(
    (a) => a.startsWith('--ca-bundle='),
    orElse: () => '',
  );
  if (caArg.isNotEmpty) {
    final path = caArg.substring('--ca-bundle='.length);
    caBundlePem = File(path).readAsStringSync();
  }

  final client = AltSvcHttpClient(
    verbose: true,
    allowInsecure: arguments.contains('--insecure'),
    caBundlePem: caBundlePem,
  );
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
