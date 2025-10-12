import 'dart:async';

import 'package:async/async.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:test/test.dart';

void main() {
  group('DataService integration', () {
    late InMemoryDataServiceEnvironment env;
    late DriftDataRepository repository;
    late RpcContext authContext;

    setUp(() async {
      repository = DriftDataRepository(
        storage: await openMainStorage(),
        // storage: DriftDataStorageAdapter.memory(),
      );
      env = await DataServiceFactory.inMemory(repository: repository);
      authContext = RpcContext.withHeaders({
        'authorization': 'Bearer integration-token',
      });
    });

    tearDown(() async {
      await env.dispose();
    });

    test('exercises full service lifecycle', () async {
      final notesChanges = StreamQueue<DataChangeEvent>(
        env.client.watchChanges(
          collection: 'notes',
          context: authContext,
        ),
      );
      addTearDown(() async {
        await notesChanges.cancel();
      });

      final created = await env.client.create(
        collection: 'notes',
        payload: {'title': 'First note', 'status': 'draft'},
      );
      expect(created.collection, 'notes');
      expect(created.version, 1);

      Future<DataChangeEvent> nextChange(String step) async {
        try {
          return await notesChanges.next.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          fail('Timed out waiting for change event during $step');
        }
      }

      final createdEvent = await nextChange('create');
      expect(createdEvent.type, DataChangeType.created);
      expect(createdEvent.record?.id, created.id);

      final fetched = await env.client.get(
        collection: 'notes',
        id: created.id,
        context: authContext,
      );
      expect(fetched, isNotNull);
      expect(fetched!.payload['status'], 'draft');

      final listResponse = await env.client.list(
        collection: 'notes',
        options: const QueryOptions(limit: 10, includeTotalCount: true),
        context: authContext,
      );
      expect(listResponse.records, hasLength(1));
      expect(listResponse.totalCount, 1);

      final updated = await env.client.update(
        collection: 'notes',
        id: created.id,
        expectedVersion: created.version,
        payload: {'title': 'First note', 'status': 'published'},
        context: authContext,
      );
      expect(updated.version, greaterThan(created.version));
      expect(updated.payload['status'], 'published');

      final updatedEvent = await nextChange('update');
      expect(updatedEvent.type, DataChangeType.updated);
      expect(updatedEvent.record?.payload['status'], 'published');

      final patched = await env.client.patch(
        collection: 'notes',
        id: created.id,
        expectedVersion: updated.version,
        patch: const RecordPatch(
          set: {
            'tags': ['important']
          },
          unset: ['status'],
        ),
        context: authContext,
      );
      expect(patched.version, greaterThan(updated.version));
      expect(patched.payload.containsKey('status'), isFalse);

      final patchedEvent = await nextChange('patch');
      expect(patchedEvent.type, DataChangeType.patched);
      expect(patchedEvent.record?.payload.containsKey('status'), isFalse);

      final searchResponse = await env.client.search(
        collection: 'notes',
        query: 'important',
        context: authContext,
      );
      expect(searchResponse.records.map((record) => record.id),
          contains(patched.id));

      final aggregateResponse = await env.client.aggregate(
        collection: 'notes',
        metrics: const {'total': 'count'},
        context: authContext,
      );
      expect(aggregateResponse.metrics['total'], 1);

      final filteredByTags = await env.client.list(
        collection: 'notes',
        filter: RecordFilter(equals: {
          'tags': ['important']
        }),
        context: authContext,
      );
      expect(filteredByTags.records.map((record) => record.id),
          contains(patched.id));

      final snapshot = await env.client.exportSnapshot(
        collection: 'notes',
        context: authContext,
      );
      expect(snapshot.records, hasLength(1));
      expect(snapshot.records.single.id, patched.id);

      final now = DateTime.now().toUtc();
      final bulkRecords = [
        DataRecord(
          id: 'task-1',
          collection: 'tasks',
          payload: {'title': 'Task A', 'priority': 1},
          version: 1,
          createdAt: now,
          updatedAt: now,
        ),
        DataRecord(
          id: 'task-2',
          collection: 'tasks',
          payload: {'title': 'Task B', 'priority': 2},
          version: 1,
          createdAt: now.add(const Duration(milliseconds: 1)),
          updatedAt: now.add(const Duration(milliseconds: 1)),
        ),
      ];
      final bulkUpserted = await env.client.bulkUpsert(
        records: bulkRecords,
        context: authContext,
      );
      expect(bulkUpserted, hasLength(2));

      final createdIndex = await env.client.createCollectionIndex(
        collection: 'tasks',
        path: r'$.priority',
        context: authContext,
        indexName: 'priority_index',
      );
      expect(createdIndex.collection, 'tasks');
      expect(createdIndex.path, 'priority');
      expect(createdIndex.indexName, isNotEmpty);

      final indexRow = await repository.storage.database.customSelect(
        'SELECT name FROM sqlite_master WHERE type = \'index\' AND name = ?',
        variables: [Variable<String>(createdIndex.indexName)],
      ).getSingleOrNull();
      expect(indexRow, isNotNull, reason: 'Index must exist after creation');
      //
      // final indexDeleted = await env.client.deleteCollectionIndex(
      //   collection: 'tasks',
      //   path: 'priority',
      //   context: authContext,
      // );
      // expect(indexDeleted, isTrue);
      //
      // final indexRowAfterDrop = await repository.storage.database.customSelect(
      //   'SELECT name FROM sqlite_master WHERE type = \'index\' AND name = ?',
      //   variables: [Variable<String>(createdIndex.indexName)],
      // ).getSingleOrNull();
      // expect(indexRowAfterDrop, isNull, reason: 'Index should be removed');
      //
      // final indexDeletedAgain = await env.client.deleteCollectionIndex(
      //   collection: 'tasks',
      //   path: 'priority',
      //   context: authContext,
      // );
      // expect(indexDeletedAgain, isFalse);

      final taskMetrics = await env.client.aggregate(
        collection: 'tasks',
        metrics: const {
          'count': 'count',
          'prioritySum': 'sum:priority',
          'maxPriority': 'max:priority',
        },
        context: authContext,
      );
      expect(taskMetrics.metrics['count'], 2);
      expect(taskMetrics.metrics['prioritySum'], closeTo(3, 1e-6));
      expect(taskMetrics.metrics['maxPriority'], closeTo(2, 1e-6));

      final exportDatabase = await env.client.exportDatabase(
        context: authContext,
      );
      expect(exportDatabase.collectionCount, greaterThanOrEqualTo(1));
      expect(exportDatabase.recordCount, greaterThan(0));
      expect(exportDatabase.payload, isNotEmpty);

      final deletedFromBulk = await env.client.bulkDelete(
        collection: 'tasks',
        ids: const ['task-1'],
        context: authContext,
      );
      expect(deletedFromBulk, 1);

      final deleted = await env.client.delete(
        collection: 'notes',
        id: patched.id,
        expectedVersion: patched.version,
        context: authContext,
      );
      expect(deleted, isTrue);

      final deletedEvent = await nextChange('delete');
      expect(deletedEvent.type, DataChangeType.deleted);
      expect(deletedEvent.record, isNull);

      final afterDelete = await env.client.get(
        collection: 'notes',
        id: patched.id,
        context: authContext,
      );
      expect(afterDelete, isNull);

      final removedCollection = await env.client.deleteCollection(
        collection: 'tasks',
        context: authContext,
      );
      expect(removedCollection, isTrue);

      final syncController = StreamController<SyncChangeRequest>();
      final syncResponses =
          env.client.syncChanges(syncController.stream, context: authContext);
      final syncResponseFuture = syncResponses.first;

      final syncCommand = DataCommand(
        commandId: 'cmd-1',
        sessionId: 'sess-1',
        type: DataCommandType.create,
        payload: const CreateRecordRequest(
          collection: 'offline',
          payload: {'message': 'from sync'},
        ).toJson(),
        issuedAt: DateTime.now().toUtc(),
      );

      syncController.add(
        SyncChangeRequest(
          requestId: 'req-1',
          command: syncCommand,
        ),
      );
      await syncController.close();

      SyncChangeResponse syncResponse;
      try {
        syncResponse =
            await syncResponseFuture.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        fail('Timed out waiting for sync response');
      }
      expect(syncResponse.applied, isTrue);
      expect(syncResponse.record, isNotNull);
      expect(syncResponse.record!.collection, 'offline');

      final importResponse = await env.client.importDatabase(
        payload: exportDatabase.payload,
        replaceExisting: true,
        context: authContext,
      );
      expect(importResponse.recordCount, exportDatabase.recordCount);

      final snapshotEvent = await nextChange('importDatabase');
      expect(snapshotEvent.type, DataChangeType.snapshot);
      expect(snapshotEvent.record?.id, created.id);

      final restored = await env.client
          .get(
            collection: 'notes',
            id: created.id,
            context: authContext,
          )
          .timeout(const Duration(seconds: 5));
      expect(restored, isNotNull);
      expect(restored!.payload.containsKey('tags'), isTrue);

      final restoredTasks = await env.client
          .list(
            collection: 'tasks',
            context: authContext,
          )
          .timeout(const Duration(seconds: 5));
      expect(restoredTasks.records, isNotEmpty);
    });
  });
}
