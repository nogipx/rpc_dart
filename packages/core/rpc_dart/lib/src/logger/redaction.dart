// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Redacts sensitive fields from log record data.
///
/// Matches field names (case-insensitive) and replaces values with [replacement].
class LogRedactor {
  final Set<String> _fields;

  /// String substituted for redacted values. Defaults to `'[REDACTED]'`.
  final String replacement;

  /// Creates a redactor that masks the given [fields] (case-insensitive).
  LogRedactor({required List<String> fields, this.replacement = '[REDACTED]'})
    : _fields = fields.map((f) => f.toLowerCase()).toSet();

  /// Returns true if there are fields to redact.
  bool get isActive => _fields.isNotEmpty;

  /// Redacts matching keys in [data]. Returns a new map (does not mutate input).
  Map<String, Object> redact(Map<String, Object> data) {
    final result = <String, Object>{};
    for (final entry in data.entries) {
      if (_fields.contains(entry.key.toLowerCase())) {
        result[entry.key] = replacement;
      } else {
        result[entry.key] = _redactValue(entry.value);
      }
    }
    return result;
  }

  /// Redacts a map of arbitrary generic type (e.g. JSON-decoded maps).
  ///
  /// Keys are compared case-insensitively (after stringification); nested maps
  /// and lists are recursed into regardless of their generic type arguments.
  Map<String, Object> _redactDynamic(Map data) {
    final result = <String, Object>{};
    for (final entry in data.entries) {
      final key = entry.key.toString();
      final value = entry.value;
      if (_fields.contains(key.toLowerCase())) {
        result[key] = replacement;
      } else if (value != null) {
        result[key] = _redactValue(value);
      }
    }
    return result;
  }

  /// Recurses into nested maps and lists so sensitive fields buried inside a
  /// list element (e.g. a list of objects) are still masked; scalars pass
  /// through unchanged.
  Object _redactValue(Object value) {
    if (value is Map) return _redactDynamic(value);
    if (value is List) {
      return [
        for (final element in value)
          element == null ? element : _redactValue(element),
      ];
    }
    return value;
  }

  /// Redacts sensitive patterns in a free-text string.
  ///
  /// Matches `field=value` and `field: value` patterns where [field] is one
  /// of the configured sensitive field names (case-insensitive).
  String redactString(String input) {
    if (_pattern == null) return input;
    // Groups: 1 = leading boundary (start-of-string or a separator char,
    // re-emitted verbatim), 2 = field name, 3 = the `=`/`:` separator with any
    // surrounding whitespace. Only the value that follows is masked.
    return input.replaceAllMapped(
      _pattern,
      (m) => '${m[1]}${m[2]}${m[3]}$replacement',
    );
  }

  late final RegExp? _pattern = _buildPattern();

  RegExp? _buildPattern() {
    if (_fields.isEmpty) return null;
    final escaped = _fields.map(RegExp.escape).join('|');
    // Matches: <boundary>field=value or field: value (value runs up to the next
    // whitespace, comma, semicolon, or end). The leading boundary (start or a
    // separator char) prevents matching a field name as a substring of a longer
    // identifier (e.g. `mytoken=`), and `\s*` around the separator handles
    // `password = value`. A captured boundary is used instead of a lookbehind
    // so the behavior is identical on the VM and dart2js.
    return RegExp(
      '(^|[\\s,;])($escaped)(\\s*[=:]\\s*)[^\\s,;]+',
      caseSensitive: false,
    );
  }
}
