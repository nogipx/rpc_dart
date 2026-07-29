// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import '../models.dart';

/// Storage adapter for blobs (files, images, binaries).
/// Implementations should stream data and avoid buffering whole payloads.
abstract interface class IBlobRepository {
  /// Create the collection if it does not exist yet.
  ///
  /// Idempotent, and meant to be called once when a collection is first set
  /// up. Without it a store has to discover the collection's absence on every
  /// write — for S3 that was a bucket check per object, to learn something
  /// that is true for all but the first write.
  Future<void> ensureCollection(String collection);

  /// Fetch blob metadata; return null when missing.
  Future<BlobDescriptor?> headBlob(String collection, String id);

  /// Stream blob bytes; return null when missing.
  Future<BlobReadResult?> readBlob(BlobReadRequest request);

  /// Write blob from a byte stream; should enforce optimistic versioning when
  /// [expectedVersion] is provided in the request.
  Future<BlobWriteResult> writeBlob(BlobWriteRequest request);

  /// Delete a blob; returns `true` when something was removed.
  Future<bool> deleteBlob(String collection, String id, {int? expectedVersion});

  /// Remove several blobs from one collection in as few round trips as the
  /// backend allows.
  ///
  /// Returns the ids the backend confirmed gone. Stores that cannot report
  /// per-key existence in a batch — S3's `DeleteObjects` among them — return
  /// the whole request: the ids are gone either way, the answer is just less
  /// specific about which ones had been there.
  ///
  /// Deliberately has no `expectedVersion`: a batch delete is unconditional.
  /// Callers that need a version check delete one id at a time via
  /// [deleteBlob].
  Future<Set<String>> deleteMany(String collection, List<String> ids);

  /// List blob descriptors with pagination.
  Future<ListBlobsResponse> listBlobs(ListBlobsRequest request);

  /// List known collections in the backing store.
  Future<List<String>> listCollections();

  /// Drop an entire collection (namespace) and all blobs within it.
  ///
  /// Returns true if the collection existed and was removed.
  Future<bool> deleteCollection(String collection);

  /// Total size in bytes of every blob in the collection, or null when this
  /// backend cannot answer without walking the whole store.
  ///
  /// A maintenance and reconciliation operation, not something to call on a
  /// request path. The nullable result is the point: the cost varies from a
  /// single indexed query to a full enumeration depending on the backend, and
  /// a plain `int` hid that well enough to get this called per upload. A
  /// caller that needs a number regardless sums [listBlobs] itself, and then
  /// the cost is written where it is paid.
  ///
  /// 0 means an empty (or absent) collection; null means "ask another way".
  Future<int?> collectionSize(String collection);

  Future<void> dispose();
}

/// Request to read a blob's bytes.
class BlobReadRequest {
  BlobReadRequest({
    required this.collection,
    required this.id,
    this.rangeStart,
    this.rangeEnd,
  });

  final String collection;
  final String id;

  /// Optional inclusive byte range start.
  final int? rangeStart;

  /// Optional exclusive byte range end.
  final int? rangeEnd;
}

/// Request to write a blob from a stream of bytes.
class BlobWriteRequest {
  BlobWriteRequest({
    required this.collection,
    required this.bytes,
    this.id,
    this.contentType,
    this.length,
    this.checksum,
    this.checksumAlgorithm,
    this.metadata = const {},
    this.expectedVersion,
  });

  final String collection;
  final String? id;
  final Stream<Uint8List> bytes;
  final String? contentType;
  final int? length;
  final String? checksum;
  final ChecksumAlgorithm? checksumAlgorithm;
  final Map<String, String> metadata;
  final int? expectedVersion;
}

/// Result after writing a blob.
class BlobWriteResult {
  BlobWriteResult({required this.descriptor});

  final BlobDescriptor descriptor;
}

/// Blob read result: descriptor + byte stream.
class BlobReadResult {
  BlobReadResult({
    required this.descriptor,
    required this.bytes,
    this.rangeStart,
    this.rangeEnd,
  });

  final BlobDescriptor descriptor;
  final Stream<Uint8List> bytes;
  final int? rangeStart;
  final int? rangeEnd;
}
