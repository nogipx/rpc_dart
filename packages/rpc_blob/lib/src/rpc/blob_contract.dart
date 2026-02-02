import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import '../models.dart';

part 'blob_contract.g.dart';

/// RPC контракт блоб-сервиса (стримовый upload/download + метаданные).
@RpcService(
  name: 'BlobService',
  transferMode: RpcDataTransferMode.codec,
  description: 'Binary/blob storage RPC contract (streamed upload/download)',
)
abstract interface class IBlobServiceContract implements IRpcContract {
  @RpcMethod.clientStream(
    name: 'putBlob',
    description: 'Chunked upload of a blob with optimistic versioning',
  )
  Future<PutBlobResponse> putBlob(
    Stream<BlobUploadChunk> request, {
    RpcContext? context,
  });

  @RpcMethod.serverStream(
    name: 'getBlob',
    description: 'Chunked download of a blob (supports optional ranges)',
  )
  Stream<BlobDownloadFrame> getBlob(
    GetBlobRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'headBlob',
    description: 'Return blob metadata without payload',
  )
  Future<HeadBlobResponse> headBlob(
    HeadBlobRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'deleteBlob',
    description: 'Delete blob by id with optional version check',
  )
  Future<DeleteBlobResponse> deleteBlob(
    DeleteBlobRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'listBlobs',
    description: 'Paginated list of blob descriptors in a collection',
  )
  Future<ListBlobsResponse> listBlobs(
    ListBlobsRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'listCollections',
    description: 'List known blob collections',
  )
  Future<ListCollectionsResponse> listCollections(
    ListCollectionsRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'bulkHeadBlob',
    description: 'Fetch metadata for multiple blobs',
  )
  Future<BulkHeadBlobResponse> bulkHeadBlob(
    BulkHeadBlobRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'bulkDeleteBlob',
    description: 'Delete multiple blobs (per item best-effort)',
  )
  Future<BulkDeleteBlobResponse> bulkDeleteBlob(
    BulkDeleteBlobRequest request, {
    RpcContext? context,
  });

  @RpcMethod.serverStream(
    name: 'bulkGetBlob',
    description: 'Download multiple blobs sequentially with identification',
  )
  Stream<BulkBlobDownloadFrame> bulkGetBlob(
    BulkGetBlobRequest request, {
    RpcContext? context,
  });

  @RpcMethod.clientStream(
    name: 'bulkPutBlob',
    description: 'Upload multiple blobs sequentially in one stream',
  )
  Future<BulkPutBlobResponse> bulkPutBlob(
    Stream<BlobUploadChunk> request, {
    RpcContext? context,
  });
}
