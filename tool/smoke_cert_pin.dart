import 'dart:convert';

import 'package:dart_apache/dart_apache.dart';

/// Live check of client certificate pinning against a TLS dart-apache server.
///   dart run bin/dart_apache.dart --root=./public --port=8600 --https \
///       --tls-cert=build/cert.pem --tls-key=build/key.pem
///   dart run tool/smoke_cert_pin.dart 8600
Future<void> main(List<String> args) async {
  final url = Uri.parse('https://127.0.0.1:${args.first}/static.html');
  final goodPin = CertificatePinner.pinForCertFile('build/cert.pem');
  final badPin = base64.encode(List<int>.filled(32, 0));

  final pinned = AltSvcHttpClient(certificatePinner: CertificatePinner([goodPin]));
  final r = await pinned.get(url);
  print('correct pin  -> status ${r.statusCode}');
  pinned.close();

  final wrong = AltSvcHttpClient(certificatePinner: CertificatePinner([badPin]));
  try {
    await wrong.get(url);
    print('wrong pin    -> UNEXPECTED success');
  } on Object catch (e) {
    print('wrong pin    -> rejected (${e.runtimeType})');
  }
  wrong.close();
}
