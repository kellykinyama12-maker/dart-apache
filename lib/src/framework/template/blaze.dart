// Blaze — a Blade-style server-side templating engine in pure Dart. Supports
// `{{ expr }}` (HTML-escaped), `{!! expr !!}` (raw), `{{-- comments --}}`,
// `@if/@elseif/@else/@endif`, `@foreach(items as item)/@endforeach`,
// `@include('partial')`, and layouts via `@extends('layout')` +
// `@section('name')...@endsection` + `@yield('name')`. Runs under AOT (no eval).
import 'dart:collection';
import 'dart:convert';
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
  final Map<String, Object?> _shared = {};

  /// Shares a value with every rendered view (per-view [context] overrides it).
  /// The framework analog of Laravel's `View::share` — handy for layout
  /// globals like the app name or the authenticated user.
  void share(String key, Object? value) => _shared[key] = value;

  /// Shares every entry of [values] with all views (see [share]).
  void shareAll(Map<String, Object?> values) => _shared.addAll(values);

  /// Renders the template [name] with [context].
  String render(String name, [Map<String, Object?> context = const {}]) {
    final t = _load(name);
    final ctx = _shared.isEmpty ? context : {..._shared, ...context};
    final sections = <String, String>{};
    final body = StringBuffer();
    _renderNodes(t.nodes, ctx, sections, body);
    if (t.extendsName != null) {
      final parent = _load(t.extendsName!);
      final out = StringBuffer();
      _renderNodes(parent.nodes, ctx, sections, out);
      return out.toString();
    }
    return body.toString();
  }

  /// Compiles and renders [source] directly (no layout/includes resolution
  /// beyond what the engine's [directory] provides). Handy for tests.
  String renderString(String source, [Map<String, Object?> context = const {}]) {
    final t = _compile(source);
    final ctx = _shared.isEmpty ? context : {..._shared, ...context};
    final sections = <String, String>{};
    final body = StringBuffer();
    _renderNodes(t.nodes, ctx, sections, body);
    if (t.extendsName != null) {
      final parent = _load(t.extendsName!);
      final out = StringBuffer();
      _renderNodes(parent.nodes, ctx, sections, out);
      return out.toString();
    }
    return body.toString();
  }

  /// Drops cached compiled templates (e.g. after editing files in dev).
  void clearCache() => _compiled.clear();

  /// Whether a template [name] exists on disk (dotted name -> folder path).
  bool exists(String name) =>
      File('$directory/${name.replaceAll('.', '/')}$extension').existsSync();

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
    'unless', 'endunless',
    'foreach', 'endforeach',
    'forelse', 'empty', 'endforelse',
    'error', 'enderror',
    'json',
    'push', 'endpush', 'stack',
    'auth', 'endauth', 'guest', 'endguest',
    'csrf',
    'checked', 'selected', 'disabled', 'readonly', 'required',
    'class', 'style',
    'switch', 'case', 'default', 'break', 'endswitch',
    'include', 'includeIf', 'includeWhen', 'each', 'extends', 'section',
    'endsection', 'yield',
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
        // @verbatim ... @endverbatim: emit the inner content literally so that
        // client-side `{{ }}` (Alpine/Vue) and @-directives pass through.
        if (src.startsWith('@verbatim', i) &&
            !_isLetter(src.length > i + 9 ? src[i + 9] : ' ')) {
          final start = i + 9;
          final end = src.indexOf('@endverbatim', start);
          if (end < 0) throw TemplateError('unterminated @verbatim');
          flush();
          toks.add(_Tok.text(src.substring(start, end)));
          i = end + '@endverbatim'.length;
          continue;
        }
        final m = _directiveAt(src, i);
        if (m != null) {
          flush();
          toks.add(_Tok.directive(m.name, m.args));
          i = m.end;
          continue;
        }
      }
      if (src.startsWith('</x-', i)) {
        final c = _componentCloseAt(src, i);
        flush();
        toks.add(_Tok.componentClose(c.name));
        i = c.end;
        continue;
      }
      if (src.startsWith('<x-', i)) {
        final o = _componentOpenAt(src, i);
        flush();
        toks.add(_Tok.componentOpen(o.name, o.attrs, o.selfClose));
        i = o.end;
        continue;
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

// Component names allow letters, digits, _ - . : (`:` for `<x-slot:footer>`).
bool _isNameChar(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 48 && u <= 57) ||
      (u >= 65 && u <= 90) ||
      (u >= 97 && u <= 122) ||
      c == '_' ||
      c == '-' ||
      c == '.' ||
      c == ':';
}

