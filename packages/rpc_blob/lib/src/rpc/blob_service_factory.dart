import 'package:crypto/crypto.dart';
import 'package:rpc_dart/rpc_dart.dart';

import '../adapters/i_blob_storage_adapter.dart';
import '../client/blob_repository_client.dart';
import '../models.dart';
import 'blob_caller.dart';
import 'blob_responder.dart';

/// Helper item for bulk uploads via convenience API.
class BulkPutBlobItem {
  BulkPutBlobItem({
    required this.collection,
    required this.bytes,
    this.id,
    this.length,
    this.contentType,
    this.checksum,
    this.checksumAlgorithm = ChecksumAlgorithm.sha256,
    this.attachChunkChecksums = false,
    this.metadata = const {},
    this.expectedVersion,
  });

  final String collection;
  final String? id;
  final Stream<Uint8List> bytes;
  final int? length;
  final String? contentType;
  final String? checksum;
  final ChecksumAlgorithm checksumAlgorithm;
  final bool attachChunkChecksums;
  final Map<String, String> metadata;
  final int? expectedVersion;
}

/// Helpers to bootstrap blob service client/server pairs over arbitrary
/// transports, similar to `DataServiceFactory`.
class BlobServiceFactory {
  const BlobServiceFactory._();

  /// Create server-side wiring for an existing [IBlobRepository].
  static BlobServiceServer createServer({
    required IRpcTransport transport,
    required IBlobRepository storage,
    RpcDataTransferMode transferMode = RpcDataTransferMode.codec,
    int? maxChunkBytes,
    String debugLabel = 'BlobServiceServer',
  }) {
    final responder = BlobServiceResponder(
      storage: storage,
      maxChunkBytes: maxChunkBytes,
      transferMode: transferMode,
    );
    final endpoint = RpcResponderEndpoint(
      transport: transport,
      debugLabel: debugLabel,
    );
    return BlobServiceServer(
      endpoint: endpoint,
      responder: responder,
      storage: storage,
    );
  }

  /// Create client-side wiring for an existing transport.
  static BlobServiceClient createClient({
    required IRpcTransport transport,
    RpcDataTransferMode transferMode = RpcDataTransferMode.codec,
    int uploadChunkBytes = BlobServiceClient.defaultChunkBytes,
    String debugLabel = 'BlobServiceClient',
  }) {
    final endpoint = RpcCallerEndpoint(
      transport: transport,
      debugLabel: debugLabel,
    );
    final caller = BlobServiceCaller(
      endpoint: endpoint,
      transferMode: transferMode,
    );
    return BlobServiceClient(
      endpoint,
      caller,
      uploadChunkBytes: uploadChunkBytes,
    );
  }

  /// Full in-memory setup: paired transports + SQLite in-memory storage.
  static Future<InMemoryBlobServiceEnvironment> inMemory({
    required IBlobRepository storage,
    String serverLabel = 'BlobResponder',
    String clientLabel = 'BlobCaller',
    RpcDataTransferMode transferMode = RpcDataTransferMode.codec,
    int uploadChunkBytes = BlobServiceClient.defaultChunkBytes,
    int? maxChunkBytes,
  }) async {
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
    final server = createServer(
      transport: serverTransport,
      storage: storage,
      transferMode: transferMode,
      maxChunkBytes: maxChunkBytes,
      debugLabel: serverLabel,
    );
    await server.start();
    final client = createClient(
      transport: clientTransport,
      transferMode: transferMode,
      uploadChunkBytes: uploadChunkBytes,
      debugLabel: clientLabel,
    );
    return InMemoryBlobServiceEnvironment(
      client: client,
      server: server,
      clientTransport: clientTransport,
      serverTransport: serverTransport,
    );
  }
}

/// Server wrapper: holds endpoint, responder, and storage.
class BlobServiceServer {
  BlobServiceServer({
    required RpcResponderEndpoint endpoint,
    required BlobServiceResponder responder,
    required IBlobRepository storage,
  }) : _endpoint = endpoint,
       _responder = responder,
       _storage = storage;

  final RpcResponderEndpoint _endpoint;
  final BlobServiceResponder _responder;
  final IBlobRepository _storage;

  RpcResponderEndpoint get endpoint => _endpoint;
  BlobServiceResponder get rawResponder => _responder;
  IBlobRepository get storage => _storage;

  Future<void> start() async {
    _endpoint.registerServiceContract(_responder);
    _endpoint.start();
  }

  Future<void> close() async {
    await _endpoint.close();
    _responder.dispose();
    await _storage.dispose();
  }
}

