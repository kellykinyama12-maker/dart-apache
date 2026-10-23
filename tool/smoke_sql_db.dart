import 'package:dart_apache/dart_apache.dart';

/// Live smoke test of SqlDatabase against a running dart-db-server.
Future<void> main(List<String> args) async {
  final port = int.parse(args.isNotEmpty ? args[0] : '4599');
  final db = SqlDatabase(host: '127.0.0.1', port: port);

  await db.execute('DROP TABLE IF EXISTS notes');
  await db.execute(
      'CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, owner TEXT, body TEXT)');

  final a = await db.table('notes').insert({'owner': 'ada', 'body': 'buy milk'});
  final b = await db.table('notes').insert({'owner': 'ada', 'body': 'walk dog'});
  print('inserted: $a | $b');

  final notes = await db.table('notes').where('owner', 'ada').orderBy('id').get();
  print('select ada: $notes');

  final updated =
      await db.table('notes').where('id', a['id']).update({'body': 'buy oat milk'});
  print('updated rows: $updated');

  final one = await db.table('notes').where('id', a['id']).first();
  print('after update: $one');

  final count = await db.table('notes').count();
  print('count: $count');

  final deleted = await db.table('notes').where('owner', 'ada').delete();
  print('deleted rows: $deleted');

  await db.close();
  print('OK');
}
