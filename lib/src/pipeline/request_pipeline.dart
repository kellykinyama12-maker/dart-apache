import 'dart:io';

import '../config.dart';
import '../mime_types.dart';
import '../php/cgi_backend.dart';
import '../php/fastcgi.dart';
import '../php/php_backend.dart';
import '../request_resolver.dart';
import 'server_exchange.dart';

/// Transport-agnostic request handling: resolves a [ServerExchange] against the
/// document root and serves static files, PHP (CGI/FastCGI), or an error —
/// writing the result to the exchange's [ServerResponse]. Shared by every
/// transport (HTTP/3, HTTP/1.1, …) so handlers are written once.
class RequestPipeline {
  RequestPipeline(this.config)
      : _resolver = RequestResolver(config),
        _php = config.phpFpm != null
            ? FastCgiBackend(config)
            : CgiBackend(config);

  final ServerConfig config;
  final RequestResolver _resolver;
  final PhpBackend _php;

  /// Called with a Common Log Format line after each request (defaults to
  /// stdout). Transports can override to centralize logging.
  void Function(String line) onAccessLog = stdout.writeln;

  Future<void> close() => _php.close();

  Future<void> serve(ServerExchange exchange) async {
    final response = exchange.respond();

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

      final resolution = _resolver.resolve(exchange.uri.path);
      switch (resolution.kind) {
        case ResolutionKind.staticFile:
          await _serveStatic(exchange, response, resolution.filePath);
        case ResolutionKind.phpScript:
          await _servePhp(exchange, response, resolution);
        case ResolutionKind.forbidden:
          await _serveError(response, HttpStatus.forbidden, 'Forbidden');
        case ResolutionKind.notFound:
          await _serveError(response, HttpStatus.notFound, 'Not Found');
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

  Future<void> _serveStatic(
    ServerExchange exchange,
    ServerResponse response,
    String filePath,
  ) async {
    final file = File(filePath);
    final length = await file.length();
    response
      ..setStatus(HttpStatus.ok)
      ..setHeader(HttpHeaders.contentTypeHeader, mimeTypeFor(filePath))
      ..setHeader(HttpHeaders.contentLengthHeader, '$length')
      ..setHeader(
        HttpHeaders.lastModifiedHeader,
        HttpDate.format(file.lastModifiedSync()),
      );

    if (exchange.method == 'HEAD') {
      await response.close();
      return;
    }
    await response.addStream(file.openRead());
    await response.close();
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
      if (name.toLowerCase() == 'content-type') sawContentType = true;
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