/// Client wrapper: holds endpoint and caller.
class BlobServiceClient implements IBlobClient {
  BlobServiceClient(
    this._endpoint,
    this._caller, {
    int uploadChunkBytes = defaultChunkBytes,
  }) : assert(uploadChunkBytes > 0, 'uploadChunkBytes must be positive'),
       _uploadChunkBytes = uploadChunkBytes;

  final RpcCallerEndpoint _endpoint;
  final BlobServiceCaller _caller;
  final int _uploadChunkBytes;

  static const int defaultChunkBytes = 256 * 1024;

  RpcCallerEndpoint get endpoint => _endpoint;
  BlobServiceCaller get caller => _caller;

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
  }) async {
    return putBlob(
      _chunkUpload(
        collection: collection,
        id: id,
        bytes: bytes,
        length: length,
        contentType: contentType,
        checksum: checksum,
        checksumAlgorithm: checksumAlgorithm,
        attachChunkChecksums: attachChunkChecksums,
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
  }) => _caller.putBlob(chunks, context: context);

  @override
  Stream<BlobDownloadFrame> get(
    String collection,
    String id, {
    int? rangeStart,
    int? rangeEnd,
    RpcContext? context,
  }) => _caller.getBlob(
    GetBlobRequest(
      collection: collection,
      id: id,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
    ),
    context: context,
  );

  @override
  Future<HeadBlobResponse> head(
    String collection,
    String id, {
    RpcContext? context,
  }) => _caller.headBlob(
    HeadBlobRequest(collection: collection, id: id),
    context: context,
  );

  @override
  Future<DeleteBlobResponse> delete(
    String collection,
    String id, {
    int? expectedVersion,
    RpcContext? context,
  }) => _caller.deleteBlob(
    DeleteBlobRequest(
      collection: collection,
      id: id,
      expectedVersion: expectedVersion,
    ),
    context: context,
  );

  @override
  Future<ListBlobsResponse> list(
    String collection, {
    String? cursor,
    int limit = 50,
    String? prefix,
    bool includeMetadata = false,
    RpcContext? context,
  }) => _caller.listBlobs(
    ListBlobsRequest(
      collection: collection,
      cursor: cursor,
      limit: limit,
      prefix: prefix,
      includeMetadata: includeMetadata,
    ),
    context: context,
  );

  @override
  Future<ListCollectionsResponse> listCollections({RpcContext? context}) =>
      _caller.listCollections(const ListCollectionsRequest(), context: context);

  @override
  Future<void> close() => _endpoint.close();

  @override
  Future<BulkHeadBlobResponse> bulkHeadBlob(
    BulkHeadBlobRequest request, {
    RpcContext? context,
  }) => _caller.bulkHeadBlob(request, context: context);

  @override
  Future<BulkDeleteBlobResponse> bulkDeleteBlob(
    BulkDeleteBlobRequest request, {
    RpcContext? context,
  }) => _caller.bulkDeleteBlob(request, context: context);

  @override
  Stream<BulkBlobDownloadFrame> bulkGetBlob(
    BulkGetBlobRequest request, {
    RpcContext? context,
  }) => _caller.bulkGetBlob(request, context: context);

  @override
  Future<BulkPutBlobResponse> bulkPutBlob(
    Stream<BlobUploadChunk> request, {
    RpcContext? context,
  }) => _caller.bulkPutBlob(request, context: context);

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
      if (chunk.isNotEmpty) {
        buffer.addAll(chunk);
      } else if (buffer.isEmpty && firstChunk && chunk.isEmpty) {
        // Allow zero-length chunk to start stream.
      }
      while (buffer.length >= _uploadChunkBytes) {
        final data = Uint8List.fromList(buffer.sublist(0, _uploadChunkBytes));
        buffer.removeRange(0, _uploadChunkBytes);
        yield BlobUploadChunk(
          collection: collection,
          blobId: id ?? '',
          offset: offset,
          bytes: data,
          totalLength: firstChunk ? length : null,
          contentType: firstChunk ? contentType : null,
          checksum: firstChunk ? checksum : null,
          checksumAlgorithm: firstChunk ? checksumAlgorithm : null,
          chunkChecksum: attachChunkChecksums
              ? _hashChunk(data, checksumAlgorithm)
              : null,
          metadata: firstChunk ? metadata : const {},
          expectedVersion: firstChunk ? expectedVersion : null,
          last: false,
        );
        offset += data.length;
        firstChunk = false;
      }
    }

    // Emit the remainder (or a zero-length sentinel) as the final chunk.
    final remaining = Uint8List.fromList(buffer);
    yield BlobUploadChunk(
      collection: collection,
      blobId: id ?? '',
      offset: offset,
      bytes: remaining,
      totalLength: firstChunk ? (length ?? remaining.length) : null,
      contentType: firstChunk ? contentType : null,
      checksum: firstChunk ? checksum : null,
      checksumAlgorithm: firstChunk ? checksumAlgorithm : null,
      chunkChecksum: attachChunkChecksums
          ? _hashChunk(remaining, checksumAlgorithm)
          : null,
      metadata: firstChunk ? metadata : const {},
      expectedVersion: firstChunk ? expectedVersion : null,
      last: true,
    );
  }

  String? _hashChunk(Uint8List data, ChecksumAlgorithm algorithm) {
    if (data.isEmpty) return null;
    switch (algorithm) {
      case ChecksumAlgorithm.sha256:
        return sha256.convert(data).toString();
    }
  }
}

