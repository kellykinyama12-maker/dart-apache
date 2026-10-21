import 'dart:async';
import 'dart:io';

import 'config.dart';
import 'mime_types.dart';
import 'php_handler.dart';
import 'request_resolver.dart';

/// A small HTTP server that serves static files and runs PHP through `php-cgi`,
/// reproducing the request-handling flow of Apache HTTP Server.
class ApacheServer {
  ApacheServer(this.config)
      : _resolver = RequestResolver(config),
        _php = PhpCgiHandler(config);

  final ServerConfig config;
  final RequestResolver _resolver;
  final PhpCgiHandler _php;

  HttpServer? _server;

  /// Binds the socket and starts handling requests.
  Future<void> start() async {
    final server = await HttpServer.bind(config.address, config.port);
    server.serverHeader = config.serverSoftware;
    _server = server;

    stdout.writeln('dart-apache serving "${config.documentRoot}"');
    stdout.writeln('Listening on http://${config.address}:${config.port}/');
    stdout.writeln('PHP handler: ${config.phpCgiPath}');

    unawaited(server.forEach(_handle));
  }

  /// Stops accepting new connections.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
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
    final body = <int>[];
    await request.forEach(body.addAll);

    final cgi = await _php.handle(
      request: request,
      scriptFilename: resolution.filePath,
      scriptName: resolution.scriptName,
      pathInfo: resolution.pathInfo,
      requestBody: body,
    );

    final response = request.response
      ..statusCode = cgi.statusCode
      ..reasonPhrase = cgi.reasonPhrase;

    var sawContentType = false;
    cgi.headers.forEach((name, values) {
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
    response.headers.set(HttpHeaders.contentLengthHeader, '${cgi.body.length}');

    if (request.method != 'HEAD') {
      response.add(cgi.body);
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
