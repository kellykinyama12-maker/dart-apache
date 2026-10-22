import 'dart:async';
import 'dart:io';

// The generator lives in the vendored dart_quiche public API.
import 'package:dart_quiche/dart_quiche.dart' show generateSelfSignedP256Cert;

/// Generates a self-signed ECDSA P-256 `cert.pem` + `key.pem` for local HTTP/3
/// testing (CN/SAN = 127.0.0.1, localhost).
///
///   dart run tool/gen_dev_cert.dart [outputDir]
///
/// Then: dart run bin/dart_apache_h3.dart --tls-cert=cert.pem --tls-key=key.pem
void main(List<String> args) {
  final dir = args.isNotEmpty ? args.first : '.';

  // The vendored generator prints the PEMs to stdout; capture them.
  final captured = StringBuffer();
  runZoned(
    generateSelfSignedP256Cert,
    zoneSpecification:
        ZoneSpecification(print: (_, _, _, line) => captured.writeln(line)),
  );
  final text = captured.toString();

  final key = _extract(text, 'EC PRIVATE KEY');
  final cert = _extract(text, 'CERTIFICATE');
  if (key == null || cert == null) {
    stderr.writeln('Failed to capture PEM output from the generator.');
    exitCode = 1;
    return;
  }

  File('$dir/key.pem').writeAsStringSync('$key\n');
  File('$dir/cert.pem').writeAsStringSync('$cert\n');
  stdout.writeln('Wrote $dir/cert.pem and $dir/key.pem');
}

String? _extract(String text, String label) {
  final match = RegExp(
    '-----BEGIN $label-----[\\s\\S]*?-----END $label-----',
  ).firstMatch(text);
  return match?.group(0);
}
