import 'dart:io';

import 'package:dart_apache/dart_apache.dart' hide Router;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';

/// Optional Shelf bridge. This adapts a `shelf.Handler` into a native
/// [DartHandler], so you can mount `shelf_router` + the Shelf middleware
/// ecosystem *inside* dart-apache — without ever using `shelf_io` (which would
/// bind a separate HTTP/1.1 socket and defeat the h3-first transport).
///
/// Shelf is a library you call from a handler here; it never becomes the
/// server. Copy this function into your app (shelf is a dev-dependency of the
/// example, not of the core package).
DartHandler fromShelf(shelf.Handler handler) {
  return (ServerExchange exchange, ServerResponse response) async {
    final headers = <String, List<String>>{};
    exchange.forEachHeader(
        (name, value) => headers.putIfAbsent(name, () => []).add(value));

    final (host, port) = _splitAuthority(exchange.authority);
    final requestedUri = Uri(
      scheme: exchange.scheme,
      host: host,
      port: port,
      path: exchange.uri.path,
      query: exchange.uri.query.isEmpty ? null : exchange.uri.query,
    );

    final request = shelf.Request(
      exchange.method,
      requestedUri,
      headers: headers,
      body: exchange.body,
      protocolVersion: exchange.protocolVersion,
    );

    final res = await handler(request);
    response.setStatus(res.statusCode);
    res.headers.forEach(response.setHeader);
    await response.addStream(res.read());
    await response.close();
  };
}

(String, int?) _splitAuthority(String authority) {
  final i = authority.lastIndexOf(':');
  if (i <= 0) return (authority, null);
  final port = int.tryParse(authority.substring(i + 1));
  return port == null ? (authority, null) : (authority.substring(0, i), port);
}

Router _demoRouter() {
  final router = Router();
  router.get('/shelf/ping', (shelf.Request r) => shelf.Response.ok('pong\n'));
  // Path parameters are a Shelf strength the native seam leaves to this bridge.
  router.get('/shelf/hello/<name>', (shelf.Request r, String name) {
    return shelf.Response.ok('hello $name\n');
  });
  return router;
}

/// Top-level builder: mount the Shelf router under a native prefix route.
DartApp buildApp(ServerConfig config) => DartApp([
      DartRoute.prefix('/shelf', fromShelf(_demoRouter().call)),
    ]);

Future<void> main(List<String> arguments) async {
  final config = ServerConfig.fromArgs(arguments);
  if (!Directory(config.documentRoot).existsSync()) {
    stderr.writeln('DocumentRoot does not exist: ${config.documentRoot}');
    exitCode = 2;
    return;
  }
  final http3 = arguments.contains('--http3');
  final server = ServerSupervisor(
    config,
    kind: http3 ? WorkerKind.unified : WorkerKind.http1,
    appBuilder: buildApp,
  );
  ProcessSignal.sigint.watch().listen((_) async {
    await server.stop();
    exit(0);
  });
  await server.start();
}
