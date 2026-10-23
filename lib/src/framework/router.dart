import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../pipeline/dart_handler.dart';
import '../pipeline/server_exchange.dart';
import '../wt/wt_handler.dart';
import 'auth/session.dart';
import 'container/container.dart';
import 'events/events.dart';
import 'queue/queue.dart';
import 'template/blaze.dart';
import 'validation.dart';

/// A request+response facade for route handlers: path params, query, body, and
/// convenient responders (view/json/text/html/redirect). The Dartisan analog of
/// Laravel's `Request` + response helpers.
class Request {
  Request(this.exchange, this.response, this.params, this._views,
      [this._sessions, this._container, this._maxBodyBytes]);

  final ServerExchange exchange;
  final ServerResponse response;

  /// `:name` path parameters captured from the route pattern.
  final Map<String, String> params;

  final BlazeEngine? _views;
  final SessionManager? _sessions;
  final Container? _container;
  final int? _maxBodyBytes;
  Session? _session;
  Future<List<int>>? _bodyFuture;
  bool _responded = false;

  /// True once a responder has started writing the response.
  bool get responded => _responded;

  /// The app's service container (requires `Router(container: ...)`).
  Container get container {
    final c = _container;
    if (c == null) {
      throw StateError('Router has no container; pass Router(container: ...)');
    }
    return c;
  }

  /// Resolves `T` from the service [container].
  T make<T>() => container.make<T>();

  /// The app event dispatcher (requires it registered on the container).
  EventDispatcher get events => make<EventDispatcher>();

  /// The app job queue (requires it registered on the container).
  Queue get queue => make<Queue>();

  /// The request's session (requires `Router(sessions: ...)`). Lazily decrypted
  /// from the `Cookie` header; mutations are persisted as a `Set-Cookie` by the
  /// responders below.
  Session get session {
    final manager = _sessions;
    if (manager == null) {
      throw StateError('Router has no session manager; pass Router(sessions: ...)');
    }
    return _session ??= manager.load(header('cookie'));
  }

  /// Authentication helper backed by [session].
  Auth get auth => Auth(session);

  // Writes the session cookie (if dirty) before the response headers are sent.
  void _persistSession() {
    final manager = _sessions;
    final s = _session;
    if (manager == null || s == null) return;
    final cookie = manager.setCookie(s);
    if (cookie != null) response.setHeader('set-cookie', cookie);
  }

  String get method => exchange.method;
  String get path => exchange.uri.path;

  /// A captured path parameter (`/users/:id` -> `param('id')`).
  String? param(String name) => params[name];

  /// A query-string parameter (`?q=x` -> `query('q')`).
  String? query(String name) => exchange.uri.queryParameters[name];

  /// A request header (case-insensitive).
  String? header(String name) {
    final want = name.toLowerCase();
    String? found;
    exchange.forEachHeader((n, v) {
      if (n.toLowerCase() == want) found = v;
    });
    return found;
  }

  /// The raw request body bytes (buffered once, so multiple readers — e.g. CSRF
  /// middleware then `validate` — all see the same body). Throws
  /// [PayloadTooLargeException] when a body-size limit is set and exceeded.
  Future<List<int>> bodyBytes() => _bodyFuture ??= _readBody();

  Future<List<int>> _readBody() async {
    final max = _maxBodyBytes;
    if (max != null && exchange.contentLength > max) {
      throw PayloadTooLargeException(max);
    }
    final out = <int>[];
    await for (final chunk in exchange.body) {
      out.addAll(chunk);
      if (max != null && out.length > max) throw PayloadTooLargeException(max);
    }
    return out;
  }

  /// The request body as UTF-8 text.
  Future<String> body() async => utf8.decode(await bodyBytes());

  /// The request body parsed as JSON.
  Future<Object?> json() async => jsonDecode(await body());

  /// The session CSRF token, generating + storing one on first use.
  String csrfToken() {
    final existing = session.get('_csrf');
    if (existing is String) return existing;
    final token = base64Url.encode(
        List<int>.generate(24, (_) => _csrfRng.nextInt(256)));
    session.put('_csrf', token);
    return token;
  }

  /// A form field from a URL-encoded body (null for JSON or when absent).
  Future<String?> formField(String name) async {
    final raw = await body();
    for (final pair in raw.split('&')) {
      final i = pair.indexOf('=');
      if (i < 0) continue;
      if (Uri.decodeQueryComponent(pair.substring(0, i)) == name) {
        return Uri.decodeQueryComponent(pair.substring(i + 1));
      }
    }
    return null;
  }

