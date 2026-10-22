import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../mime_types.dart';
import '../php/cgi_backend.dart';
import '../php/fastcgi.dart';
import '../php/php_backend.dart';
import '../proxy/reverse_proxy.dart';
import '../request_resolver.dart';
import '../wt/ticket.dart';
import 'dart_handler.dart';
import 'response_cache.dart';
import 'server_exchange.dart';

/// Outcome of parsing a `Range` header: whole body, a partial slice, or an
/// unsatisfiable range (416).
enum _RangeKind { full, partial, unsatisfiable }

/// Request-target (path + query) length cap, matching Apache's default
/// `LimitRequestLine` of 8190 bytes; over it yields 414.
const int _maxRequestTargetBytes = 8190;

/// Transport-agnostic request handling: resolves a [ServerExchange] against the
/// document root and serves static files, PHP (CGI/FastCGI), or an error —
/// writing the result to the exchange's [ServerResponse]. Shared by every
/// transport (HTTP/3, HTTP/1.1, …) so handlers are written once.
class RequestPipeline {
  RequestPipeline(this.config, {this.app})
      : _resolver = RequestResolver(config),
        _php = config.phpFpm != null
            ? FastCgiBackend(config)
            : CgiBackend(config),
        _proxy = config.proxyRoutes.isEmpty
            ? null
            : ReverseProxyHandler(config.proxyRoutes),
        _cache = config.cacheEnabled
            ? ResponseCache(maxBytes: config.cacheMaxBytes)
            : null;

  final ServerConfig config;

  /// Optional in-process Dart route table, consulted before static/PHP.
  final DartApp? app;
  final RequestResolver _resolver;
  final PhpBackend _php;
  final ReverseProxyHandler? _proxy;

  /// Optional in-memory response cache (`--cache`), null when disabled.
  final ResponseCache? _cache;

  /// Called with a Common Log Format line after each request (defaults to
  /// stdout). Transports can override to centralize logging.
  void Function(String line) onAccessLog = stdout.writeln;

  Future<void> close() async {
    await _php.close();
    await _proxy?.close();
  }

  Future<void> serve(ServerExchange exchange) async {
    var response = exchange.respond();

    // Advertise HTTP/3 on non-h3 responses so clients can upgrade.
    final altSvc = config.altSvcHeader;
    if (altSvc != null && exchange.protocol != 'h3') {
      response.setHeader('alt-svc', altSvc);
    }

    try {
      if (exchange.contentLength > config.maxRequestBodyBytes) {
        await _serveError(response, HttpStatus.requestEntityTooLarge,
            'Payload Too Large');
        return;
      }

      // Request-target length cap (Apache LimitRequestLine / nginx
      // large_client_header_buffers), answered with 414 like the giants.
      if (exchange.uri.path.length + exchange.uri.query.length >
          _maxRequestTargetBytes) {
        await _serveError(response, HttpStatus.requestUriTooLong, 'URI Too Long');
        return;
      }

      // RFC 9110 §9.3.7: server-wide OPTIONS (`OPTIONS *`) advertises the
      // methods the origin supports, without touching any resource.
      if (exchange.method == 'OPTIONS' &&
          (exchange.uri.path == '*' || exchange.uri.path.isEmpty)) {
        response
          ..setStatus(HttpStatus.noContent)
          ..setHeader(HttpHeaders.allowHeader, 'GET, HEAD, POST, OPTIONS')
          ..setHeader(HttpHeaders.contentLengthHeader, '0');
        await response.close();
        return;
      }

      // Built-in endpoint: issue an opaque WebTransport session ticket sealing
      // the request's Cookie (which the browser sends on this normal request).
      final ticketPath = config.wtTicketPath;
      if (ticketPath != null && exchange.uri.path == ticketPath) {
        await _serveWtTicket(exchange, response);
        return;
      }

      // Response cache. A fresh, vary-matching hit is replayed (a HEAD reuses
      // the stored GET, headers only); a request `no-cache` bypasses the hit;
      // otherwise a GET miss is teed through [CachingResponse], which stores it
      // iff the handler marks it cacheable (Cache-Control/Expires). `no-store`
      // requests are not stored.
      final cache = _cache;
      if (cache != null &&
          (exchange.method == 'GET' || exchange.method == 'HEAD')) {
        final reqHeaders = _requestHeaders(exchange);
        final reqCc = (reqHeaders['cache-control'] ?? '').toLowerCase();
        final key = _cacheKey(exchange);
        if (!reqCc.contains('no-cache')) {
          final hit = cache.get(key, reqHeaders);
          if (hit != null) {
            await _replayCached(response, hit,
                headOnly: exchange.method == 'HEAD');
            return;
          }
        }
        if (exchange.method == 'GET' && !reqCc.contains('no-store')) {
          response = CachingResponse(
            inner: response,
            method: exchange.method,
            requestHeaders: reqHeaders,
            onStore: (entry) => cache.put(key, entry),
          );
        }
      }

      // Reverse-proxy routes take precedence over local static/PHP.
      final route = _proxy?.routeFor(exchange.uri.path);
      if (route != null) {
        await _proxy!.proxy(exchange, response, route);
        return;
      }

      // In-process Dart handlers run before static/PHP so an app can own a
      // path prefix (e.g. /api) natively over HTTP/3. The handler owns the
      // response (write + close), like the static/PHP handlers.
      final dartRoute = app?.match(exchange.method, exchange.uri.path);
      if (dartRoute != null) {
        await dartRoute.handler(exchange, response);
        return;
      }

      final resolution = _resolver.resolve(exchange.uri.path);
      switch (resolution.kind) {
        case ResolutionKind.staticFile:
          await _serveStaticResource(exchange, response, resolution.filePath);
        case ResolutionKind.redirect:
          final q = exchange.uri.query;
          final location = q.isEmpty
              ? resolution.location
              : '${resolution.location}?$q';
          response
            ..setStatus(HttpStatus.movedPermanently)
            ..setHeader(HttpHeaders.locationHeader, location)
            ..setHeader(HttpHeaders.contentLengthHeader, '0');
          await response.close();
        case ResolutionKind.phpScript:
          await _servePhp(exchange, response, resolution);
        case ResolutionKind.forbidden:
          await _serveError(response, HttpStatus.forbidden, 'Forbidden');
        case ResolutionKind.notFound:
          if (!await _tryFrontController(exchange, response) &&
              !await _trySpaFallback(exchange, response)) {
            await _serveError(response, HttpStatus.notFound, 'Not Found');
          }
      }
    } on CgiException catch (e) {
      stderr.writeln('[php] $e');
      await _serveError(
        response,
        HttpStatus.internalServerError,
        'Internal Server Error',
      );
    } catch (e, st) {
      stderr.writeln('[error] $e\n$st');
      try {
        await _serveError(
          response,
          HttpStatus.internalServerError,
          'Internal Server Error',
        );
      } catch (_) {
        // Response may already be committed.
      }
    } finally {
      _log(exchange, response.statusCode);
    }
  }

