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
  Map<String, Object> _redactDynamic(Map<Object?, Object?> data) {
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
    if (value is Map<Object?, Object?>) return _redactDynamic(value);
    if (value is List<Object?>) {
      return [
        for (final element in value)
          element == null ? element : _redactValue(element),
      ];
    }
    return value;
  }

  /// Redacts sensitive patterns in a free-text string.
  ///
  /// Matches `field=value` and `field: value` where `field` is one of the
  /// configured names (case-insensitive), in the shapes a secret is usually
  /// logged in: a query string (`?token=x&password=y`), JSON
  /// (`"password":"x"`), and an authorization value with its scheme
  /// (`authorization: Bearer x`), where the credential, not the scheme word,
  /// is what must go.
  String redactString(String input) {
    if (_pattern == null) return input;
    return input.replaceAllMapped(_pattern, (m) {
      final value = m[5]!;
      final quote = value.startsWith('"') || value.startsWith("'")
          ? value[0]
          : '';
      return '${m[1]}${m[2]}${m[3]}${m[2]}${m[4]}$quote$replacement$quote';
    });
  }

  late final RegExp? _pattern = _buildPattern();

  RegExp? _buildPattern() {
    if (_fields.isEmpty) return null;
    final escaped = _fields.map(RegExp.escape).join('|');
    // Groups: 1 = the boundary before the name, re-emitted; 2 = an optional
    // opening quote, which must close after the name; 3 = the name; 4 = the
    // `=`/`:` separator with its whitespace; 5 = the value, masked.
    //
    // The boundary is start or any character that cannot continue an
    // identifier, so `mytoken=` and `my-token=` do not match `token`. A
    // captured boundary rather than a lookbehind keeps the VM and dart2js
    // identical. An unquoted value ends at whitespace or at a character that
    // ends a value in a query string or JSON; a scheme word before it is part
    // of it.
    return RegExp(
      '(^|[^A-Za-z0-9_\\-])(["\']?)($escaped)\\2(\\s*[=:]\\s*)'
      '("[^"]*"|\'[^\']*\'|'
      '(?:(?:bearer|basic|digest|negotiate|token)\\s+)?[^\\s,;&"\'}\\]]+)',
      caseSensitive: false,
    );
  }
}