  /// Validates request input (query + body, JSON or form-encoded) against
  /// [rules] and returns the merged data, or throws [ValidationException].
  Future<Map<String, Object?>> validate(Map<String, String> rules) async {
    final data = <String, Object?>{...exchange.uri.queryParameters};
    final raw = await body();
    if (raw.isNotEmpty) {
      final ct = (header('content-type') ?? '').toLowerCase();
      if (ct.contains('application/json')) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) data.addAll(decoded.cast<String, Object?>());
      } else {
        for (final pair in raw.split('&')) {
          final i = pair.indexOf('=');
          if (i < 0) continue;
          data[Uri.decodeQueryComponent(pair.substring(0, i))] =
              Uri.decodeQueryComponent(pair.substring(i + 1));
        }
      }
    }
    final errors = Validator.validate(data, rules);
    if (errors.isNotEmpty) throw ValidationException(errors);
    return data;
  }

  // ---- responders (each sets status + content-type, writes, and closes) ----

  /// Renders a Blaze [view] with [data] (requires a view engine on the router).
  Future<void> view(String view, [Map<String, Object?> data = const {}]) {
    final engine = _views;
    if (engine == null) {
      throw StateError('Router has no view engine; pass Router(views: ...)');
    }
    _responded = true;
    _persistSession();
    return response.writeText(engine.render(view, data),
        contentType: 'text/html; charset=UTF-8');
  }

  Future<void> html(String markup, {int status = 200}) {
    _responded = true;
    _persistSession();
    return response.writeText(markup,
        status: status, contentType: 'text/html; charset=UTF-8');
  }

  Future<void> text(String body, {int status = 200}) {
    _responded = true;
    _persistSession();
    return response.writeText(body, status: status);
  }

  Future<void> sendJson(Object? value, {int status = 200}) {
    _responded = true;
    _persistSession();
    return response.writeJson(value, status: status);
  }

  Future<void> redirect(String location, {int status = 302}) async {
    _responded = true;
    _persistSession();
    response
      ..setStatus(status)
      ..setHeader('location', location)
      ..setHeader('content-length', '0');
    await response.close();
  }
}

/// A route handler receiving a [Request].
typedef RouteAction = FutureOr<void> Function(Request request);

/// A middleware: do work, then call [next] to continue (or short-circuit by not
/// calling it). Mirrors the familiar onion model.
typedef Middleware = FutureOr<void> Function(
  Request request,
  FutureOr<void> Function() next,
);

/// Middleware that requires an authenticated session: unauthenticated requests
/// are redirected to [redirectTo], or answered `401` when it is empty.
Middleware requireAuth({String redirectTo = '/login'}) {
  return (request, next) {
    if (!request.auth.check) {
      return redirectTo.isEmpty
          ? request.text('Unauthorized', status: 401)
          : request.redirect(redirectTo);
    }
    return next();
  };
}

final Random _csrfRng = Random.secure();

/// Thrown when a request body exceeds the configured limit.
class PayloadTooLargeException implements Exception {
  PayloadTooLargeException(this.maxBytes);
  final int maxBytes;
  @override
  String toString() => 'PayloadTooLargeException: body exceeds $maxBytes bytes';
}

/// Length-aware, value-constant-time string comparison (no early-out on the
/// first differing byte), for comparing secrets/tokens without a timing oracle.
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// Middleware that verifies a CSRF token on unsafe methods (POST/PUT/PATCH/
/// DELETE). The token comes from the `_token` form field or the
/// `X-CSRF-Token` header and must match the session token; mismatches get
/// [status] (419 by convention). Safe methods pass through untouched.
Middleware verifyCsrf({int status = 419}) {
  const unsafe = {'POST', 'PUT', 'PATCH', 'DELETE'};
  return (request, next) async {
    if (!unsafe.contains(request.method.toUpperCase())) return next();
    final expected = request.session.get('_csrf');
    final provided =
        request.header('x-csrf-token') ?? await request.formField('_token');
    if (expected is! String ||
        provided == null ||
        !constantTimeEquals(provided, expected)) {
      return request.text('CSRF token mismatch', status: status);
    }
    return next();
  };
}

class _RateWindow {
  _RateWindow(this.resetAt, this.count);
  final DateTime resetAt;
  int count;
}

/// Fixed-window rate-limiting middleware: at most [max] requests per [window]
/// per key (the client IP by default, or [keyBy]). Over the limit responds
/// [status] (429) with a `Retry-After` header. In-memory, per worker isolate.
Middleware rateLimit(
  int max,
  Duration window, {
  String Function(Request request)? keyBy,
  int status = 429,
}) {
  final windows = <String, _RateWindow>{};
  return (request, next) {
    final key = keyBy?.call(request) ?? request.exchange.remoteAddress;
    final now = DateTime.now();
    final w = windows[key];
    if (w == null || !now.isBefore(w.resetAt)) {
      windows[key] = _RateWindow(now.add(window), 1);
      return next();
    }
    if (w.count >= max) {
      final retry = w.resetAt.difference(now).inSeconds + 1;
      request.response.setHeader('retry-after', '$retry');
      return request.text('Too Many Requests', status: status);
    }
    w.count++;
    return next();
  };
}

