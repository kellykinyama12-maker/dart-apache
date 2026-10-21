import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';

/// A parsed CGI response: the headers emitted by the script plus the raw body
/// bytes, and the HTTP status the script requested (via a `Status:` header).
class CgiResponse {
  CgiResponse({
    required this.statusCode,
    required this.reasonPhrase,
    required this.headers,
    required this.body,
  });

  final int statusCode;
  final String reasonPhrase;

  /// Header name -> list of values, preserving multiple `Set-Cookie` headers.
  final Map<String, List<String>> headers;
  final List<int> body;
}

/// Executes PHP scripts through the `php-cgi` binary using the CGI/1.1
/// protocol, exactly as Apache's `mod_cgi` does: environment variables carry
/// the request metadata, the request body is piped to stdin, and the response
/// (headers + body) is read back from stdout.
class PhpCgiHandler {
  PhpCgiHandler(this.config);

  final ServerConfig config;

  /// Runs [scriptFilename] for [request] and returns the parsed CGI response.
  ///
  /// [scriptName] is the URL path of the script (e.g. `/index.php`),
  /// [pathInfo] is any trailing path after the script, and [requestBody] is the
  /// already-buffered request body forwarded to the interpreter's stdin.
  Future<CgiResponse> handle({
    required HttpRequest request,
    required String scriptFilename,
    required String scriptName,
    required String pathInfo,
    required List<int> requestBody,
  }) async {
    final env = _buildCgiEnvironment(
      request: request,
      scriptFilename: scriptFilename,
      scriptName: scriptName,
      pathInfo: pathInfo,
      contentLength: requestBody.length,
    );

    final process = await Process.start(
      config.phpCgiPath,
      const [],
      environment: env,
      // CGI passes everything through env/stdin; don't inherit our own env so
      // the script sees a clean, Apache-like environment.
      includeParentEnvironment: false,
    );

    if (requestBody.isNotEmpty) {
      process.stdin.add(requestBody);
    }
    await process.stdin.close();

    final stdoutBytes = <int>[];
    final stderrBytes = <int>[];
    await Future.wait([
      process.stdout.forEach(stdoutBytes.addAll),
      process.stderr.forEach(stderrBytes.addAll),
    ]);
    final exitCode = await process.exitCode;

    if (exitCode != 0 && stdoutBytes.isEmpty) {
      final message = utf8.decode(stderrBytes, allowMalformed: true);
      throw CgiException(
        'php-cgi exited with code $exitCode: '
        '${message.isEmpty ? '(no output)' : message}',
      );
    }

    return _parseCgiOutput(stdoutBytes);
  }

  /// Builds the CGI/1.1 environment variable block for a request.
  Map<String, String> _buildCgiEnvironment({
    required HttpRequest request,
    required String scriptFilename,
    required String scriptName,
    required String pathInfo,
    required int contentLength,
  }) {
    final uri = request.uri;
    final connectionInfo = request.connectionInfo;

    final env = <String, String>{
      'GATEWAY_INTERFACE': 'CGI/1.1',
      'SERVER_SOFTWARE': config.serverSoftware,
      'SERVER_PROTOCOL': 'HTTP/${request.protocolVersion}',
      'SERVER_NAME': config.serverName,
      'SERVER_ADDR': config.address,
      'SERVER_PORT': '${config.port}',
      'DOCUMENT_ROOT': config.documentRoot,
      'REQUEST_METHOD': request.method,
      'REQUEST_URI': uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path,
      'QUERY_STRING': uri.query,
      'SCRIPT_NAME': scriptName,
      'SCRIPT_FILENAME': scriptFilename,
      'PATH_TRANSLATED': scriptFilename,
      'REMOTE_ADDR': connectionInfo?.remoteAddress.address ?? '',
      'REMOTE_PORT': '${connectionInfo?.remotePort ?? 0}',
      // php-cgi refuses to run as a CGI binary unless this is set; Apache's
      // mod_cgi sets it implicitly. 200 means "not an internal redirect".
      'REDIRECT_STATUS': '200',
    };

    if (pathInfo.isNotEmpty) {
      env['PATH_INFO'] = pathInfo;
    }

    final contentType = request.headers.contentType;
    if (contentType != null) {
      env['CONTENT_TYPE'] = contentType.toString();
    }
    if (contentLength > 0) {
      env['CONTENT_LENGTH'] = '$contentLength';
    }

    // Every request header becomes HTTP_<UPPER_SNAKE_CASE>, per CGI.
    request.headers.forEach((name, values) {
      final key = 'HTTP_${name.toUpperCase().replaceAll('-', '_')}';
      env[key] = values.join(', ');
    });

    return env;
  }

