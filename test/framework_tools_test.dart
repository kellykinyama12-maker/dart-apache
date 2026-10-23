import 'package:dart_apache/dart_apache.dart';
import 'package:dart_apache/src/framework/cli/scaffold.dart';
import 'package:test/test.dart';

void main() {
  group('Validator', () {
    test('required', () {
      expect(Validator.validate({}, {'name': 'required'}),
          {'name': ['The name field is required.']});
      expect(Validator.validate({'name': 'ada'}, {'name': 'required'}), isEmpty);
    });

    test('email', () {
      expect(Validator.validate({'e': 'bad'}, {'e': 'email'}), isNotEmpty);
      expect(Validator.validate({'e': 'a@b.co'}, {'e': 'email'}), isEmpty);
    });

    test('min/max on strings and numbers', () {
      expect(Validator.validate({'p': 'ab'}, {'p': 'min:3'}), isNotEmpty);
      expect(Validator.validate({'p': 'abc'}, {'p': 'min:3'}), isEmpty);
      expect(Validator.validate({'n': '20'}, {'n': 'numeric|max:10'}), isNotEmpty);
      expect(Validator.validate({'n': '5'}, {'n': 'numeric|max:10'}), isEmpty);
    });

    test('in + integer + confirmed', () {
      expect(Validator.validate({'r': 'x'}, {'r': 'in:a,b,c'}), isNotEmpty);
      expect(Validator.validate({'r': 'b'}, {'r': 'in:a,b,c'}), isEmpty);
      expect(Validator.validate({'n': '1.5'}, {'n': 'integer'}), isNotEmpty);
      expect(
          Validator.validate(
              {'p': 'secret', 'p_confirmation': 'nope'}, {'p': 'confirmed'}),
          isNotEmpty);
      expect(
          Validator.validate(
              {'p': 'secret', 'p_confirmation': 'secret'}, {'p': 'confirmed'}),
          isEmpty);
    });

    test('optional absent field skips rules', () {
      expect(Validator.validate({}, {'bio': 'min:10'}), isEmpty);
    });

    test('collects multiple errors per field', () {
      final errors = Validator.validate({'e': 'x'}, {'e': 'email|min:5'});
      expect(errors['e'], hasLength(2));
    });

    test('same / different / between / not_in / starts_with / regex', () {
      expect(
          Validator.validate(
              {'p': 'a', 'p2': 'b'}, {'p': 'same:p2'}),
          isNotEmpty);
      expect(
          Validator.validate(
              {'p': 'a', 'p2': 'a'}, {'p': 'same:p2'}),
          isEmpty);
      expect(Validator.validate({'a': 'x', 'b': 'x'}, {'a': 'different:b'}),
          isNotEmpty);
      expect(Validator.validate({'n': '50'}, {'n': 'between:1,10'}), isNotEmpty);
      expect(Validator.validate({'n': '5'}, {'n': 'between:1,10'}), isEmpty);
      expect(Validator.validate({'r': 'x'}, {'r': 'not_in:x,y'}), isNotEmpty);
      expect(Validator.validate({'s': 'hello'}, {'s': 'starts_with:he,yo'}),
          isEmpty);
      expect(Validator.validate({'s': 'nope'}, {'s': 'ends_with:se,ye'}),
          isNotEmpty);
      expect(Validator.validate({'z': '1234'}, {'z': r'regex:^\d+$'}), isEmpty);
      expect(Validator.validate({'d': '12'}, {'d': 'digits:3'}), isNotEmpty);
    });

    test('uuid / ip / json / size', () {
      expect(
          Validator.validate(
              {'u': '550e8400-e29b-41d4-a716-446655440000'}, {'u': 'uuid'}),
          isEmpty);
      expect(Validator.validate({'u': 'nope'}, {'u': 'uuid'}), isNotEmpty);
      expect(Validator.validate({'a': '192.168.0.1'}, {'a': 'ip'}), isEmpty);
      expect(Validator.validate({'a': '999.1.1.1'}, {'a': 'ip'}), isNotEmpty);
      expect(Validator.validate({'j': '{"a":1}'}, {'j': 'json'}), isEmpty);
      expect(Validator.validate({'j': '{bad'}, {'j': 'json'}), isNotEmpty);
      expect(Validator.validate({'s': 'abcd'}, {'s': 'size:4'}), isEmpty);
      expect(Validator.validate({'s': 'abc'}, {'s': 'size:4'}), isNotEmpty);
      expect(Validator.validate({'n': '7'}, {'n': 'numeric|size:7'}), isEmpty);
    });
  });

  group('scaffold', () {
    test('pascalCase / snakeCase', () {
      expect(pascalCase('user-profile'), 'UserProfile');
      expect(pascalCase('counter'), 'Counter');
      expect(snakeCase('UserProfile'), 'user_profile');
      expect(snakeCase('Counter'), 'counter');
    });

    test('controllerSource', () {
      final src = controllerSource('User');
      expect(src, contains('class UserController'));
      expect(src, contains('Request request'));
    });

    test('componentSource is a LiveComponent', () {
      final src = componentSource('Counter');
      expect(src, contains('extends LiveComponent'));
      expect(src, contains("String get name => 'counter'"));
      expect(src, contains('data-live-click'));
    });

    test('modelSource is a record + repository over the Database', () {
      final src = modelSource('Post');
      expect(src, contains('class Post'));
      expect(src, contains('Post.fromRow'));
      expect(src, contains('class PostRepository'));
      expect(src, contains("static const table = 'posts'"));
      expect(src, contains('final Database db'));
    });

    test('schema-aware modelSource types fields and embeds CREATE TABLE', () {
      final fields =
          parseFields(['title:text', 'views:integer', 'published:boolean']);
      final src = modelSource('Post', fields: fields);
      expect(src, contains('final String? title;'));
      expect(src, contains('final int? views;'));
      expect(src, contains('final bool? published;'));
      expect(src, contains("(row['views'] as num?)?.toInt()"));
      expect(src, contains("row['published'] as bool?"));
      expect(
          src,
          contains('CREATE TABLE IF NOT EXISTS posts (id INTEGER PRIMARY KEY '
              'AUTOINCREMENT, title TEXT, views INTEGER, published BOOLEAN)'));
    });

    test('parseFields maps types and ignores table:', () {
      final f = parseFields(['table:posts', 'n:int', 'x:double', 'name']);
      expect(f.map((e) => e.name), ['n', 'x', 'name']);
      expect(f.map((e) => e.sqlType), ['INTEGER', 'REAL', 'TEXT']);
    });

    test('tableFromMigrationName strips create_/_table', () {
      expect(tableFromMigrationName('CreatePostsTable'), 'posts');
      expect(tableFromMigrationName('add_index'), 'add_index');
    });

    test('migrationSource builds up/down from fields', () {
      final src = migrationSource('CreatePostsTable', '20260101_create_posts_table',
          table: 'posts', fields: parseFields(['title:text']));
      expect(src, contains('class CreatePostsTable implements Migration'));
      expect(src, contains("String get name => '20260101_create_posts_table'"));
      expect(src, contains('CREATE TABLE IF NOT EXISTS posts'));
      expect(src, contains('DROP TABLE IF EXISTS posts'));
    });

    test('migrationSource without fields is a stub', () {
      final src = migrationSource('AddStuff', '20260101_add_stuff', table: 'add_stuff');
      expect(src, contains('implements Migration'));
      expect(src, contains('Future<void> up(SqlDatabase db)'));
      expect(src, contains('// TODO'));
    });

    test('middlewareSource is a Middleware stub', () {
      final src = middlewareSource('EnsureAdmin');
      expect(src, contains('final Middleware ensureAdmin ='));
      expect(src, contains('await next();'));
    });

    test('viewComponentSource is a props + slot skeleton', () {
      final src = viewComponentSource('AlertBox');
      expect(src, contains('class="alert_box"'));
      expect(src, contains('{{ title }}'));
      expect(src, contains('{!! slot !!}'));
      expect(src, contains('<x-alert_box'));
    });

    test('newProjectFiles includes the full starter', () {
      final files = newProjectFiles('MyApp');
      expect(files.keys, contains('pubspec.yaml'));
      expect(files.keys, contains('bin/my_app.dart'));
      expect(
          files.keys,
          containsAll([
            'views/layout.blaze.html',
            'views/home.blaze.html',
            'views/about.blaze.html',
            'views/login.blaze.html',
            'views/dashboard.blaze.html',
          ]));
      final bin = files['bin/my_app.dart']!;
      expect(bin, contains('Router('));
      expect(bin, contains('SessionManager(_appKey'));
      expect(bin, contains('verifyCsrf()'));
      expect(bin, contains('liveWtHandler'));
      expect(bin, contains('inlineRuntime: liveRuntimeSource'));
      expect(bin, contains("requireAuth(redirectTo: '/login')"));
    });

    test('newProjectFiles writes the given dart-apache path', () {
      final files = newProjectFiles('demo', dartApachePath: '/abs/dart-apache');
      expect(files['pubspec.yaml'], contains('path: /abs/dart-apache'));
    });
  });
}
