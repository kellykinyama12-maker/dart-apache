/// Transport-agnostic request/response contract. Every transport (HTTP/3,
/// HTTP/1.1, …) adapts its native request to a [ServerExchange] so the request
/// pipeline and handlers never depend on a specific protocol.
///
/// HTTP/3 is the reference implementation of this contract; HTTP/1.1 conforms
/// to the same shape (see [12-http3-integration-plan.md]).
library;

/// One inbound request plus the means to respond to it.
abstract interface class ServerExchange {
  /// Request method (`GET`, `POST`, …).
  String get method;

  /// Request target as a URI (path + query).
  Uri get uri;

  /// HTTP version token for `SERVER_PROTOCOL` (e.g. `1.1`, `3`).
  String get protocolVersion;

  /// `http` or `https`.
  String get scheme;

  /// Transport label used in logs/metrics (`h3`, `http/1.1`).
  String get protocol;

  /// Client address and port.
  String get remoteAddress;
  int get remotePort;

  /// Declared body length, or `-1` when unknown (chunked).
  int get contentLength;

  /// Request `Content-Type`, if any.
  String? get contentType;

  /// Visits each request header once (values already joined).
  void forEachHeader(void Function(String name, String value) action);

  /// The request body as a byte stream (may be empty).
  Stream<List<int>> get body;

  /// Begins the response.
  ServerResponse respond();
}

/// A streamed response sink. Set status/headers, then stream the body and
/// close. Implementations may buffer (HTTP/3 today) or stream (HTTP/1.1).
abstract interface class ServerResponse {
  /// Sets the status line. Call before writing the body.
  void setStatus(int statusCode, [String? reasonPhrase]);

  /// Adds a response header. Call before writing the body.
  void setHeader(String name, String value);

  /// The status code set so far (defaults to 200).
  int get statusCode;

  /// Streams [body] to the client with back-pressure.
  Future<void> addStream(Stream<List<int>> body);

  /// Completes the response.
  Future<void> close();
}
