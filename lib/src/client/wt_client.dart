import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_quiche/dart_quiche.dart' hide Stream;
// Epoch / installInitialKeys live in an internal library (not re-exported).
// ignore: implementation_imports
import 'package:dart_quiche/src/handshake_keys.dart';

/// Thrown when a WebTransport session cannot be established or used.
class WebTransportClientException implements Exception {
  WebTransportClientException(this.message);
  final String message;
  @override
  String toString() => 'WebTransportClientException: $message';
}

/// An inbound WebTransport message: either a datagram, or payload bytes that
/// arrived on an inbound unidirectional / bidirectional stream. For stream
/// payloads [streamId] is the QUIC stream id and [fin] mirrors the QUIC FIN.
class WtClientMessage {
  WtClientMessage({
    required this.data,
    required this.isDatagram,
    this.streamId,
    this.fin = false,
  });

  final Uint8List data;
  final bool isDatagram;
  final int? streamId;
  final bool fin;
}

/// A pure-Dart WebTransport client over HTTP/3. Mirrors the server's native WT
/// vocabulary: datagrams plus unidirectional / bidirectional streams. Connect
/// with [connect]; inbound datagrams and stream payloads surface on [incoming].
class WebTransportClient {
  WebTransportClient._(
    this._conn,
    this._socket,
    this._sub,
    this._h3,
    this._wt,
    this._address,
    this._port,
  );

  final Connection _conn;
  final RawDatagramSocket _socket;
  final StreamSubscription<RawSocketEvent> _sub;
  final H3Connection _h3;
  final WebTransportSession _wt;
  final InternetAddress _address;
  final int _port;

  final List<Datagram> _inbox = [];
  final StreamController<WtClientMessage> _incoming =
      StreamController<WtClientMessage>();
  Timer? _timer;
  bool _closed = false;

  /// Inbound datagrams and stream payloads for this session.
  Stream<WtClientMessage> get incoming => _incoming.stream;

  /// The WT session's underlying CONNECT request stream id.
  int get sessionId => _wt.streamId;