/// One attribute on a `<x-...>` tag. [bound] is a `:name="expr"` form.
class _Attr {
  _Attr(this.name, this.value, this.bound);
  final String name;
  final String value;
  final bool bound;
}

class _ComponentOpen {
  _ComponentOpen(this.name, this.attrs, this.selfClose, this.end);
  final String name;
  final List<_Attr> attrs;
  final bool selfClose;
  final int end;
}

class _ComponentClose {
  _ComponentClose(this.name, this.end);
  final String name;
  final int end;
}

/// Parses `<x-name attr="v" :bound="expr" />` starting at [i] (`<x-`).
_ComponentOpen _componentOpenAt(String src, int i) {
  var j = i + 3; // past `<x-`
  final nameStart = j;
  while (j < src.length && _isNameChar(src[j])) {
    j++;
  }
  final name = src.substring(nameStart, j);
  final attrs = <_Attr>[];
  while (j < src.length) {
    while (j < src.length && _isWs(src[j])) {
      j++;
    }
    if (j < src.length && src.startsWith('/>', j)) {
      return _ComponentOpen(name, attrs, true, j + 2);
    }
    if (j < src.length && src[j] == '>') {
      return _ComponentOpen(name, attrs, false, j + 1);
    }
    final attrStart = j;
    while (j < src.length &&
        src[j] != '=' &&
        src[j] != '>' &&
        !_isWs(src[j]) &&
        !src.startsWith('/>', j)) {
      j++;
    }
    final attrName = src.substring(attrStart, j);
    String value = '';
    if (j < src.length && src[j] == '=') {
      j++; // past '='
      final quote = src[j];
      final valStart = j + 1;
      j = src.indexOf(quote, valStart);
      if (j < 0) throw TemplateError('unterminated attribute in <x-$name>');
      value = src.substring(valStart, j);
      j++; // past closing quote
    }
    final bound = attrName.startsWith(':');
    attrs.add(_Attr(bound ? attrName.substring(1) : attrName, value, bound));
  }
  throw TemplateError('unterminated <x-$name>');
}

/// Parses `</x-name>` starting at [i] (`</x-`).
_ComponentClose _componentCloseAt(String src, int i) {
  var j = i + 4; // past `</x-`
  final nameStart = j;
  while (j < src.length && _isNameChar(src[j])) {
    j++;
  }
  final name = src.substring(nameStart, j);
  final end = src.indexOf('>', j);
  if (end < 0) throw TemplateError('unterminated </x-$name>');
  return _ComponentClose(name, end + 1);
}

bool _isWs(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';

/// Splits directive args on the first top-level comma (outside quotes), for
/// `@include('name', expr)`.
List<String> _splitFirstComma(String s) {
  var inQuote = false;
  String? quote;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (inQuote) {
      if (c == quote) inQuote = false;
    } else if (c == "'" || c == '"') {
      inQuote = true;
      quote = c;
    } else if (c == ',') {
      return [s.substring(0, i), s.substring(i + 1)];
    }
  }
  return [s];
}

// Splits on every top-level comma, respecting quotes and (), [] nesting.
List<String> _splitArgs(String s) {
  final parts = <String>[];
  var depth = 0;
  var inQuote = false;
  String? quote;
  var start = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (inQuote) {
      if (c == quote) inQuote = false;
    } else if (c == "'" || c == '"') {
      inQuote = true;
      quote = c;
    } else if (c == '(' || c == '[') {
      depth++;
    } else if (c == ')' || c == ']') {
      depth--;
    } else if (c == ',' && depth == 0) {
      parts.add(s.substring(start, i).trim());
      start = i + 1;
    }
  }
  parts.add(s.substring(start).trim());
  return parts;
}

// ---------------------------------------------------------------------------
// Tokens + tree parser
// ---------------------------------------------------------------------------

enum _TokKind { text, echo, directive, componentOpen, componentClose }

