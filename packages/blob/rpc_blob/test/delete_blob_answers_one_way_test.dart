// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `IBlobStorageAdapter.deleteBlob(collection, id, expectedVersion:)` promised
// only "returns `true` when something was removed" and said nothing about a
// version that does not match or a blob that is not there. Four adapters, read
// against the tree in round 478:
//
//   input: blob MISSING, expectedVersion != null
//     in_memory   threw ABORTED
//     sqlite      threw ABORTED
//     webdav      returned false
//     minio       returned false
//
//   input: blob EXISTS at another version
//     all four    threw ABORTED        <- already unified by round 416
//
// So only the missing case diverged, and 2-2. `false` is the answer, because it
// is the one the contract sentence already gave and the one that cannot break a
// working caller: nothing starts throwing that did not throw before.
//
// This file pins the in-memory adapter, which is the reference implementation.
// The other three have the same pair in their own suites, which is the only way
// to test them — webdav needs a server and minio needs a live S3.

import 'dart:typed_data';

import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_dart/rpc_dart.dart' show RpcStatus, RpcStatusException;
import 'package:test/test.dart';

Future<void> _write(
  InMemoryBlobRepository repo,
  String collection,
  String id,
) async {
  await repo.writeBlob(
    BlobWriteRequest(
      collection: collection,
      id: id,
      bytes: Stream.value(Uint8List.fromList([1, 2, 3])),
    ),
  );
}

void main() {
  late InMemoryBlobRepository repo;

  setUp(() => repo = InMemoryBlobRepository());

  // WITNESS. This adapter threw ABORTED here, where webdav and minio returned
  // false for the same call.
  test('a MISSING blob with an expectedVersion is false, not a throw', () async {
    expect(
      await repo.deleteBlob('docs', 'absent', expectedVersion: 1),
      isFalse,
      reason:
          'nothing was removed, which is what the contract sentence says — and '
          'an application swapping backends got a throw from this one and a '
          'false from the other two',
    );
  });

  // GUARD on the half that was ALREADY unified: a version that exists and does
  // not match is the caller's precondition failing, and it must still say so.
  test(
    'GUARD: an existing blob at another version still throws ABORTED',
    () async {
      await _write(repo, 'docs', 'd1');

      await expectLater(
        repo.deleteBlob('docs', 'd1', expectedVersion: 99),
        throwsA(
          isA<RpcStatusException>()
              .having((e) => e.statusCode, 'statusCode', RpcStatus.aborted)
              .having((e) => e.message, 'message', contains('99')),
        ),
      );

      // And the blob is still there: a refused delete removes nothing.
      expect(await repo.headBlob('docs', 'd1'), isNotNull);
    },
  );

  // GUARD: the ordinary conditional delete still works, or "returns false" would
  // be satisfied by an adapter that deleted nothing at all.
  test('GUARD: a matching expectedVersion still deletes', () async {
    await _write(repo, 'docs', 'd2');
    final head = await repo.headBlob('docs', 'd2');

    expect(
      await repo.deleteBlob('docs', 'd2', expectedVersion: head!.version),
      isTrue,
    );
    expect(await repo.headBlob('docs', 'd2'), isNull);
  });

  // GUARD: without expectedVersion nothing changed — a missing blob was always
  // false, and this must not have become a throw.
  test(
    'GUARD: an unconditional delete of a missing blob is still false',
    () async {
      expect(await repo.deleteBlob('docs', 'absent'), isFalse);
    },
  );
}
