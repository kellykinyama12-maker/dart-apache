import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';
import 'pipeline/dart_handler.dart';
import 'pipeline/http_exchange.dart';
import 'pipeline/request_pipeline.dart';
import 'tls/dev_cert.dart';
import 'worker_server.dart';

/// A small HTTP/1.1 server that serves static files and runs PHP, reproducing
/// Apache's request-handling flow. Request handling lives in the shared,
/// transport-agnostic [RequestPipeline]; this class owns the listening socket
/// and adapts each `dart:io` request to the pipeline.
class ApacheServer implements WorkerServer {
  ApacheServer(this.config, {DartApp? app})
      : _pipeline = RequestPipeline(config, app: app);

  final ServerConfig config;
  final RequestPipeline _pipeline;

  HttpServer? _server;

  /// Binds the (shared) socket and starts handling requests.
  ///
  /// [workerId] identifies the owning isolate for logging; when omitted the
  /// server prints its own startup banner (single-isolate/dev use).
  @override
  Future<void> start({int? workerId}) async {
    // `shared: true` lets every worker isolate bind the same port and have the
    // runtime load-balance connections across them (no blocking, no lock).
    final server = config.tlsEnabled
        ? await HttpServer.bindSecure(
            config.address,
            config.port,
            _securityContext(),
            shared: true,
          )
        : await HttpServer.bind(
            config.address,
            config.port,
            shared: true,
          );
    server.serverHeader = config.serverSoftware;
    server.idleTimeout = config.idleTimeout;
    _server = server;

    final scheme = config.tlsEnabled ? 'https' : 'http';
    if (workerId == null) {
      stdout.writeln('dart-apache serving "${config.documentRoot}"');
      stdout.writeln('Listening on $scheme://${config.address}:${config.port}/');
      stdout.writeln('PHP handler: ${config.phpFpm ?? config.phpCgiPath}');
    } else {
      stdout.writeln('[worker $workerId] ready');
    }

    unawaited(server.forEach(_handle));
  }

  /// Stops accepting new connections. When [graceful] is true, in-flight
  /// requests are allowed to finish (connection draining); otherwise the
  /// listening socket is closed immediately.
  @override
  Future<void> stop({bool graceful = false}) async {
    await _server?.close(force: !graceful);
    _server = null;
    await _pipeline.close();
  }

  /// Builds the TLS context for HTTPS: a real PEM cert/key when configured, or
  /// a generated self-signed one in `--dev` mode. Only `http/1.1` is offered
  /// over ALPN (dart:io's server speaks HTTP/1.1).
  SecurityContext _securityContext() {
    final ctx = SecurityContext()..setAlpnProtocols(['http/1.1'], true);
    final certPath = config.tlsCertPath;
    final keyPath = config.tlsKeyPath;
    if (certPath != null && keyPath != null) {
      ctx
        ..useCertificateChain(certPath)
        ..usePrivateKey(keyPath);
    } else {
      final pem = generateDevCertPem();
      ctx
        ..useCertificateChainBytes(utf8.encode(pem.cert))
        ..usePrivateKeyBytes(utf8.encode(pem.key));
    }
    return ctx;
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
