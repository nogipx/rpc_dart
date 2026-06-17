// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../models.dart';
import 'i_blob_storage_adapter.dart';

typedef Clock = DateTime Function();

class _BlobEntry {
  _BlobEntry({required this.descriptor, required this.payload});

  final BlobDescriptor descriptor;
  final Uint8List payload;
}

/// In-memory implementation of [IBlobRepository].
///
/// Stores blobs in memory using nested maps. Suitable for testing and
/// development scenarios where persistence is not required.
class InMemoryBlobRepository implements IBlobRepository {
  InMemoryBlobRepository({
    int? maxBlobBytes,
    int readChunkBytes = _defaultReadChunkBytes,
    Clock? clock,
  }) : assert(readChunkBytes > 0, 'readChunkBytes must be positive'),
       _maxBlobBytes = maxBlobBytes,
       _readChunkBytes = readChunkBytes,
       _clock = clock ?? DateTime.now;

  final int? _maxBlobBytes;
  final int _readChunkBytes;
  final Clock _clock;
  bool _closed = false;

  final Map<String, Map<String, _BlobEntry>> _storage = {};

  static const int _defaultReadChunkBytes = 256 * 1024;

  @override
  Future<BlobDescriptor?> headBlob(String collection, String id) async {
    _ensureOpen();
    final collectionMap = _storage[collection];
    if (collectionMap == null) {
      return null;
    }
    final entry = collectionMap[id];
    return entry?.descriptor;
  }

  @override
  Future<BlobReadResult?> readBlob(BlobReadRequest request) async {
    _ensureOpen();
    final collectionMap = _storage[request.collection];
    if (collectionMap == null) {
      return null;
    }
    final entry = collectionMap[request.id];
    if (entry == null) {
      return null;
    }

    Uint8List payload;
    int? rangeStart;
    int? rangeEnd;

    if (request.rangeStart != null || request.rangeEnd != null) {
      final start = request.rangeStart ?? 0;
      final end = request.rangeEnd;
      if (start < 0 || (end != null && end <= start)) {
        return null;
      }
      rangeStart = start;
      rangeEnd = end;

      final actualEnd = end != null
          ? min(end, entry.payload.length)
          : entry.payload.length;
      if (start >= entry.payload.length) {
        payload = Uint8List(0);
      } else {
        payload = Uint8List.sublistView(entry.payload, start, actualEnd);
      }
    } else {
      payload = entry.payload;
    }

    return BlobReadResult(
      descriptor: entry.descriptor,
      bytes: _chunkedPayload(payload),
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
    );
  }

  @override
  Future<BlobWriteResult> writeBlob(BlobWriteRequest request) async {
    _ensureOpen();
    final id = request.id ?? _generateId();
    final payload = await _collectBytes(
      request.bytes,
      declaredLength: request.length,
    );

    if (_maxBlobBytes != null && payload.length > _maxBlobBytes) {
      throw StateError(
        'Blob too large: ${payload.length} bytes exceeds $_maxBlobBytes',
      );
    }

    if (request.checksum != null) {
      _verifyChecksum(
        payload,
        request.checksum!,
        algorithm: request.checksumAlgorithm,
      );
    }

    final now = _clock();
    final collectionMap = _storage.putIfAbsent(request.collection, () => {});
    final existing = collectionMap[id];

    DateTime createdAt;
    int version;

    if (existing == null) {
      if (request.expectedVersion != null) {
        throw StateError(
          'Expected version ${request.expectedVersion} for $id but blob is missing.',
        );
      }
      createdAt = now;
      version = 1;
    } else {
      final currentVersion = existing.descriptor.version;
      if (request.expectedVersion != null &&
          currentVersion != request.expectedVersion) {
        throw StateError(
          'Expected version ${request.expectedVersion} for $id, '
          'found $currentVersion.',
        );
      }

      final existingChecksum = existing.descriptor.checksum;
      if (existingChecksum != null &&
          request.checksum != null &&
          existingChecksum != request.checksum) {
        throw StateError(
          'Checksum mismatch for existing blob $id: stored=$existingChecksum new=${request.checksum}',
        );
      }

      if (request.checksum != null &&
          request.checksum == existingChecksum &&
          existing.descriptor.length == payload.length &&
          request.contentType == existing.descriptor.contentType) {
        return BlobWriteResult(descriptor: existing.descriptor);
      }

      createdAt = existing.descriptor.createdAt;
      version = currentVersion + 1;
    }

    final descriptor = BlobDescriptor(
      id: id,
      collection: request.collection,
      length: payload.length,
      version: version,
      createdAt: createdAt,
      updatedAt: now,
      contentType: request.contentType,
      checksum: request.checksum,
      metadata: Map<String, String>.from(request.metadata),
    );

    collectionMap[id] = _BlobEntry(descriptor: descriptor, payload: payload);

    return BlobWriteResult(descriptor: descriptor);
  }

  @override
  Future<bool> deleteBlob(
    String collection,
    String id, {
    int? expectedVersion,
  }) async {
    _ensureOpen();
    final collectionMap = _storage[collection];
    if (collectionMap == null) {
      return false;
    }

    final existing = collectionMap[id];
    if (existing == null) {
      if (expectedVersion != null) {
        throw StateError(
          'Expected version $expectedVersion for $id but blob is missing.',
        );
      }
      return false;
    }

    if (expectedVersion != null &&
        existing.descriptor.version != expectedVersion) {
      throw StateError(
        'Expected version $expectedVersion for $id but no rows deleted.',
      );
    }

    collectionMap.remove(id);
    return true;
  }

