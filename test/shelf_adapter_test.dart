import 'dart:async';
import 'dart:convert';

import 'package:dart_apache/dart_apache.dart' hide Router;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

import '../example/shelf_adapter.dart' show fromShelf;

void main() {
  group('fromShelf bridge', () {
    test('runs a shelf_router handler with a path parameter', () async {
      final router = Router()
        ..get('/hello/<name>',
            (shelf.Request r, String name) => shelf.Response.ok('hi $name'));
      final handler = fromShelf(router.call);

      final ex = _FakeExchange('GET', Uri.parse('/hello/ada'));
      await handler(ex, ex.response);

      expect(ex.response.statusCode, 200);
      expect(utf8.decode(ex.response.body), 'hi ada');
    });

    test('propagates status and headers from a shelf.Response', () async {
      handler(shelf.Request r) => shelf.Response(
            418,
            body: 'teapot',
            headers: {'x-demo': 'on'},
          );
      final ex = _FakeExchange('GET', Uri.parse('/x'));
      await fromShelf(handler)(ex, ex.response);

      expect(ex.response.statusCode, 418);
      expect(ex.response.headers['x-demo'], 'on');
      expect(utf8.decode(ex.response.body), 'teapot');
    });
  });
}

class _FakeExchange implements ServerExchange {
  _FakeExchange(this.method, this.uri);
  @override
  final String method;
  @override
  final Uri uri;
  final _FakeResponse response = _FakeResponse();

  @override
  String get protocolVersion => '3';
  @override
  String get scheme => 'https';
  @override
  String get authority => 'localhost:8443';
  @override
  String get protocol => 'h3';
  @override
  String get remoteAddress => '127.0.0.1';
  @override
  int get remotePort => 1;
  @override
  int get contentLength => 0;
  @override
  String? get contentType => null;
  @override
  void forEachHeader(void Function(String name, String value) action) {}
  @override
  Stream<List<int>> get body => const Stream.empty();
  @override
  ServerResponse respond() => response;
}

class _FakeResponse implements ServerResponse {
  int _status = 200;
  final Map<String, String> headers = {};
  final List<int> body = [];

  @override
  int get statusCode => _status;
  @override
  void setStatus(int statusCode, [String? reasonPhrase]) => _status = statusCode;
  @override
  void setHeader(String name, String value) => headers[name.toLowerCase()] = value;
  @override
  Future<void> addStream(Stream<List<int>> body) async {
    await for (final c in body) {
      this.body.addAll(c);
    }
  }

  @override
  Future<void> close() async {}
}
