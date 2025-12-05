import 'package:rpc_dart/rpc_dart.dart';

import '../adapters/i_blob_storage_adapter.dart';
import '../adapters/sqlite_blob_storage_adapter.dart';
import '../models.dart';
import '../service/blob_service.dart';
import 'blob_caller.dart';
import 'blob_responder.dart';

/// Helpers to bootstrap blob service client/server pairs over arbitrary
/// transports, similar to `DataServiceFactory`.
class BlobServiceFactory {
  const BlobServiceFactory._();

  /// Create server-side wiring for an existing [IBlobStorageAdapter].
  static BlobServiceServer createServer({
    required IRpcTransport transport,
    required IBlobStorageAdapter storage,
    RpcDataTransferMode transferMode = RpcDataTransferMode.codec,
    String debugLabel = 'BlobServiceServer',
  }) {
    final responder = BlobServiceResponder(
      service: BlobService(storage: storage),
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
    return BlobServiceClient(endpoint, caller);
  }

  /// Full in-memory setup: paired transports + SQLite in-memory storage.
  static Future<InMemoryBlobServiceEnvironment> inMemory({
    IBlobStorageAdapter? storage,
    String serverLabel = 'BlobResponder',
    String clientLabel = 'BlobCaller',
    RpcDataTransferMode transferMode = RpcDataTransferMode.codec,
  }) async {
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
    final backingStorage = storage ?? SqliteBlobStorageAdapter.memory();
    final server = createServer(
      transport: serverTransport,
      storage: backingStorage,
      transferMode: transferMode,
      debugLabel: serverLabel,
    );
    await server.start();
    final client = createClient(
      transport: clientTransport,
      transferMode: transferMode,
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
    required IBlobStorageAdapter storage,
  }) : _endpoint = endpoint,
       _responder = responder,
       _storage = storage;

  final RpcResponderEndpoint _endpoint;
  final BlobServiceResponder _responder;
  final IBlobStorageAdapter _storage;

  RpcResponderEndpoint get endpoint => _endpoint;
  BlobServiceResponder get rawResponder => _responder;
  IBlobStorageAdapter get storage => _storage;

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
  BlobServiceClient(this._endpoint, this._caller);

  final RpcCallerEndpoint _endpoint;
  final BlobServiceCaller _caller;

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
    Map<String, String> metadata = const {},
    int? expectedVersion,
    RpcContext? context,
  }) async {
    final data = await bytes.fold<BytesBuilder>(BytesBuilder(), (b, chunk) {
      b.add(chunk);
      return b;
    });
    final payload = data.takeBytes();
    return putBlob(
      Stream<BlobUploadChunk>.value(
        BlobUploadChunk(
          collection: collection,
          blobId: id ?? '',
          offset: 0,
          bytes: payload,
          totalLength: length ?? payload.length,
          contentType: contentType,
          checksum: checksum,
          metadata: metadata,
          expectedVersion: expectedVersion,
          last: true,
        ),
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
      _caller.listCollections(context: context);

  Future<void> close() => _endpoint.close();
}

/// Client-facing contract mirroring IDataService style.
abstract interface class IBlobClient {
  Future<PutBlobResponse> putBytes({
    required String collection,
    String? id,
    required Stream<Uint8List> bytes,
    int? length,
    String? contentType,
    String? checksum,
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
}
