// Blaze — a Blade-style server-side templating engine in pure Dart. Supports
// `{{ expr }}` (HTML-escaped), `{!! expr !!}` (raw), `{{-- comments --}}`,
// `@if/@elseif/@else/@endif`, `@foreach(items as item)/@endforeach`,
// `@include('partial')`, and layouts via `@extends('layout')` +
// `@section('name')...@endsection` + `@yield('name')`. Runs under AOT (no eval).
import 'dart:collection';
import 'dart:io';

import 'expression.dart';

/// Thrown on a template syntax error.
class TemplateError implements Exception {
  TemplateError(this.message);
  final String message;
  @override
  String toString() => 'TemplateError: $message';
}

/// Renders Blaze templates loaded by name from [directory]. Template files are
/// `<directory>/<name>.<extension>`; dotted names map to folders
/// (`layouts.app` -> `layouts/app`). Compiled templates are cached when
/// [cache] is true (turn off for edit-and-refresh dev).
class BlazeEngine {
  BlazeEngine(
    this.directory, {
    this.extension = '.blaze.html',
    this.cache = true,
  });

  final String directory;
  final String extension;
  final bool cache;

  final Map<String, _Template> _compiled = HashMap();

  /// Renders the template [name] with [context].
  String render(String name, [Map<String, Object?> context = const {}]) {
    final t = _load(name);
    final sections = <String, String>{};
    final body = StringBuffer();
    _renderNodes(t.nodes, context, sections, body);
    if (t.extendsName != null) {
      final parent = _load(t.extendsName!);
      final out = StringBuffer();
      _renderNodes(parent.nodes, context, sections, out);
      return out.toString();
    }
    return body.toString();
  }

  /// Compiles and renders [source] directly (no layout/includes resolution
  /// beyond what the engine's [directory] provides). Handy for tests.
  String renderString(String source, [Map<String, Object?> context = const {}]) {
    final t = _compile(source);
    final sections = <String, String>{};
    final body = StringBuffer();
    _renderNodes(t.nodes, context, sections, body);
    if (t.extendsName != null) {
      final parent = _load(t.extendsName!);
      final out = StringBuffer();
      _renderNodes(parent.nodes, context, sections, out);
      return out.toString();
    }
    return body.toString();
  }

  /// Drops cached compiled templates (e.g. after editing files in dev).
  void clearCache() => _compiled.clear();

  _Template _load(String name) {
    final cached = _compiled[name];
    if (cached != null) return cached;
    final path = '$directory/${name.replaceAll('.', '/')}$extension';
    final src = File(path).readAsStringSync();
    final t = _compile(src);
    if (cache) _compiled[name] = t;
    return t;
  }

  void _renderNodes(
    List<_Node> nodes,
    Map<String, Object?> ctx,
    Map<String, String> sections,
    StringBuffer out,
  ) {
    for (final n in nodes) {
      n.render(out, ctx, this, sections);
    }
  }

  // ---- compilation ----

  _Template _compile(String src) {
    final tokens = _tokenize(src);
    final parser = _TreeParser(tokens);
    final nodes = parser.parseBlock(const {});
    return _Template(nodes, parser.extendsName);
  }

  static const Set<String> _knownDirectives = {
    'if', 'elseif', 'else', 'endif',
    'foreach', 'endforeach',
    'include', 'extends', 'section', 'endsection', 'yield',
  };

  List<_Tok> _tokenize(String src) {
    final toks = <_Tok>[];
    final text = StringBuffer();
    void flush() {
      if (text.isNotEmpty) {
        toks.add(_Tok.text(text.toString()));
        text.clear();
      }
    }

    var i = 0;
    while (i < src.length) {
      if (src.startsWith('{{--', i)) {
        final end = src.indexOf('--}}', i + 4);
        if (end < 0) throw TemplateError('unterminated {{-- comment');
        i = end + 4;
        continue; // comments produce nothing
      }
      if (src.startsWith('{!!', i)) {
        final end = src.indexOf('!!}', i + 3);
        if (end < 0) throw TemplateError('unterminated {!! !!}');
        flush();
        toks.add(_Tok.echo(src.substring(i + 3, end).trim(), raw: true));
        i = end + 3;
        continue;
      }
      if (src.startsWith('{{', i)) {
        final end = src.indexOf('}}', i + 2);
        if (end < 0) throw TemplateError('unterminated {{ }}');
        flush();
        toks.add(_Tok.echo(src.substring(i + 2, end).trim()));
        i = end + 2;
        continue;
      }
      if (src[i] == '@') {
        final m = _directiveAt(src, i);
        if (m != null) {
          flush();
          toks.add(_Tok.directive(m.name, m.args));
          i = m.end;
          continue;
        }
      }
      text.write(src[i]);
      i++;
    }
    flush();
    return toks;
  }