class _Tok {
  _Tok.text(this.value)
      : kind = _TokKind.text,
        raw = false,
        args = '',
        attrs = const [],
        selfClose = false;
  _Tok.echo(this.value, {this.raw = false})
      : kind = _TokKind.echo,
        args = '',
        attrs = const [],
        selfClose = false;
  _Tok.directive(this.value, this.args)
      : kind = _TokKind.directive,
        raw = false,
        attrs = const [],
        selfClose = false;
  _Tok.componentOpen(this.value, this.attrs, this.selfClose)
      : kind = _TokKind.componentOpen,
        raw = false,
        args = '';
  _Tok.componentClose(this.value)
      : kind = _TokKind.componentClose,
        raw = false,
        args = '',
        attrs = const [],
        selfClose = false;

  final _TokKind kind;
  final String value; // text, echo source, directive name, or component name
  final String args; // directive args
  final bool raw;
  final List<_Attr> attrs; // component attributes
  final bool selfClose; // component self-closing tag
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

  /// Parses nodes until one of [stops] directive names, or the component close
  /// matching [componentStop] (both consumed by the caller).
  List<_Node> parseBlock(Set<String> stops, {String? componentStop}) {
    final nodes = <_Node>[];
    while (_pos < _toks.length) {
      final t = _toks[_pos];
      if (t.kind == _TokKind.directive && stops.contains(t.value)) {
        return nodes;
      }
      if (t.kind == _TokKind.componentClose) {
        if (t.value == componentStop) return nodes;
        throw TemplateError('unexpected </x-${t.value}>');
      }
      _pos++;
      switch (t.kind) {
        case _TokKind.text:
          nodes.add(_TextNode(t.value));
        case _TokKind.echo:
          nodes.add(_EchoNode(Expression.parse(t.value), t.raw));
        case _TokKind.directive:
          _directive(t, nodes);
        case _TokKind.componentOpen:
          nodes.add(_parseComponent(t));
        case _TokKind.componentClose:
          break; // handled above
      }
    }
    return nodes;
  }

  _Node _parseComponent(_Tok open) {
    if (open.selfClose) {
      return _ComponentNode(open.value, open.attrs, const []);
    }
    final body = parseBlock(const {}, componentStop: open.value);
    if (!(_pos < _toks.length &&
        _toks[_pos].kind == _TokKind.componentClose &&
        _toks[_pos].value == open.value)) {
      throw TemplateError('unclosed <x-${open.value}>');
    }
    _pos++; // consume the matching close
    return _ComponentNode(open.value, open.attrs, body);
  }

