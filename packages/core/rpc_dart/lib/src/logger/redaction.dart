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
      } else if (entry.value is Map<String, Object>) {
        result[entry.key] = redact(entry.value as Map<String, Object>);
      } else {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }
}
