import 'dart:async';

import 'package:dart_quiche/dart_quiche.dart' show generateSelfSignedP256Cert;

/// A self-signed certificate + private key as PEM strings, for dev TLS.
typedef DevCertPem = ({String cert, String key});

/// Generates a self-signed ECDSA P-256 cert/key PEM pair (CN/SAN = 127.0.0.1,
/// localhost). The vendored generator prints the PEMs to stdout, so capture
/// them in a print-collecting zone.
DevCertPem generateDevCertPem() {
  final captured = StringBuffer();
  runZoned(
    generateSelfSignedP256Cert,
    zoneSpecification:
        ZoneSpecification(print: (_, _, _, line) => captured.writeln(line)),
  );
  final text = captured.toString();

  final cert = _extract(text, 'CERTIFICATE');
  final key = _extract(text, 'EC PRIVATE KEY');
  if (cert == null || key == null) {
    throw StateError('failed to generate a dev certificate');
  }
  return (cert: cert, key: key);
}

String? _extract(String text, String label) => RegExp(
      '-----BEGIN $label-----[\\s\\S]*?-----END $label-----',
    ).firstMatch(text)?.group(0);
