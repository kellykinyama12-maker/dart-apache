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
