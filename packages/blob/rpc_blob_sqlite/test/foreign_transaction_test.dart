// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_blob_sqlite/rpc_blob_sqlite.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// A connection has one transaction slot, and this adapter is rarely its only
// user: a host may share one SQLite handle between a data layer that holds
// transactions across awaits and this blob store, which does not.
//
// So the adapter's BEGIN can fail because someone else holds the slot. That is
// survivable. What would not be is the cleanup that follows: it asks the
// CONNECTION whether a transaction is open, not whether IT opened one, and a
// ROLLBACK there would discard the other party's uncommitted work with nothing
// raised on the side that lost it.
//
// It does not, and the reason is one line of placement: BEGIN sits OUTSIDE the
// try, so when BEGIN is what failed the catch never runs. Moving it inside —
// which reads like a tidy-up — turns a survivable error into silent data loss
// for whoever owns the transaction. These tests exist to make that move fail.
// ---------------------------------------------------------------------------

void main() {
  late sqlite.Database db;
  late SqliteBlobRepository blobs;

  setUp(() {
    db = sqlite.sqlite3.openInMemory();
    blobs = SqliteBlobRepository.db(db, enableWal: false);
    db.execute('CREATE TABLE outsider (id INTEGER PRIMARY KEY, v TEXT)');
  });

  tearDown(() => db.dispose());

  Future<void> write(String id) => blobs.writeBlob(
    BlobWriteRequest(
      collection: 'c',
      id: id,
      bytes: Stream.value(Uint8List.fromList([1, 2, 3])),
      length: 3,
    ),
  );

  test(
    'a failed BEGIN does not roll back the transaction already open',
    () async {
      // Someone else owns the slot and has uncommitted work in it.
      db.execute('BEGIN');
      db.execute("INSERT INTO outsider (v) VALUES ('theirs')");

      // The adapter cannot start its own transaction. That it fails is fine.
      await expectLater(write('a'), throwsA(isA<Object>()));

      // What must survive is the other party's work.
      final rows = db.select('SELECT v FROM outsider');
      expect(
        rows.map((r) => r['v']),
        contains('theirs'),
        reason:
            'the row was inserted by whoever owns the transaction; this adapter '
            'never opened one and has no business ending it',
      );

      // And the slot is still theirs to commit.
      expect(db.autocommit, isFalse);
      db.execute('COMMIT');
      expect(db.select('SELECT v FROM outsider').length, 1);
    },
  );

  test('its own failed transaction is still cleaned up', () async {
    // The guard must not turn into "never roll back": a failure inside the
    // adapter's OWN transaction has to leave the connection usable.
    await write('first');
    await expectLater(
      blobs.writeBlob(
        BlobWriteRequest(
          collection: 'c',
          id: 'first',
          bytes: Stream.value(Uint8List.fromList([9])),
          length: 3, // lies: declared 3, sends 1
        ),
      ),
      throwsA(isA<Object>()),
    );

    expect(
      db.autocommit,
      isTrue,
      reason:
          'a transaction this adapter opened and failed must not be left '
          'open, or every later write fails on BEGIN',
    );
    await write('second');
  });
}
