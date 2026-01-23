import 'package:rpc_dart/rpc_dart.dart';

import '../models.dart';

/// Contract constants for BlobService.
abstract interface class IBlobServiceContract implements IRpcContract {
  /// RPC service name.
  static const String name = 'BlobService';

  /// Client-stream upload.
  static const String putBlob = 'putBlob';

  /// Server-stream download.
  static const String getBlob = 'getBlob';

  /// Metadata-only lookup.
  static const String headBlob = 'headBlob';

  /// Delete blob.
  static const String deleteBlob = 'deleteBlob';

  /// Paginated listing.
  static const String listBlobs = 'listBlobs';

  /// List collections.
  static const String listCollections = 'listCollections';

  @override
  String get serviceName => IBlobServiceContract.name;
}

const RpcCodec<HeadBlobRequest> headRequestCodec = RpcCodec.withDecoder(
  HeadBlobRequest.fromJson,
);
const RpcCodec<HeadBlobResponse> headResponseCodec = RpcCodec.withDecoder(
  HeadBlobResponse.fromJson,
);
const RpcCodec<GetBlobRequest> getRequestCodec = RpcCodec.withDecoder(
  GetBlobRequest.fromJson,
);
const RpcCodec<BlobDownloadFrame> downloadFrameCodec = RpcCodec.withDecoder(
  BlobDownloadFrame.fromJson,
);
const RpcCodec<BlobUploadChunk> uploadChunkCodec = RpcCodec.withDecoder(
  BlobUploadChunk.fromJson,
);
const RpcCodec<PutBlobResponse> putResponseCodec = RpcCodec.withDecoder(
  PutBlobResponse.fromJson,
);
const RpcCodec<DeleteBlobRequest> deleteRequestCodec = RpcCodec.withDecoder(
  DeleteBlobRequest.fromJson,
);
const RpcCodec<DeleteBlobResponse> deleteResponseCodec = RpcCodec.withDecoder(
  DeleteBlobResponse.fromJson,
);
const RpcCodec<ListBlobsRequest> listRequestCodec = RpcCodec.withDecoder(
  ListBlobsRequest.fromJson,
);
const RpcCodec<ListBlobsResponse> listResponseCodec = RpcCodec.withDecoder(
  ListBlobsResponse.fromJson,
);
const RpcCodec<ListCollectionsRequest> listCollectionsRequestCodec =
    RpcCodec.withDecoder(ListCollectionsRequest.fromJson);
const RpcCodec<ListCollectionsResponse> listCollectionsResponseCodec =
    RpcCodec.withDecoder(ListCollectionsResponse.fromJson);
