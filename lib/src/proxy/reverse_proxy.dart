import 'dart:async';
import 'dart:io';

import '../config.dart';
import '../pipeline/server_exchange.dart';

/// Hop-by-hop headers that must not be forwarded by a proxy (RFC 7230 §6.1).
const _hopByHop = {
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  // Framing is decided per connection; let each side compute it.
  'content-length',
  'host',
};

/// A streaming HTTP/1.1 reverse proxy with round-robin load balancing across a
/// route's upstreams. Request and response bodies are streamed with
/// back-pressure; hop-by-hop headers are stripped and `X-Forwarded-*` added.
class ReverseProxyHandler {
  ReverseProxyHandler(this.routes) {
    _client.connectionTimeout = const Duration(seconds: 10);
    _client.badCertificateCallback = (_, _, _) => true; // dev upstreams
  }

  final List<ProxyRoute> routes;
  final HttpClient _client = HttpClient();
  final Map<String, int> _rr = {};

  Future<void> close() async => _client.close(force: true);

  /// Returns the first route whose prefix matches [path], or null.
  ProxyRoute? routeFor(String path) {
    for (final route in routes) {
      if (path.startsWith(route.pathPrefix)) return route;
    }
    return null;
  }

  /// Proxies [exchange] to one of [route]'s upstreams (round-robin), writing
  /// the upstream response to [response].
  Future<void> proxy(
    ServerExchange exchange,
    ServerResponse response,
    ProxyRoute route,
  ) async {
    final base = nextUpstream(route);
    final target = Uri.parse(base).replace(
      path: exchange.uri.path,
      query: exchange.uri.hasQuery ? exchange.uri.query : null,
    );

    final HttpClientRequest req;
    try {
      req = await _client.openUrl(exchange.method, target);
    } on SocketException catch (e) {
      await _badGateway(response, 'connect to $base failed: ${e.message}');
      return;
    }
    req.followRedirects = false;

    exchange.forEachHeader((name, value) {
      if (_hopByHop.contains(name.toLowerCase())) return;
      req.headers.set(name, value);
    });
    req.headers.set(HttpHeaders.hostHeader, target.authority);
    req.headers.add('x-forwarded-for', exchange.remoteAddress);
    req.headers.set('x-forwarded-proto', exchange.scheme);
    req.headers.set('x-forwarded-host', exchange.authority);
    if (exchange.contentLength >= 0) req.contentLength = exchange.contentLength;

    try {
      await req.addStream(exchange.body);
      final upstream = await req.close();

      response.setStatus(upstream.statusCode, upstream.reasonPhrase);
      upstream.headers.forEach((name, values) {
        if (_hopByHop.contains(name.toLowerCase())) return;
        for (final value in values) {
          response.setHeader(name, value);
        }
      });

      if (exchange.method == 'HEAD') {
        await upstream.drain<void>();
        await response.close();
        return;
      }
      await response.addStream(upstream);
      await response.close();
    } on HttpException catch (e) {
      await _badGateway(response, e.message);
    } on SocketException catch (e) {
      await _badGateway(response, e.message);
    }
  }

  /// Picks the next upstream for [route] (round-robin).
  String nextUpstream(ProxyRoute route) {
    if (route.upstreams.length == 1) return route.upstreams.first;
    final i = (_rr[route.pathPrefix] ?? 0) % route.upstreams.length;
    _rr[route.pathPrefix] = i + 1;
    return route.upstreams[i];
  }

  Future<void> _badGateway(ServerResponse response, String detail) async {
    final body = '<!DOCTYPE html>\n<html><head><title>502 Bad Gateway</title>'
            '</head><body><h1>502 Bad Gateway</h1><p>$detail</p></body></html>\n'
        .codeUnits;
    response
      ..setStatus(HttpStatus.badGateway)
      ..setHeader(HttpHeaders.contentTypeHeader, 'text/html; charset=UTF-8');
    await response.addStream(Stream.value(body));
    await response.close();
  }
}