  void _directive(_Tok t, List<_Node> nodes) {
    switch (t.value) {
      case 'extends':
        extendsName = _literal(t.args);
      case 'include':
        final parts = _splitFirstComma(t.args);
        nodes.add(_IncludeNode(
            _literal(parts[0]),
            parts.length > 1 ? Expression.parse(parts[1].trim()) : null));
      case 'includeIf':
        final parts = _splitFirstComma(t.args);
        nodes.add(_IncludeNode(
            _literal(parts[0]),
            parts.length > 1 ? Expression.parse(parts[1].trim()) : null,
            true));
      case 'includeWhen':
        final parts = _splitFirstComma(t.args);
        if (parts.length < 2) {
          throw TemplateError('@includeWhen expects (condition, "view"[, data])');
        }
        final rest = _splitFirstComma(parts[1].trim());
        nodes.add(_IncludeNode(
            _literal(rest[0]),
            rest.length > 1 ? Expression.parse(rest[1].trim()) : null,
            false,
            Expression.parse(parts[0].trim())));
      case 'each':
        final parts = _splitArgs(t.args);
        if (parts.length < 3) {
          throw TemplateError(
              "@each expects ('view', collection, 'var'[, 'emptyView'])");
        }
        nodes.add(_EachNode(
            _literal(parts[0]),
            Expression.parse(parts[1]),
            _literal(parts[2]),
            parts.length > 3 ? _literal(parts[3]) : null));
      case 'yield':
        nodes.add(_YieldNode(_literal(t.args)));
      case 'section':
        final parts = _splitFirstComma(t.args);
        if (parts.length > 1) {
          // Inline form: @section('name', value) — no @endsection.
          nodes.add(_SectionNode(_literal(parts[0]),
              [_EchoNode(Expression.parse(parts[1].trim()), false)]));
        } else {
          final body = parseBlock({'endsection'});
          _expect('endsection');
          nodes.add(_SectionNode(_literal(parts[0]), body));
        }
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
      case 'switch':
        nodes.add(_parseSwitch(t));
      case 'unless':
        final body = parseBlock({'endunless'});
        _expect('endunless');
        nodes.add(_IfNode([_Branch(Expression.parse('!(${t.args})'), body)]));
      case 'forelse':
        final parts = t.args.split(' as ');
        if (parts.length != 2) {
          throw TemplateError('@forelse expects "list as item"');
        }
        final body = parseBlock({'empty', 'endforelse'});
        var emptyBody = const <_Node>[];
        if (_peekDirective('empty')) {
          _pos++;
          emptyBody = parseBlock({'endforelse'});
        }
        _expect('endforelse');
        nodes.add(_ForelseNode(Expression.parse(parts[0].trim()),
            parts[1].trim(), body, emptyBody));
      case 'auth':
        final body = parseBlock({'endauth'});
        _expect('endauth');
        nodes.add(_IfNode([_Branch(Expression.parse('auth'), body)]));
      case 'guest':
        final body = parseBlock({'endguest'});
        _expect('endguest');
        nodes.add(_IfNode([_Branch(Expression.parse('!auth'), body)]));
      case 'csrf':
        nodes.add(_CsrfNode());
      case 'break':
        nodes.add(_BreakNode());
      case 'checked':
      case 'selected':
      case 'disabled':
      case 'readonly':
      case 'required':
        nodes.add(_AttrFlagNode(Expression.parse(t.args), t.value));
      case 'class':
        nodes.add(_ClassNode(Expression.parse(t.args), false));
      case 'style':
        nodes.add(_ClassNode(Expression.parse(t.args), true));
      case 'json':
        nodes.add(_JsonNode(Expression.parse(t.args)));
      case 'push':
        final body = parseBlock({'endpush'});
        _expect('endpush');
        nodes.add(_PushNode(_literal(t.args), body));
      case 'stack':
        nodes.add(_StackNode(_literal(t.args)));
      case 'error':
        final body = parseBlock({'enderror'});
        _expect('enderror');
        nodes.add(_ErrorNode(_literal(t.args), body));
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

  _Node _parseSwitch(_Tok switchTok) {
    final subject = Expression.parse(switchTok.args);
    final cases = <_SwitchCase>[];
    List<_Node>? defaultBody;
    const stops = {'case', 'default', 'endswitch'};
    // Skip any text (whitespace) between @switch and the first @case/@default.
    while (_pos < _toks.length &&
        _toks[_pos].kind == _TokKind.text &&
        !_peekDirective('case')) {
      _pos++;
    }
    while (_peekDirective('case') || _peekDirective('default')) {
      if (_peekDirective('case')) {
        final caseTok = _toks[_pos++];
        final body = parseBlock(stops);
        _dropTrailingBreak(body);
        cases.add(_SwitchCase(Expression.parse(caseTok.args), body));
      } else {
        _pos++; // consume @default
        defaultBody = parseBlock(stops);
        _dropTrailingBreak(defaultBody);
      }
    }
    _expect('endswitch');
    return _SwitchNode(subject, cases, defaultBody);
  }

  // Blade case bodies end with @break; drop the trailing break node it parsed.
  void _dropTrailingBreak(List<_Node> body) {
    if (body.isNotEmpty && body.last is _BreakNode) body.removeLast();
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

/// Renders a hidden CSRF field using the `csrf` context value.
class _CsrfNode extends _Node {
  @override
  void render(StringBuffer out, Map<String, Object?> ctx, BlazeEngine engine,
      Map<String, String> sections) {
    final token = ctx['csrf'];
    out.write('<input type="hidden" name="_token" value="'
        '${_escapeHtml(token == null ? '' : '$token')}">');
  }
}

/// Emits an HTML boolean attribute (`checked`, `selected`, `disabled`,
/// `readonly`, `required`) when the guarded expression is truthy.
class _AttrFlagNode extends _Node {
  _AttrFlagNode(this.expr, this.attribute);
  final Expression expr;
  final String attribute;
  @override
  void render(StringBuffer out, Map<String, Object?> ctx, BlazeEngine engine,
      Map<String, String> sections) {
    if (expr.evaluateTruthy(ctx)) out.write(attribute);
  }
}

/// `@class([...])` / `@style([...])`: builds a `class="…"` / `style="…"`
/// attribute from strings (always included) and `{'name': condition}` maps
/// (included when the condition is truthy).
class _ClassNode extends _Node {
  _ClassNode(this.expr, this.isStyle);
  final Expression expr;
  final bool isStyle;
  @override
  void render(StringBuffer out, Map<String, Object?> ctx, BlazeEngine engine,
      Map<String, String> sections) {
    final parts = <String>[];
    void consume(Object? item) {
      if (item is String) {
        if (item.isNotEmpty) parts.add(item);
      } else if (item is Map) {
        item.forEach((k, v) {
          if (Expression.truthy(v)) parts.add('$k');
        });
      } else if (item is Iterable) {
        item.forEach(consume);
      }
    }

    consume(expr.evaluate(ctx));
    final joined = parts.join(isStyle ? '; ' : ' ');
    out.write('${isStyle ? 'style' : 'class'}="${_escapeHtml(joined)}"');
  }
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

/// A placeholder produced by `@break`; stripped from switch-case bodies.
class _BreakNode extends _Node {
  @override
  void render(StringBuffer out, Map<String, Object?> ctx, BlazeEngine engine,
      Map<String, String> sections) {}
}

class _SwitchCase {
  _SwitchCase(this.value, this.body);
  final Expression value;
  final List<_Node> body;
}

class _SwitchNode extends _Node {
  _SwitchNode(this.subject, this.cases, this.defaultBody);
  final Expression subject;
  final List<_SwitchCase> cases;
  final List<_Node>? defaultBody;
  @override
  void render(StringBuffer out, Map<String, Object?> ctx, BlazeEngine engine,
      Map<String, String> sections) {
    final value = subject.evaluate(ctx);
    for (final c in cases) {
      if (c.value.evaluate(ctx) == value) {
        for (final n in c.body) {
          n.render(out, ctx, engine, sections);
        }
        return;
      }
    }
    if (defaultBody != null) {
      for (final n in defaultBody!) {
        n.render(out, ctx, engine, sections);
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

/// `@forelse(list as item) … @empty … @endforelse`: iterate, or render the
/// empty branch when the list has no items.
class _ForelseNode extends _Node {
  _ForelseNode(this.listExpr, this.itemVar, this.body, this.emptyBody);
  final Expression listExpr;
  final String itemVar;
  final List<_Node> body;
  final List<_Node> emptyBody;
  @override
  void render(StringBuffer out, Map<String, Object?> ctx, BlazeEngine engine,
      Map<String, String> sections) {
    final value = listExpr.evaluate(ctx);
    final items = value is Map
        ? value.values
        : value is Iterable
            ? value
            : const [];
    if (items.isEmpty) {
      for (final n in emptyBody) {
        n.render(out, ctx, engine, sections);
      }
      return;
    }
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
  _IncludeNode(this.name, [this.dataExpr, this.ifExists = false, this.condition]);
  final String name;
  final Expression? dataExpr;
  final bool ifExists;
  final Expression? condition;
  @override
  void render(StringBuffer out, Map<String, Object?> ctx, BlazeEngine engine,
      Map<String, String> sections) {
    if (condition != null && !condition!.evaluateTruthy(ctx)) return;
    if (ifExists && !engine.exists(name)) return;
    var child = ctx;
    final data = dataExpr?.evaluate(ctx);
    if (data is Map) {
      child = <String, Object?>{...ctx, ...data.cast<String, Object?>()};
    }
    out.write(engine.render(name, child));
  }
}

/// `@each('view', collection, 'var'[, 'emptyView'])`: renders the partial once
/// per item (binding `var`), or the optional empty view when there are none.
class _EachNode extends _Node {
  _EachNode(this.view, this.listExpr, this.itemVar, this.emptyView);
  final String view;
  final Expression listExpr;
  final String itemVar;
  final String? emptyView;
  @override
  void render(StringBuffer out, Map<String, Object?> ctx, BlazeEngine engine,
      Map<String, String> sections) {
    final value = listExpr.evaluate(ctx);
    final items = value is Map
        ? value.values.toList()
        : value is Iterable
            ? value.toList()
            : const [];
    if (items.isEmpty) {
      if (emptyView != null) out.write(engine.render(emptyView!, ctx));
      return;
    }
    for (final item in items) {
      out.write(engine.render(view, {itemVar: item}));
    }
  }
}

/// `@json(expr)`: emits `jsonEncode(expr)` (unescaped) — for embedding server
/// data into a `<script>`.
class _JsonNode extends _Node {
  _JsonNode(this.expr);
  final Expression expr;
  @override
  void render(StringBuffer out, Map<String, Object?> ctx, BlazeEngine engine,
          Map<String, String> sections) =>
      out.write(jsonEncode(expr.evaluate(ctx)));
}

/// `@push('name') … @endpush`: appends its body to the named stack (emitted by
/// a `@stack('name')`, typically in a layout). Stacks ride in [sections] under
/// a `__stack:` prefix.
class _PushNode extends _Node {
  _PushNode(this.name, this.body);
  final String name;
  final List<_Node> body;
  @override
  void render(StringBuffer out, Map<String, Object?> ctx, BlazeEngine engine,
      Map<String, String> sections) {
    final sb = StringBuffer();
    for (final n in body) {
      n.render(sb, ctx, engine, sections);
    }
    final key = '__stack:$name';
    sections[key] = (sections[key] ?? '') + sb.toString();
  }
}

/// `@stack('name')`: emits everything pushed to the named stack.
class _StackNode extends _Node {
  _StackNode(this.name);
  final String name;
  @override
  void render(StringBuffer out, Map<String, Object?> ctx, BlazeEngine engine,
          Map<String, String> sections) =>
      out.write(sections['__stack:$name'] ?? '');
}

/// `@error('field') … @enderror`: renders the body (with `message` bound to the
/// first error) when `errors[field]` has messages.
class _ErrorNode extends _Node {
  _ErrorNode(this.field, this.body);
  final String field;
  final List<_Node> body;
  @override
  void render(StringBuffer out, Map<String, Object?> ctx, BlazeEngine engine,
      Map<String, String> sections) {
    final errors = ctx['errors'];
    if (errors is! Map) return;
    final messages = errors[field];
    if (messages is! List || messages.isEmpty) return;
    final child = Map<String, Object?>.of(ctx)..['message'] = messages.first;
    for (final n in body) {
      n.render(out, child, engine, sections);
    }
  }
}

/// A `<x-name attr=... >slot</x-name>` component: renders the template
/// `components/<name>` with the attributes as props plus `slot` (default body)
/// and any `<x-slot:foo>` named slots as additional context values.
class _ComponentNode extends _Node {
  _ComponentNode(this.name, this.attrs, this.body);
  final String name;
  final List<_Attr> attrs;
  final List<_Node> body;

  @override
  void render(StringBuffer out, Map<String, Object?> ctx, BlazeEngine engine,
      Map<String, String> sections) {
    final props = <String, Object?>{};
    for (final a in attrs) {
      props[_camelName(a.name)] = _attrValue(a, ctx);
    }
    // The body is the default slot, minus any <x-slot:foo> named slots.
    final slots = <String, String>{};
    final defaultSlot = StringBuffer();
    for (final n in body) {
      if (n is _ComponentNode && n.name.startsWith('slot:')) {
        final sb = StringBuffer();
        for (final c in n.body) {
          c.render(sb, ctx, engine, sections);
        }
        slots[_camelName(n.name.substring(5))] = sb.toString();
      } else {
        n.render(defaultSlot, ctx, engine, sections);
      }
    }
    final childCtx = <String, Object?>{
      ...props,
      'slot': defaultSlot.toString(),
      ...slots,
    };
    out.write(engine.render('components.$name', childCtx));
  }

  static Object? _attrValue(_Attr a, Map<String, Object?> ctx) {
    if (a.bound) return Expression.parse(a.value).evaluate(ctx); // :attr="expr"
    if (!a.value.contains('{{')) return a.value; // plain string
    return a.value.replaceAllMapped(
        RegExp(r'\{\{(.*?)\}\}'),
        (m) =>
            '${Expression.parse(m.group(1)!.trim()).evaluate(ctx) ?? ''}');
  }

  // `user-name` -> `userName` so props are valid Blaze identifiers.
  static String _camelName(String s) => s.replaceAllMapped(
      RegExp(r'-([a-z])'), (m) => m.group(1)!.toUpperCase());
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
