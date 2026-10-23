import 'dart:async';
import 'dart:convert';

import '../config.dart';
import '../wt/wt_handler.dart';
import 'server_exchange.dart';

/// An in-process request handler, native to the transport-agnostic
/// [ServerExchange]. It runs inside the serving isolate (no subprocess, no
/// extra network hop) and has full access to HTTP/3 streaming and the request
/// body, so the same handler serves over HTTP/3 and HTTP/1.1 identically.
///
/// The handler owns the full response lifecycle: set status/headers on
/// [response], stream the body, and `close()` it — or use one of the
/// [DartResponseWrite] conveniences (`writeText`, `writeBytes`, `writeJson`),
/// which do all of that.
typedef DartHandler = FutureOr<void> Function(
  ServerExchange exchange,
  ServerResponse response,
);

/// Ergonomic one-shot writers that set the status, a content type, the body,
/// and close the response — so a handler cannot forget to close.
extension DartResponseWrite on ServerResponse {
  Future<void> writeBytes(
    List<int> body, {
    int status = 200,
    String contentType = 'application/octet-stream',
  }) async {
    setStatus(status);
    setHeader('content-type', contentType);
    setHeader('content-length', '${body.length}');
    await addStream(Stream<List<int>>.value(body));
    await close();
  }

  Future<void> writeText(
    String body, {
    int status = 200,
    String contentType = 'text/plain; charset=utf-8',
  }) =>
      writeBytes(utf8.encode(body),
          status: status, contentType: contentType);

  Future<void> writeJson(
    Object? value, {
    int status = 200,
  }) =>
      writeText(jsonEncode(value),
          status: status, contentType: 'application/json; charset=utf-8');
}

/// Builds the per-worker [DartApp]. Must be a **top-level or static** function:
/// it is invoked inside each worker isolate to construct that isolate's own
/// handlers, so handler closures never have to cross the isolate boundary.
typedef DartAppBuilder = DartApp Function(ServerConfig config);

/// One route: a [handler] bound to a path [pattern], optionally constrained to
/// a set of [methods]. A route is either an exact-path match or a path-prefix
/// match ([exact] = false).
class DartRoute {
  const DartRoute(
    this.pattern,
    this.handler, {
    this.exact = false,
    this.methods,
    this.segments,
  });

  /// Exact-path route: matches [path] only when equal to it.
  const DartRoute.exact(
    String path,
    DartHandler handler, {
    Set<String>? methods,
  }) : this(path, handler, exact: true, methods: methods);

  /// Prefix route: matches any path at or under [prefix].
  const DartRoute.prefix(
    String prefix,
    DartHandler handler, {
    Set<String>? methods,
  }) : this(prefix, handler, exact: false, methods: methods);

  /// Parameterized route: `:name` segments match any single non-empty segment
  /// (e.g. `/users/:id` matches `/users/42`). Extract them with [paramsFor].
  factory DartRoute.path(
    String pattern,
    DartHandler handler, {
    Set<String>? methods,
  }) =>
      DartRoute(pattern, handler,
          exact: true, methods: methods, segments: _split(pattern));

  final String pattern;
  final DartHandler handler;
  final bool exact;

  /// Allowed request methods (upper-case), or null to accept any method.
  final Set<String>? methods;

  /// Non-null for a parameterized route: the pattern split into segments.
  final List<String>? segments;

  static List<String> _split(String p) =>
      p.split('/').where((s) => s.isNotEmpty).toList();

  /// Extracts `:name` path parameters from [path] for this route's pattern.
  Map<String, String> paramsFor(String path) {
    final segs = segments;
    if (segs == null) return const {};
    final ps = _split(path);
    final out = <String, String>{};
    for (var i = 0; i < segs.length && i < ps.length; i++) {
      if (segs[i].startsWith(':')) out[segs[i].substring(1)] = ps[i];
    }
    return out;
  }

  bool matches(String method, String path) {
    if (methods != null && !methods!.contains(method.toUpperCase())) {
      return false;
    }
    final segs = segments;
    if (segs != null) {
      final ps = _split(path);
      if (ps.length != segs.length) return false;
      for (var i = 0; i < segs.length; i++) {
        if (segs[i].startsWith(':')) continue; // param matches any segment
        if (segs[i] != ps[i]) return false;
      }
      return true;
    }
    if (exact) return path == pattern;
    if (path == pattern) return true;
    // Prefix must align on a path segment boundary: `/api` matches `/api` and
    // `/api/x` but not `/apikey`.
    if (!path.startsWith(pattern)) return false;
    if (pattern.endsWith('/')) return true;
    return path.length > pattern.length && path[pattern.length] == '/';
  }
}

/// A per-worker table of in-process [DartRoute]s. Exact routes win over prefix
/// routes; among prefix routes the longest pattern wins (like the reverse
/// proxy). Construct one from a [DartAppBuilder] inside each worker.
///
/// An optional [wt] handler owns native WebTransport sessions in-process (it
/// takes precedence over the PHP bridge / echo when set).
class DartApp {
  DartApp(List<DartRoute> routes, {this.wt})
      : routes = List.unmodifiable(
          [...routes]..sort((a, b) {
            if (a.exact != b.exact) return a.exact ? -1 : 1; // exact first
            return b.pattern.length.compareTo(a.pattern.length); // longest
          }),
        );

  final List<DartRoute> routes;

  /// Optional native WebTransport session handler (null = PHP bridge / echo).
  final WtHandler? wt;

  /// The first route matching [method] + [path] under the ordering above, or
  /// null when none match (the pipeline then falls through to static/PHP).
  DartRoute? match(String method, String path) {
    for (final r in routes) {
      if (r.matches(method, path)) return r;
    }
    return null;
  }
}
