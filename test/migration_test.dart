import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_apache/dart_apache.dart';
import 'package:test/test.dart';

/// A loopback server that keeps real state for the `schema_migrations` table so
/// the [Migrator] can be tested deterministically; all other SQL is acked.
class _StatefulDb {
  _StatefulDb(this._server) {
    _server.listen(_handle);
  }
  final ServerSocket _server;
  final List<Map<String, Object?>> migrations = []; // {name, batch}

  int get port => _server.port;

  static Future<_StatefulDb> start() async =>
      _StatefulDb(await ServerSocket.bind('127.0.0.1', 0));

  Future<void> close() => _server.close();

  Map<String, Object?> _respond(String sql) {
    if (sql.startsWith('SELECT * FROM schema_migrations')) {
      return {
        'ok': true,
        'columns': ['name', 'batch'],
        'rows': [
          for (final m in migrations) [m['name'], m['batch']]
        ],
      };
    }
    if (sql.startsWith('INSERT INTO schema_migrations')) {
      final name = RegExp(r"'([^']*)'").firstMatch(sql)!.group(1);
      final batch = int.parse(RegExp(r',\s*(\d+)\)').firstMatch(sql)!.group(1)!);
      migrations.add({'name': name, 'batch': batch});
      return {
        'ok': true,
        'columns': ['name', 'batch'],
        'rows': [
          [name, batch]
        ],
      };
    }
    if (sql.startsWith('DELETE FROM schema_migrations')) {
      final name = RegExp(r"'([^']*)'").firstMatch(sql)!.group(1);
      final before = migrations.length;
      migrations.removeWhere((m) => m['name'] == name);
      return {'ok': true, 'affected': before - migrations.length};
    }
    return {'ok': true, 'affected': 0}; // CREATE/DROP table, etc.
  }

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
        final res = {'id': req['id'], ..._respond(req['sql'] as String)};
        socket.add(utf8.encode('${jsonEncode(res)}\n'));
      }
    });
  }
}

class _Mig implements Migration {
  _Mig(this.name, this.log);
  @override
  final String name;
  final List<String> log;
  @override
  Future<void> up(SqlDatabase db) async {
    log.add('up:$name');
    await db.execute('CREATE TABLE IF NOT EXISTS $name (id INTEGER)');
  }

  @override
  Future<void> down(SqlDatabase db) async {
    log.add('down:$name');
    await db.execute('DROP TABLE IF EXISTS $name');
  }
}

void main() {
  group('Migrator', () {
    late _StatefulDb server;
    late SqlDatabase db;
    late List<String> log;

    setUp(() async {
      server = await _StatefulDb.start();
      db = SqlDatabase(host: '127.0.0.1', port: server.port);
      log = [];
    });

    tearDown(() async {
      await db.close();
      await server.close();
    });

    test('migrate runs pending in name order, is idempotent', () async {
      final migrator = Migrator(db, [
        _Mig('20260101_b_create_tags', log),
        _Mig('20260101_a_create_posts', log),
      ]);
      final ran = await migrator.migrate();
      expect(ran, ['20260101_a_create_posts', '20260101_b_create_tags']);
      expect(log, ['up:20260101_a_create_posts', 'up:20260101_b_create_tags']);
      expect(server.migrations.map((m) => m['batch']), [1, 1]);

      // Running again applies nothing.
      expect(await migrator.migrate(), isEmpty);
    });

    test('rollback undoes the last batch in reverse order', () async {
      final migrator = Migrator(db, [
        _Mig('m_a', log),
        _Mig('m_b', log),
      ]);
      await migrator.migrate();
      log.clear();
      final rolled = await migrator.rollback();
      expect(rolled, ['m_b', 'm_a']);
      expect(log, ['down:m_b', 'down:m_a']);
      expect(server.migrations, isEmpty);
    });

    test('a later migrate is a new batch; rollback only undoes it', () async {
      await Migrator(db, [_Mig('m_a', log)]).migrate();
      await Migrator(db, [_Mig('m_a', log), _Mig('m_b', log)]).migrate();
      expect(server.migrations, [
        {'name': 'm_a', 'batch': 1},
        {'name': 'm_b', 'batch': 2},
      ]);

      final rolled =
          await Migrator(db, [_Mig('m_a', log), _Mig('m_b', log)]).rollback();
      expect(rolled, ['m_b']);
      expect(server.migrations, [
        {'name': 'm_a', 'batch': 1}
      ]);
    });
  });
}
