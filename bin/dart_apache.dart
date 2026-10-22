import 'dart:io';

import 'package:dart_apache/dart_apache.dart';

/// Entry point. Usage:
///
///   dart run dart_apache --root=./public --port=8080
///   dart run dart_apache --root=./public --port=443 --http3 --dev
Future<void> main(List<String> arguments) async {
  final config = ServerConfig.fromArgs(arguments);

  if (!Directory(config.documentRoot).existsSync()) {
    stderr.writeln('DocumentRoot does not exist: ${config.documentRoot}');
    exitCode = 2;
    return;
  }

  // `--http3` co-locates an HTTP/3 (QUIC) listener with HTTP/1.1 in one
  // process; `--http3`/`--https` terminate TLS, which requires a certificate.
  final http3 = arguments.contains('--http3');
  if (config.tlsEnabled) {
    final hasCert = config.tlsCertPath != null && config.tlsKeyPath != null;
    if (!hasCert && !config.devMode) {
      stderr.writeln(
        'TLS requires a certificate: pass --tls-cert and --tls-key, '
        'or --dev to use a generated self-signed certificate.',
      );
      exitCode = 2;
      return;
    }
  }

  final server = ServerSupervisor(
    config,
    kind: http3 ? WorkerKind.unified : WorkerKind.http1,
  );

  // Graceful shutdown on Ctrl+C (and SIGTERM on POSIX).
  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\nShutting down...');
    await server.stop();
    exit(0);
  });
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) async {
      await server.stop();
      exit(0);
    });
    // Zero-downtime reload on SIGHUP (e.g. `kill -HUP <pid>`), like Apache.
    ProcessSignal.sighup.watch().listen((_) => server.reload());
  }

  await server.start();
}
