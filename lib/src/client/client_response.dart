import 'dart:convert';

/// A protocol-agnostic client response: the status, headers, and body, plus
/// which transport actually served it (`http/1.1` or `h3`).
class ClientResponse {
  ClientResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.protocol,
  });

  final int statusCode;

  /// Lowercased header name -> value.
  final Map<String, String> headers;
  final List<int> body;

  /// The transport that served this response: `http/1.1` or `h3`.
  final String protocol;

  /// Decodes the body as UTF-8 text (lenient).
  String get text => utf8.decode(body, allowMalformed: true);

  /// Decodes the body as JSON (`Map`, `List`, or scalar). Throws
  /// [FormatException] if the body is not valid JSON.
  dynamic get json => jsonDecode(text);

  /// Whether the status code is in the 2xx success range.
  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  @override
  String toString() =>
      'ClientResponse($statusCode, $protocol, ${body.length} bytes)';
}
