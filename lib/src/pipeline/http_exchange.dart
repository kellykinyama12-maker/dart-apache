import 'dart:io';

import 'server_exchange.dart';

/// Adapts a `dart:io` [HttpRequest]/[HttpResponse] to the transport-agnostic
/// [ServerExchange] contract so the HTTP/1.1 listener feeds the shared pipeline.
class HttpExchange implements ServerExchange {
  HttpExchange(this._request);

  final HttpRequest _request;

  @override
  String get method => _request.method;

  @override
  Uri get uri => _request.uri;

  @override
  String get protocolVersion => _request.protocolVersion;

  @override
  String get scheme => _request.requestedUri.scheme;

  @override
  String get protocol => 'http/${_request.protocolVersion}';

  @override
  String get remoteAddress =>
      _request.connectionInfo?.remoteAddress.address ?? '';

  @override
  int get remotePort => _request.connectionInfo?.remotePort ?? 0;

  @override
  int get contentLength => _request.contentLength;

  @override
  String? get contentType => _request.headers.contentType?.toString();

  @override
  void forEachHeader(void Function(String name, String value) action) {
    _request.headers.forEach((name, values) => action(name, values.join(', ')));
  }

  @override
  Stream<List<int>> get body => _request;

  @override
  ServerResponse respond() => _HttpResponseSink(_request.response);
}

class _HttpResponseSink implements ServerResponse {
  _HttpResponseSink(this._response);

  final HttpResponse _response;
  final Set<String> _seen = {};

  @override
  int get statusCode => _response.statusCode;

  @override
  void setStatus(int statusCode, [String? reasonPhrase]) {
    _response.statusCode = statusCode;
    if (reasonPhrase != null) _response.reasonPhrase = reasonPhrase;
  }

  @override
  void setHeader(String name, String value) {
    // First value for a header replaces any default; later values append
    // (so multiple Set-Cookie headers are preserved).
    if (_seen.add(name.toLowerCase())) {
      _response.headers.set(name, value);
    } else {
      _response.headers.add(name, value);
    }
  }

  @override
  Future<void> addStream(Stream<List<int>> body) =>
      _response.addStream(body);

  @override
  Future<void> close() => _response.close();
}
