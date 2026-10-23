import 'dart:io';

import 'package:dart_apache/dart_apache.dart';

/// Native-Dart equivalents of the PHP sample app in `public/*.php`, so the same
/// behaviors can be served without php-cgi and compared for parity against the
/// PHP versions. Each route mirrors one PHP file, mounted under `/parity/`:
///
///   /parity/           <->  index.php
///   /parity/echo       <->  echo.php
///   /parity/cacheable  <->  cacheable.php
///   /parity/swr        <->  swr.php
///   /parity/status     <->  status_echo.php
///   /parity/csrf       <->  csrf_echo.php
///   /parity/fc         <->  fc.php
///
/// Run:
///   dart run example/parity_app.dart --root=./public --port=8080
/// Then compare e.g. `GET /echo.php` with `POST /parity/echo`.
DartApp buildParityApp(ServerConfig config) => DartApp([
      DartRoute.exact('/parity/', (e, r) async {
        final name = e.uri.queryParameters['name'] ?? 'world';
        r.setHeader('x-powered-by', 'dart-apache');
        await r.writeText(_indexHtml(name, config.serverSoftware, e.method),
            contentType: 'text/html; charset=UTF-8');
      }, methods: {'GET'}),
      DartRoute.exact('/parity/echo', (e, r) async {
        final bodyBytes =
            await e.body.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
        final form = _parseForm(String.fromCharCodes(bodyBytes));
        final len = e.contentLength < 0 ? 0 : e.contentLength;
        await r.writeText(
          'method=${e.method}\n'
          'name=${form['name'] ?? '-'}\n'
          'len=$len\n',
          contentType: 'text/plain; charset=UTF-8',
        );
      }),
      DartRoute.exact('/parity/cacheable', (e, r) async {
        r.setHeader('cache-control', 'max-age=60');
        await r.writeText('generated-at=${_microtime()}\n',
            contentType: 'text/plain; charset=UTF-8');
      }, methods: {'GET'}),
      DartRoute.exact('/parity/swr', (e, r) async {
        r.setHeader('cache-control', 'max-age=0, stale-while-revalidate=30');
        await r.writeText('generated-at=${_microtime()}\n',
            contentType: 'text/plain; charset=UTF-8');
      }, methods: {'GET'}),
      DartRoute.exact('/parity/status', (e, r) async {
        r.setHeader('x-demo-header', 'demo-value');
        await r.writeJson({'msg': 'page-expired', 'code': 419}, status: 419);
      }),
      DartRoute.exact('/parity/csrf', (e, r) async {
        final h = _headerMap(e);
        final bodyBytes =
            await e.body.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
        await r.writeJson({
          'method': e.method,
          'cookie': h['cookie'],
          'x_csrf_token': h['x-csrf-token'],
          'x_xsrf_token': h['x-xsrf-token'],
          'authorization': h['authorization'],
          'x_requested_with': h['x-requested-with'],
          'content_type': h['content-type'],
          'body': String.fromCharCodes(bodyBytes),
        });
      }),
      DartRoute.exact('/parity/fc', (e, r) async {
        await r.writeJson({
          'front_controller': true,
          'request_uri': e.uri.hasQuery ? '${e.uri.path}?${e.uri.query}' : e.uri.path,
          'method': e.method,
          'script_name': e.uri.path,
        });
      }),
    ]);

String _indexHtml(String name, String software, String method) => '''
<!DOCTYPE html>
<html>
<head><title>dart-apache + PHP</title></head>
<body>
  <h1>Hello, ${_esc(name)}!</h1>
  <p>Served by ${_esc(software)}</p>
  <p>Request method: ${_esc(method)}</p>
  <p>The time is ${_now()}.</p>
</body>
</html>
''';

/// Matches PHP `htmlspecialchars` (default ENT_QUOTES | ENT_HTML401 off → it
/// escapes &, <, >, and double quotes; single quotes only with ENT_QUOTES).
String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// PHP `date('Y-m-d H:i:s')` in UTC.
String _now() {
  final t = DateTime.now().toUtc();
  String p(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${p(t.month)}-${p(t.day)} '
      '${p(t.hour)}:${p(t.minute)}:${p(t.second)}';
}

/// PHP `microtime(true)` — seconds since the epoch as a float.
String _microtime() =>
    (DateTime.now().microsecondsSinceEpoch / 1000000).toString();

Map<String, String> _parseForm(String body) {
  final out = <String, String>{};
  if (body.isEmpty) return out;
  for (final pair in body.split('&')) {
    final i = pair.indexOf('=');
    if (i < 0) continue;
    out[Uri.decodeQueryComponent(pair.substring(0, i))] =
        Uri.decodeQueryComponent(pair.substring(i + 1));
  }
  return out;
}

Map<String, String> _headerMap(ServerExchange e) {
  final h = <String, String>{};
  e.forEachHeader((name, value) => h[name.toLowerCase()] = value);
  return h;
}

Future<void> main(List<String> arguments) async {
  final config = ServerConfig.fromArgs(arguments);
  if (!Directory(config.documentRoot).existsSync()) {
    stderr.writeln('DocumentRoot does not exist: ${config.documentRoot}');
    exitCode = 2;
    return;
  }
  final server = ServerSupervisor(config, appBuilder: buildParityApp);
  ProcessSignal.sigint.watch().listen((_) async {
    await server.stop();
    exit(0);
  });
  await server.start();
}
