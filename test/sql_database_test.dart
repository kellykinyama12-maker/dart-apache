import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_apache/dart_apache.dart';
import 'package:test/test.dart';

/// A loopback server speaking dart-db-server's JSON line protocol. Records the
/// SQL it receives and replies with a programmable response per request.
class _FakeDb {
  _FakeDb(this._server) {
    _server.listen(_handle);
  }
  final ServerSocket _server;
  final List<String> sql = [];
  Map<String, Object?> Function(String sql)? responder;

  int get port => _server.port;

  static Future<_FakeDb> start() async =>
      _FakeDb(await ServerSocket.bind('127.0.0.1', 0));

  Future<void> close() => _server.close();

  void _handle(Socket socket) {
    final buf = <int>[];
    socket.listen((chunk) {
      for (final b in chunk) {
        if (b != 0x0a) {
          buf.add(b);
          continue;
        }
        final req = (jsonDecode(utf8.decode(buf)) as Map).cast<String, Object?>();
        buf.clear();
        final q = req['sql'] as String;
        sql.add(q);
        final base = responder?.call(q) ?? {'ok': true, 'affected': 0};
        socket.add(utf8.encode('${jsonEncode({'id': req['id'], ...base})}\n'));
      }
    });
  }
}

void main() {
  group('SqlDatabase wire driver', () {
    late _FakeDb server;
    late SqlDatabase db;

    setUp(() async {
      server = await _FakeDb.start();
      db = SqlDatabase(host: '127.0.0.1', port: server.port);
    });

    tearDown(() async {
      await db.close();
      await server.close();
    });

    test('select builds WHERE/ORDER/LIMIT/OFFSET and maps rows', () async {
      server.responder = (_) => {
            'ok': true,
            'columns': ['id', 'name', 'age'],
            'rows': [
              [1, 'ada', 36],
              [2, 'grace', 85],
            ],
          };
      final rows = await db
          .table('users')
          .where('age', '>=', 18)
          .orderBy('name')
          .limit(5)
          .offset(2)
          .get();

      expect(server.sql.single,
          'SELECT * FROM users WHERE age >= 18 ORDER BY name ASC LIMIT 5 OFFSET 2');
      expect(rows, [
        {'id': 1, 'name': 'ada', 'age': 36},
        {'id': 2, 'name': 'grace', 'age': 85},
      ]);
    });

    test('whereIn, like, and null conditions render as SQL', () async {
      server.responder = (_) => {'ok': true, 'columns': [], 'rows': []};
      await db.table('t').whereIn('id', [1, 2, 3]).get();
      await db.table('t').where('name', 'like', 'ad').get();
      await db.table('t').where('deleted_at', null).get();
      expect(server.sql[0], 'SELECT * FROM t WHERE id IN (1, 2, 3)');
      expect(server.sql[1], "SELECT * FROM t WHERE name LIKE '%ad%'");
      expect(server.sql[2], 'SELECT * FROM t WHERE deleted_at IS NULL');
    });

    test('insert uses RETURNING * and returns the stored row', () async {
      server.responder = (_) => {
            'ok': true,
            'columns': ['id', 'name'],
            'rows': [
              [7, 'alan']
            ],
          };
      final row = await db.table('users').insert({'name': 'alan'});
      expect(server.sql.single,
          "INSERT INTO users (name) VALUES ('alan') RETURNING *");
      expect(row, {'id': 7, 'name': 'alan'});
    });

    test('update and delete return the affected count', () async {
      server.responder = (_) => {'ok': true, 'affected': 3};
      final updated =
          await db.table('users').where('id', '>', 10).update({'active': false});
      final deleted = await db.table('users').where('name', 'x').delete();
      expect(server.sql[0],
          'UPDATE users SET active = FALSE WHERE id > 10');
      expect(server.sql[1], "DELETE FROM users WHERE name = 'x'");
      expect(updated, 3);
      expect(deleted, 3);
    });

    test('string values are single-quote escaped', () async {
      server.responder = (_) => {'ok': true, 'columns': [], 'rows': []};
      await db.table('t').where('name', "O'Brien").get();
      expect(server.sql.single, "SELECT * FROM t WHERE name = 'O''Brien'");
    });

    test('server error becomes a SqlException', () async {
      server.responder = (_) => {'ok': false, 'error': 'no such table: t'};
      expect(db.table('t').get(), throwsA(isA<SqlException>()));
    });

    test('execute returns raw columns/rows/affected', () async {
      server.responder = (_) => {
            'ok': true,
            'columns': ['n'],
            'rows': [
              [42]
            ],
            'affected': 0,
          };
      final result = await db.execute('SELECT 42 AS n');
      expect(result.columns, ['n']);
      expect(result.asMaps(), [
        {'n': 42}
      ]);
    });
  });
}
