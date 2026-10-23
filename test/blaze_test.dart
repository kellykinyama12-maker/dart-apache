import 'dart:io';

import 'package:dart_apache/dart_apache.dart';
import 'package:test/test.dart';

void main() {
  final engine = BlazeEngine('.', cache: false);
  String render(String src, [Map<String, Object?> ctx = const {}]) =>
      engine.renderString(src, ctx);

  group('expression language', () {
    Object? ev(String src, [Map<String, Object?> ctx = const {}]) =>
        Expression.parse(src).evaluate(ctx);

    test('literals and identifiers', () {
      expect(ev('42'), 42);
      expect(ev("'hi'"), 'hi');
      expect(ev('true'), true);
      expect(ev('name', {'name': 'ada'}), 'ada');
    });
    test('member + index access', () {
      expect(ev('user.name', {'user': {'name': 'ada'}}), 'ada');
      expect(ev('items.length', {'items': [1, 2, 3]}), 3);
      expect(ev('items[1]', {'items': ['a', 'b']}), 'b');
    });
    test('arithmetic + comparison + logic', () {
      expect(ev('1 + 2 * 3'), 7);
      expect(ev('n >= 18', {'n': 20}), true);
      expect(ev('a && b', {'a': true, 'b': false}), false);
      expect(ev('!done', {'done': false}), true);
      expect(ev("role == 'admin'", {'role': 'admin'}), true);
    });
  });

  group('echo + escaping', () {
    test('{{ }} HTML-escapes', () {
      expect(render('<p>{{ v }}</p>', {'v': '<b>&"x'}),
          '<p>&lt;b&gt;&amp;&quot;x</p>');
    });
    test('{!! !!} is raw', () {
      expect(render('{!! v !!}', {'v': '<b>hi</b>'}), '<b>hi</b>');
    });
    test('{{-- comment --}} produces nothing', () {
      expect(render('a{{-- hidden --}}b'), 'ab');
    });
    test('null renders empty', () {
      expect(render('[{{ missing }}]'), '[]');
    });
  });

  group('@if / @elseif / @else', () {
    const tmpl =
        '@if(n > 10)big@elseif(n > 5)mid@else small@endif';
    test('branches', () {
      expect(render(tmpl, {'n': 20}), 'big');
      expect(render(tmpl, {'n': 7}), 'mid');
      expect(render(tmpl, {'n': 1}), ' small');
    });
  });

  group('@foreach', () {
    test('iterates with item + loop metadata', () {
      final out = render(
        '@foreach(xs as x){{ loop.count }}:{{ x }}@if(!loop.last),@endif@endforeach',
        {'xs': ['a', 'b', 'c']},
      );
      expect(out, '1:a,2:b,3:c');
    });
    test('iterates map values', () {
      expect(render('@foreach(m as v){{ v }}@endforeach', {
        'm': {'a': 1, 'b': 2}
      }), '12');
    });
  });

  group('layouts + includes (file-backed)', () {
    late Directory dir;
    late BlazeEngine fe;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('blaze_');
      File('${dir.path}/layout.blaze.html').writeAsStringSync(
          '<html><body>@yield("content")</body></html>');
      File('${dir.path}/partial.blaze.html')
          .writeAsStringSync('[inc:{{ who }}]');
      File('${dir.path}/page.blaze.html').writeAsStringSync(
          '@extends("layout")@section("content")Hi @include("partial")@endsection');
      fe = BlazeEngine(dir.path, cache: false);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('@extends + @section + @yield + @include compose', () {
      expect(fe.render('page', {'who': 'ada'}),
          '<html><body>Hi [inc:ada]</body></html>');
    });
  });
}
