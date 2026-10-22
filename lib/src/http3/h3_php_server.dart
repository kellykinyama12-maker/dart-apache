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

  /// Our connection-ID length (bytes), needed to parse short-header DCIDs.
  static const int _cidLength = 8;

  /// True once a graceful drain has started (no new connections accepted).
  bool _draining = false;

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
    final socket = _socket;
    if (graceful && socket != null) {
      _draining = true;
      final active = _sessions.values.toSet();
      // GOAWAY: ask clients to stop opening new request streams.
      for (final session in active) {
        final h3 = session.h3;
        if (h3 != null) {
          h3.sendGoAway(session.maxStreamId < 0 ? 0 : session.maxStreamId + 4);
          _txAll(session);
        }
      }
      // Let in-flight requests finish (bounded drain window).
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline) &&
          active.any((s) => s.inFlight > 0)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      // CONNECTION_CLOSE (H3_NO_ERROR) on each connection.
      for (final session in active) {
        session.conn.closeApplication(appErrorCode: 0x100, reason: 'shutdown');
        _txAll(session);
      }
    }
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

    // Route by Destination Connection ID (not source address): a client that
    // migrates to a new address/port keeps the same DCID, so it stays on the
    // same session.
    final dcid = _routeDcid(datagram.data);
    var session = dcid == null ? null : _sessions[_hex(dcid)];
    if (session == null) {
      if (_draining) return; // refuse new connections while draining
      session = _acceptNewSession(datagram);
      if (session == null) return;
    } else if (session.addr.address != datagram.address.address ||
        session.port != datagram.port) {
      _log('connection migrated to '
          '${datagram.address.address}:${datagram.port}');
      session.addr = datagram.address;
      session.port = datagram.port;
    }

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
      _removeSession(session);
      return;
    }

    if (session.driver.handshakeComplete) {
      session.h3 ??= H3Connection.server(session.conn);
      _pumpH3(session);
    }

    _txAll(session);
  }

  /// Extracts the Destination Connection ID used to route a datagram to its
  /// session: from the long-header DCID field, or the fixed-length short-header
  /// DCID.
  Uint8List? _routeDcid(List<int> data) {
    if (data.isEmpty) return null;
    if ((data[0] & 0x80) != 0) {
      // Long header: first, version(4), dcidLen(1), dcid...
      if (data.length < 6) return null;
      final len = data[5];
      if (len == 0 || data.length < 6 + len) return null;
      return Uint8List.fromList(data.sublist(6, 6 + len));
    }
    // Short header: dcid is our fixed CID length right after the first byte.
    if (data.length < 1 + _cidLength) return null;
    return Uint8List.fromList(data.sublist(1, 1 + _cidLength));
  }

  String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  void _removeSession(_Session session) {
    for (final cid in session.cids) {
      _sessions.remove(cid);
    }
  }

  _Session? _acceptNewSession(Datagram datagram) {
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
    // Register under the client's initial DCID (matches Initial retransmits)
    // and our SCID (matches Handshake / 1-RTT packets).
    session.cids
      ..add(_hex(clientDcid))
      ..add(_hex(serverScid));
    _sessions[_hex(clientDcid)] = session;
    _sessions[_hex(serverScid)] = session;
    _log('new session ${_hex(serverScid)}');
    return session;
  }

  void _pumpH3(_Session session) {
    H3Event? event;
    while ((event = session.h3!.pollEvent()) != null) {
      switch (event) {
        case final H3HeadersEvent he:
          // WebTransport Extended CONNECT (stream stays open, fin=false).
          if (_tryWebTransport(session, he)) break;
          if (he.streamId > session.maxStreamId) {
            session.maxStreamId = he.streamId;
          }
          final req = session.reqs.putIfAbsent(he.streamId, _ReqState.new);
          req.headers = he.headers;
          if (he.fin) _dispatch(session, he.streamId, req);
        case H3DataEvent(:final streamId, :final data, :final fin):
          final req = session.reqs.putIfAbsent(streamId, _ReqState.new);
          req.body.add(data);
          if (fin) _dispatch(session, streamId, req);
        case H3FinishedEvent(:final streamId):
          final req = session.reqs[streamId];
          if (req != null) _dispatch(session, streamId, req);
        case H3WebTransportUniStreamEvent(
          :final sessionId,
          :final data,
          :final fin,
        ):
          _echoWtUniStream(session, sessionId, data, fin);
        case H3WebTransportBidiStreamEvent(
          :final streamId,
          :final sessionId,
          :final data,
          :final fin,
        ):
          _echoWtBidiStream(session, streamId, sessionId, data, fin);
        default:
          break;
      }
    }
    _echoWebTransport(session);
  }

  /// Accepts a WebTransport session on the configured path, or rejects it on
  /// another path. Returns true if [he] was an Extended CONNECT for
  /// WebTransport (handled here, not as a normal request).
  bool _tryWebTransport(_Session session, H3HeadersEvent he) {
    final wtPath = config.wtPath;
    if (wtPath == null) return false;
    final wt = WebTransportSession.acceptIfWebTransport(session.h3!, he);
    if (wt == null) return false;

    final path = _headerValue(he.headers, ':path');
    if (path != wtPath) {
      wt.reject(status: 404);
      return true;
    }
    wt.accept();
    session.wt = wt;
    _openWtGreetingStream(session, wt);
    _log('WebTransport session accepted on $wtPath (stream ${he.streamId})');
    return true;
  }

  /// Pushes a server-initiated unidirectional WebTransport stream carrying a
  /// greeting, so the browser receives it via `incomingUnidirectionalStreams`.
  void _openWtGreetingStream(_Session session, WebTransportSession wt) {
    final uniId = session.h3!.allocLocalUniStreamId();
    final prefix = encodeWtUniStreamPrefix(wt.streamId);
    final payload = 'hello from dart-apache webtransport\n'.codeUnits;
    session.conn.streamSend(
      uniId,
      Uint8List.fromList([...prefix, ...payload]),
      fin: true,
    );
  }

  /// Echoes any received WebTransport datagrams back to the client.
  void _echoWebTransport(_Session session) {
    final wt = session.wt;
    if (wt == null) return;
    for (Uint8List? dg = wt.recvDatagram(); dg != null; dg = wt.recvDatagram()) {
      wt.sendDatagram(dg);
    }
  }

  /// Echoes an inbound (client-initiated) WebTransport unidirectional stream
  /// back to the browser on a fresh server-initiated WT uni stream, so the
  /// round trip is observable via `incomingUnidirectionalStreams`.
  void _echoWtUniStream(
    _Session session,
    int sessionId,
    Uint8List data,
    bool fin,
  ) {
    if (session.wt == null || data.isEmpty) return;
    final uniId = session.h3!.allocLocalUniStreamId();
    final prefix = encodeWtUniStreamPrefix(sessionId);
    session.conn.streamSend(
      uniId,
      Uint8List.fromList([...prefix, ...data]),
      fin: true,
    );
    _log(
      'WebTransport uni stream echo: ${data.length} bytes '
      '(session $sessionId, fin=$fin)',
    );
  }

  /// Echoes an inbound (client-initiated) WebTransport bidirectional stream
  /// back on the same stream, so the browser observes the reply on the
  /// bidi stream's readable side.
  void _echoWtBidiStream(
    _Session session,
    int streamId,
    int sessionId,
    Uint8List data,
    bool fin,
  ) {
    if (session.wt == null || data.isEmpty) return;
    session.conn.streamSend(streamId, data, fin: true);
    _log(
      'WebTransport bidi stream echo: ${data.length} bytes '
      '(stream $streamId, session $sessionId, fin=$fin)',
    );
  }

  String? _headerValue(List<H3Header> headers, String name) {
    for (final h in headers) {
      if (String.fromCharCodes(h.name) == name) {
        return String.fromCharCodes(h.value);
      }
    }
    return null;
  }

  /// Handles one completed request by adapting it to a [ServerExchange] and
  /// running the shared pipeline, then flushing any resulting QUIC packets.
  Future<void> _dispatch(_Session session, int streamId, _ReqState req) async {
    if (req.responded) return;
    req.responded = true;
    session.inFlight++;

    final exchange = _H3Exchange(this, session, streamId, req);
    try {
      await _pipeline.serve(exchange);
    } catch (e) {
      _log('request error: $e');
    } finally {
      session.inFlight--;
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
  InternetAddress addr;
  int port;
  H3Connection? h3;
  final Map<int, _ReqState> reqs = {};

  /// Active WebTransport session on this connection, if any.
  WebTransportSession? wt;

  /// CID keys this session is registered under (client DCID + our SCID).
  final List<String> cids = [];

  /// Requests currently being served (for graceful-drain accounting).
  int inFlight = 0;

  /// Highest request stream id seen (for the GOAWAY cutoff).
  int maxStreamId = -1;
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
        case ':authority':
          _authority = value;
        case ':scheme':
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
  String _authority = '';

  @override
  String get method => _method;

  @override
  Uri get uri => Uri.parse(_target);

  @override
  String get protocolVersion => '3';

  @override
  String get scheme => 'https';

  @override
  String get authority => _authority;

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
