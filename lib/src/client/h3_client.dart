import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_quiche/dart_quiche.dart' hide Stream;
// Epoch / installInitialKeys live in an internal library (not re-exported).
// ignore: implementation_imports
import 'package:dart_quiche/src/handshake_keys.dart';

import 'client_response.dart';

/// Thrown when an HTTP/3 request cannot complete (handshake or response
/// failure), so callers can fall back to HTTP/1.1.
class H3ClientException implements Exception {
  H3ClientException(this.message);
  final String message;
  @override
  String toString() => 'H3ClientException: $message';
}

/// Signals that a request could not even be sent on a pooled connection (it
/// was dead or out of stream credit), so it is safe to reconnect and retry.
class _RetryableH3Exception implements Exception {}

/// A pooled HTTP/3 client over QUIC (pure-Dart `dart_quiche`). Connections are
/// kept alive and **reused** across requests to the same origin — the QUIC
/// handshake is paid once, then every subsequent request multiplexes onto a
/// fresh bidi stream. Idle connections are evicted after [idleTimeout].
class H3Client {
  H3Client({
    this.userAgent = 'dart-apache-client/1.0',
    this.timeout = const Duration(seconds: 5),
    this.trustStore,
    this.idleTimeout = const Duration(seconds: 30),
  });

  final String userAgent;
  final Duration timeout;
  final Duration idleTimeout;

  /// When set, the handshake validates the server certificate chain to a
  /// trusted anchor (and the hostname/SAN). When null, trust is pin/transcript
  /// based only (dev / behind a trusted terminator).
  final TrustStore? trustStore;

  final Map<String, _H3Conn> _pool = {};
  final Map<String, Future<_H3Conn>> _connecting = {};

  /// Number of live pooled connections (for tests / diagnostics).
  int get pooledConnections => _pool.length;

  Future<ClientResponse> get({
    required InternetAddress address,
    required int port,
    required String authority,
    required String sni,
    required String path,
    Map<String, String> headers = const {},
    bool acceptGzip = true,
  }) =>
      request(
        method: 'GET',
        address: address,
        port: port,
        authority: authority,
        sni: sni,
        path: path,
        headers: headers,
        acceptGzip: acceptGzip,
      );

  /// Performs an HTTP/3 request of any [method] over QUIC, reusing a pooled
  /// connection to the origin when one is live. A gzip-encoded response is
  /// decoded transparently when [acceptGzip] is set (the default).
  Future<ClientResponse> request({
    required String method,
    required InternetAddress address,
    required int port,
    required String authority,
    required String sni,
    required String path,
    Map<String, String> headers = const {},
    List<int>? body,
    bool acceptGzip = true,
  }) async {
    final key = '${address.address}:$port|$sni';
    // Up to two attempts: a stale pooled connection fails pre-send and is
    // replaced with a fresh one. Post-send failures are NOT retried (the
    // server may have already processed the request).
    for (var attempt = 0; attempt < 2; attempt++) {
      final conn = await _obtain(key, address, port, sni);
      try {
        return await conn.send(
          method: method,
          authority: authority,
          path: path,
          headers: headers,
          body: body,
          acceptGzip: acceptGzip,
          userAgent: userAgent,
          timeout: timeout,
        );
      } on _RetryableH3Exception {
        _evict(key, conn);
        // loop to reconnect
      }
    }
    throw H3ClientException('HTTP/3 connection could not be established');
  }

  Future<_H3Conn> _obtain(
    String key,
    InternetAddress address,
    int port,
    String sni,
  ) {
    final existing = _pool[key];
    if (existing != null && !existing.isDead) return Future.value(existing);
    final pending = _connecting[key];
    if (pending != null) return pending;

    final fut = _H3Conn.connect(
      address: address,
      port: port,
      sni: sni,
      trustStore: trustStore,
      handshakeTimeout: timeout,
      idleTimeout: idleTimeout,
    ).then((c) {
      _connecting.remove(key);
      c.onClosed = () => _pool.remove(key);
      _pool[key] = c;
      return c;
    }, onError: (Object e, StackTrace st) {
      _connecting.remove(key);
      throw e;
    });
    _connecting[key] = fut;
    return fut;
  }

  void _evict(String key, _H3Conn conn) {
    if (_pool[key] == conn) _pool.remove(key);
    conn.close();
  }

  /// Closes every pooled connection.
  Future<void> close() async {
    final conns = _pool.values.toList();
    _pool.clear();
    for (final c in conns) {
      c.close();
    }
  }
}