  @override
  Future<ListBlobsResponse> listBlobs(ListBlobsRequest request) async {
    _ensureOpen();
    final collectionMap = _storage[request.collection];
    if (collectionMap == null) {
      return const ListBlobsResponse(items: []);
    }

    String? cursorId;
    DateTime? cursorUpdated;
    if (request.cursor != null) {
      try {
        final decoded = utf8.decode(base64Decode(request.cursor!));
        final parts = decoded.split('|');
        if (parts.length == 2) {
          cursorUpdated = DateTime.tryParse(parts[0]);
          cursorId = parts[1];
        }
      } catch (_) {
        // Ignore malformed cursor.
      }
    }

    var entries = collectionMap.entries.toList();

    if (request.prefix != null && request.prefix!.isNotEmpty) {
      entries = entries
          .where((e) => e.key.startsWith(request.prefix!))
          .toList();
    }

    entries.sort((a, b) {
      final dateCompare = b.value.descriptor.updatedAt.compareTo(
        a.value.descriptor.updatedAt,
      );
      if (dateCompare != 0) return dateCompare;
      return b.key.compareTo(a.key);
    });

    if (cursorUpdated != null && cursorId != null) {
      final cursorIndex = entries.indexWhere((e) {
        final desc = e.value.descriptor;
        if (desc.updatedAt.isBefore(cursorUpdated!)) {
          return true;
        }
        if (desc.updatedAt == cursorUpdated &&
            e.key.compareTo(cursorId!) <= 0) {
          return true;
        }
        return false;
      });

      if (cursorIndex != -1) {
        entries = entries.sublist(cursorIndex);
      }
    }

    final hasMore = entries.length > request.limit;
    final items = entries
        .take(request.limit)
        .map((e) {
          final desc = e.value.descriptor;
          if (request.includeMetadata) {
            return desc;
          }
          return BlobDescriptor(
            id: desc.id,
            collection: desc.collection,
            length: desc.length,
            version: desc.version,
            createdAt: desc.createdAt,
            updatedAt: desc.updatedAt,
            contentType: desc.contentType,
            checksum: desc.checksum,
            metadata: const {},
          );
        })
        .toList(growable: false);

    String? nextCursor;
    if (hasMore) {
      final lastEntry = entries[request.limit];
      final desc = lastEntry.value.descriptor;
      nextCursor = base64Encode(
        utf8.encode('${desc.updatedAt.toIso8601String()}|${lastEntry.key}'),
      );
    }

    return ListBlobsResponse(items: items, nextCursor: nextCursor);
  }

  @override
  Future<List<String>> listCollections() async {
    _ensureOpen();
    final collections = _storage.entries
        .where((e) => e.value.isNotEmpty)
        .map((e) => e.key)
        .toList(growable: false);
    collections.sort();
    return collections;
  }

  @override
  Future<bool> deleteCollection(String collection) async {
    _ensureOpen();
    final existed = _storage.containsKey(collection);
    _storage.remove(collection);
    return existed;
  }

  @override
  Future<int> collectionSize(String collection) async {
    _ensureOpen();
    final entries = _storage[collection];
    if (entries == null) return 0;
    return entries.values.fold<int>(0, (sum, e) => sum + e.descriptor.length);
  }

  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _storage.clear();
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('Repository is closed');
    }
  }

  Future<Uint8List> _collectBytes(
    Stream<Uint8List> source, {
    int? declaredLength,
  }) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in source) {
      builder.add(chunk);
      if (_maxBlobBytes != null && builder.length > _maxBlobBytes) {
        throw StateError(
          'Blob too large: ${builder.length} bytes exceeds $_maxBlobBytes',
        );
      }
    }
    final bytes = builder.takeBytes();
    if (declaredLength != null && declaredLength != bytes.length) {
      throw StateError(
        'Declared length $declaredLength does not match actual ${bytes.length}',
      );
    }
    return bytes;
  }

  void _verifyChecksum(
    Uint8List payload,
    String checksumHex, {
    ChecksumAlgorithm? algorithm,
  }) {
    final algo = algorithm ?? ChecksumAlgorithm.sha256;
    final digest = switch (algo) {
      ChecksumAlgorithm.sha256 => sha256.convert(payload).toString(),
    };
    if (digest.toLowerCase() != checksumHex.toLowerCase()) {
      throw StateError('Checksum mismatch for blob payload');
    }
  }

  String _generateId() {
    final buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      buffer.write(_rng.nextInt(16).toRadixString(16));
    }
    return buffer.toString();
  }

  Stream<Uint8List> _chunkedPayload(Uint8List payload) async* {
    if (payload.isEmpty) {
      yield payload;
      return;
    }
    final chunkSize = max(1, _readChunkBytes);
    for (var i = 0; i < payload.length; i += chunkSize) {
      final end = min(payload.length, i + chunkSize);
      yield Uint8List.sublistView(payload, i, end);
    }
  }
}

/// `Random.secure()` недоступен в некоторых web-рантаймах (например, node без
/// корректного байндинга globalThis в dart2js), поэтому деградируем до обычного
/// `Random()`. Идентификаторы блобов не являются секретами, так что это
/// безопасный и кросс-платформенный компромисс.
final Random _rng = () {
  try {
    return Random.secure();
  } catch (_) {
    return Random();
  }
}();
