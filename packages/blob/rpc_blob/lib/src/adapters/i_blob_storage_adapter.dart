// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import '../models.dart';

/// Storage adapter for blobs (files, images, binaries).
/// Implementations should stream data and avoid buffering whole payloads.
abstract interface class IBlobRepository {
  /// Fetch blob metadata; return null when missing.
  Future<BlobDescriptor?> headBlob(String collection, String id);

  /// Stream blob bytes; return null when missing.
  Future<BlobReadResult?> readBlob(BlobReadRequest request);

  /// Write blob from a byte stream; should enforce optimistic versioning when
  /// [expectedVersion] is provided in the request.
  Future<BlobWriteResult> writeBlob(BlobWriteRequest request);

  /// Delete a blob; returns `true` when something was removed.
  Future<bool> deleteBlob(String collection, String id, {int? expectedVersion});

  /// List blob descriptors with pagination.
  Future<ListBlobsResponse> listBlobs(ListBlobsRequest request);

  /// List known collections in the backing store.
  Future<List<String>> listCollections();

  /// Drop an entire collection (namespace) and all blobs within it.
  ///
  /// Returns true if the collection existed and was removed.
  Future<bool> deleteCollection(String collection);

  /// Returns the total size in bytes of all blobs in the collection.
  /// Returns 0 if the collection does not exist.
  Future<int> collectionSize(String collection);

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
