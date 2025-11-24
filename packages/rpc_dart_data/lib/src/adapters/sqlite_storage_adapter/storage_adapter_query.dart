part of 'storage_adapter.dart';

extension _QueryHelpers on SqliteDataStorageAdapter {
  String? _columnForField(String field) {
    switch (field) {
      case 'id':
        return 'id';
      case 'version':
        return 'version';
      case 'createdAt':
        return 'created_at';
      case 'updatedAt':
        return 'updated_at';
      default:
        return null;
    }
  }

  String _qualifiedColumn(
    String column, {
    String? tableAlias,
  }) {
    if (tableAlias == null || tableAlias.isEmpty) {
      return '"$column"';
    }
    return '$tableAlias."$column"';
  }

  String _payloadColumn({String? tableAlias}) {
    if (tableAlias == null || tableAlias.isEmpty) {
      return 'payload';
    }
    return '$tableAlias.payload';
  }

  String _normalizeJsonFieldName(String field) {
    var normalized = field.trim();
    if (normalized.startsWith(r'$.')) {
      normalized = normalized.substring(2);
    } else if (normalized.startsWith(r'$')) {
      normalized = normalized.substring(1);
    }
    return normalized;
  }

  String _jsonPathLiteral(String field) {
    final normalized = _normalizeJsonFieldName(field);
    final segments =
        normalized.split('.').where((segment) => segment.isNotEmpty);
    final buffer = StringBuffer(r'$');
    for (final segment in segments) {
      final escaped = segment.replaceAll('"', r'\"');
      buffer.write('."$escaped"');
    }
    if (buffer.length == 1) {
      buffer.write('."$normalized"');
    }
    return "'${buffer.toString()}'";
  }

  String _jsonExtractExpression(
    String field, {
    String? tableAlias,
  }) {
    final source = _payloadColumn(tableAlias: tableAlias);
    final path = _jsonPathLiteral(field);
    return 'json_extract($source, $path)';
  }

  String? _fieldExpression(
    String field, {
    String? tableAlias,
  }) {
    final normalizedField = _normalizeJsonFieldName(field);
    final column = _columnForField(field) ?? _columnForField(normalizedField);
    if (column != null) {
      return _qualifiedColumn(column, tableAlias: tableAlias);
    }
    return _jsonExtractExpression(normalizedField, tableAlias: tableAlias);
  }

  Object? _normalizeValue(
    String field,
    Object? value, {
    bool forRange = false,
  }) {
    if (value == null) {
      return null;
    }
    final normalizedField = _normalizeJsonFieldName(field);
    final column = _columnForField(field) ?? _columnForField(normalizedField);
    if (column != null) {
      switch (column) {
        case 'id':
          return value.toString();
        case 'version':
          if (value is num) {
            return value.toInt();
          }
          return null;
        case 'created_at':
        case 'updated_at':
          if (value is DateTime) {
            return value.toUtc().microsecondsSinceEpoch;
          }
          if (value is String) {
            try {
              return DateTime.parse(value).toUtc().microsecondsSinceEpoch;
            } catch (_) {
              return null;
            }
          }
          if (value is num) {
            return value.toInt();
          }
          return null;
      }
    }
    if (value is bool) {
      return value ? 1 : 0;
    }
    if (value is num) {
      return value;
    }
    if (value is DateTime) {
      return forRange
          ? value.toUtc().toIso8601String()
          : value.toUtc().toIso8601String();
    }
    if (value is String) {
      return value;
    }
    if (value is Map || value is Iterable) {
      return jsonEncode(value);
    }
    return value.toString();
  }

  bool _applyEquals(
    RecordFilter? filter,
    List<String> conditions,
    List<Object> values, {
    String? tableAlias,
  }) {
    if (filter == null || filter.equals.isEmpty) {
      return true;
    }
    for (final entry in filter.equals.entries) {
      final expression = _fieldExpression(entry.key, tableAlias: tableAlias);
      if (expression == null) {
        return false;
      }
      final normalized = _normalizeValue(entry.key, entry.value);
      if (normalized == null) {
        return false;
      }
      conditions.add('$expression = ?');
      values.add(normalized);
    }
    return true;
  }