  /// Splits raw CGI stdout into headers and body, then maps the CGI headers to
  /// an HTTP status and response headers.
  CgiResponse _parseCgiOutput(List<int> output) {
    final separator = _findHeaderBodySeparator(output);
    final List<int> headerBytes;
    final List<int> body;
    if (separator == null) {
      headerBytes = output;
      body = const [];
    } else {
      headerBytes = output.sublist(0, separator.start);
      body = output.sublist(separator.end);
    }

    final headerText = utf8.decode(headerBytes, allowMalformed: true);
    final headers = <String, List<String>>{};
    var statusCode = 200;
    var reasonPhrase = 'OK';

    final lines = const LineSplitter().convert(headerText);

    // Some misconfigured PHP builds leak startup warnings to stdout *before*
    // the CGI header block (Apache reports these as "malformed header from
    // script"). Skip any such leading non-header lines to recover the real
    // headers, and surface the leaked text on stderr like Apache's error_log.
    var firstHeaderLine = 0;
    while (firstHeaderLine < lines.length) {
      final line = lines[firstHeaderLine].trimRight();
      if (line.isEmpty) break;
      final colon = line.indexOf(':');
      if (colon > 0 && _isValidHeaderName(line.substring(0, colon).trim())) {
        break;
      }
      firstHeaderLine++;
    }

    if (firstHeaderLine == lines.length) {
      // Nothing that looks like a header block: treat it all as the body.
      return _rawBodyResponse(output);
    }
    if (firstHeaderLine > 0) {
      final leaked = lines.take(firstHeaderLine).join('\n');
      stderr.writeln('[php-cgi] discarded leaked preamble before headers:\n'
          '$leaked');
    }

    for (final rawLine in lines.skip(firstHeaderLine)) {
      final line = rawLine.trimRight();
      if (line.isEmpty) break;
      final colon = line.indexOf(':');
      if (colon < 0) break;
      final name = line.substring(0, colon).trim();
      final value = line.substring(colon + 1).trim();
      if (!_isValidHeaderName(name)) break;

      if (name.toLowerCase() == 'status') {
        final space = value.indexOf(' ');
        if (space > 0) {
          statusCode = int.tryParse(value.substring(0, space)) ?? statusCode;
          reasonPhrase = value.substring(space + 1).trim();
        } else {
          statusCode = int.tryParse(value) ?? statusCode;
        }
        continue;
      }

      headers.putIfAbsent(name, () => <String>[]).add(value);
    }

    return CgiResponse(
      statusCode: statusCode,
      reasonPhrase: reasonPhrase,
      headers: headers,
      body: body,
    );
  }

  /// Fallback used when the interpreter did not emit a valid CGI header block:
  /// return everything it wrote as the response body.
  CgiResponse _rawBodyResponse(List<int> output) => CgiResponse(
        statusCode: 200,
        reasonPhrase: 'OK',
        headers: const {},
        body: output,
      );

  /// Whether [name] is a valid HTTP header field name (RFC 7230 token).
  bool _isValidHeaderName(String name) {
    if (name.isEmpty) return false;
    for (final code in name.codeUnits) {
      final isTokenChar = (code >= 0x30 && code <= 0x39) || // 0-9
          (code >= 0x41 && code <= 0x5A) || // A-Z
          (code >= 0x61 && code <= 0x7A) || // a-z
          '!#\$%&\'*+-.^_`|~'.contains(String.fromCharCode(code));
      if (!isTokenChar) return false;
    }
    return true;
  }

  /// Finds the blank line separating CGI headers from the body, supporting both
  /// `\r\n\r\n` and `\n\n`. Returns the byte range of the separator itself.
  _Separator? _findHeaderBodySeparator(List<int> bytes) {
    for (var i = 0; i < bytes.length; i++) {
      // \n\n
      if (bytes[i] == 0x0A && i + 1 < bytes.length && bytes[i + 1] == 0x0A) {
        return _Separator(i, i + 2);
      }
      // \r\n\r\n
      if (bytes[i] == 0x0D &&
          i + 3 < bytes.length &&
          bytes[i + 1] == 0x0A &&
          bytes[i + 2] == 0x0D &&
          bytes[i + 3] == 0x0A) {
        return _Separator(i, i + 4);
      }
    }
    return null;
  }
}

class _Separator {
  _Separator(this.start, this.end);
  final int start;
  final int end;
}

/// Raised when the CGI interpreter could not be run or produced no usable
/// output.
class CgiException implements Exception {
  CgiException(this.message);
  final String message;
  @override
  String toString() => 'CgiException: $message';
}
