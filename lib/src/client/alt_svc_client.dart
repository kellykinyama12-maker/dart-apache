import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_quiche/dart_quiche.dart' show TrustStore;

import 'alt_svc.dart';
import 'cancel_token.dart';
import 'client_response.dart';
import 'h3_client.dart';
import 'interceptor.dart';
import 'multipart.dart';
import 'retry.dart';

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
    this.interceptors = const [],
    this.retryPolicy = RetryPolicy.none,
  })  : _h3 = H3Client(
          userAgent: userAgent,
          trustStore:
              caBundlePem != null ? (TrustStore()..addPem(caBundlePem)) : null,
        ),
        _http = _buildHttpClient(allowInsecure, caBundlePem);

  final String userAgent;
  final bool verbose;

  /// Hooks applied, in order, around every request (auth, logging, mutation).
  final List<Interceptor> interceptors;

  /// Default retry behavior; can be overridden per request.
  final RetryPolicy retryPolicy;

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
    Map<String, String>? query,
    String? ifNoneMatch,
    String? range,
    Duration? timeout,
    CancelToken? cancelToken,
    RetryPolicy? retry,
  }) =>
      request(
        'GET',
        url,
        forceH1: forceH1,
        headers: headers,
        query: query,
        ifNoneMatch: ifNoneMatch,
        range: range,
        timeout: timeout,
        cancelToken: cancelToken,
        retry: retry,
      );

  /// POST convenience; supply [json] (encoded + typed), [body], or [multipart].
  Future<ClientResponse> post(
    Uri url, {
    List<int>? body,
    Object? json,
    MultipartBody? multipart,
    Map<String, String> headers = const {},
    Map<String, String>? query,
    Duration? timeout,
    CancelToken? cancelToken,
    RetryPolicy? retry,
  }) =>
      request('POST', url,
          body: body,
          json: json,
          multipart: multipart,
          headers: headers,
          query: query,
          timeout: timeout,
          cancelToken: cancelToken,
          retry: retry);

  /// PUT convenience.
  Future<ClientResponse> put(
    Uri url, {
    List<int>? body,
    Object? json,
    MultipartBody? multipart,
    Map<String, String> headers = const {},
    Map<String, String>? query,
    Duration? timeout,
    CancelToken? cancelToken,
    RetryPolicy? retry,
  }) =>
      request('PUT', url,
          body: body,
          json: json,
          multipart: multipart,
          headers: headers,
          query: query,
          timeout: timeout,
          cancelToken: cancelToken,
          retry: retry);

  /// PATCH convenience.
  Future<ClientResponse> patch(
    Uri url, {
    List<int>? body,
    Object? json,
    Map<String, String> headers = const {},
    Map<String, String>? query,
    Duration? timeout,
    CancelToken? cancelToken,
    RetryPolicy? retry,
  }) =>
      request('PATCH', url,
          body: body,
          json: json,
          headers: headers,
          query: query,
          timeout: timeout,
          cancelToken: cancelToken,
          retry: retry);

  /// DELETE convenience.
  Future<ClientResponse> delete(
    Uri url, {
    List<int>? body,
    Object? json,
    Map<String, String> headers = const {},
    Map<String, String>? query,
    Duration? timeout,
    CancelToken? cancelToken,
    RetryPolicy? retry,
  }) =>
      request('DELETE', url,
          body: body,
          json: json,
          headers: headers,
          query: query,
          timeout: timeout,
          cancelToken: cancelToken,
          retry: retry);

  /// HEAD convenience.
  Future<ClientResponse> head(
    Uri url, {
    Map<String, String> headers = const {},
    Map<String, String>? query,
    Duration? timeout,
    CancelToken? cancelToken,
    RetryPolicy? retry,
  }) =>
      request('HEAD', url,
          headers: headers,
          query: query,
          timeout: timeout,
          cancelToken: cancelToken,
          retry: retry);

  /// Sends a [method] request to [url] over HTTP/3 when discovered (falling
  /// back to HTTP/1.1). Supply at most one of [body], [json] (encoded to JSON),
  /// or [multipart]. [query] is merged into the URL. [ifNoneMatch]/[range] are
  /// conditional/range conveniences. [timeout] bounds the attempt, [cancelToken]
  /// aborts it, and [retry] (or the client default) retries on failure. gzip
  /// responses are decoded transparently. Interceptors run around the request.
  Future<ClientResponse> request(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    List<int>? body,
    Object? json,
    MultipartBody? multipart,
    Map<String, String>? query,
    bool forceH1 = false,
    String? ifNoneMatch,
    String? range,
    Duration? timeout,
    CancelToken? cancelToken,
    RetryPolicy? retry,
  }) async {
    var effectiveUrl = url;
    if (query != null && query.isNotEmpty) {
      effectiveUrl = url.replace(
        queryParameters: {...url.queryParameters, ...query},
      );
    }

    final merged = <String, String>{
      for (final e in headers.entries) e.key.toLowerCase(): e.value,
    };
    if (ifNoneMatch != null) merged['if-none-match'] = ifNoneMatch;
    if (range != null) merged['range'] = range;

    List<int>? effectiveBody = body;
    if (multipart != null) {
      effectiveBody = multipart.encode();
      merged.putIfAbsent('content-type', () => multipart.contentType);
    } else if (json != null) {
      effectiveBody = utf8.encode(jsonEncode(json));
      merged.putIfAbsent('content-type', () => 'application/json; charset=utf-8');
    }

    final options = RequestOptions(
      method: method,
      url: effectiveUrl,
      headers: merged,
      body: effectiveBody,
      forceH1: forceH1,
    );

    for (final i in interceptors) {
      await i.onRequest(options);
    }

    try {
      final response = await _execute(options, timeout, cancelToken,
          retry ?? retryPolicy);
      for (final i in interceptors) {
        await i.onResponse(response);
      }
      return response;
    } catch (e, st) {
      for (final i in interceptors) {
        await i.onError(e, st);
      }
      rethrow;
    }
  }

  /// Runs one request with retry + timeout + cancellation around [_dispatch].
  Future<ClientResponse> _execute(
    RequestOptions options,
    Duration? timeout,
    CancelToken? cancelToken,
    RetryPolicy retry,
  ) async {
    var attempt = 0;
    while (true) {
      cancelToken?.throwIfCancelled();
      try {
        var exec = _dispatch(options);
        if (timeout != null) exec = exec.timeout(timeout);
        final response =
            cancelToken == null ? await exec : await _race(exec, cancelToken);
        if (attempt < retry.maxRetries &&
            retry.shouldRetryStatus(response.statusCode)) {
          attempt++;
          await Future<void>.delayed(retry.backoff(attempt));
          continue;
        }
        return response;
      } on RequestCancelledException {
        rethrow;
      } catch (_) {
        if (retry.retryOnError && attempt < retry.maxRetries) {
          attempt++;
          await Future<void>.delayed(retry.backoff(attempt));
          continue;
        }
        rethrow;
      }
    }
  }

  /// Completes with [exec]'s result, or throws [RequestCancelledException] if
  /// [token] fires first (the orphaned [exec] is then silently drained).
  Future<ClientResponse> _race(
      Future<ClientResponse> exec, CancelToken token) async {
    ClientResponse? resp;
    var cancelled = false;
    await Future.any<void>([
      exec.then((r) => resp = r),
      token.whenCancelled.then((_) => cancelled = true),
    ]);
    if (cancelled && resp == null) {
      unawaited(exec.then((_) {}, onError: (_, _) {}));
      throw RequestCancelledException(token.reason);
    }
    return resp!;
  }

  /// Sends [options] over HTTP/3 when discovered, else HTTP/1.1.
  Future<ClientResponse> _dispatch(RequestOptions options) async {
    final url = options.url;
    final origin = '${url.host}:${url.port}';
    final alt = _altSvc[origin];

    if (!options.forceH1 && alt != null && alt.isFresh) {
      try {
        _log('→ HTTP/3 ${options.method} '
            '${alt.host}:${alt.port}${_target(url)}');
        return await _h3.request(
          method: options.method,
          address: (await InternetAddress.lookup(alt.host)).first,
          port: alt.port,
          authority: url.host,
          sni: url.host,
          path: _target(url),
          headers: options.headers,
          body: options.body,
        );
      } catch (e) {
        _log('HTTP/3 failed ($e); falling back to HTTP/1.1');
        _altSvc.remove(origin);
      }
    }

    return _requestH1(options, origin);
  }

  Future<ClientResponse> _requestH1(RequestOptions options, String origin) async {
    final url = options.url;
    _log('→ HTTP/1.1 ${options.method} ${url.host}:${url.port}${_target(url)}');
    final request = await _http.openUrl(options.method, url);
    request.headers.set(HttpHeaders.userAgentHeader, userAgent);
    options.headers.forEach((k, v) => request.headers.set(k, v));
    final body = options.body;
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

  /// Closes the HTTP/1.1 client and every pooled HTTP/3 connection.
  void close() {
    _http.close(force: true);
    unawaited(_h3.close());
  }
}
