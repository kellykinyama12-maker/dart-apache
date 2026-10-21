import 'dart:async';
import 'dart:io';

import 'config.dart';
import 'pipeline/http_exchange.dart';
import 'pipeline/request_pipeline.dart';

/// A small HTTP/1.1 server that serves static files and runs PHP, reproducing
/// Apache's request-handling flow. Request handling lives in the shared,
/// transport-agnostic [RequestPipeline]; this class owns the listening socket
/// and adapts each `dart:io` request to the pipeline.
class ApacheServer {
  ApacheServer(this.config) : _pipeline = RequestPipeline(config);

  final ServerConfig config;
  final RequestPipeline _pipeline;

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
      stdout.writeln('PHP handler: ${config.phpFpm ?? config.phpCgiPath}');
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
    await _pipeline.close();
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      await _pipeline.serve(HttpExchange(request));
    } catch (e, st) {
      stderr.writeln('[server] unhandled: $e\n$st');
      try {
        await request.response.close();
      } catch (_) {
        // Response may already be committed.
      }
    }
  }
}
