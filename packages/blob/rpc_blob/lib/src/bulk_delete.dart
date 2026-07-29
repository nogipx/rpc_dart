// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'adapters/_index.dart';
import 'models.dart';

/// Runs a bulk delete against a repository in as few round trips as the store
/// allows, and reports one result per requested id.
///
/// Shared by the RPC responder and the in-process repository client so both
/// batch the same way — the in-process one is what a server holding an
/// [IBlobRepository] directly actually calls, and it used to delete one id per
/// round trip like the responder did.
///
/// Version-checked ids stay one at a time: that check is per id, while a batch
/// delete is unconditional. Everything else is grouped by collection.
Future<List<BulkDeleteBlobResult>> applyBulkDelete(
  IBlobRepository storage,
  List<DeleteBlobRequest> items,
) async {
  final results = <BulkDeleteBlobResult>[];
  final batched = <String, List<String>>{};

  for (final item in items) {
    if (item.expectedVersion != null) {
      final deleted = await storage.deleteBlob(
        item.collection,
        item.id,
        expectedVersion: item.expectedVersion,
      );
      results.add(
        BulkDeleteBlobResult(
          collection: item.collection,
          id: item.id,
          deleted: deleted,
        ),
      );
    } else {
      (batched[item.collection] ??= <String>[]).add(item.id);
    }
  }

  for (final entry in batched.entries) {
    final collection = entry.key;
    final ids = entry.value;
    final removed = await storage.deleteMany(collection, ids);
    for (final id in ids) {
      results.add(
        BulkDeleteBlobResult(
          collection: collection,
          id: id,
          deleted: removed.contains(id),
        ),
      );
    }
  }

  return results;
}
