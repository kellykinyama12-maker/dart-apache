import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_quiche/dart_quiche.dart' hide Stream;
// installInitialKeys / Epoch live in this internal library (not re-exported).
// ignore: implementation_imports
import 'package:dart_quiche/src/handshake_keys.dart';

import '../config.dart';
import '../pipeline/dart_handler.dart';
import '../pipeline/request_pipeline.dart';
import '../pipeline/server_exchange.dart';
import '../worker_server.dart';
import '../wt/ticket.dart';
import '../wt/wt_handler.dart';

/// An experimental HTTP/3 (QUIC) server that serves static files and runs PHP
/// using the pure-Dart `dart_quiche` transport. It terminates QUIC + TLS 1.3,
/// speaks HTTP/3, and adapts each request to the shared [RequestPipeline] — the
/// same handlers the HTTP/1.1 server uses.
class Http3PhpServer implements WorkerServer {
  Http3PhpServer(this.config, {this.verbose = false, DartApp? app})
      : _pipeline = RequestPipeline(config, app: app),
        _wtHandler = app?.wt;

  final ServerConfig config;
  final bool verbose;
  final RequestPipeline _pipeline;

  /// Optional native WebTransport handler. When set it owns every inbound WT
  /// message, taking precedence over the PHP bridge / echo. Null (the default)
  /// leaves the existing bridge/echo behavior byte-for-byte unchanged.
  final WtHandler? _wtHandler;


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
          :final streamId,
          :final sessionId,
          :final data,
          :final fin,
        ):
          _onWtUniData(session, streamId, sessionId, data, fin);
        case H3WebTransportBidiStreamEvent(
          :final streamId,
          :final sessionId,
          :final data,
          :final fin,
        ):
          _onWtBidiData(session, streamId, sessionId, data, fin);
        default:
          break;
      }
    }
    _drainWtDatagrams(session);
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
    // Capture the Cookie the browser sent on the WebTransport CONNECT so the
    // bridge can forward the Laravel session / XSRF-TOKEN to PHP.
    session.cookie = _headerValue(he.headers, 'cookie');
    session.wtConnect = WtConnect(
      path: path ?? wtPath,
      authority: _headerValue(he.headers, ':authority') ?? '',
      cookie: session.cookie,
      headers: _wtHeadersMap(he.headers),
    );
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

  /// Drains and dispatches any received WebTransport datagrams.
  void _drainWtDatagrams(_Session session) {
    final wt = session.wt;
    if (wt == null) return;
    for (Uint8List? dg = wt.recvDatagram();
        dg != null;
        dg = wt.recvDatagram()) {
      _handleWtDatagram(session, dg);
    }
  }

  /// Handles one inbound WebTransport datagram. Extension point for
  /// application protocols (e.g. ephemeral Livewire signals such as presence,
  /// typing, or cursor position). Datagrams are unreliable and unordered — use
  /// streams for state that must arrive. When [ServerConfig.wtBridgePath] is
  /// set the datagram is bridged through the PHP pipeline; otherwise echoed.
  void _handleWtDatagram(_Session session, Uint8List payload) {
    final handler = _wtHandler;
    if (handler != null) {
      final sessionId = session.wt?.streamId;
      if (sessionId == null) return;
      handler(
        _WtSessionImpl(this, session, sessionId, null),
        WtMessage(
          data: payload,
          isDatagram: true,
          sessionId: sessionId,
        ),
      );
      return;
    }
    final bridgePath = config.wtBridgePath;
    if (bridgePath != null) {
      unawaited(_bridgeWtDatagram(session, payload, bridgePath));
      return;
    }
    _sendWtDatagram(session, payload);
  }

  /// Bridges one WebTransport datagram through the PHP pipeline as a synthetic
  /// `POST [path]`. The reply is returned as a datagram when it fits the
  /// negotiated size, otherwise on a fresh server-initiated uni stream so a
  /// larger Livewire response is not lost.
  Future<void> _bridgeWtDatagram(
    _Session session,
    Uint8List payload,
    String path,
  ) async {
    final response = await _runWtBridge(session, path, payload);
    final wt = session.wt;
    if (response == null || wt == null) return;
    final body = response.take();
    if (!_sendWtDatagram(session, body)) {
      final uniId = session.h3!.allocLocalUniStreamId();
      final prefix = encodeWtUniStreamPrefix(wt.streamId);
      session.conn.streamSend(
        uniId,
        Uint8List.fromList([...prefix, ...body]),
        fin: true,
      );
    }
    _txAll(session);
  }

  /// Sends a WebTransport datagram, dropping it (with a log) rather than
  /// throwing when the peer disabled datagrams or the payload exceeds the
  /// negotiated max_datagram_frame_size. Returns true if it was enqueued.
  bool _sendWtDatagram(_Session session, Uint8List payload) {
    final wt = session.wt;
    if (wt == null) return false;
    try {
      wt.sendDatagram(payload);
      return true;
    } on QuicError catch (e) {
      _log('WebTransport datagram dropped (${payload.length}B): $e');
      return false;
    }
  }

  /// Buffers an inbound (client-initiated) WebTransport unidirectional stream
  /// until its FIN, then hands the complete message to [_handleWtMessage].
  void _onWtUniData(
    _Session session,
    int wtStreamId,
    int sessionId,
    Uint8List data,
    bool fin,
  ) {
    if (session.wt == null) return;
    final buf = session.wtInbound.putIfAbsent(wtStreamId, _WtInboundStream.new);
    buf.add(data, config.maxRequestBodyBytes);
    if (!fin) return;
    session.wtInbound.remove(wtStreamId);
    if (buf.overflowed) {
      _log(
        'WebTransport uni stream $wtStreamId exceeded '
        '${config.maxRequestBodyBytes}B; dropped',
      );
      return;
    }
    _handleWtMessage(session, sessionId, buf.take(), bidiStreamId: null);
  }

  /// Buffers an inbound (client-initiated) WebTransport bidirectional stream
  /// until its FIN, then hands the complete message to [_handleWtMessage].
  void _onWtBidiData(
    _Session session,
    int bidiStreamId,
    int sessionId,
    Uint8List data,
    bool fin,
  ) {
    if (session.wt == null) return;
    final buf =
        session.wtInbound.putIfAbsent(bidiStreamId, _WtInboundStream.new);
    buf.add(data, config.maxRequestBodyBytes);
    if (!fin) return;
    session.wtInbound.remove(bidiStreamId);
    if (buf.overflowed) {
      _log(
        'WebTransport bidi stream $bidiStreamId exceeded '
        '${config.maxRequestBodyBytes}B; dropped',
      );
      return;
    }
    _handleWtMessage(
      session,
      sessionId,
      buf.take(),
      bidiStreamId: bidiStreamId,
    );
  }

  /// Handles one complete inbound WebTransport message (a full stream buffered
  /// to its FIN). This is the extension point for application protocols such as
  /// Livewire-over-WebTransport. When [ServerConfig.wtBridgePath] is set the
  /// message is bridged through the PHP pipeline; otherwise it is echoed: a
  /// bidi message is replied on the same stream; a uni message is sent out on a
  /// fresh server-initiated uni stream.
  void _handleWtMessage(
    _Session session,
    int sessionId,
    Uint8List message, {
    required int? bidiStreamId,
  }) {
    if (session.wt == null) return;
    final handler = _wtHandler;
    if (handler != null) {
      handler(
        _WtSessionImpl(this, session, sessionId, bidiStreamId),
        WtMessage(
          data: message,
          isDatagram: false,
          sessionId: sessionId,
          bidiStreamId: bidiStreamId,
        ),
      );
      return;
    }
    final bridgePath = config.wtBridgePath;
    if (bridgePath != null) {
      unawaited(
        _bridgeWtMessage(
          session,
          sessionId,
          message,
          bidiStreamId: bidiStreamId,
          path: bridgePath,
        ),
      );
      return;
    }
    if (bidiStreamId != null) {
      session.conn.streamSend(bidiStreamId, message, fin: true);
      _log(
        'WebTransport bidi message: ${message.length} bytes '
        '(session $sessionId)',
      );
      return;
    }
    final uniId = session.h3!.allocLocalUniStreamId();
    final prefix = encodeWtUniStreamPrefix(sessionId);
    session.conn.streamSend(
      uniId,
      Uint8List.fromList([...prefix, ...message]),
      fin: true,
    );
    _log(
      'WebTransport uni message: ${message.length} bytes '
      '(session $sessionId)',
    );
  }

  /// Bridges one WebTransport stream message through the PHP pipeline as a
  /// synthetic `POST [path]` (the Livewire-over-WebTransport path), then writes
  /// the response back: on the same bidi stream, or a fresh uni stream.
  Future<void> _bridgeWtMessage(
    _Session session,
    int sessionId,
    Uint8List message, {
    required int? bidiStreamId,
    required String path,
  }) async {
    final response = await _runWtBridge(session, path, message);
    if (response == null || session.wt == null) return;
    final framed = _frameBridgeReply(response);
    if (bidiStreamId != null) {
      session.conn.streamSend(bidiStreamId, framed, fin: true);
    } else {
      final uniId = session.h3!.allocLocalUniStreamId();
      final prefix = encodeWtUniStreamPrefix(sessionId);
      session.conn.streamSend(
        uniId,
        Uint8List.fromList([...prefix, ...framed]),
        fin: true,
      );
    }
    _log(
      'WebTransport bridge: ${message.length}B in -> ${framed.length}B out '
      '(${response.statusCode}) [$path]',
    );
    _txAll(session);
  }

  /// Frames a bridge reply as `status\r\nName: Value\r\n…\r\n\r\n<body>` so the
  /// client can reconstruct a faithful Response (status, headers incl.
  /// Set-Cookie/Location) rather than assuming 200.
  Uint8List _frameBridgeReply(_WtBridgeResponse response) {
    final head = StringBuffer()..write('${response.statusCode}\r\n');
    response.headers.forEach((name, values) {
      for (final v in values) {
        head.write('$name: $v\r\n');
      }
    });
    head.write('\r\n');
    return Uint8List.fromList([...utf8.encode(head.toString()), ...response.take()]);
  }

  /// Runs [message] through the PHP pipeline as a synthetic `POST [path]` and
  /// returns the captured response, or null on error. An optional HTTP-style
  /// header preamble in [message] (e.g. `X-CSRF-TOKEN: …` lines then a blank
  /// line) is parsed off and forwarded, so the client can carry credentials.
  Future<_WtBridgeResponse?> _runWtBridge(
    _Session session,
    String defaultPath,
    Uint8List message,
  ) async {
    final (preamble, body) = _parseWtPreamble(message);
    // The client may target a specific app route (e.g. Livewire's randomized
    // /livewire-<hash>/update) via X-Bridge-Uri; otherwise use the configured
    // bridge path. Always an absolute path, routed like any other request.
    final override = preamble['x-bridge-uri'];
    final path = (override != null && override.startsWith('/'))
        ? override
        : defaultPath;
    final headers = _bridgeHeaders(session, preamble);
    session.inFlight++;
    final response = _WtBridgeResponse();
    final exchange = _WtBridgeExchange(
      session,
      config.serverName,
      path,
      headers,
      body,
      response,
    );
    try {
      await _pipeline.serve(exchange);
      await response.done.future;
      return response;
    } catch (e) {
      _log('WebTransport bridge error: $e');
      return null;
    } finally {
      session.inFlight--;
    }
  }

  /// Splits a WebTransport message into an optional HTTP-style header preamble
  /// (`Name: Value` lines terminated by a blank line) and the body. A message
  /// whose first line is not a header (e.g. a JSON payload starting with `{`)
  /// is returned verbatim as the body with no headers.
  static final RegExp _headerLine = RegExp(r'^[A-Za-z][A-Za-z0-9-]*:');

  (Map<String, String>, Uint8List) _parseWtPreamble(Uint8List msg) {
    int sep = -1;
    var sepLen = 0;
    for (var i = 0; i + 1 < msg.length; i++) {
      if (msg[i] == 0x0a && msg[i + 1] == 0x0a) {
        sep = i;
        sepLen = 2;
        break;
      }
      if (i + 3 < msg.length &&
          msg[i] == 0x0d &&
          msg[i + 1] == 0x0a &&
          msg[i + 2] == 0x0d &&
          msg[i + 3] == 0x0a) {
        sep = i;
        sepLen = 4;
        break;
      }
    }
    if (sep < 0) return (const <String, String>{}, msg);
    final head = utf8.decode(
      Uint8List.sublistView(msg, 0, sep),
      allowMalformed: true,
    );
    final lines = head.split(RegExp(r'\r?\n'));
    if (lines.isEmpty || !_headerLine.hasMatch(lines.first)) {
      return (const <String, String>{}, msg);
    }
    final headers = <String, String>{};
    for (final line in lines) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      headers[line.substring(0, idx).trim().toLowerCase()] =
          line.substring(idx + 1).trim();
    }
    return (headers, Uint8List.fromList(Uint8List.sublistView(msg, sep + sepLen)));
  }

  /// Builds the header set forwarded to PHP for a bridged WebTransport message:
  /// AJAX defaults, allowed client-supplied preamble headers, the Cookie from
  /// the WT CONNECT, and a derived `X-XSRF-TOKEN` for Laravel stateful CSRF.
  Map<String, String> _bridgeHeaders(
    _Session session,
    Map<String, String> preamble,
  ) {
    final h = <String, String>{
      'content-type': 'application/json',
      'x-requested-with': 'XMLHttpRequest',
      'x-livewire': 'true',
      'accept': 'application/json, text/html; q=0.9, */*; q=0.8',
    };
    const allowed = {
      'x-csrf-token',
      'x-xsrf-token',
      'cookie',
      'authorization',
      'content-type',
      'accept',
    };
    preamble.forEach((k, v) {
      if (allowed.contains(k)) h[k] = v;
    });
    // Fall back to the cookie captured from the WT CONNECT handshake.
    if (!h.containsKey('cookie') &&
        (session.cookie?.isNotEmpty ?? false)) {
      h['cookie'] = session.cookie!;
    }
    // A WT ticket (opaque, server-sealed) is authoritative: decrypt it to
    // recover the session cookie, which stays HttpOnly on the client.
    final ticket = preamble['x-wt-ticket'];
    if (ticket != null) {
      final cookie = WtTicket.redeem(ticket, config.wtTicketKey);
      if (cookie != null && cookie.isNotEmpty) h['cookie'] = cookie;
    }
    // Laravel stateful CSRF: echo the XSRF-TOKEN cookie as X-XSRF-TOKEN unless
    // the client already supplied an explicit CSRF header.
    if (!h.containsKey('x-xsrf-token') && !h.containsKey('x-csrf-token')) {
      final xsrf = _cookieValue(h['cookie'], 'XSRF-TOKEN');
      if (xsrf != null) h['x-xsrf-token'] = Uri.decodeComponent(xsrf);
    }
    return h;
  }

  /// Returns the value of cookie [name] in a `Cookie:` header string, or null.
  String? _cookieValue(String? cookieHeader, String name) {
    if (cookieHeader == null) return null;
    for (final part in cookieHeader.split(';')) {
      final kv = part.trim();
      final eq = kv.indexOf('=');
      if (eq <= 0) continue;
      if (kv.substring(0, eq) == name) return kv.substring(eq + 1);
    }
    return null;
  }

  String? _headerValue(List<H3Header> headers, String name) {
    for (final h in headers) {
      if (String.fromCharCodes(h.name) == name) {
        return String.fromCharCodes(h.value);
      }
    }
    return null;
  }

  /// Collects non-pseudo request headers into a lower-cased map (duplicate
  /// values joined with `, `), for the WebTransport CONNECT context.
  Map<String, String> _wtHeadersMap(List<H3Header> headers) {
    final out = <String, String>{};
    for (final h in headers) {
      final name = String.fromCharCodes(h.name);
      if (name.startsWith(':')) continue;
      final value = String.fromCharCodes(h.value);
      final existing = out[name];
      out[name] = existing == null ? value : '$existing, $value';
    }
    return out;
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
  /// for headers-only / empty-body responses. Returns false if the client has
  /// reset the stream (STOP_SENDING), so the caller can abandon the response.
  bool _sendHeaders(
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
    try {
      session.h3!.sendResponse(streamId, h3Headers, fin: fin);
    } on QuicError catch (e) {
      _log('response stream $streamId stopped by client: $e');
      return false;
    }
    _txAll(session);
    return true;
  }

  /// Streams one body chunk (DATA frame) and flushes it to the socket, giving
  /// soft back-pressure as the source produces data. Returns false if the
  /// client has reset the stream (STOP_SENDING).
  bool _sendData(
    _Session session,
    int streamId,
    List<int> chunk, {
    required bool fin,
  }) {
    try {
      session.h3!.sendData(streamId, Uint8List.fromList(chunk), fin: fin);
    } on QuicError catch (e) {
      _log('response stream $streamId stopped by client: $e');
      return false;
    }
    _txAll(session);
    return true;
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

/// Reply facade handed to a native [WtHandler] for one inbound WebTransport
/// message; adapts [WtSession] onto the owning [_Session] and flushes.
class _WtSessionImpl implements WtSession {
  _WtSessionImpl(this._server, this._session, this._sessionId, this._bidiStreamId);

  final Http3PhpServer _server;
  final _Session _session;
  final int _sessionId;
  final int? _bidiStreamId;

  @override
  WtConnect get connect =>
      _session.wtConnect ??
      const WtConnect(path: '', authority: '', headers: {});

  @override
  void send(List<int> bytes) {
    final bidi = _bidiStreamId;
    if (bidi != null) {
      _session.conn.streamSend(bidi, Uint8List.fromList(bytes), fin: true);
    } else {
      _sendOnFreshUni(bytes);
    }
    _server._txAll(_session);
  }

  @override
  void sendUni(List<int> bytes) {
    _sendOnFreshUni(bytes);
    _server._txAll(_session);
  }

  @override
  void sendDatagram(List<int> bytes) {
    _server._sendWtDatagram(_session, Uint8List.fromList(bytes));
    _server._txAll(_session);
  }

  void _sendOnFreshUni(List<int> bytes) {
    final h3 = _session.h3;
    if (h3 == null) return;
    final uniId = h3.allocLocalUniStreamId();
    final prefix = encodeWtUniStreamPrefix(_sessionId);
    _session.conn.streamSend(
      uniId,
      Uint8List.fromList([...prefix, ...bytes]),
      fin: true,
    );
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

  /// The Extended CONNECT context for [wt] (path, authority, cookie, headers),
  /// captured at accept time and surfaced to a native WtHandler.
  WtConnect? wtConnect;

  /// Cookie header sent by the browser on the WebTransport CONNECT (used by the
  /// bridge to forward the Laravel session / XSRF-TOKEN to PHP).
  String? cookie;

  /// Inbound WebTransport streams buffered until FIN, keyed by QUIC stream id.
  final Map<int, _WtInboundStream> wtInbound = {};

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

/// Buffers one inbound WebTransport stream (uni or bidi) until its FIN so a
/// complete application message can be handed off in one piece. Enforces a
/// byte cap to bound per-stream memory.
class _WtInboundStream {
  final BytesBuilder _buf = BytesBuilder(copy: false);
  int _len = 0;
  bool overflowed = false;

  /// Appends [data] unless the running size would exceed [limit], in which
  /// case the buffer is discarded and the stream marked [overflowed].
  void add(Uint8List data, int limit) {
    if (overflowed) return;
    _len += data.length;
    if (_len > limit) {
      overflowed = true;
      _buf.clear();
      return;
    }
    _buf.add(data);
  }

  Uint8List take() => _buf.takeBytes();
}

/// Adapts a complete inbound WebTransport message to the [ServerExchange]
/// contract as a synthetic `POST`, so it runs through the same PHP pipeline as
/// an HTTP request. Carries AJAX-style headers so a Laravel/Livewire front
/// controller treats it like the `/livewire/update` XHR it replaces.
class _WtBridgeExchange implements ServerExchange {
  _WtBridgeExchange(
    this._session,
    this._authority,
    this._path,
    this._headers,
    this._bodyBytes,
    this._response,
  );

  final _Session _session;
  final String _authority;
  final String _path;
  final Map<String, String> _headers;
  final Uint8List _bodyBytes;
  final _WtBridgeResponse _response;

  @override
  String get method => 'POST';

  @override
  Uri get uri => Uri.parse(_path);

  @override
  String get protocolVersion => '3';

  @override
  String get scheme => 'https';

  @override
  String get authority => _authority;

  @override
  String get protocol => 'h3-wt';

  @override
  String get remoteAddress => _session.addr.address;

  @override
  int get remotePort => _session.port;

  @override
  int get contentLength => _bodyBytes.length;

  @override
  String? get contentType => _headers['content-type'];

  @override
  void forEachHeader(void Function(String name, String value) action) {
    _headers.forEach(action);
  }

  @override
  Stream<List<int>> get body =>
      _bodyBytes.isEmpty ? const Stream.empty() : Stream.value(_bodyBytes);

  @override
  ServerResponse respond() => _response;
}

/// Captures a pipeline response into memory so it can be shipped back over a
/// WebTransport stream or datagram. Completes [done] when the pipeline closes.
class _WtBridgeResponse implements ServerResponse {
  final BytesBuilder _body = BytesBuilder(copy: false);
  final Map<String, List<String>> headers = {};
  final Completer<void> done = Completer<void>();
  int _status = 200;

  @override
  int get statusCode => _status;

  @override
  void setStatus(int statusCode, [String? reasonPhrase]) => _status = statusCode;

  @override
  void setHeader(String name, String value) =>
      headers.putIfAbsent(name.toLowerCase(), () => <String>[]).add(value);

  @override
  Future<void> addStream(Stream<List<int>> body) async {
    await for (final chunk in body) {
      _body.add(chunk);
    }
  }

  @override
  Future<void> close() async {
    if (!done.isCompleted) done.complete();
  }

  Uint8List take() => _body.takeBytes();
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
          // QPACK may split one header (notably Cookie) across several fields;
          // rejoin duplicates ('; ' for Cookie per RFC 9114 §4.2.1, else ',').
          final lower = name.toLowerCase();
          final existing = _headers[lower];
          if (existing == null) {
            _headers[lower] = value;
          } else {
            _headers[lower] = '$existing${lower == 'cookie' ? '; ' : ', '}$value';
          }
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
  bool _aborted = false;

  @override
  int get statusCode => _status;

  @override
  void setStatus(int statusCode, [String? reasonPhrase]) => _status = statusCode;

  @override
  void setHeader(String name, String value) =>
      _headers.putIfAbsent(name.toLowerCase(), () => <String>[]).add(value);

  void _ensureHeaders() {
    if (_headersSent || _aborted) return;
    _headersSent = true;
    if (!_server._sendHeaders(_session, _streamId, _status, _headers, fin: false)) {
      _aborted = true;
    }
  }

  @override
  Future<void> addStream(Stream<List<int>> body) async {
    await for (final chunk in body) {
      if (_aborted) break; // client reset the stream — stop reading the source
      _ensureHeaders();
      if (_aborted) break;
      if (chunk.isNotEmpty) {
        if (!_server._sendData(_session, _streamId, chunk, fin: false)) {
          _aborted = true;
          break;
        }
      }
    }
  }

  @override
  Future<void> close() async {
    if (_aborted) return;
    if (_headersSent) {
      _server._sendData(_session, _streamId, const [], fin: true);
    } else {
      // Headers-only / empty body (e.g. HEAD, 304): close with the headers.
      _server._sendHeaders(_session, _streamId, _status, _headers, fin: true);
    }
  }
}
