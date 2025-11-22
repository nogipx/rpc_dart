import 'dart:convert';

import 'package:sqlite3/common.dart' as sqlite;

/// Ensures that [json_extract] is available on the provided SQLite database.
void ensureJsonExtractFunction(sqlite.CommonDatabase database) {
  try {
    database.select(
      r"""SELECT json_extract('1', '$')""",
    );
    return;
  } on sqlite.SqliteException catch (error) {
    final message = error.message;
    if (!message.contains('no such function: json_extract')) {
      rethrow;
    }
  }

  database.createFunction(
    functionName: 'json_extract',
    argumentCount: const sqlite.AllowedArgumentCount(2),
    deterministic: true,
    directOnly: false,
    function: _jsonExtractFallback,
  );
}

Object? _jsonExtractFallback(List<Object?> arguments) {
  if (arguments.length < 2) {
    return null;
  }

  final source = arguments[0];
  final pathArg = arguments[1];
  if (source == null || pathArg == null) {
    return null;
  }

  final jsonText = _jsonStringFromValue(source);
  if (jsonText == null) {
    return null;
  }

  final path = pathArg.toString();
  if (path.isEmpty) {
    return null;
  }

  try {
    final root = jsonDecode(jsonText);
    final tokens = _parseJsonPathTokens(path);
    if (tokens.isEmpty) {
      final normalized = path.trim();
      if (normalized == r'$') {
        return _jsonValueToSqlValue(root);
      }
      return null;
    }
    final value = _walkJsonPath(root, tokens);
    return _jsonValueToSqlValue(value);
  } catch (_) {
    return null;
  }
}

String? _jsonStringFromValue(Object? source) {
  if (source is String) {
    return source;
  }
  if (source is List<int>) {
    return utf8.decode(source, allowMalformed: true);
  }
  return null;
}

List<Object> _parseJsonPathTokens(String path) {
  final tokens = <Object>[];
  var index = 0;

  if (path.startsWith(r'$')) {
    index += 1;
  }

  while (index < path.length) {
    final current = path[index];
    if (current == '.') {
      index += 1;
      if (index >= path.length) {
        break;
      }
      if (path[index] == '"') {
        index += 1;
        final buffer = StringBuffer();
        while (index < path.length) {
          final char = path[index];
          if (char == '\\') {
            if (index + 1 < path.length) {
              buffer.write(path[index + 1]);
              index += 2;
              continue;
            }
            index += 1;
            continue;
          }
          if (char == '"') {
            index += 1;
            break;
          }
          buffer.write(char);
          index += 1;
        }
        tokens.add(buffer.toString());
        continue;
      }
    }

    if (current == '[') {
      final end = path.indexOf(']', index + 1);
      if (end == -1) {
        break;
      }
      final indexValue = int.tryParse(path.substring(index + 1, end));
      if (indexValue != null) {
        tokens.add(indexValue);
      }
      index = end + 1;
      continue;
    }

    index += 1;
  }

  return tokens;
}

dynamic _walkJsonPath(dynamic root, List<Object> tokens) {
  var current = root;
  for (final token in tokens) {
    if (token is String) {
      if (current is Map<String, dynamic>) {
        current = current[token];
        continue;
      }
      return null;
    }
    if (token is int) {
      if (current is List && token >= 0 && token < current.length) {
        current = current[token];
        continue;
      }
      return null;
    }
    return null;
  }
  return current;
}

Object? _jsonValueToSqlValue(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is num || value is String) {
    return value;
  }
  if (value is bool) {
    return value ? 1 : 0;
  }
  if (value is List || value is Map) {
    return jsonEncode(value);
  }
  return value.toString();
}
