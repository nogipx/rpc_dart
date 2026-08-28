// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:sqlite3/common.dart' as sqlite;

/// Minimal reimplementation of a sqlite3 executor.
class SqliteDataDatabase {
  SqliteDataDatabase(this.database);

  final sqlite.CommonDatabase database;

  SqliteSelectQuery customSelect(
    String sql, {
    List<Object?> variables = const [],
  }) {
    return SqliteSelectQuery(database, sql, variables);
  }

  Future<void> customStatement(
    String sql, {
    List<Object?> variables = const [],
  }) {
    return Future.sync(() => database.execute(sql, variables));
  }

  Future<int> customInsert(String sql, {List<Object?> variables = const []}) {
    return Future.sync(() {
      final stmt = database.prepare(sql);
      try {
        stmt.execute(variables);
      } finally {
        stmt.close();
      }
      return database.lastInsertRowId;
    });
  }

  /// Tail of the transaction queue. A connection has ONE transaction and
  /// SQLite has no nested ones, so overlapping callers queue instead of
  /// colliding on `BEGIN`.
  Future<void> _transactionTail = Future<void>.value();

  /// Runs [action] between `BEGIN` and `COMMIT`, serialized against every
  /// other [transaction] on this connection.
  ///
  /// [action] is now awaited. It previously was not: with the async body every
  /// caller passes, `COMMIT` ran at the body's first `await`, the writes landed
  /// afterwards outside the transaction, and nothing here was ever atomic — a
  /// body that failed part-way left its earlier writes committed.
  ///
  /// NOTE: sqlite3 is synchronous throughout, so the futures in this class are
  /// a leftover from the Drift-shaped shim this used to be, and a synchronous
  /// executor would give atomicity by construction and make this queue
  /// unnecessary. That conversion was tried and DECIDED AGAINST — it surfaces a
  /// latent nested transaction (`upsertSchema` -> `getActiveSchema` ->
  /// `ensureReady`, which opens its own) that needs a design change rather than
  /// a mechanical rewrite. Treat the async surface as settled.
  Future<T> transaction<T>(FutureOr<T> Function() action) {
    final done = Completer<void>();
    final previous = _transactionTail;
    _transactionTail = done.future;
    return previous
        .then((_) => _runTransaction(action))
        .whenComplete(done.complete);
  }

  Future<T> _runTransaction<T>(FutureOr<T> Function() action) async {
    database.execute('BEGIN');
    try {
      final result = await action();
      database.execute('COMMIT');
      return result;
    } catch (_) {
      // ONLY when a transaction is still open. SQLite aborts the transaction
      // itself for a whole class of errors (SQLITE_FULL, SQLITE_IOERR,
      // SQLITE_BUSY...), and a bare ROLLBACK then threw "cannot rollback - no
      // transaction is active" straight over the top of the real failure — so
      // the disk-full or IO error the user needed to see never reached them.
      if (!database.autocommit) {
        try {
          database.execute('ROLLBACK');
        } catch (_) {
          // Best-effort cleanup; never let it bury the original error.
        }
      }
      rethrow;
    }
  }

  Future<void> close() {
    return Future.sync(() => database.close());
  }
}

class SqliteSelectQuery {
  SqliteSelectQuery(this.database, this.sql, this.variables);

  final sqlite.CommonDatabase database;
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
        'Expected at most 1 row but query returned ${rows.length}.',
      );
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