  /// Parses an `@name` or `@name(args)` directive at [i], or null if the `@`
  /// isn't a recognized directive (so `@media`, emails, etc. stay literal).
  _DirMatch? _directiveAt(String src, int i) {
    var j = i + 1;
    final nameStart = j;
    while (j < src.length && _isLetter(src[j])) {
      j++;
    }
    final name = src.substring(nameStart, j);
    if (!_knownDirectives.contains(name)) return null;
    String args = '';
    if (j < src.length && src[j] == '(') {
      var depth = 0;
      final argStart = j + 1;
      while (j < src.length) {
        if (src[j] == '(') depth++;
        if (src[j] == ')') {
          depth--;
          if (depth == 0) break;
        }
        j++;
      }
      if (depth != 0) throw TemplateError('unterminated @$name(');
      args = src.substring(argStart, j);
      j++; // past ')'
    }
    return _DirMatch(name, args.trim(), j);
  }

  bool _isLetter(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 65 && u <= 90) || (u >= 97 && u <= 122);
  }
}

// ---------------------------------------------------------------------------
// Tokens + tree parser
// ---------------------------------------------------------------------------

enum _TokKind { text, echo, directive }

class _Tok {
  _Tok.text(this.value)
      : kind = _TokKind.text,
        raw = false,
        args = '';
  _Tok.echo(this.value, {this.raw = false})
      : kind = _TokKind.echo,
        args = '';
  _Tok.directive(this.value, this.args)
      : kind = _TokKind.directive,
        raw = false;

  final _TokKind kind;
  final String value; // text, echo source, or directive name
  final String args; // directive args
  final bool raw;
}

class _DirMatch {
  _DirMatch(this.name, this.args, this.end);
  final String name;
  final String args;
  final int end;
}

class _Template {
  _Template(this.nodes, this.extendsName);
  final List<_Node> nodes;
  final String? extendsName;
}

class _TreeParser {
  _TreeParser(this._toks);
  final List<_Tok> _toks;
  int _pos = 0;
  String? extendsName;

  /// Parses nodes until one of [stops] directive names (consumed by caller).
  List<_Node> parseBlock(Set<String> stops) {
    final nodes = <_Node>[];
    while (_pos < _toks.length) {
      final t = _toks[_pos];
      if (t.kind == _TokKind.directive && stops.contains(t.value)) {
        return nodes;
      }
      _pos++;
      switch (t.kind) {
        case _TokKind.text:
          nodes.add(_TextNode(t.value));
        case _TokKind.echo:
          nodes.add(_EchoNode(Expression.parse(t.value), t.raw));
        case _TokKind.directive:
          _directive(t, nodes);
      }
    }
    return nodes;
  }

  void _directive(_Tok t, List<_Node> nodes) {
    switch (t.value) {
      case 'extends':
        extendsName = _literal(t.args);
      case 'include':
        nodes.add(_IncludeNode(_literal(t.args)));
      case 'yield':
        nodes.add(_YieldNode(_literal(t.args)));
      case 'section':
        final body = parseBlock({'endsection'});
        _expect('endsection');
        nodes.add(_SectionNode(_literal(t.args), body));
      case 'foreach':
        final body = parseBlock({'endforeach'});
        _expect('endforeach');
        final parts = t.args.split(' as ');
        if (parts.length != 2) {
          throw TemplateError('@foreach expects "list as item"');
        }
        nodes.add(_ForeachNode(
            Expression.parse(parts[0].trim()), parts[1].trim(), body));
      case 'if':
        nodes.add(_parseIf(t));
      default:
        throw TemplateError('unexpected @${t.value}');
    }
  }

  _Node _parseIf(_Tok ifTok) {
    final branches = <_Branch>[];
    branches.add(_Branch(Expression.parse(ifTok.args),
        parseBlock({'elseif', 'else', 'endif'})));
    while (_peekDirective('elseif')) {
      final tok = _toks[_pos++];
      branches.add(_Branch(
          Expression.parse(tok.args), parseBlock({'elseif', 'else', 'endif'})));
    }
    if (_peekDirective('else')) {
      _pos++;
      branches.add(_Branch(null, parseBlock({'endif'})));
    }
    _expect('endif');
    return _IfNode(branches);
  }

