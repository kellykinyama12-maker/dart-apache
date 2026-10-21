import 'dart:async';
import 'dart:convert';

import 'package:dart_apache/src/php/fastcgi.dart';
import 'package:dart_apache/src/php/php_backend.dart';
import 'package:test/test.dart';

void main() {
  group('FastCGI record codec', () {
    test('encodeFcgiRecord writes header and pads to 8 bytes', () {
      final record = encodeFcgiRecord(FcgiType.stdout, 1, [0x41, 0x42, 0x43]);
      // version, type, requestId(2), contentLength(2), padding, reserved
      expect(record[0], 1); // version
      expect(record[1], FcgiType.stdout);
      expect(record[2] << 8 | record[3], 1); // requestId
      expect(record[4] << 8 | record[5], 3); // content length
      final padding = record[6];
      expect(record.length, 8 + 3 + padding);
      expect((8 + 3 + padding) % 8, 0); // padded to boundary
      expect(record.sublist(8, 11), [0x41, 0x42, 0x43]);
    });

    test('encodeFcgiNameValue uses 1-byte lengths for short values', () {
      final nv = encodeFcgiNameValue('A', 'B');
      expect(nv, [1, 1, 0x41, 0x42]);
    });

    test('encodeFcgiNameValue uses 4-byte length for long values', () {
      final longValue = 'x' * 200;
      final nv = encodeFcgiNameValue('K', longValue);
      expect(nv[0], 1); // name length (1 byte)
      // value length is >= 128 -> 4-byte form with high bit set
      expect(nv[1] & 0x80, 0x80);
      final valueLen = ((nv[1] & 0x7F) << 24) |
          (nv[2] << 16) |
          (nv[3] << 8) |
          nv[4];
      expect(valueLen, 200);
    });

    test('decoder round-trips multiple records across chunk boundaries', () {
      final a = encodeFcgiRecord(FcgiType.stdout, 1, utf8.encode('hello '));
      final b = encodeFcgiRecord(FcgiType.stdout, 1, utf8.encode('world'));
      final c = encodeFcgiRecord(FcgiType.endRequest, 1, [0, 0, 0, 0, 0, 0, 0, 0]);
      final wire = [...a, ...b, ...c];

      final decoder = FcgiRecordDecoder();
      final records = <FcgiRecord>[];
      // Feed one byte at a time to exercise buffering.
      for (final byte in wire) {
        records.addAll(decoder.addBytes([byte]));
      }

      expect(records.length, 3);
      expect(records[0].type, FcgiType.stdout);
      expect(utf8.decode(records[0].content), 'hello ');
      expect(utf8.decode(records[1].content), 'world');
      expect(records[2].type, FcgiType.endRequest);
    });

    test('encodeFcgiParams encodes a map into concatenated name-value pairs', () {
      final bytes = encodeFcgiParams({'A': 'B', 'C': 'D'});
      expect(bytes, [1, 1, 0x41, 0x42, 1, 1, 0x43, 0x44]);
    });
  });

  group('parseCgiStream', () {
    test('parses status and headers, streams body with back-pressure', () async {
      final raw = Stream.fromIterable([
        utf8.encode('Status: 201 Created\r\n'),
        utf8.encode('Content-Type: text/plain\r\n\r\nhel'),
        utf8.encode('lo'),
      ]);
      final response = await parseCgiStream(raw, logTag: 'test');
      expect(response.statusCode, 201);
      expect(response.reasonPhrase, 'Created');
      expect(response.headers['Content-Type'], ['text/plain']);
      final body = await response.body
          .expand((chunk) => chunk)
          .toList()
          .then(utf8.decode);
      expect(body, 'hello');
    });

    test('treats output without a header block as raw body', () async {
      final raw = Stream.fromIterable([utf8.encode('no headers here')]);
      final response = await parseCgiStream(raw, logTag: 'test');
      expect(response.statusCode, 200);
      final body = await response.body
          .expand((chunk) => chunk)
          .toList()
          .then(utf8.decode);
      expect(body, 'no headers here');
    });

    test('raises via onEmpty when the stream is empty', () async {
      final raw = const Stream<List<int>>.empty();
      expect(
        () => parseCgiStream(raw, logTag: 'test', onEmpty: () async => 'boom'),
        throwsA(isA<CgiException>()),
      );
    });
  });
}
