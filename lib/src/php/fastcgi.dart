import 'dart:async';
import 'dart:convert';
import 'dart:io' hide BytesBuilder;
import 'dart:typed_data';

import '../config.dart';
import '../pipeline/server_exchange.dart';
import 'cgi_params.dart';
import 'php_backend.dart';

/// FastCGI record types (RFC-less spec from the FastCGI 1.0 document).
class FcgiType {
  static const beginRequest = 1;
  static const abortRequest = 2;
  static const endRequest = 3;
  static const params = 4;
  static const stdin = 5;
  static const stdout = 6;
  static const stderr = 7;
  static const data = 8;
}

const int _fcgiVersion = 1;
const int _fcgiResponder = 1;
const int _fcgiMaxContent = 0xFFFF;

/// Encodes one FastCGI record (header + content + padding) for [requestId].
Uint8List encodeFcgiRecord(int type, int requestId, List<int> content) {
  final length = content.length;
  // Pad content to an 8-byte boundary (recommended by the spec).
  final padding = (8 - (length % 8)) % 8;
  final out = Uint8List(8 + length + padding);
  out[0] = _fcgiVersion;
  out[1] = type;
  out[2] = (requestId >> 8) & 0xFF;
  out[3] = requestId & 0xFF;
  out[4] = (length >> 8) & 0xFF;
  out[5] = length & 0xFF;
  out[6] = padding;
  out[7] = 0;
  out.setRange(8, 8 + length, content);
  return out;
}

/// Encodes a FastCGI `BEGIN_REQUEST` body (role + flags).
Uint8List encodeBeginRequest({required int role, required int flags}) {
  final body = Uint8List(8);
  body[0] = (role >> 8) & 0xFF;
  body[1] = role & 0xFF;
  body[2] = flags;
  return body;
}

/// Encodes a single FastCGI name-value pair with 1- or 4-byte length prefixes.
List<int> encodeFcgiNameValue(String name, String value) {
  final nameBytes = utf8.encode(name);
  final valueBytes = utf8.encode(value);
  final out = BytesBuilder(copy: false);
  _writeLength(out, nameBytes.length);
  _writeLength(out, valueBytes.length);
  out.add(nameBytes);
  out.add(valueBytes);
  return out.toBytes();
}

void _writeLength(BytesBuilder out, int length) {
  if (length < 128) {
    out.addByte(length);
  } else {
    out.add([
      ((length >> 24) & 0xFF) | 0x80,
      (length >> 16) & 0xFF,
      (length >> 8) & 0xFF,
      length & 0xFF,
    ]);
  }
}

/// Encodes a parameter map into FastCGI `PARAMS` content.
Uint8List encodeFcgiParams(Map<String, String> params) {
  final out = BytesBuilder(copy: false);
  params.forEach((name, value) => out.add(encodeFcgiNameValue(name, value)));
  return out.toBytes();
}

/// A decoded FastCGI record.
class FcgiRecord {
  FcgiRecord(this.type, this.requestId, this.content);
  final int type;
  final int requestId;
  final Uint8List content;
}

/// Incrementally decodes FastCGI records from a byte stream. Feed bytes with
/// [addBytes]; it returns any complete records parsed so far.
class FcgiRecordDecoder {
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  List<FcgiRecord> addBytes(List<int> chunk) {
    _buffer.add(chunk);
    var bytes = _buffer.toBytes();
    final records = <FcgiRecord>[];
    var offset = 0;

    while (bytes.length - offset >= 8) {
      final contentLength = (bytes[offset + 4] << 8) | bytes[offset + 5];
      final padding = bytes[offset + 6];
      final total = 8 + contentLength + padding;
      if (bytes.length - offset < total) break;

      final type = bytes[offset + 1];
      final requestId = (bytes[offset + 2] << 8) | bytes[offset + 3];
      final content = Uint8List.sublistView(
        bytes,
        offset + 8,
        offset + 8 + contentLength,
      );
      records.add(FcgiRecord(type, requestId, content));
      offset += total;
    }

    // Keep the unparsed remainder buffered.
    final remainder = bytes.sublist(offset);
    _buffer.clear();
    if (remainder.isNotEmpty) _buffer.add(remainder);
    return records;
  }
}

/// Executes PHP via FastCGI against a PHP-FPM listener (TCP `host:port` or a
/// Unix socket `unix:/path`). Uses one connection per request (FPM workers stay
/// persistent regardless); the request body and response stream with
/// back-pressure.
class FastCgiBackend implements PhpBackend {
  FastCgiBackend(this.config) : _target = _FcgiTarget.parse(config.phpFpm!);

  final ServerConfig config;
  final _FcgiTarget _target;

  static const int _requestId = 1;

