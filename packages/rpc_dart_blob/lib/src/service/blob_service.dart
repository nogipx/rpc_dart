import 'dart:async';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:crypto/crypto.dart';
import 'package:rpc_dart/rpc_dart.dart';

import '../adapters/i_blob_storage_adapter.dart';
import '../models.dart';
import '../rpc/i_blob_service.dart';

/// Default implementation of [IBlobService] backed by [IBlobStorageAdapter].
///
/// Validates chunk ordering/length and streams data through the adapter.
class BlobService implements IBlobService {
  BlobService({
    required IBlobStorageAdapter storage,
    int? maxChunkBytes,
  }) : _storage = storage,
       _maxChunkBytes = maxChunkBytes;

  final IBlobStorageAdapter _storage;
  final int? _maxChunkBytes;

  @override
  Future<PutBlobResponse> putBlob(
    Stream<BlobUploadChunk> chunks, {
    RpcContext? context,
  }) async {
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
    final checksumAlgorithm = first.checksumAlgorithm ?? ChecksumAlgorithm.sha256;

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
        throw StateError('Upload stream ended without last=true on the final chunk.');
      }
      if (declaredLength != null && declaredLength != seen) {
        throw StateError(
          'Declared length $declaredLength does not match received $seen bytes.',
        );
      }
    }

    final writeResult = await _storage.writeBlob(
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
  }

  @override
  Stream<BlobDownloadFrame> getBlob(
    GetBlobRequest request, {
    RpcContext? context,
  }) async* {
    final result = await _storage.readBlob(
      BlobReadRequest(
        collection: request.collection,
        id: request.id,
        rangeStart: request.rangeStart,
        rangeEnd: request.rangeEnd,
      ),
    );
    if (result == null) {
      return;
    }

    final offsetStart = result.rangeStart ?? 0;
    final rangeStart = result.rangeStart;
    final rangeEnd = result.rangeEnd;
    var offset = offsetStart;
    final queue = StreamQueue(result.bytes);
    var firstFrame = true;

    while (await queue.hasNext) {
      final chunk = await queue.next;
      final hasMore = await queue.hasNext;
      yield BlobDownloadFrame(
        offset: offset,
        bytes: chunk,
        descriptor: firstFrame ? result.descriptor : null,
        rangeStart: firstFrame ? rangeStart : null,
        rangeEnd: firstFrame ? rangeEnd : null,
        last: !hasMore,
      );
      firstFrame = false;
      offset += chunk.length;
    }
  }

  @override
  Future<HeadBlobResponse> headBlob(
    HeadBlobRequest request, {
    RpcContext? context,
  }) async {
    final descriptor = await _storage.headBlob(request.collection, request.id);
    return HeadBlobResponse(descriptor: descriptor);
  }

  @override
  Future<DeleteBlobResponse> deleteBlob(
    DeleteBlobRequest request, {
    RpcContext? context,
  }) async {
    final deleted = await _storage.deleteBlob(
      request.collection,
      request.id,
      expectedVersion: request.expectedVersion,
    );
    return DeleteBlobResponse(deleted: deleted);
  }

  @override
  Future<ListBlobsResponse> listBlobs(
    ListBlobsRequest request, {
    RpcContext? context,
  }) {
    return _storage.listBlobs(request);
  }

  @override
  Future<ListCollectionsResponse> listCollections(
    ListCollectionsRequest request, {
    RpcContext? context,
  }) async {
    final collections = await _storage.listCollections();
    return ListCollectionsResponse(collections: collections);
  }

  void _assertChunkSize(BlobUploadChunk chunk) {
    if (_maxChunkBytes != null && chunk.bytes.length > _maxChunkBytes!) {
      throw StateError(
        'Chunk size ${chunk.bytes.length} exceeds maxChunkBytes $_maxChunkBytes',
      );
    }
  }

  void _verifyChunkChecksum(BlobUploadChunk chunk, ChecksumAlgorithm algorithm) {
    if (chunk.chunkChecksum == null) {
      return;
    }
    switch (algorithm) {
      case ChecksumAlgorithm.sha256:
        final digest = sha256.convert(chunk.bytes).toString();
        if (digest.toLowerCase() != chunk.chunkChecksum!.toLowerCase()) {
          throw StateError('Chunk checksum mismatch at offset ${chunk.offset}');
        }
        return;
    }
  }
}
