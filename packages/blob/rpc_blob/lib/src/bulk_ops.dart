// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'adapters/_index.dart';
import 'models.dart';

/// Groups a bulk head by collection so each one is a single [IBlobRepository.headMany],
/// and reports one result per requested id.
///
/// Shared by the RPC responder and the in-process repository client, for the
/// same reason [applyBulkDelete] is: the in-process one is what a server
/// holding a repository directly calls, and both used to walk the ids one
/// request at a time.
Future<List<BulkHeadBlobResult>> applyBulkHead(
  IBlobRepository storage,
  List<HeadBlobRequest> items,
) async {
  final byCollection = <String, List<String>>{};
  for (final item in items) {
    (byCollection[item.collection] ??= <String>[]).add(item.id);
  }

  final found = <String, Map<String, BlobDescriptor>>{};
  for (final entry in byCollection.entries) {
    found[entry.key] = await storage.headMany(entry.key, entry.value);
  }

  return [
    for (final item in items)
      BulkHeadBlobResult(
        collection: item.collection,
        id: item.id,
        descriptor: found[item.collection]?[item.id],
      ),
  ];
}

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
///
/// Results come back positionally aligned with [items], the same as
/// [applyBulkHead]. Grouping is how the work is issued, not how it is
/// reported — a caller pairing request with response by index is doing the
/// obvious thing and must not get someone else's verdict.
Future<List<BulkDeleteBlobResult>> applyBulkDelete(
  IBlobRepository storage,
  List<DeleteBlobRequest> items,
) async {
  final verdicts = List<bool?>.filled(items.length, null);
  final batched = <String, List<int>>{};

  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item.expectedVersion != null) {
      verdicts[i] = await storage.deleteBlob(
        item.collection,
        item.id,
        expectedVersion: item.expectedVersion,
      );
    } else {
      (batched[item.collection] ??= <int>[]).add(i);
    }
  }

  for (final entry in batched.entries) {
    final collection = entry.key;
    final positions = entry.value;
    final removed = await storage.deleteMany(collection, [
      for (final position in positions) items[position].id,
    ]);
    for (final position in positions) {
      verdicts[position] = removed.contains(items[position].id);
    }
  }

  return [
    for (var i = 0; i < items.length; i++)
      BulkDeleteBlobResult(
        collection: items[i].collection,
        id: items[i].id,
        deleted: verdicts[i] ?? false,
      ),
  ];
}
