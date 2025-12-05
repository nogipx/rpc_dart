import 'dart:async';

import 'package:async/async.dart';
import 'package:rpc_dart/rpc_dart.dart';

import '../adapters/i_blob_storage_adapter.dart';
import '../models.dart';
import '../rpc/i_blob_service.dart';

/// Default implementation of [IBlobService] backed by [IBlobStorageAdapter].
///
/// Validates chunk ordering/length and streams data through the adapter.
class BlobService implements IBlobService {
  BlobService({required IBlobStorageAdapter storage}) : _storage = storage;

  final IBlobStorageAdapter _storage;

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

    int seen = 0;
    int expectedOffset = 0;
    int? declaredLength = first.totalLength;
    final metadata = first.metadata;

    Stream<Uint8List> byteStream() async* {
      BlobUploadChunk current = first;
      while (true) {
        if (current.offset != expectedOffset) {
          throw StateError(
            'Non-contiguous upload: got offset ${current.offset}, '
            'expected $expectedOffset.',
          );
        }
        seen += current.bytes.length;
        expectedOffset += current.bytes.length;
        declaredLength ??= current.totalLength;
        yield current.bytes;
        final hasNext = await queue.hasNext;
        if (!hasNext) {
          break;
        }
        current = await queue.next;
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
}
