import 'dart:io';

import 'package:dart_apache/dart_apache.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('mimeTypeFor', () {
    test('known extensions', () {
      expect(mimeTypeFor('a.html'), 'text/html; charset=UTF-8');
      expect(mimeTypeFor('a.css'), 'text/css; charset=UTF-8');
      expect(mimeTypeFor('a.png'), 'image/png');
    });

    test('unknown extension defaults to octet-stream', () {
      expect(mimeTypeFor('a.unknownext'), 'application/octet-stream');
    });
  });

  group('Alt-Svc advertisement', () {
    test('disabled by default', () {
      final config = ServerConfig(documentRoot: '.');
      expect(config.altSvcHeader, isNull);
    });

    test('advertises h3 on the configured port', () {
      final config =
          ServerConfig(documentRoot: '.', altSvcH3Port: 443, altSvcMaxAge: 3600);
      expect(config.altSvcHeader, 'h3=":443"; ma=3600');
    });

    test('parses --advertise-h3 flag', () {
      final config = ServerConfig.fromArgs(['--advertise-h3=4433']);
      expect(config.altSvcH3Port, 4433);
      expect(config.altSvcHeader, 'h3=":4433"; ma=86400');
    });
  });

  group('TLS / dev config', () {
    test('dev mode and cert paths default off', () {
      final config = ServerConfig(documentRoot: '.');
      expect(config.devMode, isFalse);
      expect(config.tlsCertPath, isNull);
      expect(config.tlsKeyPath, isNull);
    });

    test('parses --dev and --tls-cert/--tls-key flags', () {
      final config = ServerConfig.fromArgs(
        ['--dev', '--tls-cert=c.pem', '--tls-key=k.pem'],
      );
      expect(config.devMode, isTrue);
      expect(config.tlsCertPath, 'c.pem');
      expect(config.tlsKeyPath, 'k.pem');
    });
  });

  group('reverse proxy routes', () {
    test('parses repeatable --proxy flags, longest prefix first', () {
      final config = ServerConfig.fromArgs([
        '--proxy=/=http://a:9000',
        '--proxy=/api=http://b:9000,http://c:9000',
      ]);
      expect(config.proxyRoutes.length, 2);
      // Longest prefix sorts first.
      expect(config.proxyRoutes.first.pathPrefix, '/api');
      expect(config.proxyRoutes.first.upstreams, ['http://b:9000', 'http://c:9000']);
      expect(config.proxyRoutes.last.pathPrefix, '/');
    });

    test('routeFor matches the longest prefix', () {
      final handler = ReverseProxyHandler(const [
        ProxyRoute('/api', ['http://b:9000']),
        ProxyRoute('/', ['http://a:9000']),
      ]);
      expect(handler.routeFor('/api/users')?.pathPrefix, '/api');
      expect(handler.routeFor('/index.html')?.pathPrefix, '/');
    });

    test('round-robins across upstreams', () {
      final handler = ReverseProxyHandler(const [
        ProxyRoute('/', ['http://a:1', 'http://b:1', 'http://c:1']),
      ]);
      final route = handler.routeFor('/x')!;
      final picks = [
        for (var i = 0; i < 4; i++) handler.nextUpstream(route),
      ];
      expect(picks, ['http://a:1', 'http://b:1', 'http://c:1', 'http://a:1']);
    });
  });

  group('backoffDelay', () {
    test('first restart is immediate', () {
      expect(backoffDelay(1), Duration.zero);
    });

    test('grows exponentially from the base', () {
      expect(backoffDelay(2), const Duration(milliseconds: 200));
      expect(backoffDelay(3), const Duration(milliseconds: 400));
      expect(backoffDelay(4), const Duration(milliseconds: 800));
    });

    test('is capped at the maximum', () {
      expect(
        backoffDelay(50, max: const Duration(seconds: 30)),
        const Duration(seconds: 30),
      );
    });
  });

  group('RequestResolver', () {
    late Directory root;
    late RequestResolver resolver;

    setUp(() {
      root = Directory.systemTemp.createTempSync('dart_apache_test');
      File(p.join(root.path, 'index.html')).writeAsStringSync('home');
      File(p.join(root.path, 'style.css')).writeAsStringSync('body{}');
      File(p.join(root.path, 'info.php')).writeAsStringSync('<?php');
      Directory(p.join(root.path, 'sub')).createSync();
      File(p.join(root.path, 'sub', 'page.html')).writeAsStringSync('sub');
      resolver = RequestResolver(ServerConfig(documentRoot: root.path));
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('serves DirectoryIndex for root', () {
      final r = resolver.resolve('/');
      expect(r.kind, ResolutionKind.staticFile);
      expect(p.basename(r.filePath), 'index.html');
    });

    test('serves static file', () {
      final r = resolver.resolve('/style.css');
      expect(r.kind, ResolutionKind.staticFile);
    });

    test('identifies php script', () {
      final r = resolver.resolve('/info.php');
      expect(r.kind, ResolutionKind.phpScript);
      expect(r.scriptName, '/info.php');
    });

    test('splits PATH_INFO after php script', () {
      final r = resolver.resolve('/info.php/extra/path');
      expect(r.kind, ResolutionKind.phpScript);
      expect(r.scriptName, '/info.php');
      expect(r.pathInfo, '/extra/path');
    });

    test('rejects directory traversal', () {
      final r = resolver.resolve('/../secret');
      expect(r.kind, ResolutionKind.forbidden);
    });

    test('missing file is not found', () {
      final r = resolver.resolve('/nope.txt');
      expect(r.kind, ResolutionKind.notFound);
    });
  });
}
