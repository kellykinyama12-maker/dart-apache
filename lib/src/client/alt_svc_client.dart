import 'dart:io';

import 'package:dart_quiche/dart_quiche.dart' show TrustStore;

import 'alt_svc.dart';
import 'client_response.dart';
import 'h3_client.dart';

/// An HTTP client for pure-Dart apps that **discovers HTTP/3 and upgrades to
/// it automatically**. The first request to an origin goes over HTTP/1.1; if
/// the response carries an `Alt-Svc: h3=...` header, the client caches it and
/// serves subsequent requests to that origin over HTTP/3 (QUIC), falling back
/// to HTTP/1.1 if the h3 attempt fails.
class AltSvcHttpClient {
  AltSvcHttpClient({
    this.userAgent = 'dart-apache-client/1.0',
    this.verbose = false,
    bool allowInsecure = false,
    String? caBundlePem,
  })  : _h3 = H3Client(
          userAgent: userAgent,
          trustStore:
              caBundlePem != null ? (TrustStore()..addPem(caBundlePem)) : null,
        ),
        _http = _buildHttpClient(allowInsecure, caBundlePem);

  final String userAgent;
  final bool verbose;

  final HttpClient _http;
  final H3Client _h3;
  final Map<String, H3AltService> _altSvc = {};

  /// Builds the HTTP/1.1 client: a private [caBundlePem] is added to a trusting
  /// [SecurityContext]; [allowInsecure] accepts any cert (dev only).
  static HttpClient _buildHttpClient(bool allowInsecure, String? caBundlePem) {
    HttpClient client;
    if (caBundlePem != null) {
      final ctx = SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificatesBytes(caBundlePem.codeUnits);
      client = HttpClient(context: ctx);
    } else {
      client = HttpClient();
    }
    if (allowInsecure) {
      // Accept self-signed certs (dev TLS). Never enable in production.
      client.badCertificateCallback = (_, _, _) => true;
    }
    return client;
  }

  /// Fetches [url], automatically using HTTP/3 if it has been discovered for
  /// this origin. [forceH1] forces an HTTP/1.1 request (e.g. to re-discover).
  Future<ClientResponse> get(Uri url, {bool forceH1 = false}) async {
    final origin = '${url.host}:${url.port}';
    final alt = _altSvc[origin];

    if (!forceH1 && alt != null && alt.isFresh) {
      try {
        _log('→ HTTP/3 ${alt.host}:${alt.port}${_target(url)}');
        return await _h3.get(
          address: (await InternetAddress.lookup(alt.host)).first,
          port: alt.port,
          authority: url.host,
          sni: url.host,
          path: _target(url),
        );
      } catch (e) {
        _log('HTTP/3 failed ($e); falling back to HTTP/1.1');
        _altSvc.remove(origin);
      }
    }

    return _getH1(url, origin);
  }

  Future<ClientResponse> _getH1(Uri url, String origin) async {
    _log('→ HTTP/1.1 ${url.host}:${url.port}${_target(url)}');
    final request = await _http.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, userAgent);
    final response = await request.close();

    final body = <int>[];
    await response.forEach(body.addAll);

    final headers = <String, String>{};
    response.headers.forEach(
      (name, values) => headers[name.toLowerCase()] = values.join(', '),
    );

    final altSvc = headers['alt-svc'];
    if (altSvc != null) {
      final discovered = parseAltSvcH3(altSvc, url.host);
      if (discovered != null) {
        _altSvc[origin] = discovered;
        _log('discovered HTTP/3 at ${discovered.host}:${discovered.port} '
            '(expires ${discovered.expiry.toIso8601String()})');
      }
    }

    return ClientResponse(
      statusCode: response.statusCode,
      headers: headers,
      body: body,
      protocol: 'http/1.1',
    );
  }

  /// Whether an HTTP/3 endpoint has been discovered (and is still fresh) for
  /// the given origin URL.
  bool knowsH3For(Uri url) {
    final alt = _altSvc['${url.host}:${url.port}'];
    return alt != null && alt.isFresh;
  }

  String _target(Uri url) {
    final path = url.path.isEmpty ? '/' : url.path;
    return url.hasQuery ? '$path?${url.query}' : path;
  }

  void _log(String message) {
    if (verbose) stdout.writeln('[client] $message');
  }

  void close() => _http.close(force: true);
}
