import 'dart:convert';
import 'dart:io';

import 'package:dart_apache/dart_apache.dart';
import 'package:test/test.dart';

List<int> _firstCertDer(String pem) {
  final match =
      RegExp(r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----')
          .firstMatch(pem)!;
  return base64.decode(match.group(1)!.replaceAll(RegExp(r'\s'), ''));
}

void main() {
  group('CertificatePinner', () {
    final pem = File('build/cert.pem').readAsStringSync();
    final der = _firstCertDer(pem);
    final pin = CertificatePinner.pinForPem(pem);

    test('pin is a stable base64 SHA-256 of the cert DER', () {
      expect(pin, CertificatePinner.pinForCertFile('build/cert.pem'));
      expect(pin, CertificatePinner.pinForDer(der));
      expect(base64.decode(pin), hasLength(32));
    });

    test('cert + SPKI pins match the reference (OpenSSL/node) values', () {
      // Cross-checked against node crypto X509Certificate for build/cert.pem.
      expect(pin, 'GuglF1PDOJjfyhm8C66HxGPWGdtq4StzTpLpiXYiwhY=');
      expect(CertificatePinner.spkiPinForPem(pem),
          'uVrtKUXT6t1Wf1rByCzV7uoSB2vdw1qjZPoZYPKPgAw=');
    });

    test('an SPKI pin is accepted (survives cert renewal, same key)', () {
      final spki = CertificatePinner.spkiPinForCertFile('build/cert.pem');
      expect(spki, isNot(pin));
      expect(CertificatePinner([spki]).allowsDer(der), isTrue);
      expect(CertificatePinner(['sha256/$spki']).allowsDer(der), isTrue);
    });

    test('allowsDer accepts the matching cert and rejects others', () {
      expect(CertificatePinner([pin]).allowsDer(der), isTrue);
      final wrong = base64.encode(List<int>.filled(32, 0));
      expect(CertificatePinner([wrong]).allowsDer(der), isFalse);
    });

    test('a sha256/ prefix is accepted (HPKP-style)', () {
      expect(CertificatePinner(['sha256/$pin']).allowsDer(der), isTrue);
    });

    test('multiple pins allow any match', () {
      final other = base64.encode(List<int>.filled(32, 1));
      expect(CertificatePinner([other, pin]).allowsDer(der), isTrue);
    });

    test('isEmpty reflects having no pins', () {
      expect(CertificatePinner(const []).isEmpty, isTrue);
      expect(CertificatePinner([pin]).isEmpty, isFalse);
    });
  });
}