  /// Opens a WebTransport session to [url] (an `https://host:port/path`). The
  /// QUIC handshake runs, an Extended CONNECT with `:protocol=webtransport` is
  /// sent, and this future completes once the server answers 2xx. When
  /// [trustStore] is null the server certificate is not validated (dev /
  /// self-signed) — pass a [TrustStore] to require chain-to-root validation.
  static Future<WebTransportClient> connect(
    Uri url, {
    TrustStore? trustStore,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final address = (await InternetAddress.lookup(url.host)).first;
    final port = url.port;
    final sni = url.host;
    final path = url.path.isEmpty ? '/' : url.path;

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
      // Stage 1-2: first flight + handshake.
      txAll();
      final hsDeadline = DateTime.now().add(timeout);
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
        throw WebTransportClientException('QUIC handshake did not complete');
      }

      // Stage 3: open H3, drain control frames, send the WT CONNECT.
      final h3 = H3Connection.client(conn);
      txAll();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      while (inbox.isNotEmpty) {
        try {
          conn.recvDatagram(inbox.removeAt(0).data);
        } catch (_) {}
      }
      while (h3.pollEvent() != null) {}

      final wt = WebTransportSession.connect(
        h3,
        authority: Uint8List.fromList(sni.codeUnits),
        path: Uint8List.fromList(path.codeUnits),
      );
      txAll();

      // Stage 4: await the 2xx CONNECT response on the session stream.
      // WT uni/bidi payloads (e.g. the server greeting) and datagrams may
      // arrive in the same flight — buffer them to replay once the pump runs.
      final pending = <WtClientMessage>[];
      var accepted = false;
      final respDeadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(respDeadline) && !accepted) {
        if (inbox.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        while (inbox.isNotEmpty) {
          try {
            conn.recvDatagram(inbox.removeAt(0).data);
          } catch (_) {}
        }
        for (H3Event? ev = h3.pollEvent(); ev != null; ev = h3.pollEvent()) {
          switch (ev) {
            case H3HeadersEvent(streamId: final sid) when sid == wt.streamId:
              final status = _statusOf(ev);
              if (status >= 200 && status < 300) {
                accepted = true;
              } else {
                throw WebTransportClientException(
                    'WebTransport CONNECT rejected: $status');
              }
            case H3WebTransportUniStreamEvent(
                streamId: final sid,
                sessionId: final sessId,
                :final data,
                :final fin,
              ):
              if (sessId == wt.streamId) {
                pending.add(WtClientMessage(
                    data: data, isDatagram: false, streamId: sid, fin: fin));
              }
            case H3WebTransportBidiStreamEvent(
                streamId: final sid,
                sessionId: final sessId,
                :final data,
                :final fin,
              ):
              if (sessId == wt.streamId) {
                pending.add(WtClientMessage(
                    data: data, isDatagram: false, streamId: sid, fin: fin));
              }
            default:
              break;
          }
        }
        for (Uint8List? dg = wt.recvDatagram(); dg != null; dg = wt.recvDatagram()) {
          pending.add(WtClientMessage(data: dg, isDatagram: true));
        }
        txAll();
        if (conn.isDraining) break;
      }
      if (!accepted) {
        throw WebTransportClientException('no WebTransport CONNECT response');
      }

      final client =
          WebTransportClient._(conn, socket, sub, h3, wt, address, port);
      client._inbox.addAll(inbox);
      for (final m in pending) {
        client._incoming.add(m);
      }
      client._start();
      return client;
    } catch (_) {
      await sub.cancel();
      socket.close();
      rethrow;
    }
  }

  static int _statusOf(H3HeadersEvent ev) {
    for (final h in ev.headers) {
      if (String.fromCharCodes(h.name) == ':status') {
        return int.tryParse(String.fromCharCodes(h.value)) ?? 0;
      }
    }
    return 0;
  }

  void _start() {
    // Take over the socket's read events to drive the session pump.
    _sub.onData((event) {
      if (event != RawSocketEvent.read) return;
      final d = _socket.receive();
      if (d != null) {
        _inbox.add(d);
        _pump();
      }
    });
    // A periodic tick drives QUIC loss/ack timers between inbound packets.
    _timer = Timer.periodic(const Duration(milliseconds: 5), (_) => _pump());
    _pump();
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
    if (_closed) return;
    while (_inbox.isNotEmpty) {
      try {
        _conn.recvDatagram(_inbox.removeAt(0).data);
      } catch (_) {}
    }
    for (H3Event? ev = _h3.pollEvent(); ev != null; ev = _h3.pollEvent()) {
      switch (ev) {
        case H3WebTransportUniStreamEvent(
            streamId: final sid,
            sessionId: final sessId,
            :final data,
            :final fin,
          ):
          if (sessId == _wt.streamId) {
            _incoming.add(WtClientMessage(
                data: data, isDatagram: false, streamId: sid, fin: fin));
          }
        case H3WebTransportBidiStreamEvent(
            streamId: final sid,
            sessionId: final sessId,
            :final data,
            :final fin,
          ):
          if (sessId == _wt.streamId) {
            _incoming.add(WtClientMessage(
                data: data, isDatagram: false, streamId: sid, fin: fin));
          }
        default:
          break;
      }
    }
    for (Uint8List? dg = _wt.recvDatagram(); dg != null; dg = _wt.recvDatagram()) {
      _incoming.add(WtClientMessage(data: dg, isDatagram: true));
    }
    _txAll();
  }

  /// Sends a WebTransport datagram (unreliable, unordered).
  void sendDatagram(List<int> data) {
    _ensureOpen();
    _wt.sendDatagram(Uint8List.fromList(data));
    _txAll();
  }

  /// Opens a unidirectional WT stream, writes [data] (FIN by default), and
  /// returns the new stream id.
  int openUniStream(List<int> data, {bool fin = true}) {
    _ensureOpen();
    final id = _wt.openUniStream();
    _wt.sendUniStreamData(id, Uint8List.fromList(data), fin: fin);
    _txAll();
    return id;
  }

  /// Opens a bidirectional WT stream, writes [data], and returns the new
  /// stream id. The server's reply arrives on [incoming] with the same id.
  int openBidiStream(List<int> data, {bool fin = false}) {
    _ensureOpen();
    final id = _wt.openBidiStream();
    _wt.sendBidiStreamData(id, Uint8List.fromList(data), fin: fin);
    _txAll();
    return id;
  }

  /// Appends [data] to an already-open WT stream [streamId].
  void sendStreamData(int streamId, List<int> data, {bool fin = false}) {
    _ensureOpen();
    _conn.streamSend(streamId, Uint8List.fromList(data), fin: fin);
    _txAll();
  }

  /// Closes the session (FIN on the CONNECT stream) and releases the socket.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    try {
      _wt.close();
      _txAll();
    } catch (_) {}
    await _sub.cancel();
    _socket.close();
    await _incoming.close();
  }

  void _ensureOpen() {
    if (_closed) throw WebTransportClientException('session is closed');
  }
}
