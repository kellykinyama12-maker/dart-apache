import 'dart:async';
import 'dart:convert';

import '../pipeline/dart_handler.dart';
import '../pipeline/server_exchange.dart';
import '../wt/wt_handler.dart';
import 'template/blaze.dart';
import 'validation.dart';

/// A request+response facade for route handlers: path params, query, body, and
/// convenient responders (view/json/text/html/redirect). The Dartisan analog of
/// Laravel's `Request` + response helpers.
class Request {
  Request(this.exchange, this.response, this.params, this._views);

  final ServerExchange exchange;
  final ServerResponse response;

  /// `:name` path parameters captured from the route pattern.
  final Map<String, String> params;

  final BlazeEngine? _views;

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

  /// The raw request body bytes.
  Future<List<int>> bodyBytes() =>
      exchange.body.fold<List<int>>(<int>[], (a, b) => a..addAll(b));

  /// The request body as UTF-8 text.
  Future<String> body() async => utf8.decode(await bodyBytes());

  /// The request body parsed as JSON.
  Future<Object?> json() async => jsonDecode(await body());

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
    return response.writeText(engine.render(view, data),
        contentType: 'text/html; charset=UTF-8');
  }

  Future<void> html(String markup, {int status = 200}) => response
      .writeText(markup, status: status, contentType: 'text/html; charset=UTF-8');

  Future<void> text(String body, {int status = 200}) =>
      response.writeText(body, status: status);

  Future<void> sendJson(Object? value, {int status = 200}) =>
      response.writeJson(value, status: status);

  Future<void> redirect(String location, {int status = 302}) async {
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

/// A Laravel-style router over the in-process [DartApp] pipeline: methods,
/// `:param` paths, groups (prefix + middleware), global middleware, and a Blaze
/// view engine. Build it into a [DartApp] with [toApp].
class Router {
  // Named params can't be underscore-prefixed, so no initializing formal here.
  // ignore: prefer_initializing_formals
  Router({BlazeEngine? views}) : _views = views;

  final BlazeEngine? _views;
  final List<DartRoute> _routes = [];
  final List<Middleware> _globalMiddleware = [];

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
      final request = Request(exchange, response, params, _views);
      await _runChain(request, chain, action);
    }, methods: {method});
    _routes.add(route);
  }

  Future<void> _runChain(
    Request request,
    List<Middleware> chain,
    RouteAction action,
  ) {
    var i = -1;
    FutureOr<void> next() {
      i++;
      if (i < chain.length) return chain[i](request, next);
      return action(request);
    }

    return Future<void>.sync(next);
  }

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