  bool _peekDirective(String name) =>
      _pos < _toks.length &&
      _toks[_pos].kind == _TokKind.directive &&
      _toks[_pos].value == name;

  void _expect(String name) {
    if (!_peekDirective(name)) {
      throw TemplateError('expected @$name');
    }
    _pos++;
  }

  /// Extracts a single-quoted / double-quoted string literal from directive
  /// args like `'layouts.app'`.
  String _literal(String args) {
    final s = args.trim();
    if (s.length >= 2 &&
        ((s.startsWith("'") && s.endsWith("'")) ||
            (s.startsWith('"') && s.endsWith('"')))) {
      return s.substring(1, s.length - 1);
    }
    throw TemplateError('expected a quoted name, got "$args"');
  }
}

// ---------------------------------------------------------------------------
// Render nodes
// ---------------------------------------------------------------------------

abstract class _Node {
  void render(StringBuffer out, Map<String, Object?> ctx, BlazeEngine engine,
      Map<String, String> sections);
}

class _TextNode extends _Node {
  _TextNode(this.text);
  final String text;
  @override
  void render(StringBuffer out, Map<String, Object?> ctx, BlazeEngine engine,
          Map<String, String> sections) =>
      out.write(text);
}

class _EchoNode extends _Node {
  _EchoNode(this.expr, this.raw);
  final Expression expr;
  final bool raw;
  @override
  void render(StringBuffer out, Map<String, Object?> ctx, BlazeEngine engine,
      Map<String, String> sections) {
    final v = expr.evaluate(ctx);
    final s = v == null ? '' : '$v';
    out.write(raw ? s : _escapeHtml(s));
  }
}

class _Branch {
  _Branch(this.condition, this.body);
  final Expression? condition; // null for @else
  final List<_Node> body;
}

class _IfNode extends _Node {
  _IfNode(this.branches);
  final List<_Branch> branches;
  @override
  void render(StringBuffer out, Map<String, Object?> ctx, BlazeEngine engine,
      Map<String, String> sections) {
    for (final b in branches) {
      if (b.condition == null || b.condition!.evaluateTruthy(ctx)) {
        for (final n in b.body) {
          n.render(out, ctx, engine, sections);
        }
        return;
      }
    }
  }
}

class _ForeachNode extends _Node {
  _ForeachNode(this.listExpr, this.itemVar, this.body);
  final Expression listExpr;
  final String itemVar;
  final List<_Node> body;
  @override
  void render(StringBuffer out, Map<String, Object?> ctx, BlazeEngine engine,
      Map<String, String> sections) {
    final value = listExpr.evaluate(ctx);
    final items = value is Map
        ? value.values
        : value is Iterable
            ? value
            : const [];
    var index = 0;
    final last = items.length - 1;
    for (final item in items) {
      final child = Map<String, Object?>.of(ctx)
        ..[itemVar] = item
        ..['loop'] = {
          'index': index,
          'first': index == 0,
          'last': index == last,
          'count': index + 1,
        };
      for (final n in body) {
        n.render(out, child, engine, sections);
      }
      index++;
    }
  }
}

class _IncludeNode extends _Node {
  _IncludeNode(this.name);
  final String name;
  @override
  void render(StringBuffer out, Map<String, Object?> ctx, BlazeEngine engine,
      Map<String, String> sections) {
    out.write(engine.render(name, ctx));
  }
}

class _SectionNode extends _Node {
  _SectionNode(this.name, this.body);
  final String name;
  final List<_Node> body;
  @override
  void render(StringBuffer out, Map<String, Object?> ctx, BlazeEngine engine,
      Map<String, String> sections) {
    // Record the rendered section for a parent @yield; emits nothing inline.
    final sb = StringBuffer();
    for (final n in body) {
      n.render(sb, ctx, engine, sections);
    }
    sections[name] = sb.toString();
  }
}

class _YieldNode extends _Node {
  _YieldNode(this.name);
  final String name;
  @override
  void render(StringBuffer out, Map<String, Object?> ctx, BlazeEngine engine,
          Map<String, String> sections) =>
      out.write(sections[name] ?? '');
}

String _escapeHtml(String s) {
  final sb = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    switch (s[i]) {
      case '&':
        sb.write('&amp;');
      case '<':
        sb.write('&lt;');
      case '>':
        sb.write('&gt;');
      case '"':
        sb.write('&quot;');
      case "'":
        sb.write('&#39;');
      default:
        sb.write(s[i]);
    }
  }
  return sb.toString();
}
