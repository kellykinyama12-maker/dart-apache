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
}