/// A Laravel-style router over the in-process [DartApp] pipeline: methods,
/// `:param` paths, groups (prefix + middleware), global middleware, and a Blaze
/// view engine. Build it into a [DartApp] with [toApp].
class Router {
  // Named params can't be underscore-prefixed, so no initializing formal here.
  Router({
    BlazeEngine? views,
    SessionManager? sessions,
    Container? container,
    int? maxBodyBytes,
    void Function(Object error, StackTrace stackTrace)? onError,
  })  :
        // ignore: prefer_initializing_formals
        _views = views,
        // ignore: prefer_initializing_formals
        _sessions = sessions,
        _container = container ?? Container(),
        // ignore: prefer_initializing_formals
        _maxBodyBytes = maxBodyBytes,
        // ignore: prefer_initializing_formals
        _onError = onError;

  final BlazeEngine? _views;
  final SessionManager? _sessions;
  final Container _container;
  final int? _maxBodyBytes;
  final void Function(Object error, StackTrace stackTrace)? _onError;
  final List<DartRoute> _routes = [];
  final List<Middleware> _globalMiddleware = [];

  /// The app service container (DI). Register services with [bind] / [singleton]
  /// / [instance], resolve them in handlers via `request.make<T>()`.
  Container get container => _container;

  /// Registers a transient factory for `T` on the [container].
  void bind<T>(ServiceFactory<T> factory) => _container.bind<T>(factory);

  /// Registers a shared (singleton) factory for `T` on the [container].
  void singleton<T>(ServiceFactory<T> factory) =>
      _container.singleton<T>(factory);

  /// Registers an existing [value] as the singleton for `T`.
  void instance<T>(T value) => _container.instance<T>(value);

  /// Optional native WebTransport session handler (e.g. Dartisan Live).
  WtHandler? wt;

  // Active group scope while [group] runs.
  String _prefix = '';
  final List<Middleware> _scoped = [];

  /// Registers global middleware (runs for every route).
  void use(Middleware middleware) => _globalMiddleware.add(middleware);

  void get(String pattern, RouteAction action) => _add('GET', pattern, action);
  void post(String pattern, RouteAction action) => _add('POST', pattern, action);
  void put(String pattern, RouteAction action) => _add('PUT', pattern, action);
  void patch(String pattern, RouteAction action) =>
      _add('PATCH', pattern, action);
  void delete(String pattern, RouteAction action) =>
      _add('DELETE', pattern, action);

  /// Groups routes under a path [prefix] and optional [middleware]. Register
  /// routes on this same router inside [build].
  void group(
    String prefix,
    void Function() build, {
    List<Middleware> middleware = const [],
  }) {
    final savedPrefix = _prefix;
    final savedLen = _scoped.length;
    _prefix = '$_prefix$prefix';
    _scoped.addAll(middleware);
    build();
    _prefix = savedPrefix;
    _scoped.removeRange(savedLen, _scoped.length);
  }

  void _add(String method, String pattern, RouteAction action) {
    final full = '$_prefix$pattern';
    final chain = [..._globalMiddleware, ..._scoped];
    final route = DartRoute.path(full, (exchange, response) async {
      final params = _paramsFor(full, exchange.uri.path);
      final request = Request(
          exchange, response, params, _views, _sessions, _container, _maxBodyBytes);
      await _runChain(request, chain, action);
    }, methods: {method});
    _routes.add(route);
  }

  Future<void> _runChain(
    Request request,
    List<Middleware> chain,
    RouteAction action,
  ) async {
    try {
      var i = -1;
      FutureOr<void> next() {
        i++;
        if (i < chain.length) return chain[i](request, next);
        return action(request);
      }

      await Future<void>.sync(next);
    } catch (error, stackTrace) {
      await _handleError(request, error, stackTrace);
    }
  }

  // Turns uncaught handler errors into clean responses without leaking details.
  Future<void> _handleError(
      Request request, Object error, StackTrace stackTrace) async {
    if (request.responded) {
      _onError?.call(error, stackTrace);
      return;
    }
    if (error is ValidationException) {
      await request.sendJson({'errors': error.errors}, status: 422);
    } else if (error is PayloadTooLargeException) {
      await request.text('Payload Too Large', status: 413);
    } else {
      (_onError ?? _logError)(error, stackTrace);
      await request.text('Internal Server Error', status: 500);
    }
  }

  static void _logError(Object error, StackTrace stackTrace) =>
      stderr.writeln('[router] unhandled error: $error\n$stackTrace');

  /// Builds the per-worker [DartApp] (routes + optional WT handler).
  DartApp toApp() => DartApp(_routes, wt: wt);
}

/// Extracts `:name` params for a pattern/path pair (the router closure has only
/// the pattern string, not the route instance).
Map<String, String> _paramsFor(String pattern, String path) {
  final segs = pattern.split('/').where((s) => s.isNotEmpty).toList();
  final ps = path.split('/').where((s) => s.isNotEmpty).toList();
  final out = <String, String>{};
  for (var i = 0; i < segs.length && i < ps.length; i++) {
    if (segs[i].startsWith(':')) out[segs[i].substring(1)] = ps[i];
  }
  return out;
}
