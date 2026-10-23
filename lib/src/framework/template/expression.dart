// A tiny, safe expression language for the Blaze templating engine. It
// evaluates against a `Map<String, Object?>` context at runtime (AOT-friendly —
// no `eval`), supporting variable paths, literals, arithmetic, comparisons,
// boolean logic, and an allow-listed set of helper functions (no arbitrary
// code).
import 'dart:collection';

/// Thrown when an expression cannot be parsed.
class ExpressionError implements Exception {
  ExpressionError(this.message);
  final String message;
  @override
  String toString() => 'ExpressionError: $message';
}

/// A parsed expression; evaluate it against a context map.
class Expression {
  Expression._(this._root);
  final _Node _root;

  static final Map<String, Expression> _cache = HashMap();

  /// Parses [source] (cached).
  factory Expression.parse(String source) =>
      _cache.putIfAbsent(source, () => Expression._(_Parser(source).parse()));

  /// Evaluates against [context].
  Object? evaluate(Map<String, Object?> context) => _root.eval(context);

  /// Evaluates and coerces to a boolean using template truthiness.
  bool evaluateTruthy(Map<String, Object?> context) => truthy(evaluate(context));

  /// Template truthiness: null/false/0/''/empty-collection are falsey.
  static bool truthy(Object? v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v.isNotEmpty;
    if (v is Iterable) return v.isNotEmpty;
    if (v is Map) return v.isNotEmpty;
    return true;
  }
}

// ---------------------------------------------------------------------------
// AST
// ---------------------------------------------------------------------------

abstract class _Node {
  Object? eval(Map<String, Object?> ctx);
}

class _Literal extends _Node {
  _Literal(this.value);
  final Object? value;
  @override
  Object? eval(Map<String, Object?> ctx) => value;
}

class _Ident extends _Node {
  _Ident(this.name);
  final String name;
  @override
  Object? eval(Map<String, Object?> ctx) => ctx[name];
}

/// A call to one of the allow-listed [_builtins] helper functions.
class _Call extends _Node {
  _Call(this.name, this.args);
  final String name;
  final List<_Node> args;
  @override
  Object? eval(Map<String, Object?> ctx) {
    final fn = _builtins[name];
    if (fn == null) throw ExpressionError('unknown function "$name"');
    return fn([for (final a in args) a.eval(ctx)]);
  }
}

int _len(Object? v) {
  if (v is String) return v.length;
  if (v is Iterable) return v.length;
  if (v is Map) return v.length;
  return 0;
}

/// The only functions callable from a template expression.
final Map<String, Object? Function(List<Object?>)> _builtins = {
  'upper': (a) => '${a.isEmpty ? '' : a[0] ?? ''}'.toUpperCase(),
  'lower': (a) => '${a.isEmpty ? '' : a[0] ?? ''}'.toLowerCase(),
  'trim': (a) => '${a.isEmpty ? '' : a[0] ?? ''}'.trim(),
  'length': (a) => _len(a.isEmpty ? null : a[0]),
  'ucfirst': (a) {
    final s = '${a.isEmpty ? '' : a[0] ?? ''}';
    return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
  },
  'default': (a) {
    final v = a.isEmpty ? null : a[0];
    final empty = v == null || (v is String && v.isEmpty);
    return empty ? (a.length > 1 ? a[1] : '') : v;
  },
  'limit': (a) {
    final s = '${a.isEmpty ? '' : a[0] ?? ''}';
    final n = a.length > 1 ? (a[1] as num).toInt() : 100;
    final end = a.length > 2 ? '${a[2]}' : '…';
    return s.length <= n ? s : s.substring(0, n) + end;
  },
  'round': (a) => (a[0] as num).round(),
  'abs': (a) => (a[0] as num).abs(),
  'join': (a) {
    final v = a.isEmpty ? null : a[0];
    final sep = a.length > 1 ? '${a[1]}' : ', ';
    return v is Iterable ? v.map((e) => '$e').join(sep) : '$v';
  },
};

class _Member extends _Node {
  _Member(this.target, this.name);
  final _Node target;
  final String name;
  @override
  Object? eval(Map<String, Object?> ctx) {
    final t = target.eval(ctx);
    if (t is Map) return t[name];
    if (name == 'length') {
      if (t is String) return t.length;
      if (t is Iterable) return t.length;
      if (t is Map) return t.length;
    }
    if (name == 'isEmpty') {
      if (t is String) return t.isEmpty;
      if (t is Iterable) return t.isEmpty;
      if (t is Map) return t.isEmpty;
    }
    return null;
  }
}

