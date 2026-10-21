import 'dart:io';

import 'package:dart_apache/src/config.dart';
import 'package:dart_apache/src/http3/h3_php_server.dart';

/// Experimental HTTP/3 (QUIC) entry point serving static files and PHP.
///
///   dart run bin/dart_apache_h3.dart --root=./public --port=4433 [--verbose]
Future<void> main(List<String> arguments) async {
  final config = ServerConfig.fromArgs(arguments);
  final verbose = arguments.contains('--verbose');

  if (!Directory(config.documentRoot).existsSync()) {
    stderr.writeln('DocumentRoot does not exist: ${config.documentRoot}');
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
          serverName: config.serverName,
        )
      : config;

  await Http3PhpServer(effective, verbose: verbose).start();
}
