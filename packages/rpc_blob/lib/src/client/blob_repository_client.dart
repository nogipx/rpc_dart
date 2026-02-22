// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:async/async.dart';
import 'package:crypto/crypto.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// IBlobClient реализация, работающая напрямую с IBlobRepository без RPC.
class BlobRepositoryClient implements IBlobClient {
  BlobRepositoryClient({
    required IBlobRepository repository,
    bool disposeRepositoryOnClose = false,
    int uploadChunkBytes = defaultChunkBytes,
    int? maxChunkBytes,
    RpcLogger? logger,
    bool attachChunkChecksums = false,
  }) : _repository = repository,
       _disposeRepositoryOnClose = disposeRepositoryOnClose,
       _uploadChunkBytes = uploadChunkBytes,
       _maxChunkBytes = maxChunkBytes,
       _attachChunkChecksums = attachChunkChecksums,
       _log = logger ?? RpcLogger('BlobRepositoryClient') {
    assert(uploadChunkBytes > 0, 'uploadChunkBytes must be positive');
  }

  final IBlobRepository _repository;
  final bool _disposeRepositoryOnClose;
  final int _uploadChunkBytes;
  final int? _maxChunkBytes;
  final bool _attachChunkChecksums;
  final RpcLogger _log;

  static const int defaultChunkBytes = 256 * 1024;

  @override
  Future<PutBlobResponse> putBytes({
    required String collection,
    String? id,
    required Stream<Uint8List> bytes,
    int? length,
    String? contentType,
    String? checksum,
    ChecksumAlgorithm checksumAlgorithm = ChecksumAlgorithm.sha256,
    bool attachChunkChecksums = false,
    Map<String, String> metadata = const {},
    int? expectedVersion,
    RpcContext? context,
  }) {
    return putBlob(
      _chunkUpload(
        collection: collection,
        id: id,
        bytes: bytes,
        length: length,
        contentType: contentType,
        checksum: checksum,
        checksumAlgorithm: checksumAlgorithm,
        attachChunkChecksums: attachChunkChecksums || _attachChunkChecksums,
        metadata: metadata,
        expectedVersion: expectedVersion,
      ),
      context: context,
    );
  }

