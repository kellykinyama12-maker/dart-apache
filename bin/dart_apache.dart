import 'dart:io';

import 'package:dart_apache/dart_apache.dart';

/// Entry point. Usage:
///
///   dart run dart_apache \
///     --root=./public --port=8080 --php-cgi=php-cgi --server-name=localhost
Future<void> main(List<String> arguments) async {
  final config = ServerConfig.fromArgs(arguments);

  if (!Directory(config.documentRoot).existsSync()) {
    stderr.writeln('DocumentRoot does not exist: ${config.documentRoot}');
    exitCode = 2;
    return;
  }

  final server = ApacheServer(config);

  // Graceful shutdown on Ctrl+C.
  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\nShutting down...');
    await server.stop();
    exit(0);
  });

  await server.start();
}