  bool _applyRanges(
    RecordFilter? filter,
    List<String> conditions,
    List<Object> values, {
    String? tableAlias,
  }) {
    if (filter == null || filter.range.isEmpty) {
      return true;
    }
    for (final entry in filter.range.entries) {
      final expression = _fieldExpression(entry.key, tableAlias: tableAlias);
      if (expression == null) {
        return false;
      }
      final constraint = entry.value;
      if (constraint.min != null) {
        final min = _normalizeValue(
          entry.key,
          constraint.min,
          forRange: true,
        );
        if (min == null) {
          return false;
        }
        final op = constraint.includeMin ? '>=' : '>';
        conditions.add('$expression $op ?');
        values.add(min);
      }
      if (constraint.max != null) {
        final max = _normalizeValue(
          entry.key,
          constraint.max,
          forRange: true,
        );
        if (max == null) {
          return false;
        }
        final op = constraint.includeMax ? '<=' : '<';
        conditions.add('$expression $op ?');
        values.add(max);
      }
    }
    return true;
  }

  bool _translateFilter(
    RecordFilter? filter,
    List<String> conditions,
    List<Object> values, {
    String? tableAlias,
  }) {
    if (filter == null) {
      return true;
    }
    if (filter.containsTerms.isNotEmpty) {
      final payloadColumn = _payloadColumn(tableAlias: tableAlias);
      for (final term in filter.containsTerms) {
        final normalized = term.trim().toLowerCase();
        if (normalized.isEmpty) {
          continue;
        }
        conditions.add('LOWER($payloadColumn) LIKE ?');
        values.add('%$normalized%');
      }
    }
    if (!_applyEquals(
      filter,
      conditions,
      values,
      tableAlias: tableAlias,
    )) {
      return false;
    }
    if (!_applyRanges(
      filter,
      conditions,
      values,
      tableAlias: tableAlias,
    )) {
      return false;
    }
    return true;
  }

  bool _supportsSort(SortOrder? sort) {
    if (sort == null) {
      return true;
    }
    return _fieldExpression(sort.field) != null;
  }

  List<Object?> _buildVariables(Iterable<Object> values) {
    return values.toList(growable: false);
  }

  String? _buildFtsMatchPattern(String query) {
    final tokens = query
        .split(RegExp(r'\s+'))
        .map((token) => token.trim())
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    if (tokens.isEmpty) {
      return null;
    }
    final wildcardTokens =
        tokens.map((token) => '${token.replaceAll('"', '""')}*').join(' ');
    return wildcardTokens;
  }

  String _normalizeSearchToken(Object? value) {
    if (value == null) {
      return '';
    }
    if (value is DateTime) {
      return value.toUtc().toIso8601String();
    }
    if (value is bool) {
      return value ? 'true' : 'false';
    }
    if (value is Map || value is Iterable) {
      return jsonEncode(value);
    }
    return value.toString();
  }

  String _prepareSearchText(DataRecord record) {
    final buffer = StringBuffer()
      ..write(record.id)
      ..write(' ')
      ..write(record.collection);
    buffer
      ..write(' version ')
      ..write(record.version.toString());
    record.payload.forEach((key, value) {
      buffer
        ..write(' ')
        ..write(key);
      final token = _normalizeSearchToken(value);
      if (token.isNotEmpty) {
        buffer
          ..write(' ')
          ..write(token);
      }
    });
    buffer
      ..write(' created ')
      ..write(record.createdAt.toUtc().toIso8601String())
      ..write(' updated ')
      ..write(record.updatedAt.toUtc().toIso8601String());
    return buffer.toString().toLowerCase();
  }
}
