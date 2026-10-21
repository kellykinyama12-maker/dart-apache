import 'dart:async';
import 'dart:io';

import 'config.dart';
import 'mime_types.dart';
import 'php/cgi_backend.dart';
import 'php/fastcgi.dart';
import 'php/php_backend.dart';
import 'request_resolver.dart';

/// A small HTTP server that serves static files and runs PHP through `php-cgi`,
/// reproducing the request-handling flow of Apache HTTP Server.
class ApacheServer {
  ApacheServer(this.config)
      : _resolver = RequestResolver(config),
        _php = config.phpFpm != null
            ? FastCgiBackend(config)
            : CgiBackend(config);

  final ServerConfig config;
  final RequestResolver _resolver;
  final PhpBackend _php;

  HttpServer? _server;

  /// Binds the (shared) socket and starts handling requests.
  ///
  /// [workerId] identifies the owning isolate for logging; when omitted the
  /// server prints its own startup banner (single-isolate/dev use).
  Future<void> start({int? workerId}) async {
    // `shared: true` lets every worker isolate bind the same port and have the
    // runtime load-balance connections across them (no blocking, no lock).
    final server = await HttpServer.bind(
      config.address,
      config.port,
      shared: true,
    );
    server.serverHeader = config.serverSoftware;
    server.idleTimeout = config.idleTimeout;
    _server = server;

    if (workerId == null) {
      stdout.writeln('dart-apache serving "${config.documentRoot}"');
      stdout.writeln('Listening on http://${config.address}:${config.port}/');
      stdout.writeln('PHP handler: ${config.phpCgiPath}');
    } else {
      stdout.writeln('[worker $workerId] ready');
    }

    unawaited(server.forEach(_handle));
  }

  /// Stops accepting new connections. When [graceful] is true, in-flight
  /// requests are allowed to finish (connection draining); otherwise the
  /// listening socket is closed immediately.
  Future<void> stop({bool graceful = false}) async {
    await _server?.close(force: !graceful);
    _server = null;
    await _php.close();
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    // Advertise HTTP/3 availability so capable clients upgrade to QUIC.
    final altSvc = config.altSvcHeader;
    if (altSvc != null) response.headers.set('alt-svc', altSvc);
    try {
      // Reject over-large declared bodies before doing any work.
      if (request.contentLength > config.maxRequestBodyBytes) {
        await _serveError(
          response,
          HttpStatus.requestEntityTooLarge,
          'Payload Too Large',
        );
        return;
      }
      final resolution = _resolver.resolve(request.uri.path);
      switch (resolution.kind) {
        case ResolutionKind.staticFile:
          await _serveStatic(request, resolution.filePath);
        case ResolutionKind.phpScript:
          await _servePhp(request, resolution);
        case ResolutionKind.forbidden:
          await _serveError(response, HttpStatus.forbidden, 'Forbidden');
        case ResolutionKind.notFound:
          await _serveError(response, HttpStatus.notFound, 'Not Found');
      }
    } on CgiException catch (e) {
      stderr.writeln('[php-cgi] $e');
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
        // Response may already be committed; nothing more we can do.
      }
    } finally {
      _logRequest(request, response);
    }
  }

  Future<void> _serveStatic(HttpRequest request, String filePath) async {
    final file = File(filePath);
    final length = await file.length();
    final response = request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = null
      ..headers.set(HttpHeaders.contentTypeHeader, mimeTypeFor(filePath))
      ..headers.set(HttpHeaders.contentLengthHeader, '$length')
      ..headers.set(
        HttpHeaders.lastModifiedHeader,
        HttpDate.format(file.lastModifiedSync()),
      );

    if (request.method == 'HEAD') {
      await response.close();
      return;
    }

    await response.addStream(file.openRead());
    await response.close();
  }

  Future<void> _servePhp(HttpRequest request, Resolution resolution) async {
    final php = await _php.handle(
      request: request,
      scriptFilename: resolution.filePath,
      scriptName: resolution.scriptName,
      pathInfo: resolution.pathInfo,
    );

    final response = request.response
      ..statusCode = php.statusCode
      ..reasonPhrase = php.reasonPhrase;

    var sawContentType = false;
    php.headers.forEach((name, values) {
      if (name.toLowerCase() == 'content-type') sawContentType = true;
      for (final value in values) {
        response.headers.add(name, value);
      }
    });
    if (!sawContentType) {
      response.headers.set(
        HttpHeaders.contentTypeHeader,
        'text/html; charset=UTF-8',
      );
    }

    // No Content-Length is set here: the body is streamed, so the response is
    // chunked unless the script supplied its own Content-Length header.
    if (request.method == 'HEAD') {
      await php.body.drain<void>();
    } else {
      await response.addStream(php.body);
    }
    await response.close();
  }

  Future<void> _serveError(
    HttpResponse response,
    int status,
    String title,
  ) async {
    final html = '<!DOCTYPE html>\n'
        '<html><head><title>$status $title</title></head>\n'
        '<body><h1>$status $title</h1>\n'
        '<hr><address>${config.serverSoftware}</address></body></html>\n';
    final bytes = html.codeUnits;
    response
      ..statusCode = status
      ..headers.set(HttpHeaders.contentTypeHeader, 'text/html; charset=UTF-8')
      ..headers.set(HttpHeaders.contentLengthHeader, '${bytes.length}')
      ..add(bytes);
    await response.close();
  }

  void _logRequest(HttpRequest request, HttpResponse response) {
    final remote = request.connectionInfo?.remoteAddress.address ?? '-';
    final now = HttpDate.format(DateTime.now());
    // Common Log Format, as Apache writes to access_log.
    stdout.writeln(
      '$remote - - [$now] "${request.method} ${request.uri} '
      'HTTP/${request.protocolVersion}" ${response.statusCode} -',
    );
  }
}
