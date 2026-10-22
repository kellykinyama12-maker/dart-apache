import 'dart:typed_data';

/// One inbound WebTransport message handed to a [WtHandler]: either a complete
/// stream (buffered to its FIN) or a datagram. For stream messages,
/// [bidiStreamId] is non-null when the client opened a *bidirectional* stream
/// (so a reply can go back on the same stream); it is null for client
/// unidirectional streams and for datagrams.
class WtMessage {
  const WtMessage({
    required this.data,
    required this.isDatagram,
    required this.sessionId,
    this.bidiStreamId,
  });

  /// The complete message bytes (a stream buffered to FIN, or a datagram).
  final Uint8List data;

  /// True when this arrived as a WebTransport datagram (unreliable/unordered).
  final bool isDatagram;

  /// The WebTransport session id (the Extended CONNECT request stream id).
  final int sessionId;

  /// For a client-initiated bidirectional stream, its QUIC stream id; null for
  /// unidirectional streams and datagrams.
  final int? bidiStreamId;
}

/// The means to reply within a WebTransport session from a [WtHandler].
abstract interface class WtSession {
  /// Replies on the originating stream: the same bidirectional stream when the
  /// message arrived on one, otherwise a fresh server unidirectional stream.
  void send(List<int> bytes);

  /// Sends [bytes] on a fresh server-initiated unidirectional stream.
  void sendUni(List<int> bytes);

  /// Sends a WebTransport datagram (dropped with a log if too large or
  /// disabled by the peer).
  void sendDatagram(List<int> bytes);
}

/// A native, in-process WebTransport session handler. When registered (via
/// [DartApp.wt]) it takes precedence over the PHP bridge / echo for every
/// inbound WebTransport message, letting a Dart app own real-time sessions
/// (datagrams + uni/bidi streams) without a subprocess.
typedef WtHandler = void Function(WtSession session, WtMessage message);
