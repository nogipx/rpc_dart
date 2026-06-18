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
  LogRedactor({
    required List<String> fields,
    this.replacement = '[REDACTED]',
  }) : _fields = fields.map((f) => f.toLowerCase()).toSet();

  /// Returns true if there are fields to redact.
  bool get isActive => _fields.isNotEmpty;

  /// Redacts matching keys in [data]. Returns a new map (does not mutate input).
  Map<String, Object> redact(Map<String, Object> data) {
    final result = <String, Object>{};
    for (final entry in data.entries) {
      if (_fields.contains(entry.key.toLowerCase())) {
        result[entry.key] = replacement;
      } else if (entry.value is Map) {
        // Recurse into ANY map regardless of its generic type arguments
        // (JSON-decoded maps are typically Map<String, dynamic> / untyped),
        // otherwise nested sensitive fields would leak.
        result[entry.key] = _redactDynamic(entry.value as Map);
      } else {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  /// Redacts a map of arbitrary generic type (e.g. JSON-decoded maps).
  ///
  /// Keys are compared case-insensitively (after stringification); nested maps
  /// are recursed into regardless of their generic type arguments.
  Map<String, Object> _redactDynamic(Map data) {
    final result = <String, Object>{};
    for (final entry in data.entries) {
      final key = entry.key.toString();
      final value = entry.value;
      if (_fields.contains(key.toLowerCase())) {
        result[key] = replacement;
      } else if (value is Map) {
        result[key] = _redactDynamic(value);
      } else if (value != null) {
        result[key] = value;
      }
    }
    return result;
  }

  /// Redacts sensitive patterns in a free-text string.
  ///
  /// Matches `field=value` and `field: value` patterns where [field] is one
  /// of the configured sensitive field names (case-insensitive).
  String redactString(String input) {
    if (_pattern == null) return input;
    return input.replaceAllMapped(_pattern!, (m) => '${m[1]}$replacement');
  }

  late final RegExp? _pattern = _buildPattern();

  RegExp? _buildPattern() {
    if (_fields.isEmpty) return null;
    final escaped = _fields.map(RegExp.escape).join('|');
    // Matches: field=value or field: value (up to whitespace, comma, or end)
    return RegExp(
      '($escaped[=:]\\s?)[^\\s,;]+',
      caseSensitive: false,
    );
  }
}
