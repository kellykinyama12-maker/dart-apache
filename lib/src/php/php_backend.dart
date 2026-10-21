import 'dart:async';
import 'dart:convert';
import 'dart:io' hide BytesBuilder;
import 'dart:typed_data' show BytesBuilder;

import 'package:path/path.dart' as p;

import '../pipeline/server_exchange.dart';

/// A streamed PHP/CGI response: parsed status and headers, plus a body stream
/// that carries back-pressure from the client all the way back to the
/// interpreter (php-cgi stdout or a FastCGI stream).
class PhpResponse {
  PhpResponse({
    required this.statusCode,
    required this.reasonPhrase,
    required this.headers,
    required this.body,
  });

  final int statusCode;
  final String reasonPhrase;

  /// Header name -> values, preserving multiple `Set-Cookie` headers.
  final Map<String, List<String>> headers;

  /// Response body, streamed (never fully buffered).
  final Stream<List<int>> body;
}

/// A backend that executes a PHP script and returns a streamed response.
/// Implemented by the CGI (`php-cgi`) and FastCGI (PHP-FPM) backends.
abstract interface class PhpBackend {
  Future<PhpResponse> handle({
    required ServerExchange exchange,
    required String scriptFilename,
    required String scriptName,
    required String pathInfo,
  });

  /// Releases any pooled resources (FastCGI connections, etc.).
  Future<void> close();
}

/// Raised when a PHP backend cannot run or produced no usable output.
class CgiException implements Exception {
  CgiException(this.message);
  final String message;
  @override
  String toString() => 'CgiException: $message';
}

/// Consumes a raw CGI output stream (`raw`), parses the CGI header block, and
/// returns a [PhpResponse] whose body streams the remaining bytes with
/// back-pressure. [logTag] labels diagnostics (e.g. `php-cgi`, `php-fpm`).
///
/// [onEmpty], if provided, is awaited when the stream closes before any header
/// block was seen *and* no bytes were produced; it should yield an error
/// message (e.g. interpreter stderr) used to raise a [CgiException].
Future<PhpResponse> parseCgiStream(
  Stream<List<int>> raw, {
  required String logTag,
  Future<String> Function()? onEmpty,
}) {
  final headCompleter = Completer<_CgiHead>();
  final bodyController = StreamController<List<int>>();
  final buffer = BytesBuilder(copy: false);
  var headParsed = false;

  late StreamSubscription<List<int>> sub;

  void failOrFallback(List<int> pending) {
    // Stream ended with no header separator. If there is content, treat it all
    // as the body (a script that emitted output without proper headers). If
    // there is nothing, raise an error via onEmpty.
    if (pending.isNotEmpty) {
      headCompleter.complete(_CgiHead.rawBody());
      bodyController.add(pending);
      bodyController.close();
      return;
    }
    if (onEmpty != null) {
      onEmpty().then((msg) {
        if (!headCompleter.isCompleted) {
          headCompleter.completeError(CgiException(msg));
        }
      });
    } else if (!headCompleter.isCompleted) {
      headCompleter.complete(_CgiHead.rawBody());
    }
    bodyController.close();
  }

  sub = raw.listen(
    (chunk) {
      if (headParsed) {
        bodyController.add(chunk);
        return;
      }
      buffer.add(chunk);
      final bytes = buffer.toBytes();
      final sep = _findHeaderBodySeparator(bytes);
      if (sep == null) return;

      headParsed = true;
      final head = _parseHead(bytes.sublist(0, sep.start), logTag);
      headCompleter.complete(head);
      final leftover = bytes.sublist(sep.end);
      if (leftover.isNotEmpty) bodyController.add(leftover);
    },
    onDone: () {
      if (!headParsed) {
        failOrFallback(buffer.toBytes());
      } else {
        bodyController.close();
      }
    },
    onError: (Object e, StackTrace st) {
      if (!headCompleter.isCompleted) headCompleter.completeError(e);
      if (!bodyController.isClosed) {
        bodyController.addError(e);
        bodyController.close();
      }
    },
    cancelOnError: true,
  );

  // Propagate client back-pressure to the interpreter output.
  bodyController
    ..onPause = sub.pause
    ..onResume = sub.resume
    ..onCancel = sub.cancel;

  return headCompleter.future.then(
    (head) => PhpResponse(
      statusCode: head.statusCode,
      reasonPhrase: head.reasonPhrase,
      headers: head.headers,
      body: bodyController.stream,
    ),
  );
}

class _CgiHead {
  _CgiHead(this.statusCode, this.reasonPhrase, this.headers);
  _CgiHead.rawBody()
      : statusCode = 200,
        reasonPhrase = 'OK',
        headers = const {};
  final int statusCode;
  final String reasonPhrase;
  final Map<String, List<String>> headers;
}

/// Parses the CGI header block, tolerating a leaked startup-warning preamble
/// (Apache reports these as "malformed header from script").
_CgiHead _parseHead(List<int> headerBytes, String logTag) {
  final headerText = utf8.decode(headerBytes, allowMalformed: true);
  final headers = <String, List<String>>{};
  var statusCode = 200;
  var reasonPhrase = 'OK';

  final lines = const LineSplitter().convert(headerText);

  var first = 0;
  while (first < lines.length) {
    final line = lines[first].trimRight();
    if (line.isEmpty) break;
    final colon = line.indexOf(':');
    if (colon > 0 && _isValidHeaderName(line.substring(0, colon).trim())) break;
    first++;
  }
  if (first == lines.length) return _CgiHead.rawBody();
  if (first > 0) {
    stderr.writeln('[$logTag] discarded leaked preamble before headers:\n'
        '${lines.take(first).join('\n')}');
  }

  for (final rawLine in lines.skip(first)) {
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

  return _CgiHead(statusCode, reasonPhrase, headers);
}

bool _isValidHeaderName(String name) {
  if (name.isEmpty) return false;
  for (final code in name.codeUnits) {
    final isTokenChar = (code >= 0x30 && code <= 0x39) ||
        (code >= 0x41 && code <= 0x5A) ||
        (code >= 0x61 && code <= 0x7A) ||
        '!#\$%&\'*+-.^_`|~'.contains(String.fromCharCode(code));
    if (!isTokenChar) return false;
  }
  return true;
}

class _Separator {
  _Separator(this.start, this.end);
  final int start;
  final int end;
}

/// Finds the blank line separating CGI headers from the body (`\r\n\r\n` or
/// `\n\n`), returning the byte range of the separator itself.
_Separator? _findHeaderBodySeparator(List<int> bytes) {
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] == 0x0A && i + 1 < bytes.length && bytes[i + 1] == 0x0A) {
      return _Separator(i, i + 2);
    }
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

/// Normalizes a script path for diagnostics (used by backends when reporting
/// which script failed).
String shortScript(String path) => p.basename(path);
