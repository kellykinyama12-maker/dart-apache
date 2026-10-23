// Certificate pinning for the HTTP client. A [CertificatePinner] holds a set of
// trusted SHA-256 fingerprints of whole DER certificates; a TLS connection is
// accepted only when the server's leaf certificate matches a pin — trust comes
// from the pin, not from a CA. This is the client-side analog of the harness's
// `--ignore-certificate-errors-spki-list` (here keyed on the whole cert).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Pins one or more server certificates by SHA-256 of their DER encoding, or by
/// SHA-256 of their SubjectPublicKeyInfo (SPKI). A connection is accepted when
/// the leaf cert matches either kind of pin.
class CertificatePinner {
  /// Each pin is base64 of SHA-256(certificate DER) **or** SHA-256(SPKI DER); a
  /// leading `sha256/` is accepted and stripped (HPKP-style).
  CertificatePinner(Iterable<String> pins)
      : _pins = pins.map(_normalize).toSet();

  final Set<String> _pins;

  bool get isEmpty => _pins.isEmpty;

  /// True when [cert]'s DER matches one of the pins (as a whole-cert or SPKI
  /// pin).
  bool allows(X509Certificate cert) => allowsDer(cert.der);

  /// True when the DER bytes match one of the pins — either SHA-256 of the
  /// whole certificate or SHA-256 of its SubjectPublicKeyInfo.
  bool allowsDer(List<int> der) {
    if (_pins.contains(pinForDer(der))) return true;
    try {
      return _pins.contains(spkiPinForDer(der));
    } on Object {
      return false; // not a parseable X.509 cert
    }
  }

  /// The whole-certificate pin (base64 SHA-256 of the DER).
  static String pinForDer(List<int> der) => _sha256b64(der);

  /// The SPKI pin: base64 SHA-256 of the certificate's SubjectPublicKeyInfo.
  /// Survives certificate renewal that keeps the same key pair.
  static String spkiPinForDer(List<int> certDer) =>
      _sha256b64(_extractSpki(certDer is Uint8List
          ? certDer
          : Uint8List.fromList(certDer)));

  /// The whole-certificate pin for the first certificate in a PEM string.
  static String pinForPem(String pem) => pinForDer(_firstCertDer(pem));

  /// The SPKI pin for the first certificate in a PEM string.
  static String spkiPinForPem(String pem) => spkiPinForDer(_firstCertDer(pem));

  /// The whole-certificate pin for the certificate file at [path].
  static String pinForCertFile(String path) =>
      pinForPem(File(path).readAsStringSync());

  /// The SPKI pin for the certificate file at [path].
  static String spkiPinForCertFile(String path) =>
      spkiPinForPem(File(path).readAsStringSync());

  static String _normalize(String pin) =>
      pin.startsWith('sha256/') ? pin.substring(7) : pin;

  static String _sha256b64(List<int> bytes) {
    final digest = SHA256Digest();
    final input = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final out = Uint8List(32);
    digest
      ..update(input, 0, input.length)
      ..doFinal(out, 0);
    return base64.encode(out);
  }

  static Uint8List _firstCertDer(String pem) {
    final match = RegExp(
            r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----')
        .firstMatch(pem);
    final body = (match?.group(1) ?? pem).replaceAll(RegExp(r'\s'), '');
    return Uint8List.fromList(base64.decode(body));
  }
}

// ---- minimal ASN.1/DER walk to locate the SubjectPublicKeyInfo ----
//
// Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { [0] version?,
//   serialNumber, signature, issuer, validity, subject,
//   subjectPublicKeyInfo SEQUENCE { ... }, ... }, ... }

class _Tlv {
  _Tlv(this.start, this.headerLen, this.length, this.tag);
  final int start;
  final int headerLen;
  final int length;
  final int tag;
  int get contentStart => start + headerLen;
  int get end => start + headerLen + length;
}

_Tlv _readTlv(Uint8List d, int off) {
  final tag = d[off];
  var i = off + 1;
  var first = d[i];
  int length;
  int headerLen;
  if (first & 0x80 == 0) {
    length = first;
    headerLen = 2;
  } else {
    final n = first & 0x7f;
    length = 0;
    for (var k = 0; k < n; k++) {
      length = (length << 8) | d[i + 1 + k];
    }
    headerLen = 2 + n;
  }
  return _Tlv(off, headerLen, length, tag);
}

/// Returns the DER bytes of the certificate's SubjectPublicKeyInfo.
Uint8List _extractSpki(Uint8List der) {
  final cert = _readTlv(der, 0); // Certificate SEQUENCE
  final tbs = _readTlv(der, cert.contentStart); // tbsCertificate SEQUENCE
  var off = tbs.contentStart;
  // Optional EXPLICIT [0] version.
  if (_readTlv(der, off).tag == 0xA0) off = _readTlv(der, off).end;
  off = _readTlv(der, off).end; // serialNumber
  off = _readTlv(der, off).end; // signatureAlgorithm
  off = _readTlv(der, off).end; // issuer
  off = _readTlv(der, off).end; // validity
  off = _readTlv(der, off).end; // subject
  final spki = _readTlv(der, off); // subjectPublicKeyInfo
  return Uint8List.sublistView(der, spki.start, spki.end);
}
