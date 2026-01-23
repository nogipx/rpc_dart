// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'blob_contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class BlobServiceContractNames {
  const BlobServiceContractNames._();
  static const service = 'BlobService';
  static String instance(String suffix) => '\$service\_$suffix';
  static const putBlob = 'putBlob';
  static const getBlob = 'getBlob';
  static const headBlob = 'headBlob';
  static const deleteBlob = 'deleteBlob';
  static const listBlobs = 'listBlobs';
  static const listCollections = 'listCollections';
}

class BlobServiceContractCaller extends RpcCallerContract
    implements IBlobServiceContract {
  BlobServiceContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? BlobServiceContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<PutBlobResponse> putBlob(
    Stream<BlobUploadChunk> requests, {
    RpcContext? context,
  }) {
    return callClientStream<BlobUploadChunk, PutBlobResponse>(
      methodName: BlobServiceContractNames.putBlob,
      requestCodec: const RpcCodec<BlobUploadChunk>.withDecoder(
        BlobUploadChunk.fromJson,
      ),
      responseCodec: const RpcCodec<PutBlobResponse>.withDecoder(
        PutBlobResponse.fromJson,
      ),
      requests: requests,
      context: context,
    );
  }

  @override
  Stream<BlobDownloadFrame> getBlob(
    GetBlobRequest request, {
    RpcContext? context,
  }) {
    return callServerStream<GetBlobRequest, BlobDownloadFrame>(
      methodName: BlobServiceContractNames.getBlob,
      requestCodec: const RpcCodec<GetBlobRequest>.withDecoder(
        GetBlobRequest.fromJson,
      ),
      responseCodec: const RpcCodec<BlobDownloadFrame>.withDecoder(
        BlobDownloadFrame.fromJson,
      ),
      request: request,
      context: context,
    );
  }

  @override
  Future<HeadBlobResponse> headBlob(
    HeadBlobRequest request, {
    RpcContext? context,
  }) {
    return callUnary<HeadBlobRequest, HeadBlobResponse>(
      methodName: BlobServiceContractNames.headBlob,
      requestCodec: const RpcCodec<HeadBlobRequest>.withDecoder(
        HeadBlobRequest.fromJson,
      ),
      responseCodec: const RpcCodec<HeadBlobResponse>.withDecoder(
        HeadBlobResponse.fromJson,
      ),
      request: request,
      context: context,
    );
  }

  @override
  Future<DeleteBlobResponse> deleteBlob(
    DeleteBlobRequest request, {
    RpcContext? context,
  }) {
    return callUnary<DeleteBlobRequest, DeleteBlobResponse>(
      methodName: BlobServiceContractNames.deleteBlob,
      requestCodec: const RpcCodec<DeleteBlobRequest>.withDecoder(
        DeleteBlobRequest.fromJson,
      ),
      responseCodec: const RpcCodec<DeleteBlobResponse>.withDecoder(
        DeleteBlobResponse.fromJson,
      ),
      request: request,
      context: context,
    );
  }

  @override
  Future<ListBlobsResponse> listBlobs(
    ListBlobsRequest request, {
    RpcContext? context,
  }) {
    return callUnary<ListBlobsRequest, ListBlobsResponse>(
      methodName: BlobServiceContractNames.listBlobs,
      requestCodec: const RpcCodec<ListBlobsRequest>.withDecoder(
        ListBlobsRequest.fromJson,
      ),
      responseCodec: const RpcCodec<ListBlobsResponse>.withDecoder(
        ListBlobsResponse.fromJson,
      ),
      request: request,
      context: context,
    );
  }

  @override
  Future<ListCollectionsResponse> listCollections(
    ListCollectionsRequest request, {
    RpcContext? context,
  }) {
    return callUnary<ListCollectionsRequest, ListCollectionsResponse>(
      methodName: BlobServiceContractNames.listCollections,
      requestCodec: const RpcCodec<ListCollectionsRequest>.withDecoder(
        ListCollectionsRequest.fromJson,
      ),
      responseCodec: const RpcCodec<ListCollectionsResponse>.withDecoder(
        ListCollectionsResponse.fromJson,
      ),
      request: request,
      context: context,
    );
  }
}

abstract class BlobServiceContractResponder extends RpcResponderContract
    implements IBlobServiceContract {
  BlobServiceContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? BlobServiceContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addClientStreamMethod<BlobUploadChunk, PutBlobResponse>(
      methodName: BlobServiceContractNames.putBlob,
      handler: putBlob,
      description: 'Chunked upload of a blob with optimistic versioning',
      requestCodec: const RpcCodec<BlobUploadChunk>.withDecoder(
        BlobUploadChunk.fromJson,
      ),
      responseCodec: const RpcCodec<PutBlobResponse>.withDecoder(
        PutBlobResponse.fromJson,
      ),
    );
    addServerStreamMethod<GetBlobRequest, BlobDownloadFrame>(
      methodName: BlobServiceContractNames.getBlob,
      handler: getBlob,
      description: 'Chunked download of a blob (supports optional ranges)',
      requestCodec: const RpcCodec<GetBlobRequest>.withDecoder(
        GetBlobRequest.fromJson,
      ),
      responseCodec: const RpcCodec<BlobDownloadFrame>.withDecoder(
        BlobDownloadFrame.fromJson,
      ),
    );
    addUnaryMethod<HeadBlobRequest, HeadBlobResponse>(
      methodName: BlobServiceContractNames.headBlob,
      handler: headBlob,
      description: 'Return blob metadata without payload',
      requestCodec: const RpcCodec<HeadBlobRequest>.withDecoder(
        HeadBlobRequest.fromJson,
      ),
      responseCodec: const RpcCodec<HeadBlobResponse>.withDecoder(
        HeadBlobResponse.fromJson,
      ),
    );
    addUnaryMethod<DeleteBlobRequest, DeleteBlobResponse>(
      methodName: BlobServiceContractNames.deleteBlob,
      handler: deleteBlob,
      description: 'Delete blob by id with optional version check',
      requestCodec: const RpcCodec<DeleteBlobRequest>.withDecoder(
        DeleteBlobRequest.fromJson,
      ),
      responseCodec: const RpcCodec<DeleteBlobResponse>.withDecoder(
        DeleteBlobResponse.fromJson,
      ),
    );
    addUnaryMethod<ListBlobsRequest, ListBlobsResponse>(
      methodName: BlobServiceContractNames.listBlobs,
      handler: listBlobs,
      description: 'Paginated list of blob descriptors in a collection',
      requestCodec: const RpcCodec<ListBlobsRequest>.withDecoder(
        ListBlobsRequest.fromJson,
      ),
      responseCodec: const RpcCodec<ListBlobsResponse>.withDecoder(
        ListBlobsResponse.fromJson,
      ),
    );
    addUnaryMethod<ListCollectionsRequest, ListCollectionsResponse>(
      methodName: BlobServiceContractNames.listCollections,
      handler: listCollections,
      description: 'List known blob collections',
      requestCodec: const RpcCodec<ListCollectionsRequest>.withDecoder(
        ListCollectionsRequest.fromJson,
      ),
      responseCodec: const RpcCodec<ListCollectionsResponse>.withDecoder(
        ListCollectionsResponse.fromJson,
      ),
    );
  }
}
