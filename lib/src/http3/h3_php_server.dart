import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_quiche/dart_quiche.dart' hide Stream;
// installInitialKeys / Epoch live in this internal library (not re-exported).
// ignore: implementation_imports
import 'package:dart_quiche/src/handshake_keys.dart';

import '../config.dart';
import '../pipeline/request_pipeline.dart';
import '../pipeline/server_exchange.dart';
import '../worker_server.dart';

/// An experimental HTTP/3 (QUIC) server that serves static files and runs PHP
/// using the pure-Dart `dart_quiche` transport. It terminates QUIC + TLS 1.3,
/// speaks HTTP/3, and adapts each request to the shared [RequestPipeline] — the
/// same handlers the HTTP/1.1 server uses.
class Http3PhpServer implements WorkerServer {
  Http3PhpServer(this.config, {this.verbose = false})
      : _pipeline = RequestPipeline(config);

  final ServerConfig config;
  final bool verbose;
  final RequestPipeline _pipeline;

  RawDatagramSocket? _socket;
  late final EcdsaCert _cert;
  final Map<String, _Session> _sessions = {};
  final Random _rng = Random.secure();

  /// This worker's index (0..N-1), encoded into server-chosen connection IDs
  /// so datagrams can later be routed to the owning worker.
  int _workerId = 0;

  /// A forked zone that swallows `print()` so the vendored `dart_quiche` cert
  /// and TLS code don't spam stdout. Our own logging uses `stdout.writeln`,
  /// which bypasses the zone's print handler and is unaffected.
  late final Zone _quietZone = Zone.current.fork(
    specification: ZoneSpecification(print: (_, _, _, _) {}),
  );

  @override
  Future<void> start({int? workerId}) async {
    _workerId = workerId ?? 0;
    _cert = _quietZone.run(_buildCert);

    // `reusePort` (SO_REUSEPORT on Linux/BSD) lets every worker isolate bind the
    // same UDP port; the kernel load-balances datagrams by 4-tuple, giving
    // per-connection affinity for non-migrating clients. Not supported on
    // Windows, so it is only requested off-Windows.
    final socket = await RawDatagramSocket.bind(
      InternetAddress(config.address),
      config.port,
      reuseAddress: true,
      reusePort: !Platform.isWindows,
    );
    _socket = socket;

    if (workerId == null) {
      stdout.writeln('dart-apache HTTP/3 serving "${config.documentRoot}"');
      stdout.writeln('Listening on https://${config.address}:${config.port}/ '
          '(QUIC/UDP)');
      stdout.writeln('PHP handler: ${config.phpFpm ?? config.phpCgiPath}');
    } else {
      stdout.writeln('[worker $workerId] ready (h3)');
    }

    // Run the datagram handler in the quiet zone so handshake debug prints are
    // suppressed (callbacks inherit the zone active at listen() time).
    _quietZone.run(() => socket.listen(_onSocketEvent));
  }

  @override
  Future<void> stop({bool graceful = false}) async {
    // QUIC is connectionless at the socket layer; closing the socket stops new
    // datagrams. (GOAWAY-based draining is tracked as H3-7.)
    _socket?.close();
    _socket = null;
    _sessions.clear();
    await _pipeline.close();
  }

  /// Builds the server certificate: a real PEM cert/key when configured, or a
  /// generated self-signed cert in `--dev` mode.
  EcdsaCert _buildCert() {
    final certPath = config.tlsCertPath;
    final keyPath = config.tlsKeyPath;
    if (certPath != null && keyPath != null) {
      return loadEcdsaCertFromPem(
        certPem: File(certPath).readAsStringSync(),
        keyPem: File(keyPath).readAsStringSync(),
      );
    }
    if (config.devMode) return generateSelfSignedP256Cert();
    throw StateError(
      'HTTP/3 requires a TLS certificate: pass --tls-cert and --tls-key, '
      'or --dev to use a generated self-signed certificate.',
    );
  }

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _socket;
    if (socket == null) return;
    final datagram = socket.receive();
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
      _socket?.send(vn, datagram.address, datagram.port);
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
    // Tag the first CID byte with this worker's id so datagrams can later be
    // routed to the owning worker (CID-affinity groundwork).
    serverScid[0] = _workerId & 0xFF;

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

  /// Handles one completed request by adapting it to a [ServerExchange] and
  /// running the shared pipeline, then flushing any resulting QUIC packets.
  Future<void> _dispatch(_Session session, int streamId, _ReqState req) async {
    if (req.responded) return;
    req.responded = true;

    final exchange = _H3Exchange(this, session, streamId, req);
    try {
      await _pipeline.serve(exchange);
    } catch (e) {
      _log('request error: $e');
    }
    _txAll(session);
  }

