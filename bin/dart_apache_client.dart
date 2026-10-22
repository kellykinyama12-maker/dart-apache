import 'dart:io';

import 'package:dart_apache/src/client/alt_svc_client.dart';
import 'package:dart_apache/src/client/client_response.dart';

/// An Alt-Svc-aware Dart HTTP client. Without request flags it runs a two-step
/// discovery demo (HTTP/1.1 first, auto-upgrade to HTTP/3). With curl-like
/// flags it performs a single request of the given method.
///
///   dart run bin/dart_apache_client.dart http://127.0.0.1:8080/
///   dart run bin/dart_apache_client.dart https://127.0.0.1:8443/ --insecure
///   dart run bin/dart_apache_client.dart https://host/ --ca-bundle=roots.pem
///   dart run bin/dart_apache_client.dart -X POST -H 'Content-Type: application/json' \
///     -d '{"a":1}' https://127.0.0.1:8443/echo.php --insecure
///   dart run bin/dart_apache_client.dart --head https://127.0.0.1:8443/ --insecure
Future<void> main(List<String> arguments) async {
  final opts = _parseArgs(arguments);
  final url = Uri.parse(opts.target);

  // --ca-bundle=<pem> enables chain-to-root validation (h3 + h1); otherwise
  // trust is pin/transcript based (use --insecure for dev self-signed certs).
  String? caBundlePem;
  if (opts.caBundlePath != null) {
    caBundlePem = File(opts.caBundlePath!).readAsStringSync();
  }

  final client = AltSvcHttpClient(
    verbose: true,
    allowInsecure: opts.insecure,
    caBundlePem: caBundlePem,
  );
  try {
    if (opts.hasRequestFlags) {
      final response = await client.request(
        opts.method,
        url,
        headers: opts.headers,
        body: opts.body,
      );
      await _emit(response, opts);
    } else {
      stdout.writeln('=== Request 1 (discovery) ===');
      _printResponse(await client.get(url));

      stdout.writeln(
          '\nHTTP/3 discovered for origin: ${client.knowsH3For(url)}');

      stdout.writeln('\n=== Request 2 (auto-upgrade) ===');
      _printResponse(await client.get(url));
    }
  } finally {
    client.close();
  }
}

class _Options {
  _Options({
    required this.target,
    required this.method,
    required this.headers,
    required this.body,
    required this.insecure,
    required this.caBundlePath,
    required this.outputPath,
    required this.headOnly,
    required this.hasRequestFlags,
  });

  final String target;
  final String method;
  final Map<String, String> headers;
  final List<int>? body;
  final bool insecure;
  final String? caBundlePath;
  final String? outputPath;
  final bool headOnly;
  final bool hasRequestFlags;
}

_Options _parseArgs(List<String> args) {
  var method = 'GET';
  final headers = <String, String>{};
  List<int>? body;
  var insecure = false;
  String? caBundlePath;
  String? outputPath;
  var headOnly = false;
  var explicitMethod = false;
  final positional = <String>[];

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String next() => (i + 1 < args.length)
        ? args[++i]
        : throw ArgumentError('missing value after $a');
    switch (a) {
      case '-X':
      case '--method':
        method = next();
        explicitMethod = true;
      case '-H':
      case '--header':
        final raw = next();
        final idx = raw.indexOf(':');
        if (idx <= 0) {
          throw ArgumentError('bad header (want "Name: Value"): $raw');
        }
        headers[raw.substring(0, idx).trim()] = raw.substring(idx + 1).trim();
      case '-d':
      case '--data':
        body = next().codeUnits;
      case '--head':
        headOnly = true;
      case '-o':
      case '--output':
        outputPath = next();
      case '--insecure':
        insecure = true;
      default:
        if (a.startsWith('--ca-bundle=')) {
          caBundlePath = a.substring('--ca-bundle='.length);
        } else if (!a.startsWith('--')) {
          positional.add(a);
        }
    }
  }

  // --head implies HEAD; a body with no explicit method implies POST.
  if (headOnly && !explicitMethod) method = 'HEAD';
  if (body != null && !explicitMethod && !headOnly) method = 'POST';

  final hasRequestFlags =
      explicitMethod || headers.isNotEmpty || body != null || headOnly ||
      outputPath != null;

  return _Options(
    target: positional.isNotEmpty ? positional[0] : 'http://127.0.0.1:8080/',
    method: method,
    headers: headers,
    body: body,
    insecure: insecure,
    caBundlePath: caBundlePath,
    outputPath: outputPath,
    headOnly: headOnly,
    hasRequestFlags: hasRequestFlags,
  );
}

Future<void> _emit(ClientResponse response, _Options opts) async {
  stdout.writeln('served over: ${response.protocol}  '
      'status: ${response.statusCode}  bytes: ${response.body.length}');
  final sortedKeys = response.headers.keys.toList()..sort();
  for (final k in sortedKeys) {
    stdout.writeln('  $k: ${response.headers[k]}');
  }
  if (opts.headOnly) return;
  if (opts.outputPath != null) {
    await File(opts.outputPath!).writeAsBytes(response.body);
    stdout.writeln('wrote ${response.body.length} bytes to ${opts.outputPath}');
  } else {
    final preview = response.text;
    stdout.writeln(
        preview.length > 240 ? '${preview.substring(0, 240)}…' : preview);
  }
}

void _printResponse(ClientResponse response) {
  stdout.writeln('served over: ${response.protocol}  '
      'status: ${response.statusCode}  bytes: ${response.body.length}');
  final preview = response.text;
  stdout.writeln(
      preview.length > 240 ? '${preview.substring(0, 240)}…' : preview);
}
