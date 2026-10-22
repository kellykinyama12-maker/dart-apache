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
  Future<ClientResponse> get(
    Uri url, {
    bool forceH1 = false,
    Map<String, String> headers = const {},
    String? ifNoneMatch,
    String? range,
  }) =>
      request(
        'GET',
        url,
        forceH1: forceH1,
        headers: headers,
        ifNoneMatch: ifNoneMatch,
        range: range,
      );

  /// Sends a [method] request to [url] over HTTP/3 when discovered (falling
  /// back to HTTP/1.1), with an optional [body] and custom [headers].
  /// [ifNoneMatch] and [range] are conveniences for conditional / range
  /// requests. gzip responses are decoded transparently on both transports.
  Future<ClientResponse> request(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    List<int>? body,
    bool forceH1 = false,
    String? ifNoneMatch,
    String? range,
  }) async {
    final merged = <String, String>{
      for (final e in headers.entries) e.key: e.value,
    };
    if (ifNoneMatch != null) merged['if-none-match'] = ifNoneMatch;
    if (range != null) merged['range'] = range;

    final origin = '${url.host}:${url.port}';
    final alt = _altSvc[origin];

    if (!forceH1 && alt != null && alt.isFresh) {
      try {
        _log('→ HTTP/3 $method ${alt.host}:${alt.port}${_target(url)}');
        return await _h3.request(
          method: method,
          address: (await InternetAddress.lookup(alt.host)).first,
          port: alt.port,
          authority: url.host,
          sni: url.host,
          path: _target(url),
          headers: merged,
          body: body,
        );
      } catch (e) {
        _log('HTTP/3 failed ($e); falling back to HTTP/1.1');
        _altSvc.remove(origin);
      }
    }

    return _requestH1(method, url, origin, merged, body);
  }

  Future<ClientResponse> _requestH1(
    String method,
    Uri url,
    String origin,
    Map<String, String> headers,
    List<int>? body,
  ) async {
    _log('→ HTTP/1.1 $method ${url.host}:${url.port}${_target(url)}');
    final request = await _http.openUrl(method, url);
    request.headers.set(HttpHeaders.userAgentHeader, userAgent);
    headers.forEach((k, v) => request.headers.set(k, v));
    if (body != null) {
      // Set an explicit Content-Length so the CGI/FastCGI bridge forwards the
      // body (dart:io would otherwise default to chunked transfer).
      request.headers.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close();

    final respBody = <int>[];
    await response.forEach(respBody.addAll);

    final respHeaders = <String, String>{};
    response.headers.forEach(
      (name, values) => respHeaders[name.toLowerCase()] = values.join(', '),
    );

    final altSvc = respHeaders['alt-svc'];
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
      headers: respHeaders,
      body: respBody,
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
