import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../pipeline/server_exchange.dart';
import 'cgi_params.dart';
import 'php_backend.dart';

/// Executes PHP via the `php-cgi` binary using CGI/1.1: request metadata is
/// passed as environment variables, the request body is streamed to stdin, and
/// the response is streamed back from stdout — all with back-pressure.
class CgiBackend implements PhpBackend {
  CgiBackend(this.config);

  final ServerConfig config;

  @override
  Future<PhpResponse> handle({
    required ServerExchange exchange,
    required String scriptFilename,
    required String scriptName,
    required String pathInfo,
  }) async {
    final env = buildCgiParams(
      config: config,
      exchange: exchange,
      scriptFilename: scriptFilename,
      scriptName: scriptName,
      pathInfo: pathInfo,
    );

    final process = await Process.start(
      config.phpCgiPath,
      const [],
      environment: env,
      // A clean, Apache-like environment: the script sees only CGI vars.
      includeParentEnvironment: false,
    );

    // Stream the request body to the interpreter (back-pressure in). Errors
    // (e.g. client abort) just close stdin.
    unawaited(
      exchange.body.cast<List<int>>().pipe(process.stdin).catchError((_) {}),
    );

    // Collect stderr for diagnostics if the process fails without output.
    final stderrBytes = <int>[];
    final stderrDone = process.stderr.forEach(stderrBytes.addAll);

    return parseCgiStream(
      process.stdout,
      logTag: 'php-cgi',
      onEmpty: () async {
        await stderrDone;
        final code = await process.exitCode;
        final message = utf8.decode(stderrBytes, allowMalformed: true).trim();
        return 'php-cgi exited with code $code '
            'for ${shortScript(scriptFilename)}: '
            '${message.isEmpty ? '(no output)' : message}';
      },
    );
  }

  @override
  Future<void> close() async {}
}
