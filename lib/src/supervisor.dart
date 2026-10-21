import 'dart:io';
import 'dart:isolate';

import 'config.dart';
import 'server.dart';

/// Spawns and supervises worker isolates, each running an independent,
/// non-blocking [ApacheServer] bound to a shared listening socket. This is the
/// shared-nothing, worker-per-core model (nginx-style) that lets the server
/// scale across all CPU cores.
class ServerSupervisor {
  ServerSupervisor(this.config);

  final ServerConfig config;
  final List<Isolate> _workers = [];

  /// Starts the configured number of workers. With a single worker the server
  /// runs in-process; otherwise each worker runs in its own isolate.
  Future<void> start() async {
    stdout.writeln('dart-apache serving "${config.documentRoot}"');
    stdout.writeln('Listening on http://${config.address}:${config.port}/');
    stdout.writeln('PHP handler: ${config.phpCgiPath}');
    stdout.writeln('Workers: ${config.workers} isolate(s)');

    if (config.workers <= 1) {
      await ApacheServer(config).start(workerId: 0);
      return;
    }

    for (var i = 0; i < config.workers; i++) {
      final isolate = await Isolate.spawn(
        _workerMain,
        _WorkerArgs(config, i),
        debugName: 'dart-apache-worker-$i',
      );
      _workers.add(isolate);
    }
  }

  /// Tears down all worker isolates.
  Future<void> stop() async {
    for (final worker in _workers) {
      worker.kill(priority: Isolate.immediate);
    }
    _workers.clear();
  }
}

/// Isolate payload: the (sendable) config plus the worker index.
class _WorkerArgs {
  _WorkerArgs(this.config, this.id);
  final ServerConfig config;
  final int id;
}

/// Entry point run inside each worker isolate.
Future<void> _workerMain(_WorkerArgs args) async {
  await ApacheServer(args.config).start(workerId: args.id);
}
