// Named params cannot be underscore-prefixed, so the callback fields can't use
// initializing formals.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'client_response.dart';

/// Mutable description of an outbound request, handed to [Interceptor]s before
/// it is sent. Interceptors may rewrite any field (e.g. add an auth header).
class RequestOptions {
  RequestOptions({
    required this.method,
    required this.url,
    required this.headers,
    this.body,
    this.forceH1 = false,
  });

  String method;
  Uri url;
  Map<String, String> headers;
  List<int>? body;
  bool forceH1;
}

/// A request/response/error hook, applied in order by the client. Mirrors the
/// familiar `dio` interceptor shape: [onRequest] can mutate the outgoing
/// request, [onResponse] can inspect the result, [onError] observes failures.
abstract class Interceptor {
  FutureOr<void> onRequest(RequestOptions options) {}
  FutureOr<void> onResponse(ClientResponse response) {}
  FutureOr<void> onError(Object error, StackTrace stackTrace) {}
}

/// Convenience [Interceptor] built from callbacks, so callers don't have to
/// subclass for one-off hooks.
class InterceptorCallbacks extends Interceptor {
  InterceptorCallbacks({
    FutureOr<void> Function(RequestOptions)? onRequest,
    FutureOr<void> Function(ClientResponse)? onResponse,
    FutureOr<void> Function(Object, StackTrace)? onError,
  })  : _onRequest = onRequest,
        _onResponse = onResponse,
        _onError = onError;

  final FutureOr<void> Function(RequestOptions)? _onRequest;
  final FutureOr<void> Function(ClientResponse)? _onResponse;
  final FutureOr<void> Function(Object, StackTrace)? _onError;

  @override
  FutureOr<void> onRequest(RequestOptions options) => _onRequest?.call(options);
  @override
  FutureOr<void> onResponse(ClientResponse response) =>
      _onResponse?.call(response);
  @override
  FutureOr<void> onError(Object error, StackTrace stackTrace) =>
      _onError?.call(error, stackTrace);
}

/// Adds a static `Authorization` header to every request.
class BearerAuthInterceptor extends Interceptor {
  BearerAuthInterceptor(this.token);
  final String token;
  @override
  void onRequest(RequestOptions options) {
    options.headers['authorization'] = 'Bearer $token';
  }
}
