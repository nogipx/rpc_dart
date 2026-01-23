import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import '../models.dart';
import 'blob_contract.dart';
import 'i_blob_service.dart';

class BlobServiceResponder extends RpcResponderContract
    implements IBlobServiceContract {
  BlobServiceResponder({
    required IBlobService service,
    required RpcDataTransferMode transferMode,
  }) : _service = service,
       super(IBlobServiceContract.name, dataTransferMode: transferMode);

  final IBlobService _service;

  @override
  void setup() {
    addClientStreamMethod<BlobUploadChunk, PutBlobResponse>(
      methodName: IBlobServiceContract.putBlob,
      handler: _handlePut,
      requestCodec: uploadChunkCodec,
      responseCodec: putResponseCodec,
      description: 'Chunked upload of a blob with optimistic versioning',
    );

    addServerStreamMethod<GetBlobRequest, BlobDownloadFrame>(
      methodName: IBlobServiceContract.getBlob,
      handler: _handleGet,
      requestCodec: getRequestCodec,
      responseCodec: downloadFrameCodec,
      description: 'Chunked download of a blob (supports optional ranges)',
    );

    addUnaryMethod<HeadBlobRequest, HeadBlobResponse>(
      methodName: IBlobServiceContract.headBlob,
      handler: _handleHead,
      requestCodec: headRequestCodec,
      responseCodec: headResponseCodec,
      description: 'Return blob metadata without payload',
    );

    addUnaryMethod<DeleteBlobRequest, DeleteBlobResponse>(
      methodName: IBlobServiceContract.deleteBlob,
      handler: _handleDelete,
      requestCodec: deleteRequestCodec,
      responseCodec: deleteResponseCodec,
      description: 'Delete blob by id with optional version check',
    );

    addUnaryMethod<ListBlobsRequest, ListBlobsResponse>(
      methodName: IBlobServiceContract.listBlobs,
      handler: _handleList,
      requestCodec: listRequestCodec,
      responseCodec: listResponseCodec,
      description: 'Paginated list of blob descriptors in a collection',
    );

    addUnaryMethod<ListCollectionsRequest, ListCollectionsResponse>(
      methodName: IBlobServiceContract.listCollections,
      handler: _handleListCollections,
      requestCodec: listCollectionsRequestCodec,
      responseCodec: listCollectionsResponseCodec,
      description: 'List known blob collections',
    );
  }

  Future<PutBlobResponse> _handlePut(
    Stream<BlobUploadChunk> chunks, {
    RpcContext? context,
  }) {
    return _service.putBlob(chunks, context: context);
  }

  Stream<BlobDownloadFrame> _handleGet(
    GetBlobRequest request, {
    RpcContext? context,
  }) {
    return _service.getBlob(request, context: context);
  }

  Future<HeadBlobResponse> _handleHead(
    HeadBlobRequest request, {
    RpcContext? context,
  }) {
    return _service.headBlob(request, context: context);
  }

  Future<DeleteBlobResponse> _handleDelete(
    DeleteBlobRequest request, {
    RpcContext? context,
  }) {
    return _service.deleteBlob(request, context: context);
  }

  Future<ListBlobsResponse> _handleList(
    ListBlobsRequest request, {
    RpcContext? context,
  }) {
    return _service.listBlobs(request, context: context);
  }

  Future<ListCollectionsResponse> _handleListCollections(
    ListCollectionsRequest request, {
    RpcContext? context,
  }) {
    return _service.listCollections(request, context: context);
  }
}
