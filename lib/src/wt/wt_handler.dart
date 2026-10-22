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
  /// The Extended CONNECT request that opened this session (path, authority,
  /// cookie, headers) — e.g. to route by WT path or recover a session cookie.
  WtConnect get connect;

  /// Replies on the originating stream: the same bidirectional stream when the
  /// message arrived on one, otherwise a fresh server unidirectional stream.
  void send(List<int> bytes);

  /// Sends [bytes] on a fresh server-initiated unidirectional stream.
  void sendUni(List<int> bytes);

  /// Sends a WebTransport datagram (dropped with a log if too large or
  /// disabled by the peer).
  void sendDatagram(List<int> bytes);
}

/// The Extended CONNECT request that established a WebTransport session.
class WtConnect {
  const WtConnect({
    required this.path,
    required this.authority,
    required this.headers,
    this.cookie,
  });

  /// The `:path` the client connected to (matches `--wt-path`).
  final String path;

  /// The `:authority` (host[:port]) of the CONNECT.
  final String authority;

  /// The `Cookie` header sent on the CONNECT, if any (e.g. the session cookie).
  final String? cookie;

  /// All non-pseudo request headers (lower-cased names, values joined).
  final Map<String, String> headers;
}

/// A native, in-process WebTransport session handler. When registered (via
/// [DartApp.wt]) it takes precedence over the PHP bridge / echo for every
/// inbound WebTransport message, letting a Dart app own real-time sessions
/// (datagrams + uni/bidi streams) without a subprocess.
typedef WtHandler = void Function(WtSession session, WtMessage message);
