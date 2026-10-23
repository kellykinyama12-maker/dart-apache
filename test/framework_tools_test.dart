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

    test('middlewareSource is a Middleware stub', () {
      final src = middlewareSource('EnsureAdmin');
      expect(src, contains('final Middleware ensureAdmin ='));
      expect(src, contains('await next();'));
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
