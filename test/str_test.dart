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
    test('limit + words', () {
      expect(Str.limit('abcdef', 3), 'abc...');
      expect(Str.limit('abc', 5), 'abc');
      expect(Str.words('one two three four', 2), 'one two...');
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
  });
}
