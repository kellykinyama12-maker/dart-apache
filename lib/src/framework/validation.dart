// Request validation for Dartisan — the Laravel `Validator` / FormRequest
// analog. Rules are `pipe|separated` strings (e.g. `required|email|min:3`),
// validated against a data map; errors are collected per field.

/// Thrown by [Request.validate] when validation fails; carries field errors.
class ValidationException implements Exception {
  ValidationException(this.errors);

  /// field name -> list of human-readable error messages.
  final Map<String, List<String>> errors;

  @override
  String toString() => 'ValidationException($errors)';
}

/// Validates a data map against rule strings, returning `field -> [messages]`
/// (empty when everything passes). Supported rules: `required`, `email`,
/// `numeric`, `integer`, `boolean`, `url`, `alpha`, `alphanum`, `min:N`,
/// `max:N`, `in:a,b,c`, `confirmed`.
class Validator {
  static final _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
  static final _alpha = RegExp(r'^[A-Za-z]+$');
  static final _alphanum = RegExp(r'^[A-Za-z0-9]+$');

  static Map<String, List<String>> validate(
    Map<String, Object?> data,
    Map<String, String> rules,
  ) {
    final errors = <String, List<String>>{};
    rules.forEach((field, spec) {
      final specs = spec.split('|').where((s) => s.isNotEmpty).toList();
      final value = data[field];
      final present = value != null && '$value'.isNotEmpty;
      final required = specs.contains('required');

      if (!present) {
        if (required) {
          (errors[field] ??= []).add('The $field field is required.');
        }
        return; // optional + absent -> no further checks
      }

      for (final rule in specs) {
        if (rule == 'required') continue;
        final idx = rule.indexOf(':');
        final name = idx < 0 ? rule : rule.substring(0, idx);
        final arg = idx < 0 ? '' : rule.substring(idx + 1);
        final msg = _check(name, arg, field, value, data);
        if (msg != null) (errors[field] ??= []).add(msg);
      }
    });
    return errors;
  }

  static String? _check(
    String rule,
    String arg,
    String field,
    Object? value,
    Map<String, Object?> data,
  ) {
    final s = '$value';
    switch (rule) {
      case 'email':
        return _email.hasMatch(s)
            ? null
            : 'The $field must be a valid email address.';
      case 'numeric':
        return num.tryParse(s) != null ? null : 'The $field must be a number.';
      case 'integer':
        return int.tryParse(s) != null
            ? null
            : 'The $field must be an integer.';
      case 'boolean':
        return const {'true', 'false', '0', '1'}.contains(s)
            ? null
            : 'The $field field must be true or false.';
      case 'url':
        return (s.startsWith('http://') || s.startsWith('https://'))
            ? null
            : 'The $field must be a valid URL.';
      case 'alpha':
        return _alpha.hasMatch(s)
            ? null
            : 'The $field may only contain letters.';
      case 'alphanum':
        return _alphanum.hasMatch(s)
            ? null
            : 'The $field may only contain letters and numbers.';
      case 'min':
        final n = int.tryParse(arg) ?? 0;
        final num_ = num.tryParse(s);
        if (num_ != null) {
          return num_ >= n ? null : 'The $field must be at least $n.';
        }
        return s.length >= n
            ? null
            : 'The $field must be at least $n characters.';
      case 'max':
        final n = int.tryParse(arg) ?? 0;
        final num_ = num.tryParse(s);
        if (num_ != null) {
          return num_ <= n ? null : 'The $field must not be greater than $n.';
        }
        return s.length <= n
            ? null
            : 'The $field must not be greater than $n characters.';
      case 'in':
        final options = arg.split(',');
        return options.contains(s)
            ? null
            : 'The selected $field is invalid.';
      case 'confirmed':
        return '${data['${field}_confirmation']}' == s
            ? null
            : 'The $field confirmation does not match.';
      default:
        return null; // unknown rule -> ignore
    }
  }
}
