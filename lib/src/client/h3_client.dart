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

/// Performs a single HTTP/3 `GET` over QUIC using the pure-Dart `dart_quiche`
/// client, returning a uniform [ClientResponse]. Intended for pure-Dart apps
/// that discovered an HTTP/3 endpoint via `Alt-Svc`.
class H3Client {
  H3Client({
    this.userAgent = 'dart-apache-client/1.0',
    this.timeout = const Duration(seconds: 5),
    this.trustStore,
  });

  final String userAgent;
  final Duration timeout;

  /// When set, the handshake validates the server certificate chain to a
  /// trusted anchor (and the hostname/SAN). When null, trust is pin/transcript
  /// based only (dev / behind a trusted terminator).
  final TrustStore? trustStore;

  Future<ClientResponse> get({
    required InternetAddress address,
    required int port,
    required String authority,
    required String sni,
    required String path,
  }) async {
    final rng = Random.secure();
    final dcid =
        Uint8List.fromList(List.generate(8, (_) => rng.nextInt(256)));
    final scid =
        Uint8List.fromList(List.generate(8, (_) => rng.nextInt(256)));

    final conn = Connection(localCid: scid, isServer: false, peerCid: dcid)
      ..spaces.installInitialKeys(
        cid: dcid,
        version: protocolVersionV1,
        isServer: false,
      );
    final driver =
        TlsClientDriver(
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
          // The client's first Initial must be padded to >= 1200 bytes.
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
          final d = inbox.removeAt(0);
          try {
            conn.recvDatagram(d.data);
          } catch (_) {}
          driver.poll();
        }
        driver.poll();
        txAll();
        if (conn.isDraining) break;
      }
      if (!driver.handshakeComplete) {
        throw H3ClientException('QUIC handshake did not complete');
      }

      // Stage 3: HTTP/3 request. Drain post-handshake control frames first so
      // the QPACK encoder sees the peer's advertised capacity.
      final h3 = H3Connection.client(conn);
      txAll();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      while (inbox.isNotEmpty) {
        try {
          conn.recvDatagram(inbox.removeAt(0).data);
        } catch (_) {}
      }
      while (h3.pollEvent() != null) {}

      final reqStream = h3.sendRequest([
        H3Header.fromString(':method', 'GET'),
        H3Header.fromString(':scheme', 'https'),
        H3Header.fromString(':authority', authority),
        H3Header.fromString(':path', path),
        H3Header.fromString('user-agent', userAgent),
      ], fin: true);
      txAll();

      // Stage 4: collect the response.
      final headers = <String, String>{};
      var statusCode = 0;
      final body = BytesBuilder(copy: false);
      var done = false;

      final respDeadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(respDeadline) && !done) {
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
            case H3HeadersEvent(
                streamId: final sid,
                headers: final hs,
                :final fin,
              ):
              if (sid != reqStream) break;
              for (final h in hs) {
                final name = String.fromCharCodes(h.name);
                final value = String.fromCharCodes(h.value);
                if (name == ':status') {
                  statusCode = int.tryParse(value) ?? statusCode;
                } else if (!name.startsWith(':')) {
                  headers[name.toLowerCase()] = value;
                }
              }
              if (fin) done = true;
            case H3DataEvent(streamId: final sid, :final data, :final fin):
              if (sid != reqStream) break;
              body.add(data);
              if (fin) done = true;
            case H3FinishedEvent(streamId: final sid):
              if (sid == reqStream) done = true;
            default:
              break;
          }
        }
        txAll();
        if (conn.isDraining) break;
      }

      if (statusCode == 0) {
        throw H3ClientException('no HTTP/3 response headers received');
      }
      return ClientResponse(
        statusCode: statusCode,
        headers: headers,
        body: body.takeBytes(),
        protocol: 'h3',
      );
    } finally {
      await sub.cancel();
      socket.close();
    }
  }
}
