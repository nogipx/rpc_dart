import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:path/path.dart' as p;
import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:test/test.dart';

void main() {
  final dbFile = File(
    p.join(Directory.current.path, 'rpc_dart_data_test.sqlite'),
  );
  final skip = false;

  Future<void> resetDatabase() async {
    final storage = DriftDataStorageAdapter.file(dbFile);
    try {
      final tables = await storage.database
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table'"
            " AND name NOT LIKE 'sqlite_%'",
          )
          .get();

      for (final row in tables) {
        final tableName = row.read<String>('name');
        if (tableName == 'collection_registry') {
          await storage.database
              .customStatement('DELETE FROM collection_registry');
        } else {
          await storage.database
              .customStatement('DROP TABLE IF EXISTS "$tableName"');
        }
      }
    } finally {
      await storage.dispose();
    }
  }

  setUp(() async {
    if (!skip) {
      await resetDatabase();
    }
  });

  RpcContext buildContext() => RpcContext.withHeaders({
        'authorization': 'Bearer test-token',
      });

  test('Drift storage adapter supports CRUD lifecycle', skip: skip, () async {
    final storage = DriftDataStorageAdapter.file(dbFile);
    final repository = DriftDataRepository(storage: storage);
    final env = await DataServiceFactory.inMemory(repository: repository);
    addTearDown(() async => repository.storage.dispose());
    addTearDown(() async => env.dispose());

    final ctx = buildContext();

    final created = await env.client.create(
      collection: 'notes',
      payload: {'title': 'Hello', 'done': false},
      context: ctx,
    );

    expect(created.collection, 'notes');
    expect(created.payload['title'], 'Hello');

    final fetched = await env.client.get(
      collection: 'notes',
      id: created.id,
      context: ctx,
    );
    expect(fetched, isNotNull);
    expect(fetched!.payload['done'], isFalse);

    final patched = await env.client.patch(
      collection: 'notes',
      id: created.id,
      expectedVersion: created.version,
      patch: const RecordPatch(set: {'done': true}),
      context: ctx,
    );
    expect(patched.version, greaterThan(created.version));
    expect(patched.payload['done'], isTrue);

    final listResponse = await env.client.list(
      collection: 'notes',
      context: ctx,
    );
    expect(listResponse.records.length, 1);

    final deleted = await env.client.delete(
      collection: 'notes',
      id: created.id,
      expectedVersion: patched.version,
      context: ctx,
    );
    expect(deleted, isTrue);

    final afterDelete = await env.client.get(
      collection: 'notes',
      id: created.id,
      context: ctx,
    );
    expect(afterDelete, isNull);
  });

  test('Drift storage adapter persists records on disk', skip: skip, () async {
    Future<
        ({
          InMemoryDataServiceEnvironment env,
          DriftDataRepository repository,
        })> openEnv() async {
      final storage = DriftDataStorageAdapter.file(dbFile);
      final repository = DriftDataRepository(storage: storage);
      final env = await DataServiceFactory.inMemory(repository: repository);
      return (env: env, repository: repository);
    }

    final firstSession = await openEnv();
    final env1 = firstSession.env;
    final repo1 = firstSession.repository;
    final ctx = buildContext();

    final created = await env1.client.create(
      collection: 'tasks',
      payload: {'title': 'Persisted'},
      context: ctx,
    );
    final recordId = created.id;
    await env1.dispose();
    await repo1.storage.dispose();

    final secondSession = await openEnv();
    final env2 = secondSession.env;
    final repo2 = secondSession.repository;
    addTearDown(() async {
      await env2.dispose();
      await repo2.storage.dispose();
    });

    final fetched = await env2.client.get(
      collection: 'tasks',
      id: recordId,
      context: ctx,
    );

    expect(fetched, isNotNull);
    expect(fetched!.payload['title'], 'Persisted');
  });

  test('creates isolated tables per collection on demand', skip: skip,
      () async {
    final storage = DriftDataStorageAdapter.file(dbFile);
    final repository = DriftDataRepository(storage: storage);
    final env = await DataServiceFactory.inMemory(repository: repository);
    addTearDown(() async => repository.storage.dispose());
    addTearDown(() async => env.dispose());

    // Reading before any writes should not create a backing table.
    final empty = await storage.readCollection('drafts');
    expect(empty, isEmpty);

    final ctx = buildContext();

    await env.client.create(
      collection: 'notes',
      payload: {'title': 'One'},
      context: ctx,
    );
    await env.client.create(
      collection: 'tasks',
      payload: {'title': 'Two'},
      context: ctx,
    );

    final tables = await storage.database
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
        )
        .get();
    final tableNames = tables.map((row) => row.read<String>('name')).toList();
    expect(
      tableNames,
      containsAll(['collection_registry', 'c_notes', 'c_tasks']),
    );

    final registryRows = await storage.database
        .customSelect(
          'SELECT collection, table_name FROM collection_registry ORDER BY collection',
        )
        .get();
    final registryMap = <String, String>{
      for (final row in registryRows)
        row.read<String>('collection'): row.read<String>('table_name'),
    };
    expect(
      registryMap,
      equals({'notes': 'c_notes', 'tasks': 'c_tasks'}),
    );
  });

  test('supports multi-session clients working with many collections',
      skip: skip, () async {
    Future<
        ({
          InMemoryDataServiceEnvironment env,
          DriftDataRepository repository,
        })> startSession(String name) async {
      final storage = DriftDataStorageAdapter.file(dbFile);
      final repository = DriftDataRepository(storage: storage);
      final env = await DataServiceFactory.inMemory(
        repository: repository,
        serverLabel: 'DataResponder-$name',
        clientLabel: 'DataCaller-$name',
      );
      return (env: env, repository: repository);
    }

    final session1 = await startSession('session1');
    final env1 = session1.env;
    final repo1 = session1.repository;

    final ctxAlice = RpcContext.withHeaders({
      'authorization': 'Bearer alice',
    });
    final ctxBob = RpcContext.withHeaders({
      'authorization': 'Bearer bob',
    });
    final ctxCharlie = RpcContext.withHeaders({
      'authorization': 'Bearer charlie',
    });

    final aliceNote = await env1.client.create(
      collection: 'notes',
      payload: {
        'title': 'Product ideas',
        'owner': 'alice',
      },
      context: ctxAlice,
    );

    final bobTask = await env1.client.create(
      collection: 'tasks',
      payload: {
        'title': 'Ship drift integration',
        'status': 'pending',
        'owner': 'bob',
      },
      context: ctxBob,
    );

    final systemLog = await env1.client.create(
      collection: 'logs',
      payload: {
        'event': 'boot',
        'actor': 'system',
      },
      context: ctxCharlie,
    );

    final bobTaskPatched = await env1.client.patch(
      collection: 'tasks',
      id: bobTask.id,
      expectedVersion: bobTask.version,
      patch: const RecordPatch(set: {'status': 'done'}),
      context: ctxBob,
    );

    final notesList = await env1.client.list(
      collection: 'notes',
      context: ctxAlice,
    );
    expect(
        notesList.records.map((record) => record.id), contains(aliceNote.id));
    expect(
      notesList.records.map((record) => record.id),
      isNot(contains(bobTask.id)),
    );

    final tasksList = await env1.client.list(
      collection: 'tasks',
      context: ctxBob,
    );
    final tasksById = {
      for (final record in tasksList.records) record.id: record,
    };
    expect(tasksById[bobTask.id]!.payload['status'], 'done');

    final logsList = await env1.client.list(
      collection: 'logs',
      context: ctxCharlie,
    );
    expect(logsList.records.length, 1);
    expect(logsList.records.single.payload['event'], 'boot');

    await env1.dispose();
    await repo1.storage.dispose();

    final session2 = await startSession('session2');
    final env2 = session2.env;
    final repo2 = session2.repository;
    addTearDown(() async {
      await env2.dispose();
      await repo2.storage.dispose();
    });
    final auditCtx = RpcContext.withHeaders({
      'authorization': 'Bearer auditor',
    });

    final persistedTask = await env2.client.get(
      collection: 'tasks',
      id: bobTask.id,
      context: auditCtx,
    );
    expect(persistedTask, isNotNull);
    expect(persistedTask!.payload['status'], 'done');
    expect(persistedTask.version, bobTaskPatched.version);

    final persistedNotes = await env2.client.list(
      collection: 'notes',
      context: auditCtx,
    );
    expect(
      persistedNotes.records.map((record) => record.id),
      contains(aliceNote.id),
    );

    final persistedLog = await env2.client.get(
      collection: 'logs',
      id: systemLog.id,
      context: auditCtx,
    );
    expect(persistedLog, isNotNull);

    final metricsRecord = await env2.client.create(
      collection: 'metrics',
      payload: {
        'key': 'uptime',
        'value': 99.9,
      },
      context: auditCtx,
    );

    final metricsList = await env2.client.list(
      collection: 'metrics',
      context: auditCtx,
    );
    expect(metricsList.records.map((record) => record.id),
        contains(metricsRecord.id));

    final tables = await repo2.storage.database
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
        )
        .get();
    final tableNames = tables.map((row) => row.read<String>('name')).toList();
    expect(
      tableNames,
      containsAll(
          ['collection_registry', 'c_logs', 'c_metrics', 'c_notes', 'c_tasks']),
    );

    final registryRows = await repo2.storage.database
        .customSelect(
          'SELECT collection, table_name FROM collection_registry ORDER BY collection',
        )
        .get();
    final registry = <String, String>{
      for (final row in registryRows)
        row.read<String>('collection'): row.read<String>('table_name'),
    };
    expect(registry.keys, containsAll(['logs', 'metrics', 'notes', 'tasks']));
  });

  test('bulk upsert preserves provided record metadata', () async {
    final storage = DriftDataStorageAdapter.file(dbFile);
    final repository = DriftDataRepository(storage: storage);
    final env = await DataServiceFactory.inMemory(repository: repository);
    addTearDown(() async => repository.storage.dispose());
    addTearDown(() async => env.dispose());

    final ctx = buildContext();

    final createdAt = DateTime.utc(2024, 1, 1, 12, 0, 0);
    final initialUpdatedAt = DateTime.utc(2024, 1, 2, 12, 0, 0);
    final incoming = DataRecord(
      id: 'external-1',
      collection: 'notes',
      payload: const {'title': 'Imported note'},
      version: 3,
      createdAt: createdAt,
      updatedAt: initialUpdatedAt,
    );

    final inserted = await env.client.bulkUpsert(
      records: [incoming],
      context: ctx,
    );

    expect(inserted.single.version, 3);
    expect(inserted.single.createdAt, createdAt);
    expect(inserted.single.updatedAt, initialUpdatedAt);

    final stored = await env.client.get(
      collection: 'notes',
      id: incoming.id,
      context: ctx,
    );

    expect(stored, isNotNull);
    expect(stored!.createdAt, createdAt);
    expect(stored.updatedAt, initialUpdatedAt);
    expect(stored.version, 3);

    final newUpdatedAt = DateTime.utc(2024, 1, 3, 12, 0, 0);
    final updatedIncoming = DataRecord(
      id: incoming.id,
      collection: incoming.collection,
      payload: const {'title': 'Imported note', 'status': 'synced'},
      version: 4,
      createdAt: createdAt,
      updatedAt: newUpdatedAt,
    );

    final updated = await env.client.bulkUpsert(
      records: [updatedIncoming],
      context: ctx,
    );

    expect(updated.single.version, 4);
    expect(updated.single.createdAt, createdAt);
    expect(updated.single.updatedAt, newUpdatedAt);

    final storedUpdated = await env.client.get(
      collection: 'notes',
      id: incoming.id,
      context: ctx,
    );

    expect(storedUpdated, isNotNull);
    expect(storedUpdated!.createdAt, createdAt);
    expect(storedUpdated.updatedAt, newUpdatedAt);
    expect(storedUpdated.version, 4);
    expect(storedUpdated.payload['status'], 'synced');
  });

  test('deleteCollection drops tables and registry entries', () async {
    final storage = DriftDataStorageAdapter.file(dbFile);
    final repository = DriftDataRepository(storage: storage);
    final env = await DataServiceFactory.inMemory(repository: repository);
    addTearDown(() async => repository.storage.dispose());
    addTearDown(() async => env.dispose());

    final ctx = buildContext();

    await env.client.create(
      collection: 'archive',
      payload: {'title': 'Old note'},
      context: ctx,
    );
    await env.client.create(
      collection: 'active',
      payload: {'title': 'Fresh note'},
      context: ctx,
    );

    var tableRows = await storage.database
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
        )
        .get();
    expect(
      tableRows.map((row) => row.read<String>('name')),
      contains('c_archive'),
    );

    final deleted = await env.client.deleteCollection(
      collection: 'archive',
      context: ctx,
    );
    expect(deleted, isTrue);

    final archiveList = await env.client.list(
      collection: 'archive',
      context: ctx,
    );
    expect(archiveList.records, isEmpty);

    tableRows = await storage.database
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
        )
        .get();
    final tableNamesAfter =
        tableRows.map((row) => row.read<String>('name')).toList();
    expect(tableNamesAfter, isNot(contains('c_archive')));

    final registryRows = await storage.database.customSelect(
      'SELECT collection FROM collection_registry WHERE collection = ?',
      variables: [drift.Variable<String>('archive')],
    ).get();
    expect(registryRows, isEmpty);

    final secondDelete = await env.client.deleteCollection(
      collection: 'archive',
      context: ctx,
    );
    expect(secondDelete, isFalse);

    final activeList = await env.client.list(
      collection: 'active',
      context: ctx,
    );
    expect(activeList.records, isNotEmpty);
  });

  test('search respects cursor-based pagination', () async {
    final storage = DriftDataStorageAdapter.file(dbFile);
    final repository = DriftDataRepository(storage: storage);
    final env = await DataServiceFactory.inMemory(repository: repository);
    addTearDown(() async => repository.storage.dispose());
    addTearDown(() async => env.dispose());

    final ctx = buildContext();

    final ids = <String>{};
    for (final id in ['note-1', 'note-2', 'note-3']) {
      final record = await env.client.create(
        collection: 'notes',
        id: id,
        payload: {
          'title': 'Note $id',
          'body': 'note body $id',
        },
        context: ctx,
      );
      ids.add(record.id);
    }

    final firstPage = await env.client.search(
      collection: 'notes',
      query: 'note',
      options: const QueryOptions(limit: 2),
      context: ctx,
    );

    expect(firstPage.totalHits, 3);
    expect(firstPage.records, hasLength(2));
    expect(firstPage.nextCursor, isNotNull);
    expect(
        ids.containsAll(firstPage.records.map((record) => record.id)), isTrue);

    final secondPage = await env.client.search(
      collection: 'notes',
      query: 'note',
      options: QueryOptions(limit: 2, cursor: firstPage.nextCursor),
      context: ctx,
    );

    expect(secondPage.records, hasLength(1));
    expect(secondPage.nextCursor, isNull);
    expect(ids.contains(secondPage.records.single.id), isTrue);
    expect(
      {
        ...firstPage.records.map((record) => record.id),
        ...secondPage.records.map((record) => record.id),
      },
      equals(ids),
    );
  });
}
