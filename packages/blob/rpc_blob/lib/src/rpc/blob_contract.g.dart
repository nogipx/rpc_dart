// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'blob_contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class BlobServiceContractNames {
  const BlobServiceContractNames._();
  static const service = 'BlobService';
  static String instance(String suffix) => '$service\_$suffix';
  static const putBlob = 'putBlob';
  static const getBlob = 'getBlob';
  static const headBlob = 'headBlob';
  static const deleteBlob = 'deleteBlob';
  static const listBlobs = 'listBlobs';
  static const listCollections = 'listCollections';
  static const deleteCollection = 'deleteCollection';
  static const bulkHeadBlob = 'bulkHeadBlob';
  static const bulkDeleteBlob = 'bulkDeleteBlob';
  static const bulkGetBlob = 'bulkGetBlob';
  static const bulkPutBlob = 'bulkPutBlob';
  static const collectionSize = 'collectionSize';
}

class BlobServiceContractCodecs {
  const BlobServiceContractCodecs._();
  static const codecBlobDownloadFrame = RpcCodec<BlobDownloadFrame>.withDecoder(
    BlobDownloadFrame.fromJson,
  );
  static const codecBlobUploadChunk = RpcCodec<BlobUploadChunk>.withDecoder(
    BlobUploadChunk.fromJson,
  );
  static const codecBulkBlobDownloadFrame =
      RpcCodec<BulkBlobDownloadFrame>.withDecoder(
        BulkBlobDownloadFrame.fromJson,
      );
  static const codecBulkDeleteBlobRequest =
      RpcCodec<BulkDeleteBlobRequest>.withDecoder(
        BulkDeleteBlobRequest.fromJson,
      );
  static const codecBulkDeleteBlobResponse =
      RpcCodec<BulkDeleteBlobResponse>.withDecoder(
        BulkDeleteBlobResponse.fromJson,
      );
  static const codecBulkGetBlobRequest =
      RpcCodec<BulkGetBlobRequest>.withDecoder(BulkGetBlobRequest.fromJson);
  static const codecBulkHeadBlobRequest =
      RpcCodec<BulkHeadBlobRequest>.withDecoder(BulkHeadBlobRequest.fromJson);
  static const codecBulkHeadBlobResponse =
      RpcCodec<BulkHeadBlobResponse>.withDecoder(BulkHeadBlobResponse.fromJson);
  static const codecBulkPutBlobResponse =
      RpcCodec<BulkPutBlobResponse>.withDecoder(BulkPutBlobResponse.fromJson);
  static const codecCollectionSizeRequest =
      RpcCodec<CollectionSizeRequest>.withDecoder(
        CollectionSizeRequest.fromJson,
      );
  static const codecCollectionSizeResponse =
      RpcCodec<CollectionSizeResponse>.withDecoder(
        CollectionSizeResponse.fromJson,
      );
  static const codecDeleteBlobRequest = RpcCodec<DeleteBlobRequest>.withDecoder(
    DeleteBlobRequest.fromJson,
  );
  static const codecDeleteBlobResponse =
      RpcCodec<DeleteBlobResponse>.withDecoder(DeleteBlobResponse.fromJson);
  static const codecDeleteCollectionRequest =
      RpcCodec<DeleteCollectionRequest>.withDecoder(
        DeleteCollectionRequest.fromJson,
      );
  static const codecDeleteCollectionResponse =
      RpcCodec<DeleteCollectionResponse>.withDecoder(
        DeleteCollectionResponse.fromJson,
      );
  static const codecGetBlobRequest = RpcCodec<GetBlobRequest>.withDecoder(
    GetBlobRequest.fromJson,
  );
  static const codecHeadBlobRequest = RpcCodec<HeadBlobRequest>.withDecoder(
    HeadBlobRequest.fromJson,
  );
  static const codecHeadBlobResponse = RpcCodec<HeadBlobResponse>.withDecoder(
    HeadBlobResponse.fromJson,
  );
  static const codecListBlobsRequest = RpcCodec<ListBlobsRequest>.withDecoder(
    ListBlobsRequest.fromJson,
  );
  static const codecListBlobsResponse = RpcCodec<ListBlobsResponse>.withDecoder(
    ListBlobsResponse.fromJson,
  );
  static const codecListCollectionsRequest =
      RpcCodec<ListCollectionsRequest>.withDecoder(
        ListCollectionsRequest.fromJson,
      );
  static const codecListCollectionsResponse =
      RpcCodec<ListCollectionsResponse>.withDecoder(
        ListCollectionsResponse.fromJson,
      );
  static const codecPutBlobResponse = RpcCodec<PutBlobResponse>.withDecoder(
    PutBlobResponse.fromJson,
  );
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
      requestCodec: BlobServiceContractCodecs.codecBlobUploadChunk,
      responseCodec: BlobServiceContractCodecs.codecPutBlobResponse,
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
      requestCodec: BlobServiceContractCodecs.codecGetBlobRequest,
      responseCodec: BlobServiceContractCodecs.codecBlobDownloadFrame,
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
      requestCodec: BlobServiceContractCodecs.codecHeadBlobRequest,
      responseCodec: BlobServiceContractCodecs.codecHeadBlobResponse,
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
      requestCodec: BlobServiceContractCodecs.codecDeleteBlobRequest,
      responseCodec: BlobServiceContractCodecs.codecDeleteBlobResponse,
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
      requestCodec: BlobServiceContractCodecs.codecListBlobsRequest,
      responseCodec: BlobServiceContractCodecs.codecListBlobsResponse,
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
      requestCodec: BlobServiceContractCodecs.codecListCollectionsRequest,
      responseCodec: BlobServiceContractCodecs.codecListCollectionsResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<DeleteCollectionResponse> deleteCollection(
    DeleteCollectionRequest request, {
    RpcContext? context,
  }) {
    return callUnary<DeleteCollectionRequest, DeleteCollectionResponse>(
      methodName: BlobServiceContractNames.deleteCollection,
      requestCodec: BlobServiceContractCodecs.codecDeleteCollectionRequest,
      responseCodec: BlobServiceContractCodecs.codecDeleteCollectionResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<BulkHeadBlobResponse> bulkHeadBlob(
    BulkHeadBlobRequest request, {
    RpcContext? context,
  }) {
    return callUnary<BulkHeadBlobRequest, BulkHeadBlobResponse>(
      methodName: BlobServiceContractNames.bulkHeadBlob,
      requestCodec: BlobServiceContractCodecs.codecBulkHeadBlobRequest,
      responseCodec: BlobServiceContractCodecs.codecBulkHeadBlobResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<BulkDeleteBlobResponse> bulkDeleteBlob(
    BulkDeleteBlobRequest request, {
    RpcContext? context,
  }) {
    return callUnary<BulkDeleteBlobRequest, BulkDeleteBlobResponse>(
      methodName: BlobServiceContractNames.bulkDeleteBlob,
      requestCodec: BlobServiceContractCodecs.codecBulkDeleteBlobRequest,
      responseCodec: BlobServiceContractCodecs.codecBulkDeleteBlobResponse,
      request: request,
      context: context,
    );
  }

  @override
  Stream<BulkBlobDownloadFrame> bulkGetBlob(
    BulkGetBlobRequest request, {
    RpcContext? context,
  }) {
    return callServerStream<BulkGetBlobRequest, BulkBlobDownloadFrame>(
      methodName: BlobServiceContractNames.bulkGetBlob,
      requestCodec: BlobServiceContractCodecs.codecBulkGetBlobRequest,
      responseCodec: BlobServiceContractCodecs.codecBulkBlobDownloadFrame,
      request: request,
      context: context,
    );
  }

  @override
  Future<BulkPutBlobResponse> bulkPutBlob(
    Stream<BlobUploadChunk> requests, {
    RpcContext? context,
  }) {
    return callClientStream<BlobUploadChunk, BulkPutBlobResponse>(
      methodName: BlobServiceContractNames.bulkPutBlob,
      requestCodec: BlobServiceContractCodecs.codecBlobUploadChunk,
      responseCodec: BlobServiceContractCodecs.codecBulkPutBlobResponse,
      requests: requests,
      context: context,
    );
  }

  @override
  Future<CollectionSizeResponse> collectionSize(
    CollectionSizeRequest request, {
    RpcContext? context,
  }) {
    return callUnary<CollectionSizeRequest, CollectionSizeResponse>(
      methodName: BlobServiceContractNames.collectionSize,
      requestCodec: BlobServiceContractCodecs.codecCollectionSizeRequest,
      responseCodec: BlobServiceContractCodecs.codecCollectionSizeResponse,
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
      requestCodec: BlobServiceContractCodecs.codecBlobUploadChunk,
      responseCodec: BlobServiceContractCodecs.codecPutBlobResponse,
    );
    addServerStreamMethod<GetBlobRequest, BlobDownloadFrame>(
      methodName: BlobServiceContractNames.getBlob,
      handler: getBlob,
      description: 'Chunked download of a blob (supports optional ranges)',
      requestCodec: BlobServiceContractCodecs.codecGetBlobRequest,
      responseCodec: BlobServiceContractCodecs.codecBlobDownloadFrame,
    );
    addUnaryMethod<HeadBlobRequest, HeadBlobResponse>(
      methodName: BlobServiceContractNames.headBlob,
      handler: headBlob,
      description: 'Return blob metadata without payload',
      requestCodec: BlobServiceContractCodecs.codecHeadBlobRequest,
      responseCodec: BlobServiceContractCodecs.codecHeadBlobResponse,
    );
    addUnaryMethod<DeleteBlobRequest, DeleteBlobResponse>(
      methodName: BlobServiceContractNames.deleteBlob,
      handler: deleteBlob,
      description: 'Delete blob by id with optional version check',
      requestCodec: BlobServiceContractCodecs.codecDeleteBlobRequest,
      responseCodec: BlobServiceContractCodecs.codecDeleteBlobResponse,
    );
    addUnaryMethod<ListBlobsRequest, ListBlobsResponse>(
      methodName: BlobServiceContractNames.listBlobs,
      handler: listBlobs,
      description: 'Paginated list of blob descriptors in a collection',
      requestCodec: BlobServiceContractCodecs.codecListBlobsRequest,
      responseCodec: BlobServiceContractCodecs.codecListBlobsResponse,
    );
    addUnaryMethod<ListCollectionsRequest, ListCollectionsResponse>(
      methodName: BlobServiceContractNames.listCollections,
      handler: listCollections,
      description: 'List known blob collections',
      requestCodec: BlobServiceContractCodecs.codecListCollectionsRequest,
      responseCodec: BlobServiceContractCodecs.codecListCollectionsResponse,
    );
    addUnaryMethod<DeleteCollectionRequest, DeleteCollectionResponse>(
      methodName: BlobServiceContractNames.deleteCollection,
      handler: deleteCollection,
      description: 'Drop a blob collection and all contained blobs',
      requestCodec: BlobServiceContractCodecs.codecDeleteCollectionRequest,
      responseCodec: BlobServiceContractCodecs.codecDeleteCollectionResponse,
    );
    addUnaryMethod<BulkHeadBlobRequest, BulkHeadBlobResponse>(
      methodName: BlobServiceContractNames.bulkHeadBlob,
      handler: bulkHeadBlob,
      description: 'Fetch metadata for multiple blobs',
      requestCodec: BlobServiceContractCodecs.codecBulkHeadBlobRequest,
      responseCodec: BlobServiceContractCodecs.codecBulkHeadBlobResponse,
    );
    addUnaryMethod<BulkDeleteBlobRequest, BulkDeleteBlobResponse>(
      methodName: BlobServiceContractNames.bulkDeleteBlob,
      handler: bulkDeleteBlob,
      description: 'Delete multiple blobs (per item best-effort)',
      requestCodec: BlobServiceContractCodecs.codecBulkDeleteBlobRequest,
      responseCodec: BlobServiceContractCodecs.codecBulkDeleteBlobResponse,
    );
    addServerStreamMethod<BulkGetBlobRequest, BulkBlobDownloadFrame>(
      methodName: BlobServiceContractNames.bulkGetBlob,
      handler: bulkGetBlob,
      description: 'Download multiple blobs sequentially with identification',
      requestCodec: BlobServiceContractCodecs.codecBulkGetBlobRequest,
      responseCodec: BlobServiceContractCodecs.codecBulkBlobDownloadFrame,
    );
    addClientStreamMethod<BlobUploadChunk, BulkPutBlobResponse>(
      methodName: BlobServiceContractNames.bulkPutBlob,
      handler: bulkPutBlob,
      description: 'Upload multiple blobs sequentially in one stream',
      requestCodec: BlobServiceContractCodecs.codecBlobUploadChunk,
      responseCodec: BlobServiceContractCodecs.codecBulkPutBlobResponse,
    );
    addUnaryMethod<CollectionSizeRequest, CollectionSizeResponse>(
      methodName: BlobServiceContractNames.collectionSize,
      handler: collectionSize,
      description: 'Return total size in bytes of all blobs in a collection',
      requestCodec: BlobServiceContractCodecs.codecCollectionSizeRequest,
      responseCodec: BlobServiceContractCodecs.codecCollectionSizeResponse,
    );
  }
}
