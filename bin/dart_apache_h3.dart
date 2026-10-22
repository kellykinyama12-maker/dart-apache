import 'dart:io';

import 'package:dart_apache/src/config.dart';
import 'package:dart_apache/src/supervisor.dart';

/// Experimental HTTP/3 (QUIC) entry point serving static files and PHP.
///
///   dart run bin/dart_apache_h3.dart --root=./public --port=4433 --dev
///   dart run bin/dart_apache_h3.dart --root=./public --tls-cert=cert.pem \
///       --tls-key=key.pem --workers=4
Future<void> main(List<String> arguments) async {
  final config = ServerConfig.fromArgs(arguments);

  if (!Directory(config.documentRoot).existsSync()) {
    stderr.writeln('DocumentRoot does not exist: ${config.documentRoot}');
    exitCode = 2;
    return;
  }

  final hasCert = config.tlsCertPath != null && config.tlsKeyPath != null;
  if (!hasCert && !config.devMode) {
    stderr.writeln(
      'HTTP/3 requires a TLS certificate: pass --tls-cert and --tls-key, '
      'or --dev to use a generated self-signed certificate.',
    );
    exitCode = 2;
    return;
  }

  // QUIC defaults to UDP/4433 for the demo if no port is given.
  final effective = config.port == 8080
      ? ServerConfig(
          address: config.address,
          port: 4433,
          documentRoot: config.documentRoot,
          phpCgiPath: config.phpCgiPath,
          phpFpm: config.phpFpm,
          serverName: config.serverName,
          tlsCertPath: config.tlsCertPath,
          tlsKeyPath: config.tlsKeyPath,
          devMode: config.devMode,
          workers: config.workers,
          wtPath: config.wtPath,
        )
      : config;

  final server = ServerSupervisor(effective, kind: WorkerKind.http3);

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
    ProcessSignal.sighup.watch().listen((_) => server.reload());
  }

  await server.start();
}
