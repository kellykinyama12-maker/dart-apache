import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_quiche/dart_quiche.dart' hide Stream;
// installInitialKeys / Epoch live in this internal library (not re-exported).
// ignore: implementation_imports
import 'package:dart_quiche/src/handshake_keys.dart';

import '../config.dart';
import '../mime_types.dart';
import '../php/php_backend.dart';
import '../request_resolver.dart';

/// An experimental HTTP/3 (QUIC) server that serves static files and runs PHP
/// via `php-cgi`, using the pure-Dart `dart_quiche` transport. This is the
/// Phase 4 proof-of-concept: it terminates QUIC + TLS 1.3, speaks HTTP/3, and
/// maps each request onto the same document-root resolution and CGI execution
/// used by the HTTP/1.1 server.
class Http3PhpServer {
  Http3PhpServer(this.config, {this.verbose = false})
      : _resolver = RequestResolver(config);

  final ServerConfig config;
  final bool verbose;
  final RequestResolver _resolver;

  late final RawDatagramSocket _socket;
  late final _cert = generateSelfSignedP256Cert();
  final Map<String, _Session> _sessions = {};
  final Random _rng = Random.secure();

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(
      InternetAddress(config.address),
      config.port,
    );

    stdout.writeln('dart-apache HTTP/3 serving "${config.documentRoot}"');
    stdout.writeln('Listening on https://${config.address}:${config.port}/ '
        '(QUIC/UDP)');
    stdout.writeln('PHP handler: ${config.phpCgiPath}');