/// Client-facing contract mirroring IDataService style.
abstract interface class IBlobClient {
  // Backwards-compatible alias.
  static IBlobClient factory({
    required RpcCallerEndpoint endpoint,
    required RpcDataTransferMode transferMode,
  }) => IBlobClient.endpoint(endpoint: endpoint, transferMode: transferMode);

  static IBlobClient endpoint({
    required RpcCallerEndpoint endpoint,
    required RpcDataTransferMode transferMode,
  }) {
    return BlobServiceClient(
      endpoint,
      BlobServiceCaller(endpoint: endpoint, transferMode: transferMode),
    );
  }

  static IBlobClient repository({
    required IBlobRepository repository,
    bool disposeRepositoryOnClose = false,
    int uploadChunkBytes = BlobRepositoryClient.defaultChunkBytes,
    int? maxChunkBytes,
  }) {
    return BlobRepositoryClient(
      repository: repository,
      disposeRepositoryOnClose: disposeRepositoryOnClose,
      uploadChunkBytes: uploadChunkBytes,
      maxChunkBytes: maxChunkBytes,
    );
  }

  Future<PutBlobResponse> putBytes({
    required String collection,
    String? id,
    required Stream<Uint8List> bytes,
    int? length,
    String? contentType,
    String? checksum,
    ChecksumAlgorithm checksumAlgorithm = ChecksumAlgorithm.sha256,
    bool attachChunkChecksums = false,
    Map<String, String> metadata,
    int? expectedVersion,
    RpcContext? context,
  });

  Future<PutBlobResponse> putBlob(
    Stream<BlobUploadChunk> chunks, {
    RpcContext? context,
  });

  Stream<BlobDownloadFrame> get(
    String collection,
    String id, {
    int? rangeStart,
    int? rangeEnd,
    RpcContext? context,
  });

  Future<HeadBlobResponse> head(
    String collection,
    String id, {
    RpcContext? context,
  });

  Future<DeleteBlobResponse> delete(
    String collection,
    String id, {
    int? expectedVersion,
    RpcContext? context,
  });

  Future<ListBlobsResponse> list(
    String collection, {
    String? cursor,
    int limit,
    String? prefix,
    bool includeMetadata,
    RpcContext? context,
  });

  Future<ListCollectionsResponse> listCollections({RpcContext? context});

  Future<BulkHeadBlobResponse> bulkHeadBlob(
    BulkHeadBlobRequest request, {
    RpcContext? context,
  });

  Future<BulkDeleteBlobResponse> bulkDeleteBlob(
    BulkDeleteBlobRequest request, {
    RpcContext? context,
  });

  Stream<BulkBlobDownloadFrame> bulkGetBlob(
    BulkGetBlobRequest request, {
    RpcContext? context,
  });

  Future<BulkPutBlobResponse> bulkPutBlob(
    Stream<BlobUploadChunk> request, {
    RpcContext? context,
  });

  Future<BulkPutBlobResponse> bulkPutBytes(
    List<BulkPutBlobItem> items, {
    RpcContext? context,
  });

  Future<void> close();
}

/// Result of in-memory helper for quick setups.
class InMemoryBlobServiceEnvironment {
  InMemoryBlobServiceEnvironment({
    required this.client,
    required this.server,
    required this.clientTransport,
    required this.serverTransport,
  });

  final BlobServiceClient client;
  final BlobServiceServer server;
  final IRpcTransport clientTransport;
  final IRpcTransport serverTransport;

  Future<void> dispose() async {
    await client.close();
    await server.close();
  }
}
