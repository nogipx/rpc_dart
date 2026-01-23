import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import '../models.dart';
import 'blob_contract.dart';

class BlobServiceCaller extends RpcCallerContract
    implements IBlobServiceContract {
  BlobServiceCaller({
    required RpcCallerEndpoint endpoint,
    required RpcDataTransferMode transferMode,
  }) : super(
         IBlobServiceContract.name,
         endpoint,
         dataTransferMode: transferMode,
       );

  Future<PutBlobResponse> putBlob(
    Stream<BlobUploadChunk> chunks, {
    RpcContext? context,
  }) {
    return callClientStream(
      methodName: IBlobServiceContract.putBlob,
      requests: chunks,
      requestCodec: uploadChunkCodec,
      responseCodec: putResponseCodec,
      context: context,
    );
  }

  Stream<BlobDownloadFrame> getBlob(
    GetBlobRequest request, {
    RpcContext? context,
  }) {
    return callServerStream(
      methodName: IBlobServiceContract.getBlob,
      request: request,
      requestCodec: getRequestCodec,
      responseCodec: downloadFrameCodec,
      context: context,
    );
  }

  Future<HeadBlobResponse> headBlob(
    HeadBlobRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IBlobServiceContract.headBlob,
      request: request,
      requestCodec: headRequestCodec,
      responseCodec: headResponseCodec,
      context: context,
    );
  }

  Future<DeleteBlobResponse> deleteBlob(
    DeleteBlobRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IBlobServiceContract.deleteBlob,
      request: request,
      requestCodec: deleteRequestCodec,
      responseCodec: deleteResponseCodec,
      context: context,
    );
  }

  Future<ListBlobsResponse> listBlobs(
    ListBlobsRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IBlobServiceContract.listBlobs,
      request: request,
      requestCodec: listRequestCodec,
      responseCodec: listResponseCodec,
      context: context,
    );
  }

  Future<ListCollectionsResponse> listCollections({RpcContext? context}) {
    return callUnary(
      methodName: IBlobServiceContract.listCollections,
      request: const ListCollectionsRequest(),
      requestCodec: listCollectionsRequestCodec,
      responseCodec: listCollectionsResponseCodec,
      context: context,
    );
  }
}
