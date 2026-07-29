// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';
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
        transferMode: RpcDataTransferMode.zeroCopy,
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
      final caller = DataServiceCaller(
        endpoint: callerEndpoint,
        transferMode: RpcDataTransferMode.zeroCopy,
      );
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

      final context = RpcContext.withHeaders({
        'authorization': 'Bearer valid-token',
      });
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
        DateTime.now().subtract(const Duration(minutes: 1)),
      );

      await expectLater(
        () => client.list(collection: 'logs', context: expiredContext),
        throwsA(isA<RpcDeadlineExceededException>()),
      );
    });

    test(
      'repository exceptions are wrapped as internal RpcDataError',
      () async {
        await startServer(repo: _ThrowingRepository());

        await expectLater(
          () => client.create(collection: 'notes', payload: {'title': 'boom'}),
          throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              contains('Unhandled repository error'),
            ),
          ),
        );
      },
    );

    test('listCollections exposes registered collection names', () async {
      await startServer();
      await repository.create(
        const CreateRecordRequest(
          collection: 'notes',
          payload: {'tag': 'alpha'},
        ),
      );
      await repository.create(
        const CreateRecordRequest(
          collection: 'tasks',
          payload: {'tag': 'beta'},
        ),
      );

      final collections = await client.listCollections();
      expect(collections.toSet(), containsAll({'notes', 'tasks'}));
    });
  });

  group('DataService RPC export/import resume', () {
    Future<DataServiceClient> seededClient(DataServiceClient client) async {
      await client.create(
        collection: 'notes',
        payload: {'title': 'First', 'done': false},
      );
      await client.create(
        collection: 'notes',
        payload: {'title': 'Second', 'done': true},
      );
      await client.create(collection: 'tasks', payload: {'title': 'Task 1'});
      return client;
    }

    test('importDatabase can resume over RPC after a drop', () async {
      final sourceEnv = await DataServiceFactory.inMemory(
        serverLabel: 'source-server',
        clientLabel: 'source-client',
      );
      final targetEnv = await DataServiceFactory.inMemory(
        serverLabel: 'target-server',
        clientLabel: 'target-client',
      );
      await seededClient(sourceEnv.client);

      final chunks = await sourceEnv.client.exportDatabase().toList();

      // First attempt: truncated stream → error, partial data written.
      late int lastChunkIndexFromError;
      await expectLater(() async {
        try {
          await targetEnv.client.importDatabase(
            // Cut off before finishing the second collection to emulate network drop.
            payload: Stream<Uint8List>.fromIterable(chunks.take(3)),
            replaceExisting: true,
          );
        } on ImportResumeException catch (error) {
          lastChunkIndexFromError = error.lastChunkIndex ?? -1;
          rethrow;
        } catch (error) {
          rethrow;
        }
      }(), throwsA(isA<Exception>()));

      final partialNotes = await targetEnv.client.list(collection: 'notes');
      expect(partialNotes.records.length, greaterThan(0));

      final resumeResponse = await targetEnv.client.importDatabase(
        payload: Stream<Uint8List>.fromIterable(chunks),
        replaceExisting: true,
        resumeAfterChunk: lastChunkIndexFromError,
      );

      expect(resumeResponse.recordCount, 3);
      expect(resumeResponse.lastChunkIndex, chunks.length - 1);

      final notes = await targetEnv.client.list(collection: 'notes');
      final tasks = await targetEnv.client.list(collection: 'tasks');
      expect(notes.records.length, 2);
      expect(tasks.records.length, 1);

      await sourceEnv.dispose();
      await targetEnv.dispose();
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
  Future<List<DataRecord>> getMany(GetRecordsRequest request) =>
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
    ExportSnapshotRequest request,
  ) => throw UnimplementedError();

  @override
  Stream<Uint8List> exportDatabase(ExportDatabaseRequest request) =>
      throw UnimplementedError();

  @override
  Future<ImportDatabaseResponse> importDatabase({
    required Stream<Uint8List> payload,
    bool replaceExisting = true,
    int resumeAfterChunk = -1,
    void Function(int chunkIndex)? onChunkProcessed,
  }) => throw UnimplementedError();

  @override
  Future<SearchRecordsResponse> search(SearchRecordsRequest request) =>
      throw UnimplementedError();

  @override
  Stream<DataChangeEvent> watch(WatchChangesRequest request) =>
      throw UnimplementedError();

  @override
  Future<CollectionIndex> createCollectionIndex(
    CreateCollectionIndexRequest request,
  ) => throw UnimplementedError();

  @override
  Future<bool> deleteCollectionIndex(DeleteCollectionIndexRequest request) =>
      throw UnimplementedError();

  @override
  Future<void> dispose() async {}

  @override
  Future<GetSchemaResponse> getSchema(GetSchemaRequest request) {
    // TODO: implement getSchema
    throw UnimplementedError();
  }

  @override
  Future<ListSchemasResponse> listSchemas() {
    // TODO: implement listSchemas
    throw UnimplementedError();
  }

  @override
  Future<SetSchemaPolicyResponse> setSchemaPolicy(
    SetSchemaPolicyRequest request,
  ) {
    // TODO: implement setSchemaPolicy
    throw UnimplementedError();
  }
}
