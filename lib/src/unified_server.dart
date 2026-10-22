import 'dart:async';

import 'config.dart';
import 'http3/h3_php_server.dart';
import 'pipeline/dart_handler.dart';
import 'server.dart';
import 'worker_server.dart';

/// Serves HTTP/1.1 (TCP) and HTTP/3 (UDP/QUIC) from the same worker, on the
/// same port number (TCP and UDP ports are independent). The HTTP/1.1 responses
/// advertise the co-located HTTP/3 listener via `Alt-Svc`, so discovery points
/// at a listener that is actually running in this process.
class UnifiedServer implements WorkerServer {
  UnifiedServer(this.config, {DartApp? app})
      : _h1 = ApacheServer(config, app: app),
        _h3 = Http3PhpServer(config, app: app);

  final ServerConfig config;
  final ApacheServer _h1;
  final Http3PhpServer _h3;

  @override
  Future<void> start({int? workerId}) async {
    // Build the h3 cert first so a bad/missing cert fails before we bind TCP.
    await _h3.start(workerId: workerId);
    await _h1.start(workerId: workerId);
  }

  @override
  Future<void> stop({bool graceful = false}) async {
    await Future.wait([
      _h1.stop(graceful: graceful),
      _h3.stop(graceful: graceful),
    ]);
  }
}
