// Certificate pinning for the HTTP client. A [CertificatePinner] holds a set of
// trusted SHA-256 fingerprints of whole DER certificates; a TLS connection is
// accepted only when the server's leaf certificate matches a pin — trust comes
// from the pin, not from a CA. This is the client-side analog of the harness's
// `--ignore-certificate-errors-spki-list` (here keyed on the whole cert).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Pins one or more server certificates by SHA-256 of their DER encoding.
class CertificatePinner {
  /// Each pin is base64 of SHA-256(certificate DER); a leading `sha256/` is
  /// accepted and stripped (HPKP-style).
  CertificatePinner(Iterable<String> pins)
      : _pins = pins.map(_normalize).toSet();

  final Set<String> _pins;

  bool get isEmpty => _pins.isEmpty;

  /// True when [cert]'s DER matches one of the pins.
  bool allows(X509Certificate cert) => allowsDer(cert.der);

  /// True when the DER bytes match one of the pins.
  bool allowsDer(List<int> der) => _pins.contains(pinForDer(der));

  /// The pin (base64 SHA-256) for a DER-encoded certificate.
  static String pinForDer(List<int> der) {
    final digest = SHA256Digest();
    final bytes = der is Uint8List ? der : Uint8List.fromList(der);
    final out = Uint8List(32);
    digest
      ..update(bytes, 0, bytes.length)
      ..doFinal(out, 0);
    return base64.encode(out);
  }

  /// The pin for the first certificate in a PEM string.
  static String pinForPem(String pem) {
    final match = RegExp(
            r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----')
        .firstMatch(pem);
    final body = (match?.group(1) ?? pem).replaceAll(RegExp(r'\s'), '');
    return pinForDer(base64.decode(body));
  }

  /// The pin for the certificate in a PEM file at [path].
  static String pinForCertFile(String path) =>
      pinForPem(File(path).readAsStringSync());

  static String _normalize(String pin) =>
      pin.startsWith('sha256/') ? pin.substring(7) : pin;
}