  @override
  Future<PutBlobResponse> putBlob(
    Stream<BlobUploadChunk> chunks, {
    RpcContext? context,
  }) async {
    _ensureContext(context);
    context?.cancellationToken?.throwIfCancelled();

    final queue = StreamQueue<BlobUploadChunk>(chunks);
    if (!await queue.hasNext) {
      throw StateError('Upload stream is empty');
    }
    final first = await queue.next;
    if (first.offset != 0) {
      throw StateError('First chunk must start at offset 0.');
    }
    _assertChunkSize(first);

    int seen = 0;
    int expectedOffset = 0;
    int? declaredLength = first.totalLength;
    final metadata = first.metadata;
    BlobUploadChunk lastChunk = first;
    final checksumAlgorithm =
        first.checksumAlgorithm ?? ChecksumAlgorithm.sha256;

    Stream<Uint8List> byteStream() async* {
      BlobUploadChunk current = first;
      while (true) {
        if (current.offset != expectedOffset) {
          throw StateError(
            'Non-contiguous upload: got offset ${current.offset}, '
            'expected $expectedOffset.',
          );
        }
        _assertChunkSize(current);
        _verifyChunkChecksum(current, checksumAlgorithm);
        seen += current.bytes.length;
        expectedOffset += current.bytes.length;
        declaredLength ??= current.totalLength;
        lastChunk = current;
        yield current.bytes;
        final hasNext = await queue.hasNext;
        if (!hasNext) {
          break;
        }
        if (current.last) {
          throw StateError('Chunk marked last but stream continues.');
        }
        current = await queue.next;
      }
      if (!lastChunk.last) {
        throw StateError(
          'Upload stream ended without last=true on the final chunk.',
        );
      }
      if (declaredLength != null && declaredLength != seen) {
        throw StateError(
          'Declared length $declaredLength does not match received $seen bytes.',
        );
      }
    }

    try {
      final writeResult = await _repository.writeBlob(
        BlobWriteRequest(
          collection: first.collection,
          id: first.blobId.isEmpty ? null : first.blobId,
          bytes: byteStream(),
          contentType: first.contentType,
          length: declaredLength,
          checksum: first.checksum,
          checksumAlgorithm: checksumAlgorithm,
          metadata: metadata,
          expectedVersion: first.expectedVersion,
        ),
      );
      return PutBlobResponse(descriptor: writeResult.descriptor);
    } catch (error, stackTrace) {
      _log.error(
        'Unhandled repository error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  Stream<BlobDownloadFrame> get(
    String collection,
    String id, {
    int? rangeStart,
    int? rangeEnd,
    RpcContext? context,
  }) async* {
    _ensureContext(context);
    final result = await _repository.readBlob(
      BlobReadRequest(
        collection: collection,
        id: id,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
      ),
    );
    if (result == null) return;

    final offsetStart = result.rangeStart ?? 0;
    final start = result.rangeStart;
    final end = result.rangeEnd;
    var offset = offsetStart;
    final queue = StreamQueue<Uint8List>(result.bytes);
    var firstFrame = true;

    while (await queue.hasNext) {
      final Uint8List chunk = await queue.next;
      final hasMore = await queue.hasNext;
      yield BlobDownloadFrame(
        offset: offset,
        bytes: chunk,
        descriptor: firstFrame ? result.descriptor : null,
        rangeStart: firstFrame ? start : null,
        rangeEnd: firstFrame ? end : null,
        last: !hasMore,
      );
      firstFrame = false;
      offset += chunk.length;
    }
  }

  @override
  Future<HeadBlobResponse> head(
    String collection,
    String id, {
    RpcContext? context,
  }) async {
    _ensureContext(context);
    final descriptor = await _repository.headBlob(collection, id);
    return HeadBlobResponse(descriptor: descriptor);
  }

  @override
  Future<DeleteBlobResponse> delete(
    String collection,
    String id, {
    int? expectedVersion,
    RpcContext? context,
  }) async {
    _ensureContext(context);
    final deleted = await _repository.deleteBlob(
      collection,
      id,
      expectedVersion: expectedVersion,
    );
    return DeleteBlobResponse(deleted: deleted);
  }

  @override
  Future<ListBlobsResponse> list(
    String collection, {
    String? cursor,
    int limit = 50,
    String? prefix,
    bool includeMetadata = false,
    RpcContext? context,
  }) {
    _ensureContext(context);
    return _repository.listBlobs(
      ListBlobsRequest(
        collection: collection,
        cursor: cursor,
        limit: limit,
        prefix: prefix,
        includeMetadata: includeMetadata,
      ),
    );
  }

  @override
  Future<ListCollectionsResponse> listCollections({RpcContext? context}) {
    _ensureContext(context);
    return _repository.listCollections().then(
      (value) => ListCollectionsResponse(collections: value),
    );
  }

  @override
  Future<DeleteCollectionResponse> deleteCollection(
    String collection, {
    RpcContext? context,
  }) async {
    _ensureContext(context);
    final deleted = await _repository.deleteCollection(collection);
    return DeleteCollectionResponse(deleted: deleted);
  }

  @override
  Future<BulkHeadBlobResponse> bulkHeadBlob(
    BulkHeadBlobRequest request, {
    RpcContext? context,
  }) async {
    _ensureContext(context);
    final results = <BulkHeadBlobResult>[];
    for (final item in request.items) {
      final descriptor = await _repository.headBlob(item.collection, item.id);
      results.add(
        BulkHeadBlobResult(
          collection: item.collection,
          id: item.id,
          descriptor: descriptor,
        ),
      );
    }
    return BulkHeadBlobResponse(items: results);
  }

  @override
  Future<BulkDeleteBlobResponse> bulkDeleteBlob(
    BulkDeleteBlobRequest request, {
    RpcContext? context,
  }) async {
    _ensureContext(context);
    final results = <BulkDeleteBlobResult>[];
    for (final item in request.items) {
      final deleted = await _repository.deleteBlob(
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
    }
    return BulkDeleteBlobResponse(items: results);
  }

  @override
  Stream<BulkBlobDownloadFrame> bulkGetBlob(
    BulkGetBlobRequest request, {
    RpcContext? context,
  }) async* {
    _ensureContext(context);
    for (final item in request.items) {
      final result = await _repository.readBlob(
        BlobReadRequest(
          collection: item.collection,
          id: item.id,
          rangeStart: item.rangeStart,
          rangeEnd: item.rangeEnd,
        ),
      );
      if (result == null) continue;
      final offsetStart = result.rangeStart ?? 0;
      final start = result.rangeStart;
      final end = result.rangeEnd;
      var offset = offsetStart;
      final queue = StreamQueue<Uint8List>(result.bytes);
      var firstFrame = true;

      while (await queue.hasNext) {
        final chunk = await queue.next;
        final hasMore = await queue.hasNext;
        yield BulkBlobDownloadFrame(
          collection: item.collection,
          id: item.id,
          frame: BlobDownloadFrame(
            offset: offset,
            bytes: chunk,
            descriptor: firstFrame ? result.descriptor : null,
            rangeStart: firstFrame ? start : null,
            rangeEnd: firstFrame ? end : null,
            last: !hasMore,
          ),
        );
        firstFrame = false;
        offset += chunk.length;
      }
    }
  }

  @override
  Future<BulkPutBlobResponse> bulkPutBlob(
    Stream<BlobUploadChunk> chunks, {
    RpcContext? context,
  }) async {
    _ensureContext(context);
    final queue = StreamQueue<BlobUploadChunk>(chunks);
    final descriptors = <BlobDescriptor>[];
    while (await queue.hasNext) {
      final first = await queue.next;
      if (first.offset != 0) {
        throw StateError('First chunk of a blob must start at offset 0.');
      }
      descriptors.add(await _consumeAndStoreBlob(first, queue));
    }
    return BulkPutBlobResponse(items: descriptors);
  }

  @override
  Future<BulkPutBlobResponse> bulkPutBytes(
    List<BulkPutBlobItem> items, {
    RpcContext? context,
  }) {
    final stream = _concatUploads(items);
    return bulkPutBlob(stream, context: context);
  }

  Stream<BlobUploadChunk> _concatUploads(List<BulkPutBlobItem> items) async* {
    for (final item in items) {
      yield* _chunkUpload(
        collection: item.collection,
        id: item.id,
        bytes: item.bytes,
        length: item.length,
        contentType: item.contentType,
        checksum: item.checksum,
        checksumAlgorithm: item.checksumAlgorithm,
        attachChunkChecksums: item.attachChunkChecksums,
        metadata: item.metadata,
        expectedVersion: item.expectedVersion,
      );
    }
  }

  void _assertChunkSize(BlobUploadChunk chunk) {
    if (_maxChunkBytes != null && chunk.bytes.length > _maxChunkBytes) {
      throw StateError(
        'Chunk size ${chunk.bytes.length} exceeds maxChunkBytes $_maxChunkBytes',
      );
    }
  }

  void _verifyChunkChecksum(
    BlobUploadChunk chunk,
    ChecksumAlgorithm algorithm,
  ) {
    if (chunk.chunkChecksum == null) return;
    switch (algorithm) {
      case ChecksumAlgorithm.sha256:
        final digest = sha256.convert(chunk.bytes).toString();
        if (digest.toLowerCase() != chunk.chunkChecksum!.toLowerCase()) {
          throw StateError('Chunk checksum mismatch at offset ${chunk.offset}');
        }
    }
  }

  Stream<BlobUploadChunk> _chunkUpload({
    required String collection,
    required Stream<Uint8List> bytes,
    String? id,
    int? length,
    String? contentType,
    String? checksum,
    ChecksumAlgorithm checksumAlgorithm = ChecksumAlgorithm.sha256,
    bool attachChunkChecksums = false,
    Map<String, String> metadata = const {},
    int? expectedVersion,
  }) async* {
    final buffer = <int>[];
    var offset = 0;
    var firstChunk = true;
    await for (final chunk in bytes) {
      buffer.addAll(chunk);
      while (buffer.length >= _uploadChunkBytes) {
        final slice = Uint8List.fromList(buffer.sublist(0, _uploadChunkBytes));
        buffer.removeRange(0, _uploadChunkBytes);
        final chunkChecksum = attachChunkChecksums
            ? _hashChunk(slice, checksumAlgorithm)
            : null;
        yield BlobUploadChunk(
          collection: collection,
          blobId: id ?? '',
          offset: offset,
          bytes: slice,
          totalLength: length,
          contentType: firstChunk ? contentType : null,
          checksum: firstChunk ? checksum : null,
          checksumAlgorithm: firstChunk ? checksumAlgorithm : null,
          chunkChecksum: chunkChecksum,
          metadata: firstChunk ? metadata : const {},
          expectedVersion: firstChunk ? expectedVersion : null,
          last: false,
        );
        offset += slice.length;
        firstChunk = false;
      }
    }
    if (buffer.isNotEmpty || firstChunk) {
      final chunkChecksum = attachChunkChecksums
          ? _hashChunk(Uint8List.fromList(buffer), checksumAlgorithm)
          : null;
      yield BlobUploadChunk(
        collection: collection,
        blobId: id ?? '',
        offset: offset,
        bytes: Uint8List.fromList(buffer),
        totalLength: length,
        contentType: firstChunk ? contentType : null,
        checksum: firstChunk ? checksum : null,
        checksumAlgorithm: firstChunk ? checksumAlgorithm : null,
        chunkChecksum: chunkChecksum,
        metadata: firstChunk ? metadata : const {},
        expectedVersion: firstChunk ? expectedVersion : null,
        last: true,
      );
    }
  }

  String? _hashChunk(Uint8List data, ChecksumAlgorithm algorithm) {
    if (data.isEmpty) return null;
    switch (algorithm) {
      case ChecksumAlgorithm.sha256:
        return sha256.convert(data).toString();
    }
  }

  Future<BlobDescriptor> _consumeAndStoreBlob(
    BlobUploadChunk first,
    StreamQueue<BlobUploadChunk> queue,
  ) async {
    _assertChunkSize(first);
    int seen = 0;
    int expectedOffset = 0;
    int? declaredLength = first.totalLength;
    BlobUploadChunk current = first;
    final metadata = first.metadata;
    final checksumAlgorithm =
        first.checksumAlgorithm ?? ChecksumAlgorithm.sha256;
    final payloadBuilder = BytesBuilder(copy: false);
    final chunks = <Uint8List>[];
    BlobUploadChunk lastChunk = first;

    while (true) {
      if (current.offset != expectedOffset) {
        throw StateError(
          'Non-contiguous upload: got offset ${current.offset}, '
          'expected $expectedOffset.',
        );
      }
      _assertChunkSize(current);
      _verifyChunkChecksum(current, checksumAlgorithm);
      seen += current.bytes.length;
      expectedOffset += current.bytes.length;
      declaredLength ??= current.totalLength;
      lastChunk = current;
      payloadBuilder.add(current.bytes);
      chunks.add(current.bytes);

      if (current.last) {
        break;
      }
      if (!await queue.hasNext) {
        throw StateError(
          'Upload stream ended without last=true on the final chunk.',
        );
      }
      current = await queue.next;
    }

    if (declaredLength != null && declaredLength != seen) {
      throw StateError(
        'Declared length $declaredLength does not match received $seen bytes.',
      );
    }

    final writeResult = await _repository.writeBlob(
      BlobWriteRequest(
        collection: first.collection,
        id: first.blobId.isEmpty ? null : first.blobId,
        bytes: Stream.fromIterable(chunks),
        contentType: first.contentType,
        length: declaredLength,
        checksum: first.checksum,
        checksumAlgorithm: checksumAlgorithm,
        metadata: metadata,
        expectedVersion: first.expectedVersion,
      ),
    );

    final computedHex = sha256.convert(payloadBuilder.toBytes()).toString();
    final shouldVerify = first.checksum != null || _looksLikeHash(first.blobId);
    if (shouldVerify) {
      final expectedHex = (first.checksum ?? first.blobId).toLowerCase();
      if (computedHex.toLowerCase() != expectedHex) {
        throw StateError(
          'Checksum mismatch for blob ${first.blobId}: expected $expectedHex got $computedHex',
        );
      }
    }

    return writeResult.descriptor;
  }

  void _ensureContext(RpcContext? context) {
    if (context?.isExpired ?? false) {
      final deadline = context!.deadline!;
      final timeout = deadline.difference(DateTime.now());
      throw RpcDeadlineExceededException(deadline, timeout);
    }
  }

  @override
  Future<void> close() async {
    if (_disposeRepositoryOnClose) {
      await _repository.dispose();
    }
  }

  bool _looksLikeHash(String value) =>
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value);
}