  /// Sends the response HEADERS frame (QPACK-encoded). [fin] closes the stream
  /// for headers-only / empty-body responses.
  void _sendHeaders(
    _Session session,
    int streamId,
    int status,
    Map<String, List<String>> headers, {
    required bool fin,
  }) {
    final h3Headers = <H3Header>[_h3Header(':status', '$status')];
    headers.forEach((name, values) {
      if (name == ':status') return;
      for (final value in values) {
        h3Headers.add(_h3Header(name, value));
      }
    });
    if (!headers.containsKey('server')) {
      h3Headers.add(_h3Header('server', config.serverSoftware));
    }
    session.h3!.sendResponse(streamId, h3Headers, fin: fin);
    _txAll(session);
  }

  /// Streams one body chunk (DATA frame) and flushes it to the socket, giving
  /// soft back-pressure as the source produces data.
  void _sendData(
    _Session session,
    int streamId,
    List<int> chunk, {
    required bool fin,
  }) {
    session.h3!.sendData(streamId, Uint8List.fromList(chunk), fin: fin);
    _txAll(session);
  }

  void _txAll(_Session session) {
    final socket = _socket;
    if (socket == null) return;
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
      socket.send(pkt, session.addr, session.port);
    }
  }

  H3Header _h3Header(String name, String value) => H3Header(
        Uint8List.fromList(name.codeUnits),
        Uint8List.fromList(value.codeUnits),
      );

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

/// Adapts a completed HTTP/3 request to the [ServerExchange] contract.
class _H3Exchange implements ServerExchange {
  _H3Exchange(this._server, this._session, this._streamId, _ReqState req)
      : _bodyBytes = req.body.takeBytes() {
    for (final h in req.headers ?? const <H3Header>[]) {
      final name = String.fromCharCodes(h.name);
      final value = String.fromCharCodes(h.value);
      switch (name) {
        case ':method':
          _method = value;
        case ':path':
          _target = value;
        case ':scheme':
        case ':authority':
        case ':protocol':
          break; // pseudo-headers are not CGI/request headers
        default:
          _headers[name.toLowerCase()] = value;
      }
    }
  }

  final Http3PhpServer _server;
  final _Session _session;
  final int _streamId;
  final List<int> _bodyBytes;
  final Map<String, String> _headers = {};
  String _method = 'GET';
  String _target = '/';

  @override
  String get method => _method;

  @override
  Uri get uri => Uri.parse(_target);

  @override
  String get protocolVersion => '3';

  @override
  String get scheme => 'https';

  @override
  String get protocol => 'h3';

  @override
  String get remoteAddress => _session.addr.address;

  @override
  int get remotePort => _session.port;

  @override
  int get contentLength => _bodyBytes.length;

  @override
  String? get contentType => _headers['content-type'];

  @override
  void forEachHeader(void Function(String name, String value) action) =>
      _headers.forEach(action);

  @override
  Stream<List<int>> get body =>
      _bodyBytes.isEmpty ? const Stream.empty() : Stream.value(_bodyBytes);

  @override
  ServerResponse respond() =>
      _H3ResponseSink(_server, _session, _streamId);
}

/// Streams a response over HTTP/3: HEADERS on the first body chunk, then a DATA
/// frame per chunk (each flushed to the socket), then FIN on close.
class _H3ResponseSink implements ServerResponse {
  _H3ResponseSink(this._server, this._session, this._streamId);

  final Http3PhpServer _server;
  final _Session _session;
  final int _streamId;
  final Map<String, List<String>> _headers = {};
  int _status = 200;
  bool _headersSent = false;

  @override
  int get statusCode => _status;

  @override
  void setStatus(int statusCode, [String? reasonPhrase]) => _status = statusCode;

  @override
  void setHeader(String name, String value) =>
      _headers.putIfAbsent(name.toLowerCase(), () => <String>[]).add(value);

  void _ensureHeaders() {
    if (_headersSent) return;
    _headersSent = true;
    _server._sendHeaders(_session, _streamId, _status, _headers, fin: false);
  }

  @override
  Future<void> addStream(Stream<List<int>> body) async {
    await for (final chunk in body) {
      _ensureHeaders();
      if (chunk.isNotEmpty) {
        _server._sendData(_session, _streamId, chunk, fin: false);
      }
    }
  }

  @override
  Future<void> close() async {
    if (_headersSent) {
      _server._sendData(_session, _streamId, const [], fin: true);
    } else {
      // Headers-only / empty body (e.g. HEAD, 304): close with the headers.
      _server._sendHeaders(_session, _streamId, _status, _headers, fin: true);
    }
  }
}
