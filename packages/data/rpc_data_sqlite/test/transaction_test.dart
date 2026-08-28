// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_data_sqlite/src/sqlite_storage/database.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Database raw;
  late SqliteDataDatabase db;

  setUp(() {
    raw = sqlite3.openInMemory();
    raw.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    db = SqliteDataDatabase(raw);
  });

  tearDown(() => raw.close());

  List<String> rows() => raw
      .select('SELECT v FROM t ORDER BY id')
      .map((r) => r['v'] as String)
      .toList();

  group('transaction', () {
    test('an async body runs INSIDE the transaction, not after it', () async {
      // The body only reaches its write after an await. If COMMIT is issued
      // before the body resumes, the write lands in autocommit and the
      // transaction covered nothing at all.
      late bool insideTransaction;
      await db.transaction(() async {
        await Future<void>.delayed(Duration.zero);
        insideTransaction = !raw.autocommit;
        raw.execute("INSERT INTO t (v) VALUES ('a')");
      });
      expect(insideTransaction, isTrue,
          reason: 'the body resumed outside the transaction');
      expect(rows(), ['a']);
      expect(raw.autocommit, isTrue, reason: 'transaction left open');
    });

    test('an async body that throws rolls back its writes', () async {
      await expectLater(
        db.transaction(() async {
          raw.execute("INSERT INTO t (v) VALUES ('a')");
          await Future<void>.delayed(Duration.zero);
          throw StateError('boom');
        }),
        throwsA(isA<StateError>()),
      );
      expect(rows(), isEmpty, reason: 'the failed write was not rolled back');
      expect(raw.autocommit, isTrue);
    });

    test('concurrent transactions do not collide on BEGIN/ROLLBACK', () async {
      // Now that the body is awaited, a transaction spans its awaits — so two
      // of them overlapping would collide on BEGIN unless they are serialized.
      final a = db.transaction(() async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        raw.execute("INSERT INTO t (v) VALUES ('a')");
      });
      final b = db.transaction(() async {
        await Future<void>.delayed(Duration.zero);
        raw.execute("INSERT INTO t (v) VALUES ('b')");
      });
      await Future.wait([a, b]);
      expect(rows()..sort(), ['a', 'b']);
      expect(raw.autocommit, isTrue);
    });

    test('a failing transaction does not destroy a concurrent one', () async {
      final ok = db.transaction(() async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        raw.execute("INSERT INTO t (v) VALUES ('keep')");
      });
      final bad = db.transaction(() async {
        await Future<void>.delayed(Duration.zero);
        throw StateError('boom');
      });
      await expectLater(bad, throwsA(isA<StateError>()));
      await ok;
      expect(rows(), ['keep']);
    });

    test('the connection is usable after a rollback', () async {
      await expectLater(
        db.transaction(() async => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );
      await db.transaction(() async {
        raw.execute("INSERT INTO t (v) VALUES ('after')");
      });
      expect(rows(), ['after']);
    });

    test('a body that throws once the transaction is already gone surfaces '
        'the ORIGINAL error', () async {
      // The shape users actually hit. SQLite aborts the transaction itself for
      // a whole class of errors (SQLITE_FULL, SQLITE_IOERR, SQLITE_BUSY...).
      // The bare ROLLBACK then threw "cannot rollback - no transaction is
      // active" and REPLACED the real failure, so the disk-full or IO error
      // the user needed to see never reached them. Executing ROLLBACK inside
      // the body stands in for that abort deterministically.
      await expectLater(
        db.transaction(() {
          raw.execute('ROLLBACK');
          throw StateError('original');
        }),
        throwsA(isA<StateError>()),
      );
      expect(raw.autocommit, isTrue);
    });

    test('returns the body result', () async {
      expect(await db.transaction(() async => 42), 42);
    });
  });
}