  @override
  Future<PhpResponse> handle({
    required ServerExchange exchange,
    required String scriptFilename,
    required String scriptName,
    required String pathInfo,
  }) async {
    final params = buildCgiParams(
      config: config,
      exchange: exchange,
      scriptFilename: scriptFilename,
      scriptName: scriptName,
      pathInfo: pathInfo,
    );

    final Socket socket;
    try {
      socket = await _target.connect();
    } on SocketException catch (e) {
      throw CgiException('FastCGI connect to ${_target.describe()} failed: $e');
    }

    // BEGIN_REQUEST (flags=0 -> server closes the connection when done).
    socket.add(encodeFcgiRecord(
      FcgiType.beginRequest,
      _requestId,
      encodeBeginRequest(role: _fcgiResponder, flags: 0),
    ));

    // PARAMS, terminated by an empty PARAMS record.
    final paramBytes = encodeFcgiParams(params);
    for (final chunk in _chunked(paramBytes)) {
      socket.add(encodeFcgiRecord(FcgiType.params, _requestId, chunk));
    }
    socket.add(encodeFcgiRecord(FcgiType.params, _requestId, const []));

    // STDIN: stream the request body, terminated by an empty STDIN record.
    unawaited(_pumpStdin(exchange.body, socket));

    // Decode STDOUT into a byte stream for the shared CGI parser; log STDERR.
    final stdoutController = StreamController<List<int>>();
    final stderrBytes = <int>[];
    final decoder = FcgiRecordDecoder();
    var ended = false;

    final sub = socket.listen(
      (data) {
        for (final record in decoder.addBytes(data)) {
          switch (record.type) {
            case FcgiType.stdout:
              if (record.content.isNotEmpty) stdoutController.add(record.content);
            case FcgiType.stderr:
              stderrBytes.addAll(record.content);
            case FcgiType.endRequest:
              ended = true;
          }
        }
      },
      onDone: () {
        if (!stdoutController.isClosed) stdoutController.close();
      },
      onError: (Object e, StackTrace st) {
        if (!stdoutController.isClosed) {
          stdoutController.addError(e);
          stdoutController.close();
        }
      },
      cancelOnError: true,
    );

    // Pause/resume the socket read with downstream back-pressure.
    stdoutController
      ..onPause = sub.pause
      ..onResume = sub.resume
      ..onCancel = () async {
        await sub.cancel();
        socket.destroy();
      };

    return parseCgiStream(
      stdoutController.stream,
      logTag: 'php-fpm',
      onEmpty: () async {
        final message = utf8.decode(stderrBytes, allowMalformed: true).trim();
        return 'FastCGI produced no output for '
            '${shortScript(scriptFilename)}'
            '${ended ? '' : ' (connection closed early)'}'
            '${message.isEmpty ? '' : ': $message'}';
      },
    );
  }

  Future<void> _pumpStdin(Stream<List<int>> body, Socket socket) async {
    try {
      await for (final chunk in body) {
        for (final part in _chunked(chunk)) {
          socket.add(encodeFcgiRecord(FcgiType.stdin, _requestId, part));
        }
      }
    } catch (_) {
      // Client aborted; fall through to close STDIN.
    }
    socket.add(encodeFcgiRecord(FcgiType.stdin, _requestId, const []));
  }

  /// Splits [bytes] into FastCGI-content-sized chunks (<= 65535 bytes).
  Iterable<List<int>> _chunked(List<int> bytes) sync* {
    if (bytes.isEmpty) return;
    for (var i = 0; i < bytes.length; i += _fcgiMaxContent) {
      final end = (i + _fcgiMaxContent < bytes.length)
          ? i + _fcgiMaxContent
          : bytes.length;
      yield bytes.sublist(i, end);
    }
  }

  @override
  Future<void> close() async {}
}

/// A parsed FastCGI target: either a TCP endpoint or a Unix domain socket.
class _FcgiTarget {
  _FcgiTarget.tcp(this.host, this.port)
      : unixPath = null;
  _FcgiTarget.unix(this.unixPath)
      : host = null,
        port = null;

  final String? host;
  final int? port;
  final String? unixPath;

  factory _FcgiTarget.parse(String spec) {
    if (spec.startsWith('unix:')) {
      return _FcgiTarget.unix(spec.substring('unix:'.length));
    }
    final colon = spec.lastIndexOf(':');
    if (colon <= 0) {
      throw ArgumentError('Invalid --php-fpm target: "$spec" '
          '(expected host:port or unix:/path)');
    }
    final host = spec.substring(0, colon);
    final port = int.tryParse(spec.substring(colon + 1));
    if (port == null) {
      throw ArgumentError('Invalid --php-fpm port in "$spec"');
    }
    return _FcgiTarget.tcp(host, port);
  }

  Future<Socket> connect() {
    if (unixPath != null) {
      return Socket.connect(
        InternetAddress(unixPath!, type: InternetAddressType.unix),
        0,
      );
    }
    return Socket.connect(host!, port!);
  }

  String describe() => unixPath != null ? 'unix:$unixPath' : '$host:$port';
}