/// One pending request awaiting its response on a bidi stream.
class _Pending {
  _Pending(this.acceptGzip);
  final bool acceptGzip;
  final Completer<ClientResponse> completer = Completer<ClientResponse>();
  final Map<String, String> headers = {};
  int status = 0;
  final BytesBuilder body = BytesBuilder(copy: false);
}

/// A single live, reusable HTTP/3 connection. Multiplexes many requests over
/// their own bidi streams and routes responses back by stream id.
class _H3Conn {
  _H3Conn._(
    this._conn,
    this._socket,
    this._sub,
    this._h3,
    this._address,
    this._port,
    this._idleTimeout,
  );

  final Connection _conn;
  final RawDatagramSocket _socket;
  final StreamSubscription<RawSocketEvent> _sub;
  final H3Connection _h3;
  final InternetAddress _address;
  final int _port;
  final Duration _idleTimeout;

  final List<Datagram> _inbox = [];
  final Map<int, _Pending> _pending = {};
  Timer? _pumpTimer;
  Timer? _idleTimer;
  bool _dead = false;

  /// Invoked when the connection closes, so the pool can drop it.
  void Function()? onClosed;

  bool get isDead => _dead;

  static Future<_H3Conn> connect({
    required InternetAddress address,
    required int port,
    required String sni,
    required TrustStore? trustStore,
    required Duration handshakeTimeout,
    required Duration idleTimeout,
  }) async {
    final rng = Random.secure();
    final dcid = Uint8List.fromList(List.generate(8, (_) => rng.nextInt(256)));
    final scid = Uint8List.fromList(List.generate(8, (_) => rng.nextInt(256)));
    final conn = Connection(localCid: scid, isServer: false, peerCid: dcid)
      ..spaces.installInitialKeys(
        cid: dcid,
        version: protocolVersionV1,
        isServer: false,
      );
    final driver = TlsClientDriver(
      conn: conn,
      hostname: sni,
      verifyHostname: trustStore != null,
      trustStore: trustStore,
    )..start();

    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final inbox = <Datagram>[];
    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d != null) inbox.add(d);
    });

    var firstFlightSent = false;
    void txAll() {
      while (true) {
        Uint8List? pkt;
        for (final epoch in const [
          Epoch.initial,
          Epoch.handshake,
          Epoch.application,
        ]) {
          pkt = conn.send(epoch);
          if (pkt != null) break;
        }
        if (pkt == null) break;
        var wire = pkt;
        if (!firstFlightSent) {
          final padded = Uint8List(1200);
          padded.setRange(0, pkt.length, pkt);
          wire = padded;
          firstFlightSent = true;
        }
        socket.send(wire, address, port);
      }
    }

    try {
      txAll();
      final hsDeadline = DateTime.now().add(handshakeTimeout);
      while (DateTime.now().isBefore(hsDeadline) && !driver.handshakeComplete) {
        if (inbox.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        while (inbox.isNotEmpty) {
          try {
            conn.recvDatagram(inbox.removeAt(0).data);
          } catch (_) {}
          driver.poll();
        }
        driver.poll();
        txAll();
        if (conn.isDraining) break;
      }
      if (!driver.handshakeComplete) {
        await sub.cancel();
        socket.close();
        throw H3ClientException('QUIC handshake did not complete');
      }

      // Drain post-handshake control frames so QPACK sees the peer's capacity.
      final h3 = H3Connection.client(conn);
      txAll();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      while (inbox.isNotEmpty) {
        try {
          conn.recvDatagram(inbox.removeAt(0).data);
        } catch (_) {}
      }
      while (h3.pollEvent() != null) {}

      final c = _H3Conn._(conn, socket, sub, h3, address, port, idleTimeout);
      c._inbox.addAll(inbox);
      c._start();
      return c;
    } catch (e) {
      await sub.cancel();
      socket.close();
      if (e is H3ClientException) rethrow;
      throw H3ClientException('HTTP/3 connect failed: $e');
    }
  }

  void _start() {
    _sub.onData((event) {
      if (event != RawSocketEvent.read) return;
      final d = _socket.receive();
      if (d != null) {
        _inbox.add(d);
        _pump();
      }
    });
    _pumpTimer = Timer.periodic(const Duration(milliseconds: 5), (_) => _pump());
    _resetIdle();
  }

  Future<ClientResponse> send({
    required String method,
    required String authority,
    required String path,
    required Map<String, String> headers,
    required List<int>? body,
    required bool acceptGzip,
    required String userAgent,
    required Duration timeout,
  }) {
    if (_dead) throw _RetryableH3Exception();
    final bodyBytes = body == null ? null : Uint8List.fromList(body);
    final lowerKeys = {for (final k in headers.keys) k.toLowerCase()};
    final reqHeaders = <H3Header>[
      H3Header.fromString(':method', method),
      H3Header.fromString(':scheme', 'https'),
      H3Header.fromString(':authority', authority),
      H3Header.fromString(':path', path),
    ];
    if (!lowerKeys.contains('user-agent')) {
      reqHeaders.add(H3Header.fromString('user-agent', userAgent));
    }
    if (acceptGzip && !lowerKeys.contains('accept-encoding')) {
      reqHeaders.add(H3Header.fromString('accept-encoding', 'gzip'));
    }
    if (bodyBytes != null && !lowerKeys.contains('content-length')) {
      reqHeaders
          .add(H3Header.fromString('content-length', '${bodyBytes.length}'));
    }
    for (final e in headers.entries) {
      reqHeaders.add(H3Header.fromString(e.key.toLowerCase(), e.value));
    }

    final int streamId;
    try {
      streamId = _h3.sendRequest(reqHeaders, body: bodyBytes, fin: true);
    } on QuicError {
      // Out of stream credit (or similar) — reconnect and retry.
      throw _RetryableH3Exception();
    }

    final pending = _Pending(acceptGzip);
    _pending[streamId] = pending;
    _idleTimer?.cancel();
    _txAll();

    return pending.completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(streamId);
      _resetIdle();
      throw H3ClientException('HTTP/3 response timed out');
    });
  }

  void _txAll() {
    while (true) {
      Uint8List? pkt;
      for (final epoch in const [
        Epoch.initial,
        Epoch.handshake,
        Epoch.application,
      ]) {
        pkt = _conn.send(epoch);
        if (pkt != null) break;
      }
      if (pkt == null) break;
      _socket.send(pkt, _address, _port);
    }
  }

  void _pump() {
    if (_dead) return;
    while (_inbox.isNotEmpty) {
      try {
        _conn.recvDatagram(_inbox.removeAt(0).data);
      } catch (_) {}
    }
    for (H3Event? ev = _h3.pollEvent(); ev != null; ev = _h3.pollEvent()) {
      switch (ev) {
        case H3HeadersEvent(streamId: final sid, headers: final hs, :final fin):
          final p = _pending[sid];
          if (p == null) break;
          for (final h in hs) {
            final name = String.fromCharCodes(h.name);
            final value = String.fromCharCodes(h.value);
            if (name == ':status') {
              p.status = int.tryParse(value) ?? p.status;
            } else if (!name.startsWith(':')) {
              p.headers[name.toLowerCase()] = value;
            }
          }
          if (fin) _complete(sid);
        case H3DataEvent(streamId: final sid, :final data, :final fin):
          final p = _pending[sid];
          if (p == null) break;
          p.body.add(data);
          if (fin) _complete(sid);
        case H3FinishedEvent(streamId: final sid):
          if (_pending.containsKey(sid)) _complete(sid);
        default:
          break;
      }
    }
    _txAll();
    if (_conn.isDraining) {
      _die(H3ClientException('HTTP/3 connection closed'));
    }
  }

  void _complete(int streamId) {
    final p = _pending.remove(streamId);
    if (p == null) return;
    if (p.status == 0) {
      p.completer.completeError(
          H3ClientException('no HTTP/3 response headers received'));
    } else {
      var out = p.body.takeBytes();
      if ((p.headers['content-encoding'] ?? '')
          .toLowerCase()
          .contains('gzip')) {
        out = Uint8List.fromList(gzip.decode(out));
        p.headers.remove('content-encoding');
        p.headers['content-length'] = '${out.length}';
      }
      p.completer.complete(ClientResponse(
        statusCode: p.status,
        headers: p.headers,
        body: out,
        protocol: 'h3',
      ));
    }
    _resetIdle();
  }

  void _resetIdle() {
    _idleTimer?.cancel();
    if (_pending.isNotEmpty) return;
    _idleTimer = Timer(_idleTimeout, () {
      if (_pending.isEmpty) _die(H3ClientException('idle'));
    });
  }

  void _die(Object error) {
    if (_dead) return;
    _dead = true;
    _pumpTimer?.cancel();
    _idleTimer?.cancel();
    for (final p in _pending.values) {
      if (!p.completer.isCompleted) p.completer.completeError(error);
    }
    _pending.clear();
    _sub.cancel();
    _socket.close();
    onClosed?.call();
  }

  void close() => _die(H3ClientException('HTTP/3 connection closed'));
}
