// Dartisan string helpers — the Laravel `Str` analog. Small, pure, app-facing
// utilities for slugs, titles, truncation, and naive pluralization.
import 'dart:math';

class Str {
  Str._();

  /// A URL-friendly slug: lowercased, non-alphanumerics collapsed to [separator].
  static String slug(String value, [String separator = '-']) {
    var s = value.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), separator);
    while (s.startsWith(separator)) {
      s = s.substring(separator.length);
    }
    while (s.endsWith(separator)) {
      s = s.substring(0, s.length - separator.length);
    }
    return s;
  }

  /// Title-cases each word (`hello_world` -> `Hello World`).
  static String title(String value) => value
      .split(RegExp(r'[\s_-]+'))
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
      .join(' ');

  /// Uppercases the first character.
  static String ucfirst(String value) =>
      value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

  // Splits an identifier into lowercase words on spaces, _/-, and camelCase
  // boundaries.
  static List<String> _words(String value) => value
      .replaceAllMapped(RegExp('([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .split(RegExp(r'[\s_-]+'))
      .where((w) => w.isNotEmpty)
      .map((w) => w.toLowerCase())
      .toList();

  /// `camelCase` (`foo_bar` / `foo-bar` / `FooBar` -> `fooBar`).
  static String camel(String value) {
    final words = _words(value);
    if (words.isEmpty) return '';
    return words.first +
        words.skip(1).map((w) => w[0].toUpperCase() + w.substring(1)).join();
  }

  /// `StudlyCase` / `PascalCase` (`foo_bar` -> `FooBar`).
  static String studly(String value) =>
      _words(value).map((w) => w[0].toUpperCase() + w.substring(1)).join();

  /// `snake_case` (`fooBar` / `foo-bar` -> `foo_bar`), using [separator].
  static String snake(String value, [String separator = '_']) =>
      _words(value).join(separator);

  /// `kebab-case` (`fooBar` / `foo_bar` -> `foo-bar`).
  static String kebab(String value) => snake(value, '-');

  /// Truncates to [limit] characters, appending [end] when cut.
  static String limit(String value, int limit, [String end = '...']) =>
      value.length <= limit ? value : '${value.substring(0, limit).trimRight()}$end';

  /// Truncates to [count] words, appending [end] when cut.
  static String words(String value, int count, [String end = '...']) {
    final parts = value.split(RegExp(r'\s+'));
    return parts.length <= count ? value : '${parts.take(count).join(' ')}$end';
  }

  /// Collapses runs of whitespace to single spaces and trims.
  static String squish(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// The portion of [value] before the first occurrence of [search].
  static String before(String value, String search) {
    final i = value.indexOf(search);
    return i < 0 ? value : value.substring(0, i);
  }

  /// The portion of [value] after the first occurrence of [search].
  static String after(String value, String search) {
    final i = value.indexOf(search);
    return i < 0 ? value : value.substring(i + search.length);
  }

  /// The portion of [value] before the last occurrence of [search].
  static String beforeLast(String value, String search) {
    final i = value.lastIndexOf(search);
    return i < 0 ? value : value.substring(0, i);
  }

  /// The portion of [value] after the last occurrence of [search].
  static String afterLast(String value, String search) {
    final i = value.lastIndexOf(search);
    return i < 0 ? value : value.substring(i + search.length);
  }

  /// The portion of [value] between the first [from] and the last [to].
  static String between(String value, String from, String to) =>
      beforeLast(after(value, from), to);

  /// Masks all but the last [visible] characters with [char].
  static String mask(String value, {int visible = 4, String char = '*'}) =>
      value.length <= visible
          ? value
          : char * (value.length - visible) + value.substring(value.length - visible);

  /// A random alphanumeric string of [length] characters (secure RNG).
  static String random([int length = 16]) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return String.fromCharCodes(
        List.generate(length, (_) => chars.codeUnitAt(r.nextInt(chars.length))));
  }

  /// Naive English pluralization (good enough for table names, labels).
  static String plural(String value) {
    if (value.isEmpty) return value;
    final lower = value.toLowerCase();
    if (lower.endsWith('y') &&
        value.length > 1 &&
        !'aeiou'.contains(lower[lower.length - 2])) {
      return '${value.substring(0, value.length - 1)}ies';
    }
    if (RegExp(r'(s|x|z|ch|sh)$').hasMatch(lower)) return '${value}es';
    return '${value}s';
  }

  /// Naive English singularization (inverse of [plural]).
  static String singular(String value) {
    final lower = value.toLowerCase();
    if (lower.endsWith('ies') && value.length > 3) {
      return '${value.substring(0, value.length - 3)}y';
    }
    if (RegExp(r'(s|x|z|ch|sh)es$').hasMatch(lower)) {
      return value.substring(0, value.length - 2);
    }
    if (lower.endsWith('s') && !lower.endsWith('ss')) {
      return value.substring(0, value.length - 1);
    }
    return value;
  }
}
