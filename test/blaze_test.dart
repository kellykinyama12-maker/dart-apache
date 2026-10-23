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

  group('components (<x-...>)', () {
    late Directory dir;
    late BlazeEngine ce;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('blaze_comp_');
      Directory('${dir.path}/components').createSync();
      File('${dir.path}/components/card.blaze.html').writeAsStringSync(
          '<div class="card"><h2>{{ title }}</h2>{!! slot !!}</div>');
      File('${dir.path}/components/panel.blaze.html').writeAsStringSync(
          '<section>{!! slot !!}<footer>{!! footer !!}</footer></section>');
      File('${dir.path}/components/divider.blaze.html')
          .writeAsStringSync('<hr data-n="{{ n }}">');
      ce = BlazeEngine(dir.path, cache: false);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('props (string) + default slot', () {
      expect(
          ce.renderString('<x-card title="Hello">Body</x-card>'),
          '<div class="card"><h2>Hello</h2>Body</div>');
    });

    test('interpolated prop + bound :prop expression', () {
      expect(
          ce.renderString('<x-card title="Hi {{ name }}">x</x-card>',
              {'name': 'ada'}),
          '<div class="card"><h2>Hi ada</h2>x</div>');
      expect(
          ce.renderString('<x-divider :n="a + 1" />', {'a': 4}),
          '<hr data-n="5">');
    });

    test('escaped output + kebab prop become camelCase', () {
      // user-supplied title is HTML-escaped by {{ }}
      expect(
          ce.renderString('<x-card title="<b>">y</x-card>'),
          '<div class="card"><h2>&lt;b&gt;</h2>y</div>');
    });

    test('named slot via <x-slot:footer>', () {
      expect(
          ce.renderString(
              '<x-panel>main<x-slot:footer>feet</x-slot:footer></x-panel>'),
          '<section>main<footer>feet</footer></section>');
    });

    test('self-closing component', () {
      expect(ce.renderString('<x-divider/>'), '<hr data-n="">');
    });

    test('nested + slot content can use directives', () {
      expect(
          ce.renderString(
              '<x-card title="T">@if(ok)<x-divider :n="1"/>@endif</x-card>',
              {'ok': true}),
          '<div class="card"><h2>T</h2><hr data-n="1"></div>');
    });
  });
}
