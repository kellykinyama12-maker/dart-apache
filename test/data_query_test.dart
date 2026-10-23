import 'package:dart_apache/dart_apache.dart';
import 'package:test/test.dart';

void main() {
  group('InMemoryDatabase', () {
    late InMemoryDatabase db;

    setUp(() async {
      db = InMemoryDatabase();
      await db.table('users').insert({'name': 'ada', 'age': 36});
      await db.table('users').insert({'name': 'linus', 'age': 54});
      await db.table('users').insert({'name': 'grace', 'age': 85});
    });

    test('insert assigns auto-increment ids and returns the row', () async {
      final row = await db.table('users').insert({'name': 'alan', 'age': 41});
      expect(row['id'], 4);
      expect(row['name'], 'alan');
    });

    test('get returns all rows by default', () async {
      final rows = await db.table('users').get();
      expect(rows.length, 3);
    });

    test('where equality filters rows', () async {
      final rows = await db.table('users').where('name', 'ada').get();
      expect(rows.single['age'], 36);
    });

    test('where with operator filters rows', () async {
      final rows = await db.table('users').where('age', '>=', 54).get();
      expect(rows.map((r) => r['name']), containsAll(['linus', 'grace']));
      expect(rows.length, 2);
    });

    test('whereIn filters by set membership', () async {
      final rows =
          await db.table('users').whereIn('name', ['ada', 'grace']).get();
      expect(rows.length, 2);
    });

    test('like is case-insensitive substring match', () async {
      final rows = await db.table('users').where('name', 'like', 'A').get();
      expect(rows.map((r) => r['name']), containsAll(['ada', 'grace']));
    });

    test('orderBy ascending and descending', () async {
      final asc = await db.table('users').orderBy('age').get();
      expect(asc.first['name'], 'ada');
      final desc =
          await db.table('users').orderBy('age', descending: true).get();
      expect(desc.first['name'], 'grace');
    });

    test('limit and offset paginate', () async {
      final page = await db.table('users').orderBy('age').limit(1).offset(1).get();
      expect(page.single['name'], 'linus');
    });

    test('first returns one row or null', () async {
      final found = await db.table('users').where('name', 'ada').first();
      expect(found?['age'], 36);
      final missing = await db.table('users').where('name', 'nobody').first();
      expect(missing, isNull);
    });

    test('count counts matching rows', () async {
      expect(await db.table('users').where('age', '>=', 54).count(), 2);
    });

    test('find / value / exists / pluck / orderByDesc / whereNull', () async {
      expect((await db.table('users').find(1))?['name'], 'ada');
      expect(await db.table('users').find(99), isNull);
      expect(await db.table('users').where('name', 'linus').value('age'), 54);
      expect(await db.table('users').where('age', '>=', 54).exists(), isTrue);
      expect(await db.table('users').where('name', 'nobody').exists(), isFalse);
      final names = await db.table('users').orderByDesc('age').pluck('name');
      expect(names, ['grace', 'linus', 'ada']);
      await db.table('users').insert({'name': 'nn', 'age': null});
      expect((await db.table('users').whereNull('age').get()).single['name'],
          'nn');
      expect(await db.table('users').whereNotNull('age').count(), 3);
    });

    test('paginate returns a page + metadata', () async {
      final p = await db.table('users').orderBy('age').paginate(page: 1, perPage: 2);
      expect(p.items.map((r) => r['name']), ['ada', 'linus']);
      expect(p.total, 3);
      expect(p.page, 1);
      expect(p.perPage, 2);
      expect(p.lastPage, 2);
      expect(p.hasNext, isTrue);
      expect(p.hasPrev, isFalse);
      expect(p.from, 1);
      expect(p.to, 2);

      final p2 = await db.table('users').orderBy('age').paginate(page: 2, perPage: 2);
      expect(p2.items.map((r) => r['name']), ['grace']);
      expect(p2.hasNext, isFalse);
      expect(p2.hasPrev, isTrue);
      expect(p2.toMap()['lastPage'], 2);
    });

    test('Paginator.pages returns a window around the current page', () {
      final p = Paginator<int>(const [], total: 100, page: 5, perPage: 10);
      expect(p.lastPage, 10);
      expect(p.pages(onEachSide: 2), [3, 4, 5, 6, 7]);
      final first = Paginator<int>(const [], total: 100, page: 1, perPage: 10);
      expect(first.pages(onEachSide: 2), [1, 2, 3]); // clamped at the start
      expect(p.toMap()['pages'], [3, 4, 5, 6, 7]);
    });

    test('update mutates matching rows and returns affected count', () async {
      final n =
          await db.table('users').where('name', 'ada').update({'age': 37});
      expect(n, 1);
      final row = await db.table('users').where('name', 'ada').first();
      expect(row?['age'], 37);
    });

    test('delete removes matching rows and returns affected count', () async {
      final n = await db.table('users').where('age', '>', 50).delete();
      expect(n, 2);
      expect(await db.table('users').count(), 1);
    });

    test('get returns copies that do not mutate the store', () async {
      final rows = await db.table('users').where('name', 'ada').get();
      rows.single['age'] = 999;
      final fresh = await db.table('users').where('name', 'ada').first();
      expect(fresh?['age'], 36);
    });
  });
}