class _Index extends _Node {
  _Index(this.target, this.key);
  final _Node target;
  final _Node key;
  @override
  Object? eval(Map<String, Object?> ctx) {
    final t = target.eval(ctx);
    final k = key.eval(ctx);
    if (t is Map) return t[k];
    if (t is List && k is num) {
      final i = k.toInt();
      return (i >= 0 && i < t.length) ? t[i] : null;
    }
    return null;
  }
}

class _Unary extends _Node {
  _Unary(this.op, this.operand);
  final String op;
  final _Node operand;
  @override
  Object? eval(Map<String, Object?> ctx) {
    final v = operand.eval(ctx);
    if (op == '!') return !Expression.truthy(v);
    if (op == '-') return v is num ? -v : null;
    return null;
  }
}

class _Binary extends _Node {
  _Binary(this.op, this.left, this.right);
  final String op;
  final _Node left;
  final _Node right;
  @override
  Object? eval(Map<String, Object?> ctx) {
    // Short-circuit logic.
    if (op == '&&') {
      return Expression.truthy(left.eval(ctx)) &&
          Expression.truthy(right.eval(ctx));
    }
    if (op == '||') {
      return Expression.truthy(left.eval(ctx)) ||
          Expression.truthy(right.eval(ctx));
    }
    final l = left.eval(ctx);
    final r = right.eval(ctx);
    switch (op) {
      case '==':
        return l == r;
      case '!=':
        return l != r;
      case '+':
        if (l is num && r is num) return l + r;
        if (l is String || r is String) return '${l ?? ''}${r ?? ''}';
        return null;
      case '-':
        return (l is num && r is num) ? l - r : null;
      case '*':
        return (l is num && r is num) ? l * r : null;
      case '/':
        return (l is num && r is num) ? l / r : null;
      case '%':
        return (l is num && r is num) ? l % r : null;
      case '<':
        return (l is num && r is num) ? l < r : _strCmp(l, r) < 0;
      case '>':
        return (l is num && r is num) ? l > r : _strCmp(l, r) > 0;
      case '<=':
        return (l is num && r is num) ? l <= r : _strCmp(l, r) <= 0;
      case '>=':
        return (l is num && r is num) ? l >= r : _strCmp(l, r) >= 0;
    }
    return null;
  }

  static int _strCmp(Object? a, Object? b) => '$a'.compareTo('$b');
}

// ---------------------------------------------------------------------------
// Lexer + parser (recursive descent with precedence climbing)
// ---------------------------------------------------------------------------

class _Parser {
  _Parser(this._src);
  final String _src;
  int _pos = 0;

  _Node parse() {
    final node = _parseOr();
    _skipWs();
    if (_pos != _src.length) {
      throw ExpressionError('unexpected "${_src.substring(_pos)}"');
    }
    return node;
  }

  _Node _parseOr() {
    var left = _parseAnd();
    while (_match('||')) {
      left = _Binary('||', left, _parseAnd());
    }
    return left;
  }

  _Node _parseAnd() {
    var left = _parseEquality();
    while (_match('&&')) {
      left = _Binary('&&', left, _parseEquality());
    }
    return left;
  }

  _Node _parseEquality() {
    var left = _parseComparison();
    while (true) {
      if (_match('==')) {
        left = _Binary('==', left, _parseComparison());
      } else if (_match('!=')) {
        left = _Binary('!=', left, _parseComparison());
      } else {
        return left;
      }
    }
  }

  _Node _parseComparison() {
    var left = _parseAdd();
    while (true) {
      if (_match('<=')) {
        left = _Binary('<=', left, _parseAdd());
      } else if (_match('>=')) {
        left = _Binary('>=', left, _parseAdd());
      } else if (_match('<')) {
        left = _Binary('<', left, _parseAdd());
      } else if (_match('>')) {
        left = _Binary('>', left, _parseAdd());
      } else {
        return left;
      }
    }
  }

