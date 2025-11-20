import 'dart:async';

import 'package:sqlite3/sqlite3.dart' as sqlite;

/// Minimal reimplementation of a sqlite3 executor.
class SqliteDataDatabase {
  SqliteDataDatabase(this.database);

  final sqlite.Database database;

  _SqliteSelectQuery customSelect(
    String sql, {
    List<Object?> variables = const [],
  }) {
    return _SqliteSelectQuery(database, sql, variables);
  }

  Future<void> customStatement(
    String sql, {
    List<Object?> variables = const [],
  }) {
    return Future.sync(() => database.execute(sql, variables));
  }

  Future<int> customInsert(
    String sql, {
    List<Object?> variables = const [],
  }) {
    return Future.sync(() {
      final stmt = database.prepare(sql);
      try {
        stmt.execute(variables);
      } finally {
        stmt.dispose();
      }
      return database.lastInsertRowId;
    });
  }

  Future<T> transaction<T>(FutureOr<T> Function() action) {
    return Future.sync(() {
      database.execute('BEGIN');
      try {
        final result = action();
        database.execute('COMMIT');
        return result;
      } catch (error) {
        database.execute('ROLLBACK');
        rethrow;
      }
    });
  }

  Future<void> close() {
    return Future.sync(() => database.dispose());
  }
}

class _SqliteSelectQuery {
  _SqliteSelectQuery(
    this.database,
    this.sql,
    this.variables,
  );

  final sqlite.Database database;
  final String sql;
  final List<Object?> variables;

  Future<List<sqlite.Row>> get() async {
    return database.select(sql, variables);
  }

  Future<sqlite.Row?> getSingleOrNull() async {
    final rows = await get();
    if (rows.isEmpty) {
      return null;
    }
    if (rows.length > 1) {
      throw StateError(
          'Expected at most 1 row but query returned ${rows.length}.');
    }
    return rows.first;
  }

  Future<sqlite.Row> getSingle() async {
    final row = await getSingleOrNull();
    if (row == null) {
      throw StateError('Expected exactly 1 row but query returned 0.');
    }
    return row;
  }
}

extension SqliteRowRead on sqlite.Row {
  T read<T>(String column) {
    final value = this[column];
    return value as T;
  }
}