  /// Method gating for a static file (RFC 9110): `OPTIONS` -> 204 + `Allow`,
  /// any method other than GET/HEAD -> 405 + `Allow`. PHP scripts are exempt —
  /// the app owns its own methods.
  Future<void> _serveStaticResource(
    ServerExchange exchange,
    ServerResponse response,
    String filePath,
  ) async {
    const allow = 'GET, HEAD, OPTIONS';
    final method = exchange.method;
    if (method == 'OPTIONS') {
      response
        ..setStatus(HttpStatus.noContent)
        ..setHeader(HttpHeaders.allowHeader, allow)
        ..setHeader(HttpHeaders.contentLengthHeader, '0');
      await response.close();
      return;
    }
    if (method != 'GET' && method != 'HEAD') {
      response.setHeader(HttpHeaders.allowHeader, allow);
      await _serveError(
          response, HttpStatus.methodNotAllowed, 'Method Not Allowed');
      return;
    }
    await _serveStatic(exchange, response, filePath);
  }

  Future<void> _serveStatic(
    ServerExchange exchange,
    ServerResponse response,
    String filePath,
  ) async {
    final file = File(filePath);
    final stat = await file.stat();
    final length = stat.size;
    final modified = stat.modified;
    final etag = _etagFor(stat);
    final reqHeaders = _requestHeaders(exchange);

    // Validators + range advertisement on every static response (RFC 9110).
    response
      ..setHeader(HttpHeaders.lastModifiedHeader, HttpDate.format(modified))
      ..setHeader(HttpHeaders.etagHeader, etag)
      ..setHeader(HttpHeaders.acceptRangesHeader, 'bytes');

    // Conditional GET -> 304 Not Modified (RFC 9110 §13).
    if (_isNotModified(reqHeaders, etag, modified)) {
      response.setStatus(HttpStatus.notModified);
      await response.close();
      return;
    }

    response.setHeader(HttpHeaders.contentTypeHeader, mimeTypeFor(filePath));

    // Range request (RFC 9110 §14) — single range; multi-range falls back to
    // a full 200, which is a permitted conservative response.
    final (kind, start, end) = _parseRange(
      reqHeaders[HttpHeaders.rangeHeader],
      length,
      ifRange: reqHeaders[HttpHeaders.ifRangeHeader],
      etag: etag,
      modified: modified,
    );
    if (kind == _RangeKind.unsatisfiable) {
      response
        ..setStatus(HttpStatus.requestedRangeNotSatisfiable)
        ..setHeader(HttpHeaders.contentRangeHeader, 'bytes */$length')
        ..setHeader(HttpHeaders.contentLengthHeader, '0');
      await response.close();
      return;
    }
    if (kind == _RangeKind.partial) {
      response
        ..setStatus(HttpStatus.partialContent)
        ..setHeader(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length')
        ..setHeader(HttpHeaders.contentLengthHeader, '${end - start + 1}');
      if (exchange.method == 'HEAD') {
        await response.close();
        return;
      }
      await response.addStream(file.openRead(start, end + 1));
      await response.close();
      return;
    }

    response
      ..setStatus(HttpStatus.ok)
      ..setHeader(HttpHeaders.contentLengthHeader, '$length');
    if (exchange.method == 'HEAD') {
      await response.close();
      return;
    }

    // Transparent gzip for compressible text assets above a threshold (nginx
    // `gzip`/`gzip_vary`). Compressed in memory so Content-Length stays exact;
    // huge files are streamed uncompressed. Never combined with a byte range.
    final contentType = mimeTypeFor(filePath);
    if (_isCompressible(contentType)) {
      response.setHeader(HttpHeaders.varyHeader, 'Accept-Encoding');
    }
    if (_isCompressible(contentType) &&
        length >= _gzipMinBytes &&
        length <= _gzipMaxBytes &&
        _acceptsGzip(reqHeaders)) {
      final compressed = gzip.encode(await file.readAsBytes());
      response
        ..setHeader(HttpHeaders.contentEncodingHeader, 'gzip')
        // Weak ETag: the gzip representation differs from identity, but weak
        // comparison still lets a conditional request revalidate to 304.
        ..setHeader(HttpHeaders.etagHeader, 'W/$etag')
        ..setHeader(HttpHeaders.contentLengthHeader, '${compressed.length}');
      await response.addStream(Stream<List<int>>.value(compressed));
      await response.close();
      return;
    }

    await response.addStream(file.openRead());
    await response.close();
  }

  static const int _gzipMinBytes = 1024;
  static const int _gzipMaxBytes = 10 * 1024 * 1024;
  static const Set<String> _compressibleTypes = {
    'application/json',
    'application/javascript',
    'application/xml',
    'application/rss+xml',
    'application/atom+xml',
    'application/xhtml+xml',
    'application/manifest+json',
    'application/wasm',
    'image/svg+xml',
  };

  bool _isCompressible(String contentType) {
    final ct = contentType.split(';').first.trim().toLowerCase();
    return ct.startsWith('text/') || _compressibleTypes.contains(ct);
  }

  bool _acceptsGzip(Map<String, String> headers) {
    final ae = headers[HttpHeaders.acceptEncodingHeader];
    return ae != null && ae.toLowerCase().contains('gzip');
  }

  /// Strong entity-tag from size + mtime (nginx-style `"<mtime>-<size>"`).
  String _etagFor(FileStat stat) {
    final mtime = stat.modified.millisecondsSinceEpoch ~/ 1000;
    return '"${mtime.toRadixString(16)}-${stat.size.toRadixString(16)}"';
  }

  /// Cache key: always the GET target, so a HEAD reuses a stored GET entry.
  String _cacheKey(ServerExchange e) {
    final q = e.uri.query;
    return 'GET ${e.scheme}://${e.authority}${e.uri.path}'
        '${q.isEmpty ? '' : '?$q'}';
  }

  /// Replays a cached response with a recomputed `Age` and `X-Cache: HIT`.
  /// [headOnly] omits the body (serving HEAD from a cached GET).
  Future<void> _replayCached(
    ServerResponse response,
    CachedResponse e, {
    bool headOnly = false,
  }) async {
    response.setStatus(e.statusCode);
    for (final h in e.headers) {
      response.setHeader(h.key, h.value);
    }
    response
      ..setHeader('Age', '${e.ageSeconds(DateTime.now())}')
      ..setHeader('X-Cache', 'HIT');
    if (!headOnly) {
      await response.addStream(Stream<List<int>>.value(e.body));
    }
    await response.close();
  }

  /// Collects request headers into a lower-cased map (duplicates joined).
  Map<String, String> _requestHeaders(ServerExchange exchange) {
    final h = <String, String>{};
    exchange.forEachHeader((name, value) {
      final k = name.toLowerCase();
      final existing = h[k];
      h[k] = existing == null ? value : '$existing, $value';
    });
    return h;
  }

  /// RFC 9110 §13.1: `If-None-Match` wins over `If-Modified-Since`.
  bool _isNotModified(
    Map<String, String> headers,
    String etag,
    DateTime modified,
  ) {
    final inm = headers[HttpHeaders.ifNoneMatchHeader];
    if (inm != null) {
      if (inm.trim() == '*') return true;
      for (final raw in inm.split(',')) {
        var tag = raw.trim();
        if (tag.startsWith('W/')) tag = tag.substring(2); // weak comparison
        if (tag == etag) return true;
      }
      return false;
    }
    final ims = headers[HttpHeaders.ifModifiedSinceHeader];
    if (ims == null) return false;
    try {
      final since = HttpDate.parse(ims).toUtc();
      final mod = DateTime.fromMillisecondsSinceEpoch(
        (modified.millisecondsSinceEpoch ~/ 1000) * 1000,
        isUtc: true,
      );
      return !mod.isAfter(since);
    } catch (_) {
      return false;
    }
  }

  /// Parses a single byte range. Returns [_RangeKind.full] for no range or a
  /// request we answer with the whole body, [_RangeKind.partial] with the
  /// inclusive bounds, or [_RangeKind.unsatisfiable].
  (_RangeKind, int, int) _parseRange(
    String? rangeHeader,
    int length, {
    String? ifRange,
    required String etag,
    required DateTime modified,
  }) {
    if (rangeHeader == null) return (_RangeKind.full, 0, 0);
    // If-Range: only honor the range when the validator still matches.
    if (ifRange != null && !_ifRangeMatches(ifRange, etag, modified)) {
      return (_RangeKind.full, 0, 0);
    }
    if (!rangeHeader.startsWith('bytes=')) return (_RangeKind.full, 0, 0);
    final spec = rangeHeader.substring(6).trim();
    if (spec.isEmpty || spec.contains(',')) return (_RangeKind.full, 0, 0);
    final dash = spec.indexOf('-');
    if (dash < 0) return (_RangeKind.full, 0, 0);
    final startStr = spec.substring(0, dash).trim();
    final endStr = spec.substring(dash + 1).trim();
    int start;
    int end;
    if (startStr.isEmpty) {
      final n = int.tryParse(endStr);
      if (n == null || n <= 0) return (_RangeKind.full, 0, 0);
      if (length == 0) return (_RangeKind.unsatisfiable, 0, 0);
      start = n >= length ? 0 : length - n;
      end = length - 1;
    } else {
      final s = int.tryParse(startStr);
      if (s == null) return (_RangeKind.full, 0, 0);
      start = s;
      if (endStr.isEmpty) {
        end = length - 1;
      } else {
        final e = int.tryParse(endStr);
        if (e == null) return (_RangeKind.full, 0, 0);
        end = e >= length ? length - 1 : e;
      }
      if (start >= length) return (_RangeKind.unsatisfiable, 0, 0);
      if (end < start) return (_RangeKind.full, 0, 0);
    }
    return (_RangeKind.partial, start, end);
  }

  bool _ifRangeMatches(String ifRange, String etag, DateTime modified) {
    final v = ifRange.trim();
    if (v.startsWith('"') || v.startsWith('W/')) {
      return (v.startsWith('W/') ? v.substring(2) : v) == etag;
    }
    try {
      final d = HttpDate.parse(v).toUtc();
      final mod = DateTime.fromMillisecondsSinceEpoch(
        (modified.millisecondsSinceEpoch ~/ 1000) * 1000,
        isUtc: true,
      );
      return !mod.isAfter(d);
    } catch (_) {
      return false;
    }
  }

  Future<void> _servePhp(
    ServerExchange exchange,
    ServerResponse response,
    Resolution resolution,
  ) async {
    final php = await _php.handle(
      exchange: exchange,
      scriptFilename: resolution.filePath,
      scriptName: resolution.scriptName,
      pathInfo: resolution.pathInfo,
    );

    response.setStatus(php.statusCode, php.reasonPhrase);
    var sawContentType = false;
    php.headers.forEach((name, values) {
      final lower = name.toLowerCase();
      if (lower == 'content-type') sawContentType = true;
      // Drop the CGI-declared Content-Length: our streaming parser may strip a
      // leaked startup preamble, so the body length can differ from what PHP
      // declared. Let the transport frame the body (chunked / h3 DATA) instead.
      if (lower == 'content-length') return;
      for (final value in values) {
        response.setHeader(name, value);
      }
    });
    if (!sawContentType) {
      response.setHeader(
          HttpHeaders.contentTypeHeader, 'text/html; charset=UTF-8');
    }

    if (exchange.method == 'HEAD') {
      await php.body.drain<void>();
      await response.close();
      return;
    }
    await response.addStream(php.body);
    await response.close();
  }

  /// Front-controller routing: when [ServerConfig.frontController] is set, run a
  /// request that matched no file through that PHP script while preserving the
  /// original request URI (so the app router sees the real path, e.g.
  /// `/livewire/update`). Returns true if handled.
  Future<bool> _tryFrontController(
    ServerExchange exchange,
    ServerResponse response,
  ) async {
    final fc = config.frontController;
    if (fc == null) return false;
    final res = _resolver.resolve(fc);
    if (res.kind != ResolutionKind.phpScript) return false;
    // Keep the original exchange (REQUEST_URI/QUERY_STRING) but point
    // SCRIPT_FILENAME/SCRIPT_NAME at the front controller.
    await _servePhp(
      exchange,
      response,
      Resolution.phpScript(
        filePath: res.filePath,
        scriptName: res.scriptName,
        pathInfo: '',
      ),
    );
    return true;
  }

  /// Single-page-app rewrite: when [ServerConfig.spaFallback] is set, serve it
  /// for an extensionless GET/HEAD that otherwise 404s, so client-side routes
  /// (e.g. a Flutter/Dart web build) survive a refresh. Returns true if served.
  Future<bool> _trySpaFallback(
    ServerExchange exchange,
    ServerResponse response,
  ) async {
    final fallback = config.spaFallback;
    if (fallback == null) return false;
    if (exchange.method != 'GET' && exchange.method != 'HEAD') return false;
    // Only rewrite navigation paths; genuinely-missing assets (with a file
    // extension, e.g. main.dart.js, foo.png) must still 404.
    final lastSegment = exchange.uri.pathSegments.isEmpty
        ? ''
        : exchange.uri.pathSegments.last;
    if (lastSegment.contains('.')) return false;
    final fb = _resolver.resolve(fallback);
    switch (fb.kind) {
      case ResolutionKind.staticFile:
        await _serveStatic(exchange, response, fb.filePath);
        return true;
      case ResolutionKind.phpScript:
        await _servePhp(exchange, response, fb);
        return true;
      case ResolutionKind.redirect:
      case ResolutionKind.forbidden:
      case ResolutionKind.notFound:
        return false;
    }
  }

  /// Issues an opaque WebTransport session ticket that seals the request's
  /// `Cookie` header (sent automatically on this normal HTTPS request, HttpOnly
  /// included) so the browser can carry the session over WebTransport without
  /// ever reading the cookie in JS.
  Future<void> _serveWtTicket(
    ServerExchange exchange,
    ServerResponse response,
  ) async {
    final cookies = <String>[];
    exchange.forEachHeader((name, value) {
      if (name.toLowerCase() == 'cookie') cookies.add(value);
    });
    final ticket = WtTicket.issue(cookies.join('; '), config.wtTicketKey);
    final bytes = utf8.encode(jsonEncode({'ticket': ticket}));
    response
      ..setStatus(HttpStatus.ok)
      ..setHeader(HttpHeaders.contentTypeHeader, 'application/json')
      ..setHeader(HttpHeaders.cacheControlHeader, 'no-store');
    await response.addStream(Stream.value(bytes));
    await response.close();
  }

  Future<void> _serveError(
    ServerResponse response,
    int status,
    String title,
  ) async {
    final html = '<!DOCTYPE html>\n'
        '<html><head><title>$status $title</title></head>\n'
        '<body><h1>$status $title</h1>\n'
        '<hr><address>${config.serverSoftware}</address></body></html>\n';
    final bytes = html.codeUnits;
    response
      ..setStatus(status)
      ..setHeader(HttpHeaders.contentTypeHeader, 'text/html; charset=UTF-8')
      ..setHeader(HttpHeaders.contentLengthHeader, '${bytes.length}');
    await response.addStream(Stream.value(bytes));
    await response.close();
  }

  void _log(ServerExchange exchange, int status) {
    final now = HttpDate.format(DateTime.now());
    onAccessLog(
      '${exchange.remoteAddress} - - [$now] '
      '"${exchange.method} ${exchange.uri} HTTP/${exchange.protocolVersion}" '
      '$status -',
    );
  }
}
