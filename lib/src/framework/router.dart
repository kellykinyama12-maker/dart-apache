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

  /// A query parameter parsed as an int, or [fallback] (handy for `?page=`).
  int queryInt(String name, [int fallback = 0]) =>
      int.tryParse(query(name) ?? '') ?? fallback;

  /// A query parameter read as a boolean (`1/true/on/yes` are true).
  bool queryBool(String name) {
    final v = query(name)?.toLowerCase();
    return v == '1' || v == 'true' || v == 'on' || v == 'yes';
  }

  /// A request header (case-insensitive).
  String? header(String name) {
    final want = name.toLowerCase();
    String? found;
    exchange.forEachHeader((n, v) {
      if (n.toLowerCase() == want) found = v;
    });
    return found;
  }

  /// True when the request method equals [verb] (case-insensitive).
  bool isMethod(String verb) => method.toUpperCase() == verb.toUpperCase();

  /// True for an AJAX request (`X-Requested-With: XMLHttpRequest`).
  bool get isAjax =>
      (header('x-requested-with') ?? '').toLowerCase() == 'xmlhttprequest';

  /// True when the request body is declared as JSON (`Content-Type`).
  bool get isJson =>
      (header('content-type') ?? '').toLowerCase().contains('json');

  /// True when the client prefers a JSON response (AJAX, or an `Accept` header
  /// that favours JSON over HTML) — handy for returning JSON vs a redirect.
  bool get wantsJson {
    if (isAjax) return true;
    final accept = (header('accept') ?? '').toLowerCase();
    if (accept.contains('application/json') || accept.contains('+json')) {
      return !accept.contains('text/html');
    }
    return false;
  }

  /// A cookie value by [name] (parsed from the `Cookie` header), or null.
  String? cookie(String name) {
    final raw = header('cookie');
    if (raw == null) return null;
    for (final pair in raw.split(';')) {
      final i = pair.indexOf('=');
      if (i < 0) continue;
      if (pair.substring(0, i).trim() == name) {
        return Uri.decodeComponent(pair.substring(i + 1).trim());
      }
    }
    return null;
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
    final data = await input();
    final errors = Validator.validate(data, rules);
    if (errors.isNotEmpty) throw ValidationException(errors);
    return data;
  }

  /// All request input merged: query string + body (JSON object or
  /// form-urlencoded).
  Future<Map<String, Object?>> input() async {
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
    return data;
  }

  /// Only the listed [keys] from [input] (for controlled mass-assignment).
  Future<Map<String, Object?>> only(List<String> keys) async {
    final data = await input();
    return {
      for (final k in keys)
        if (data.containsKey(k)) k: data[k],
    };
  }

  /// Everything from [input] except the listed [keys].
  Future<Map<String, Object?>> except(List<String> keys) async {
    final data = await input();
    return {
      for (final e in data.entries)
        if (!keys.contains(e.key)) e.key: e.value,
    };
  }

  /// An input [field] (query or body) as a string, or [fallback].
  Future<String?> string(String field, [String? fallback]) async {
    final v = (await input())[field];
    return v == null ? fallback : '$v';
  }

  /// An input [field] parsed as an int, or [fallback].
  Future<int> integer(String field, [int fallback = 0]) async {
    final v = (await input())[field];
    return v is int ? v : int.tryParse('${v ?? ''}') ?? fallback;
  }

  /// An input [field] read as a boolean (`1/true/on/yes` are true).
  Future<bool> boolean(String field) async {
    final v = '${(await input())[field] ?? ''}'.toLowerCase();
    return v == '1' || v == 'true' || v == 'on' || v == 'yes';
  }

  /// Whether [field] is present in the request input (even if empty).
  Future<bool> has(String field) async => (await input()).containsKey(field);

  /// Whether [field] is present and non-empty.
  Future<bool> filled(String field) async {
    final v = (await input())[field];
    return v != null && '$v'.isNotEmpty;
  }

  /// Whether [field] is absent from the request input.
  Future<bool> missing(String field) async =>
      !(await input()).containsKey(field);

  /// A value flashed as "old input" by the previous request (for form
  /// repopulation), or [fallback].
  Object? old(String field, [Object? fallback]) {
    if (_sessions == null) return fallback;
    final o = session.flashed('_old');
    return (o is Map && o.containsKey(field)) ? o[field] : fallback;
  }

  /// Flashes [e]'s errors + the current input and redirects back (to the
  /// `Referer`, or [fallback]) — the Laravel `back()->withErrors()->withInput()`.
  Future<void> backWithErrors(ValidationException e,
      {String fallback = '/'}) async {
    session.flash('_errors', e.errors);
    session.flash('_old', await input());
    await redirect(header('referer') ?? fallback);
  }

  // ---- responders (each sets status + content-type, writes, and closes) ----

  /// Renders a Blaze [view] with [data] (requires a view engine on the router).
  /// When a session is configured, `errors` and `old` (from the flash) are
  /// injected into the view data so `@error` / `{{ old.x }}` work automatically
  /// ([data] overrides them).
  Future<void> view(String view,
      [Map<String, Object?> data = const {}, int status = 200]) {
    final engine = _views;
    if (engine == null) {
      throw StateError('Router has no view engine; pass Router(views: ...)');
    }
    _responded = true;
    final enriched = <String, Object?>{
      if (_sessions != null) 'errors': session.flashed('_errors') ?? const {},
      if (_sessions != null) 'old': session.flashed('_old') ?? const {},
      if (_sessions != null)
        'flash': {
          for (final e in session.flashBag.entries)
            if (!e.key.startsWith('_')) e.key: e.value,
        },
      ...data,
    };
    _persistSession();
    return response.writeText(engine.render(view, enriched),
        status: status, contentType: 'text/html; charset=UTF-8');
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

  /// Responds `201 Created` with a JSON body, optionally setting `Location`.
  Future<void> created(Object? value, {String? location}) {
    if (location != null) response.setHeader('location', location);
    return sendJson(value, status: 201);
  }

  /// Responds `204 No Content` (empty body).
  Future<void> noContent() async {
    _responded = true;
    _persistSession();
    response
      ..setStatus(204)
      ..setHeader('content-length', '0');
    await response.close();
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

  /// Redirects to the referring page (the `Referer` header), or [fallback].
  Future<void> back({String fallback = '/', int status = 302}) =>
      redirect(header('referer') ?? fallback, status: status);

  /// Flashes each entry of [data] to the session (surviving one redirect) and
  /// redirects to [location]. The flashed values appear in the next view's
  /// `flash` map (the post/redirect/get pattern).
  Future<void> redirectWith(String location, Map<String, Object?> data,
      {int status = 302}) {
    data.forEach(session.flash);
    return redirect(location, status: status);
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

/// An HTTP error with a status code, caught by the router's error boundary and
/// turned into a response with that status. Raise it with [abort].
class HttpException implements Exception {
  HttpException(this.status, [this.message]);
  final int status;
  final String? message;
  @override
  String toString() => 'HttpException($status): ${message ?? ''}';
}

/// Aborts the current request with [status] (e.g. `abort(404)`), optionally with
/// a [message] body. The router's error boundary writes the response.
Never abort(int status, [String? message]) => throw HttpException(status, message);

/// Aborts with [status] when [condition] is true.
void abortIf(bool condition, int status, [String? message]) {
  if (condition) throw HttpException(status, message);
}

/// Aborts with [status] unless [condition] is true.
void abortUnless(bool condition, int status, [String? message]) {
  if (!condition) throw HttpException(status, message);
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
  final Map<String, String> _names = {};

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
  String _namePrefix = '';
  final List<Middleware> _scoped = [];

  /// Registers global middleware (runs for every route).
  void use(Middleware middleware) => _globalMiddleware.add(middleware);

  void get(String pattern, RouteAction action, {String? name}) =>
      _add('GET', pattern, action, name: name);
  void post(String pattern, RouteAction action, {String? name}) =>
      _add('POST', pattern, action, name: name);
  void put(String pattern, RouteAction action, {String? name}) =>
      _add('PUT', pattern, action, name: name);
  void patch(String pattern, RouteAction action, {String? name}) =>
      _add('PATCH', pattern, action, name: name);
  void delete(String pattern, RouteAction action, {String? name}) =>
      _add('DELETE', pattern, action, name: name);

  /// Builds the URL for a named route, substituting `:param` segments from
  /// [params]. Leftover params are appended as a query string.
  String urlFor(String name, [Map<String, Object?> params = const {}]) {
    final pattern = _names[name];
    if (pattern == null) {
      throw ArgumentError('No route named "$name"');
    }
    final used = <String>{};
    final path = pattern.split('/').map((seg) {
      if (seg.startsWith(':')) {
        final key = seg.substring(1);
        if (!params.containsKey(key)) {
          throw ArgumentError('Missing route param "$key" for "$name"');
        }
        used.add(key);
        return Uri.encodeComponent('${params[key]}');
      }
      return seg;
    }).join('/');
    final query = <String, String>{
      for (final e in params.entries)
        if (!used.contains(e.key)) e.key: '${e.value}',
    };
    if (query.isEmpty) return path;
    return Uri(path: path, queryParameters: query).toString();
  }

  /// Groups routes under a path [prefix] and optional [middleware]. A [name]
  /// prefix is prepended to the `name:` of routes registered inside [build]
  /// (e.g. `group('/admin', ..., name: 'admin.')`).
  void group(
    String prefix,
    void Function() build, {
    List<Middleware> middleware = const [],
    String name = '',
  }) {
    final savedPrefix = _prefix;
    final savedName = _namePrefix;
    final savedLen = _scoped.length;
    _prefix = '$_prefix$prefix';
    _namePrefix = '$_namePrefix$name';
    _scoped.addAll(middleware);
    build();
    _prefix = savedPrefix;
    _namePrefix = savedName;
    _scoped.removeRange(savedLen, _scoped.length);
  }

  void _add(String method, String pattern, RouteAction action, {String? name}) {
    final full = '$_prefix$pattern';
    if (name != null) _names['$_namePrefix$name'] = full;
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
    } else if (error is HttpException) {
      await request.text(error.message ?? _statusText(error.status),
          status: error.status);
    } else {
      (_onError ?? _logError)(error, stackTrace);
      await request.text('Internal Server Error', status: 500);
    }
  }

  static String _statusText(int status) {
    switch (status) {
      case 400:
        return 'Bad Request';
      case 401:
        return 'Unauthorized';
      case 403:
        return 'Forbidden';
      case 404:
        return 'Not Found';
      case 405:
        return 'Method Not Allowed';
      case 409:
        return 'Conflict';
      case 422:
        return 'Unprocessable Entity';
      case 429:
        return 'Too Many Requests';
      default:
        return 'Error $status';
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
