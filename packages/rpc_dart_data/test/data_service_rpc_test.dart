import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:test/test.dart';

void main() {
  group('DataService RPC layer', () {
    late IDataRepository repository;
    late DataServiceClient client;
    late DataServiceServer server;

    Future<void> startServer({
      IDataRepository? repo,
      Iterable<String> allowedBearerTokens = const [],
    }) async {
      repository = repo ?? InMemoryDataRepository();
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
      final endpoint = RpcResponderEndpoint(
        transport: serverTransport,
        debugLabel: 'rpc-server',
      );
      final responder = DataServiceResponder(
        repository: repository,
        allowedBearerTokens: allowedBearerTokens,
      );
      server = DataServiceServer(
        endpoint: endpoint,
        responder: responder,
        repository: repository,
      );
      await server.start();

      final callerEndpoint = RpcCallerEndpoint(
        transport: clientTransport,
        debugLabel: 'rpc-client',
      );
      final caller = DataServiceCaller(callerEndpoint);
      client = DataServiceClient(callerEndpoint, caller);
    }

    tearDown(() async {
      await client.close();
      await server.close();
      await repository.dispose();
    });

    test('enforces bearer token when configured', () async {
      await startServer(allowedBearerTokens: ['valid-token']);

      await expectLater(
        () => client.create(
          collection: 'notes',
          payload: {'title': 'Unauthorized'},
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('Authorization header is required for this service'),
          ),
        ),
      );

      final context =
          RpcContext.withHeaders({'authorization': 'Bearer valid-token'});
      final record = await client.create(
        collection: 'notes',
        payload: {'title': 'Authorized'},
        context: context,
      );

      expect(record.payload['title'], 'Authorized');
    });

    test('deadline expiry is detected before repository execution', () async {
      await startServer();
      final expiredContext = RpcContext.withDeadline(
          DateTime.now().subtract(const Duration(minutes: 1)));

      await expectLater(
        () => client.list(collection: 'logs', context: expiredContext),
        throwsA(isA<RpcDeadlineExceededException>()),
      );
    });

    test('repository exceptions are wrapped as internal RpcDataError',
        () async {
      await startServer(repo: _ThrowingRepository());

      await expectLater(
        () => client.create(
          collection: 'notes',
          payload: {'title': 'boom'},
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('Unhandled repository error'),
          ),
        ),
      );
    });

    test('listCollections exposes registered collection names', () async {
      await startServer();
      await repository.create(
        const CreateRecordRequest(
            collection: 'notes', payload: {'tag': 'alpha'}),
      );
      await repository.create(
        const CreateRecordRequest(
            collection: 'tasks', payload: {'tag': 'beta'}),
      );

      final collections = await client.listCollections();
      expect(collections.toSet(), containsAll({'notes', 'tasks'}));
    });
  });
}

class _ThrowingRepository implements IDataRepository {
  @override
  Future<DataRecord> create(CreateRecordRequest request) =>
      throw StateError('boom');

  @override
  Future<DataRecord?> get(GetRecordRequest request) =>
      throw UnimplementedError();

  @override
  Future<ListRecordsResponse> list(ListRecordsRequest request) =>
      throw UnimplementedError();

  @override
  Future<List<String>> listCollections() => throw UnimplementedError();

  @override
  Future<DataRecord> update(UpdateRecordRequest request) =>
      throw UnimplementedError();

  @override
  Future<DataRecord> patch(PatchRecordRequest request) =>
      throw UnimplementedError();

  @override
  Future<bool> delete(DeleteRecordRequest request) =>
      throw UnimplementedError();

  @override
  Future<bool> deleteCollection(DeleteCollectionRequest request) =>
      throw UnimplementedError();

  @override
  Future<List<DataRecord>> bulkUpsert(BulkUpsertRequest request) =>
      throw UnimplementedError();

  @override
  Future<int> bulkDelete(BulkDeleteRequest request) =>
      throw UnimplementedError();

  @override
  Future<ExportSnapshotResponse> exportSnapshot(
          ExportSnapshotRequest request) =>
      throw UnimplementedError();

  @override
  Future<ExportDatabaseResponse> exportDatabase(
          ExportDatabaseRequest request) =>
      throw UnimplementedError();

  @override
  Future<ImportDatabaseResponse> importDatabase(
          ImportDatabaseRequest request) =>
      throw UnimplementedError();

  @override
  Future<SearchRecordsResponse> search(SearchRecordsRequest request) =>
      throw UnimplementedError();

  @override
  Future<AggregateMetricsResponse> aggregate(AggregateMetricsRequest request) =>
      throw UnimplementedError();

  @override
  Stream<DataChangeEvent> watch(WatchChangesRequest request) =>
      throw UnimplementedError();

  @override
  Future<CollectionIndex> createCollectionIndex(
          CreateCollectionIndexRequest request) =>
      throw UnimplementedError();

  @override
  Future<bool> deleteCollectionIndex(DeleteCollectionIndexRequest request) =>
      throw UnimplementedError();

  @override
  Stream<SyncChangeResponse> sync(Stream<SyncChangeRequest> requests) =>
      throw UnimplementedError();

  @override
  Future<void> dispose() async {}
}