    _socket.listen(_onSocketEvent);
  }

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _socket.receive();
    if (datagram == null) return;

    final key = '${datagram.address.address}:${datagram.port}';
    var session = _sessions[key];
    session ??= _acceptNewSession(datagram, key);
    if (session == null) return;

    try {
      session.conn.recvDatagram(datagram.data);
    } on QuicError catch (e) {
      _log('recv QuicError: $e');
    } catch (e) {
      _log('recv threw: $e');
    }

    try {
      session.driver.poll();
    } catch (e) {
      _log('driver poll threw: $e');
      _sessions.remove(key);
      return;
    }

    if (session.driver.handshakeComplete) {
      if (session.h3 == null) {
        _log('handshake complete with $key');
        session.h3 = H3Connection.server(session.conn);
      }
      _pumpH3(session);
    }

    _txAll(session);
  }

  _Session? _acceptNewSession(Datagram datagram, String key) {
    final badVersion = Connection.unsupportedInitialVersion(datagram.data);
    if (badVersion != null) {
      final hdr = Header.fromBytes(Octets.withSlice(datagram.data), 0);
      final vn = Connection.versionNegotiationPacket(
        clientDcid: hdr.dcid.bytes,
        clientScid: hdr.scid.bytes,
        rng: _rng,
      );
      _socket.send(vn, datagram.address, datagram.port);
      return null;
    }
    if (datagram.data.isEmpty || (datagram.data[0] & 0x80) == 0) {
      return null; // not a long-header (Initial) packet
    }

    final Header hdr;
    try {
      hdr = Header.fromBytes(Octets.withSlice(datagram.data), 8);
    } catch (e) {
      _log('drop: header parse: $e');
      return null;
    }
    if (hdr.ty != PacketType.initial) return null;

    final clientDcid = hdr.dcid.bytes;
    final clientScid = hdr.scid.bytes;
    final serverScid =
        Uint8List.fromList(List.generate(8, (_) => _rng.nextInt(256)));

    final conn = Connection(
      localCid: serverScid,
      isServer: true,
      peerCid: clientScid,
    )..spaces.installInitialKeys(
        cid: clientDcid,
        version: protocolVersionV1,
        isServer: true,
      );
    final driver = TlsServerDriver(
      conn: conn,
      serverCert: _cert,
      originalDcid: clientDcid,
    );
    final session = _Session(
      conn: conn,
      driver: driver,
      addr: datagram.address,
      port: datagram.port,
    );
    _sessions[key] = session;
    _log('new session $key');
    return session;
  }

  void _pumpH3(_Session session) {
    H3Event? event;
    while ((event = session.h3!.pollEvent()) != null) {
      switch (event) {
        case H3HeadersEvent(:final streamId, :final headers, :final fin):
          final req = session.reqs.putIfAbsent(streamId, _ReqState.new);
          req.headers = headers;
          if (fin) _dispatch(session, streamId, req);
        case H3DataEvent(:final streamId, :final data, :final fin):
          final req = session.reqs.putIfAbsent(streamId, _ReqState.new);
          req.body.add(data);
          if (fin) _dispatch(session, streamId, req);
        case H3FinishedEvent(:final streamId):
          final req = session.reqs[streamId];
          if (req != null) _dispatch(session, streamId, req);
        default:
          break;
      }
    }
  }

  /// Handles one completed request: resolve, execute, and respond — then flush
  /// any resulting QUIC packets.
  Future<void> _dispatch(_Session session, int streamId, _ReqState req) async {
    if (req.responded) return;
    req.responded = true;

    try {
      final request = _parseRequest(req);
      final response = await _serve(session, request);
      _send(session, streamId, response);
    } catch (e) {
      _log('request error: $e');
      _send(
        session,
        streamId,
        _H3Response.text(500, 'Internal Server Error\n'),
      );
    }
    _txAll(session);
  }

  Future<_H3Response> _serve(_Session session, _H3Request request) async {
    final resolution = _resolver.resolve(request.path);
    switch (resolution.kind) {
      case ResolutionKind.staticFile:
        final bytes = await File(resolution.filePath).readAsBytes();
        return _H3Response(
          200,
          {'content-type': mimeTypeFor(resolution.filePath)},
          bytes,
        );
      case ResolutionKind.phpScript:
        return _runPhp(session, request, resolution);
      case ResolutionKind.forbidden:
        return _H3Response.text(403, 'Forbidden\n');
      case ResolutionKind.notFound:
        return _H3Response.text(404, 'Not Found\n');
    }
  }

  Future<_H3Response> _runPhp(
    _Session session,
    _H3Request request,
    Resolution resolution,
  ) async {
    final env = _buildCgiEnv(session, request, resolution);
    final process = await Process.start(
      config.phpCgiPath,
      const [],
      environment: env,
      includeParentEnvironment: false,
    );

    if (request.body.isNotEmpty) process.stdin.add(request.body);
    unawaited(process.stdin.close().catchError((_) {}));

    final stderrBytes = <int>[];
    final stderrDone = process.stderr.forEach(stderrBytes.addAll);

    final php = await parseCgiStream(
      process.stdout,
      logTag: 'php-cgi',
      onEmpty: () async {
        await stderrDone;
        final code = await process.exitCode;
        return 'php-cgi exited with code $code';
      },
    );

    final body = await _collect(php.body);
    final headers = <String, String>{};
    php.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(', ');
    });
    headers.putIfAbsent('content-type', () => 'text/html; charset=UTF-8');
    return _H3Response(php.statusCode, headers, body);
  }

  Map<String, String> _buildCgiEnv(
    _Session session,
    _H3Request request,
    Resolution resolution,
  ) {
    final env = <String, String>{
      'GATEWAY_INTERFACE': 'CGI/1.1',
      'SERVER_SOFTWARE': config.serverSoftware,
      'SERVER_PROTOCOL': 'HTTP/3.0',
      'SERVER_NAME': config.serverName,
      'SERVER_ADDR': config.address,
      'SERVER_PORT': '${config.port}',
      'DOCUMENT_ROOT': config.documentRoot,
      'REQUEST_METHOD': request.method,
      'REQUEST_URI': request.requestUri,
      'QUERY_STRING': request.query,
      'SCRIPT_NAME': resolution.scriptName,
      'SCRIPT_FILENAME': resolution.filePath,
      'PATH_TRANSLATED': resolution.filePath,
      'REMOTE_ADDR': session.addr.address,
      'REMOTE_PORT': '${session.port}',
      'HTTPS': 'on',
      'REDIRECT_STATUS': '200',
    };
    if (resolution.pathInfo.isNotEmpty) {
      env['PATH_INFO'] = resolution.pathInfo;
    }
    final contentType = request.headers['content-type'];
    if (contentType != null) env['CONTENT_TYPE'] = contentType;
    if (request.body.isNotEmpty) {
      env['CONTENT_LENGTH'] = '${request.body.length}';
    }
    request.headers.forEach((name, value) {
      final key = 'HTTP_${name.toUpperCase().replaceAll('-', '_')}';
      env[key] = value;
    });
    return env;
  }

  void _send(_Session session, int streamId, _H3Response response) {
    final headers = <H3Header>[
      _h3Header(':status', '${response.statusCode}'),
      _h3Header('content-length', '${response.body.length}'),
      _h3Header('server', config.serverSoftware),
    ];
    response.headers.forEach((name, value) {
      if (name == 'content-length' || name == ':status') return;
      headers.add(_h3Header(name, value));
    });

    session.h3!.sendResponse(
      streamId,
      headers,
      body: Uint8List.fromList(response.body),
      fin: true,
    );
    _log('→ stream $streamId: ${response.statusCode} '
        '(${response.body.length}B)');
  }

  void _txAll(_Session session) {
    while (true) {
      Uint8List? pkt;
      for (final epoch in const [
        Epoch.initial,
        Epoch.handshake,
        Epoch.application,
      ]) {
        pkt = session.conn.send(epoch);
        if (pkt != null) break;
      }
      if (pkt == null) break;
      _socket.send(pkt, session.addr, session.port);
    }
  }

  _H3Request _parseRequest(_ReqState req) {
    var method = 'GET';
    var target = '/';
    final headers = <String, String>{};
    for (final h in req.headers ?? const <H3Header>[]) {
      final name = String.fromCharCodes(h.name);
      final value = String.fromCharCodes(h.value);
      switch (name) {
        case ':method':
          method = value;
        case ':path':
          target = value;
        case ':scheme':
        case ':authority':
        case ':protocol':
          break; // other pseudo-headers are not CGI vars
        default:
          headers[name] = value;
      }
    }
    final q = target.indexOf('?');
    final path = q < 0 ? target : target.substring(0, q);
    final query = q < 0 ? '' : target.substring(q + 1);
    return _H3Request(
      method: method,
      path: Uri.decodeComponent(path),
      query: query,
      requestUri: target,
      headers: headers,
      body: req.body.takeBytes(),
    );
  }

  H3Header _h3Header(String name, String value) => H3Header(
        Uint8List.fromList(name.codeUnits),
        Uint8List.fromList(value.codeUnits),
      );

  Future<List<int>> _collect(Stream<List<int>> stream) async {
    final out = <int>[];
    await for (final chunk in stream) {
      out.addAll(chunk);
    }
    return out;
  }

  void _log(String message) {
    if (verbose) stdout.writeln('  $message');
  }
}

class _Session {
  _Session({
    required this.conn,
    required this.driver,
    required this.addr,
    required this.port,
  });

  final Connection conn;
  final TlsServerDriver driver;
  final InternetAddress addr;
  final int port;
  H3Connection? h3;
  final Map<int, _ReqState> reqs = {};
}

class _ReqState {
  List<H3Header>? headers;
  final BytesBuilder body = BytesBuilder(copy: false);
  bool responded = false;
}

class _H3Request {
  _H3Request({
    required this.method,
    required this.path,
    required this.query,
    required this.requestUri,
    required this.headers,
    required this.body,
  });

  final String method;
  final String path;
  final String query;
  final String requestUri;
  final Map<String, String> headers;
  final List<int> body;
}

class _H3Response {
  _H3Response(this.statusCode, this.headers, this.body);

  _H3Response.text(int status, String text)
      : statusCode = status,
        headers = {'content-type': 'text/plain; charset=utf-8'},
        body = text.codeUnits;

  final int statusCode;
  final Map<String, String> headers;
  final List<int> body;
}
