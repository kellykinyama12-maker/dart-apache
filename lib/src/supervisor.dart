import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'config.dart';
import 'http3/h3_php_server.dart';
import 'server.dart';
import 'unified_server.dart';
import 'worker_server.dart';

/// Which transport(s) a supervised worker serves.
enum WorkerKind { http1, http3, unified }

/// Supervises worker isolates, each running an independent, non-blocking
/// [WorkerServer] bound to a shared listening socket (shared-nothing,
/// worker-per-core — nginx-style). The supervisor:
///
/// - **respawns** workers that exit unexpectedly (with backoff), and
/// - performs **zero-downtime reloads**: a fresh generation of workers is
///   spawned on the same shared socket, then the old generation is told to
///   drain in-flight requests and exit.
class ServerSupervisor {
  ServerSupervisor(this.config, {this.kind = WorkerKind.http1});

  final ServerConfig config;
  final WorkerKind kind;
  final List<_Worker> _workers = [];

  bool _stopping = false;
  bool _reloading = false;

  /// A worker that stays up at least this long resets its crash counter.
  static const Duration _stableWindow = Duration(seconds: 60);

  /// Give up respawning after this many rapid consecutive crashes.
  static const int _maxRestarts = 5;

  /// Spawns the configured number of workers and begins serving.
  Future<void> start() async {
    stdout.writeln('dart-apache serving "${config.documentRoot}"');
    switch (kind) {
      case WorkerKind.unified:
        stdout.writeln('Listening on http://${config.address}:${config.port}/ '
            '(HTTP/1.1) and https://${config.address}:${config.port}/ '
            '(HTTP/3, QUIC/UDP)');
      case WorkerKind.http3:
        stdout.writeln(
            'Listening on https://${config.address}:${config.port}/ '
            '(QUIC/UDP)');
      case WorkerKind.http1:
        stdout.writeln(
            'Listening on http://${config.address}:${config.port}/');
    }
    stdout.writeln('PHP handler: ${config.phpFpm ?? config.phpCgiPath}');
    stdout.writeln('Workers: ${config.workers} isolate(s)');

    for (var i = 0; i < config.workers; i++) {
      _workers.add(await _spawn(i));
    }
  }

  /// Zero-downtime reload: spawn a new generation, then drain the old one.
  Future<void> reload() async {
    if (_stopping || _reloading) return;
    _reloading = true;
    stdout.writeln('[supervisor] reloading ${config.workers} worker(s)...');

    final old = List<_Worker>.of(_workers);
    final fresh = <_Worker>[];
    for (var i = 0; i < config.workers; i++) {
      fresh.add(await _spawn(i));
    }
    _workers
      ..clear()
      ..addAll(fresh);

    // New workers are bound to the shared socket; drain the old generation.
    for (final worker in old) {
      worker.draining = true;
      worker.control.send(_WorkerMessage.drain);
    }
    _reloading = false;
    stdout.writeln('[supervisor] reload complete');
  }

  /// Gracefully drains and stops all workers.
  Future<void> stop() async {
    _stopping = true;
    for (final worker in _workers) {
      worker.draining = true;
      worker.control.send(_WorkerMessage.drain);
    }
    _workers.clear();
  }

  Future<_Worker> _spawn(int id, {int restarts = 0}) async {
    final ready = ReceivePort();
    final exit = ReceivePort();
    final readyCompleter = Completer<SendPort>();
    late _Worker worker;

    ready.listen((msg) {
      if (!readyCompleter.isCompleted) readyCompleter.complete(msg as SendPort);
    });

    final isolate = await Isolate.spawn(
      _workerMain,
      _WorkerArgs(config, id, ready.sendPort, kind),
      onExit: exit.sendPort,
      debugName: 'dart-apache-worker-$id',
    );

    exit.listen((_) {
      exit.close();
      ready.close();
      if (!readyCompleter.isCompleted) {
        readyCompleter.completeError(
          StateError('worker $id exited before becoming ready'),
        );
        return;
      }
      if (_stopping || worker.draining) return;
      stderr.writeln('[supervisor] worker $id exited unexpectedly');
      _respawn(worker);
    });

    // Wait until the worker is bound and ready (or fails to start).
    final control = await readyCompleter.future;
    ready.close();
    worker = _Worker(id, isolate, control, exit, restarts: restarts);
    return worker;
  }

  /// Respawns a crashed worker with exponential backoff, giving up if it keeps
  /// crashing (crash-loop protection).
  Future<void> _respawn(_Worker dead) async {
    _workers.remove(dead);
    if (_stopping) return;

    // A worker that ran long enough is treated as a fresh failure, not a loop.
    final ranLongEnough =
        DateTime.now().difference(dead.startedAt) >= _stableWindow;
    final restarts = ranLongEnough ? 1 : dead.restarts + 1;

    if (restarts > _maxRestarts) {
      stderr.writeln('[supervisor] worker ${dead.id} crashed $restarts times '
          'in a row; giving up (crash loop)');
      return;
    }

    final delay = backoffDelay(restarts);
    if (delay > Duration.zero) {
      stderr.writeln('[supervisor] respawning worker ${dead.id} in '
          '${delay.inMilliseconds}ms (attempt $restarts)');
      await Future<void>.delayed(delay);
      if (_stopping) return;
    }
    try {
      _workers.add(await _spawn(dead.id, restarts: restarts));
    } catch (e) {
      stderr.writeln('[supervisor] failed to respawn worker ${dead.id}: $e');
    }
  }
}

/// Control messages sent from the supervisor to a worker.
enum _WorkerMessage { drain }

/// Exponential backoff for respawning a crashed worker: the first restart is
/// immediate, then `base * 2^(n-2)` capped at [max].
Duration backoffDelay(
  int restarts, {
  Duration base = const Duration(milliseconds: 200),
  Duration max = const Duration(seconds: 30),
}) {
  if (restarts <= 1) return Duration.zero;
  final ms = base.inMilliseconds * (1 << (restarts - 2));
  return Duration(
    milliseconds: ms > max.inMilliseconds ? max.inMilliseconds : ms,
  );
}

class _Worker {
  _Worker(
    this.id,
    this.isolate,
    this.control,
    this.exit, {
    this.restarts = 0,
  }) : startedAt = DateTime.now();
  final int id;
  final Isolate isolate;
  final SendPort control;
  final ReceivePort exit;

  /// Consecutive rapid crash count carried across respawns.
  final int restarts;

  /// When this worker became ready (used to detect crash loops).
  final DateTime startedAt;

  /// True once the worker has been asked to drain (so its exit is expected).
  bool draining = false;
}

/// Isolate payload: the (sendable) config, worker index, a port used to report
/// readiness back to the supervisor, and which transport to serve.
class _WorkerArgs {
  _WorkerArgs(this.config, this.id, this.toSupervisor, this.kind);
  final ServerConfig config;
  final int id;
  final SendPort toSupervisor;
  final WorkerKind kind;
}

/// Entry point run inside each worker isolate.
Future<void> _workerMain(_WorkerArgs args) async {
  final control = ReceivePort();
  final WorkerServer server = switch (args.kind) {
    WorkerKind.http3 => Http3PhpServer(args.config),
    WorkerKind.unified => UnifiedServer(args.config),
    WorkerKind.http1 => ApacheServer(args.config),
  };
  await server.start(workerId: args.id);

  // Signal readiness by handing the supervisor our control port.
  args.toSupervisor.send(control.sendPort);

  await for (final message in control) {
    if (message == _WorkerMessage.drain) {
      await server.stop(graceful: true);
      control.close();
      break;
    }
  }
}
