import 'package:dart_apache/dart_apache.dart';
import 'package:test/test.dart';

void main() {
  group('Str', () {
    test('slug', () {
      expect(Str.slug('Hello, World!'), 'hello-world');
      expect(Str.slug('  a__b  c '), 'a-b-c');
      expect(Str.slug('Foo Bar', '_'), 'foo_bar');
    });
    test('title + ucfirst', () {
      expect(Str.title('hello_world foo'), 'Hello World Foo');
      expect(Str.ucfirst('ada'), 'Ada');
    });
    test('camel / studly / snake / kebab', () {
      expect(Str.camel('foo_bar baz'), 'fooBarBaz');
      expect(Str.studly('foo-bar'), 'FooBar');
      expect(Str.snake('fooBar'), 'foo_bar');
      expect(Str.snake('FooBarBaz'), 'foo_bar_baz');
      expect(Str.kebab('fooBar'), 'foo-bar');
    });
    test('limit + words', () {
      expect(Str.limit('abcdef', 3), 'abc...');
      expect(Str.limit('abc', 5), 'abc');
      expect(Str.words('one two three four', 2), 'one two...');
    });
    test('squish / before / after / between', () {
      expect(Str.squish('  a   b\tc '), 'a b c');
      expect(Str.before('user@example.com', '@'), 'user');
      expect(Str.after('user@example.com', '@'), 'example.com');
      expect(Str.beforeLast('a.b.c', '.'), 'a.b');
      expect(Str.afterLast('a.b.c', '.'), 'c');
      expect(Str.between('[hello]', '[', ']'), 'hello');
      expect(Str.before('nodelim', '@'), 'nodelim');
    });
    test('mask', () {
      expect(Str.mask('4111111111111234'), '************1234');
      expect(Str.mask('abc', visible: 4), 'abc');
    });
    test('random length + alphanumeric', () {
      final r = Str.random(24);
      expect(r, hasLength(24));
      expect(RegExp(r'^[A-Za-z0-9]+$').hasMatch(r), isTrue);
    });
    test('plural + singular', () {
      expect(Str.plural('post'), 'posts');
      expect(Str.plural('category'), 'categories');
      expect(Str.plural('box'), 'boxes');
      expect(Str.singular('posts'), 'post');
      expect(Str.singular('categories'), 'category');
      expect(Str.singular('boxes'), 'box');
    });
  });

  group('collections', () {
    final rows = <Map<String, Object?>>[
      {'id': 3, 'cat': 'a', 'name': 'c'},
      {'id': 1, 'cat': 'b', 'name': 'a'},
      {'id': 2, 'cat': 'a', 'name': 'b'},
    ];
    test('sortedBy / sortedByDesc', () {
      expect(rows.sortedBy((r) => r['id'] as int).pluck('id'), [1, 2, 3]);
      expect(rows.sortedByDesc((r) => r['id'] as int).pluck('id'), [3, 2, 1]);
    });
    test('groupBy', () {
      final g = rows.groupBy((r) => r['cat'] as String);
      expect(g.keys.toList(), ['a', 'b']);
      expect(g['a']!.pluck('id'), [3, 2]);
    });
    test('keyBy', () {
      final k = rows.keyBy((r) => r['id'] as int);
      expect(k[2]!['name'], 'b');
    });
    test('pluck', () {
      expect(rows.pluck('name'), ['c', 'a', 'b']);
    });
    test('sumBy / avgBy / maxBy / minBy', () {
      expect(rows.sumBy((r) => r['id'] as int), 6);
      expect(rows.avgBy((r) => r['id'] as int), 2);
      expect(rows.maxBy((r) => r['id'] as int)!['name'], 'c');
      expect(rows.minBy((r) => r['id'] as int)!['name'], 'a');
      expect(const <Map<String, Object?>>[].maxBy((r) => r['id'] as int),
          isNull);
    });
    test('chunk / uniqueBy', () {
      expect([1, 2, 3, 4, 5].chunk(2), [
        [1, 2],
        [3, 4],
        [5]
      ]);
      expect(() => [1].chunk(0), throwsArgumentError);
      expect(rows.uniqueBy((r) => r['cat']).pluck('id'), [3, 1]);
    });
  });
}