  _Node _parseAdd() {
    var left = _parseMul();
    while (true) {
      if (_match('+')) {
        left = _Binary('+', left, _parseMul());
      } else if (_matchMinus()) {
        left = _Binary('-', left, _parseMul());
      } else {
        return left;
      }
    }
  }

  _Node _parseMul() {
    var left = _parseUnary();
    while (true) {
      if (_match('*')) {
        left = _Binary('*', left, _parseUnary());
      } else if (_match('/')) {
        left = _Binary('/', left, _parseUnary());
      } else if (_match('%')) {
        left = _Binary('%', left, _parseUnary());
      } else {
        return left;
      }
    }
  }

  _Node _parseUnary() {
    _skipWs();
    if (_match('!')) return _Unary('!', _parseUnary());
    if (_matchMinus()) return _Unary('-', _parseUnary());
    return _parsePostfix();
  }

  _Node _parsePostfix() {
    var node = _parsePrimary();
    while (true) {
      _skipWs();
      if (_peek() == '.') {
        _pos++;
        final name = _readIdent();
        node = _Member(node, name);
      } else if (_peek() == '[') {
        _pos++;
        final key = _parseOr();
        _skipWs();
        _expect(']');
        node = _Index(node, key);
      } else {
        return node;
      }
    }
  }

  _Node _parsePrimary() {
    _skipWs();
    final c = _peek();
    if (c == '(') {
      _pos++;
      final node = _parseOr();
      _skipWs();
      _expect(')');
      return node;
    }
    if (c == "'" || c == '"') return _Literal(_readString(c!));
    if (c != null && (_isDigit(c))) return _Literal(_readNumber());
    if (c != null && (_isIdentStart(c))) {
      final id = _readIdent();
      switch (id) {
        case 'true':
          return _Literal(true);
        case 'false':
          return _Literal(false);
        case 'null':
          return _Literal(null);
      }
      _skipWs();
      if (_peek() == '(') {
        _pos++; // past '('
        final args = <_Node>[];
        _skipWs();
        if (_peek() != ')') {
          args.add(_parseOr());
          _skipWs();
          while (_peek() == ',') {
            _pos++;
            args.add(_parseOr());
            _skipWs();
          }
        }
        _expect(')');
        return _Call(id, args);
      }
      return _Ident(id);
    }
    throw ExpressionError('unexpected "${c ?? '<eof>'}" at $_pos');
  }

  // --- scanning helpers ---
  String? _peek() => _pos < _src.length ? _src[_pos] : null;

  void _skipWs() {
    while (_pos < _src.length && _src[_pos].trim().isEmpty) {
      _pos++;
    }
  }

  bool _match(String op) {
    _skipWs();
    if (_src.startsWith(op, _pos)) {
      _pos += op.length;
      return true;
    }
    return false;
  }

  // Minus needs care so it isn't confused with `->`-like sequences; simple here.
  bool _matchMinus() {
    _skipWs();
    if (_peek() == '-') {
      _pos++;
      return true;
    }
    return false;
  }

  void _expect(String ch) {
    if (_peek() != ch) {
      throw ExpressionError('expected "$ch" at $_pos');
    }
    _pos++;
  }

  String _readIdent() {
    _skipWs();
    final start = _pos;
    if (_pos >= _src.length || !_isIdentStart(_src[_pos])) {
      throw ExpressionError('expected identifier at $_pos');
    }
    _pos++;
    while (_pos < _src.length && _isIdentPart(_src[_pos])) {
      _pos++;
    }
    return _src.substring(start, _pos);
  }

  String _readString(String quote) {
    _pos++; // opening quote
    final sb = StringBuffer();
    while (_pos < _src.length && _src[_pos] != quote) {
      if (_src[_pos] == r'\' && _pos + 1 < _src.length) {
        _pos++;
      }
      sb.write(_src[_pos]);
      _pos++;
    }
    _expect(quote);
    return sb.toString();
  }

  num _readNumber() {
    final start = _pos;
    while (_pos < _src.length && (_isDigit(_src[_pos]) || _src[_pos] == '.')) {
      _pos++;
    }
    final text = _src.substring(start, _pos);
    return text.contains('.')
        ? double.parse(text)
        : int.parse(text);
  }

  bool _isDigit(String c) => c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;
  bool _isIdentStart(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || c == '_';
  }

  bool _isIdentPart(String c) => _isIdentStart(c) || _isDigit(c);
}
