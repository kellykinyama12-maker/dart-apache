import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_apache/dart_apache.dart';
import 'package:test/test.dart';

void main() {
  group('static serving: conditional GET + ETag + ranges', () {
    late Directory dir;
    late RequestPipeline pipeline;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('da_static_');
      File('${dir.path}/data.txt').writeAsStringSync('0123456789');
      pipeline = RequestPipeline(ServerConfig(documentRoot: dir.path));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<_FakeResponse> req(
      String method, {
      Map<String, String> headers = const {},
    }) async {
      final ex = _FakeExchange(method, Uri.parse('/data.txt'), headers);
      await pipeline.serve(ex);
      return ex.response;
    }

    test('200 carries ETag, Accept-Ranges, Content-Length, Last-Modified', () async {
      final r = await req('GET');
      expect(r.statusCode, 200);
      expect(r.headers['etag'], isNotNull);
      expect(r.headers['accept-ranges'], 'bytes');
      expect(r.headers['content-length'], '10');
      expect(r.headers['last-modified'], isNotNull);
      expect(utf8.decode(r.body), '0123456789');
    });

    test('HEAD returns headers but no body', () async {
      final r = await req('HEAD');
      expect(r.statusCode, 200);
      expect(r.headers['content-length'], '10');
      expect(r.body, isEmpty);
    });

    test('If-None-Match with the current ETag -> 304, no body', () async {
      final first = await req('GET');
      final etag = first.headers['etag']!;
      final r = await req('GET', headers: {'if-none-match': etag});
      expect(r.statusCode, 304);
      expect(r.body, isEmpty);
      expect(r.headers['etag'], etag);
    });

    test('If-None-Match: * -> 304', () async {
      final r = await req('GET', headers: {'if-none-match': '*'});
      expect(r.statusCode, 304);
    });

    test('If-Modified-Since in the future -> 304; past -> 200', () async {
      final future = HttpDate.format(DateTime.now().add(const Duration(days: 1)));
      expect((await req('GET', headers: {'if-modified-since': future})).statusCode, 304);
      final past = HttpDate.format(DateTime(2000));
      expect((await req('GET', headers: {'if-modified-since': past})).statusCode, 200);
    });

    test('Range bytes=0-3 -> 206 with Content-Range and sliced body', () async {
      final r = await req('GET', headers: {'range': 'bytes=0-3'});
      expect(r.statusCode, 206);
      expect(r.headers['content-range'], 'bytes 0-3/10');
      expect(r.headers['content-length'], '4');
      expect(utf8.decode(r.body), '0123');
    });

    test('suffix Range bytes=-4 -> last 4 bytes', () async {
      final r = await req('GET', headers: {'range': 'bytes=-4'});
      expect(r.statusCode, 206);
      expect(r.headers['content-range'], 'bytes 6-9/10');
      expect(utf8.decode(r.body), '6789');
    });

    test('open-ended Range bytes=5- -> to end', () async {
      final r = await req('GET', headers: {'range': 'bytes=5-'});
      expect(r.statusCode, 206);
      expect(r.headers['content-range'], 'bytes 5-9/10');
      expect(utf8.decode(r.body), '56789');
    });

    test('unsatisfiable Range -> 416 with Content-Range bytes */size', () async {
      final r = await req('GET', headers: {'range': 'bytes=100-200'});
      expect(r.statusCode, 416);
      expect(r.headers['content-range'], 'bytes */10');
    });

    test('If-Range mismatch ignores the range (full 200)', () async {
      final r = await req('GET',
          headers: {'range': 'bytes=0-3', 'if-range': '"stale-etag"'});
      expect(r.statusCode, 200);
      expect(utf8.decode(r.body), '0123456789');
    });
  });
}

class _FakeExchange implements ServerExchange {
  _FakeExchange(this.method, this.uri, this._headers);
  @override
  final String method;
  @override
  final Uri uri;
  final Map<String, String> _headers;
  final _FakeResponse response = _FakeResponse();

  @override
  String get protocolVersion => '1.1';
  @override
  String get scheme => 'http';
  @override
  String get authority => 'localhost';
  @override
  String get protocol => 'http/1.1';
  @override
  String get remoteAddress => '127.0.0.1';
  @override
  int get remotePort => 1;
  @override
  int get contentLength => 0;
  @override
  String? get contentType => null;
  @override
  void forEachHeader(void Function(String name, String value) action) =>
      _headers.forEach(action);
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
