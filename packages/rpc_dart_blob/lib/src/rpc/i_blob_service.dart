import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import '../models.dart';

/// Application-facing service contract to implement on the server side.
abstract interface class IBlobService {
  Future<PutBlobResponse> putBlob(
    Stream<BlobUploadChunk> chunks, {
    RpcContext? context,
  });

  Stream<BlobDownloadFrame> getBlob(
    GetBlobRequest request, {
    RpcContext? context,
  });

  Future<HeadBlobResponse> headBlob(
    HeadBlobRequest request, {
    RpcContext? context,
  });

  Future<DeleteBlobResponse> deleteBlob(
    DeleteBlobRequest request, {
    RpcContext? context,
  });

  Future<ListBlobsResponse> listBlobs(
    ListBlobsRequest request, {
    RpcContext? context,
  });

  Future<ListCollectionsResponse> listCollections(
    ListCollectionsRequest request, {
    RpcContext? context,
  });
}
