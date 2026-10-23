import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../php/cgi_params.dart';
import '../php/php_backend.dart';
import '../pipeline/server_exchange.dart';

/// Runs a `.dart` file as a CGI-style script via the Dart VM — the direct
/// analog of [CgiBackend] (`php-cgi`) for Dart. Request metadata is passed as
/// environment variables (the same CGI/1.1 block PHP gets), the request body is
/// streamed to the script's stdin, and the script writes a CGI response
/// (`Header: value` lines, a blank line, then the body) to stdout.
///
/// Because it executes source through `dart run`, you **edit the script and the
/// next request runs the new code — no compile step** (just like editing PHP).
/// The trade-off is Dart VM startup per request; for production either compile
/// the app in-process or front a persistent Dart app via `--proxy`.
class DartCgiBackend implements PhpBackend {
  DartCgiBackend(this.config);

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

    // `dart run <file>` executes the script source on the VM (no AOT compile).
    final process = await Process.start(
      config.dartExecutable,
      ['run', scriptFilename],
      environment: env,
    );

    unawaited(
      exchange.body.cast<List<int>>().pipe(process.stdin).catchError((_) {}),
    );

    final stderrBytes = <int>[];
    final stderrDone = process.stderr.forEach(stderrBytes.addAll);

    return parseCgiStream(
      process.stdout,
      logTag: 'dart-cgi',
      onEmpty: () async {
        await stderrDone;
        final code = await process.exitCode;
        final message = utf8.decode(stderrBytes, allowMalformed: true).trim();
        return 'dart-cgi exited with code $code '
            'for ${shortScript(scriptFilename)}: '
            '${message.isEmpty ? '(no output)' : message}';
      },
    );
  }

  @override
  Future<void> close() async {}
}
