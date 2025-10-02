import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:test/test.dart';

void main() {
  RpcContext buildContext() => RpcContext.withHeaders({
        'authorization': 'Bearer test-token',
      });

  test('Drift storage adapter supports CRUD lifecycle', () async {
    final storage = DriftDataStorageAdapter.memory();
    final repository = DriftDataRepository(storage: storage);
    final env = await DataServiceFactory.inMemory(repository: repository);
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

  test('Drift storage adapter persists records on disk', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'rpc_dart_drift_test',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final dbFile = File(p.join(tempDir.path, 'data.sqlite3'));

    Future<InMemoryDataServiceEnvironment> openEnv() async {
      final storage = DriftDataStorageAdapter.file(dbFile);
      final repository = DriftDataRepository(storage: storage);
      return DataServiceFactory.inMemory(repository: repository);
    }

    final env1 = await openEnv();
    final ctx = buildContext();

    final created = await env1.client.create(
      collection: 'tasks',
      payload: {'title': 'Persisted'},
      context: ctx,
    );
    final recordId = created.id;
    await env1.dispose();

    final env2 = await openEnv();
    addTearDown(() async => env2.dispose());

    final fetched = await env2.client.get(
      collection: 'tasks',
      id: recordId,
      context: ctx,
    );

    expect(fetched, isNotNull);
    expect(fetched!.payload['title'], 'Persisted');
  });

  test('creates isolated tables per collection on demand', () async {
    final storage = DriftDataStorageAdapter.memory();
    final repository = DriftDataRepository(storage: storage);
    final env = await DataServiceFactory.inMemory(repository: repository);
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

  test('supports multi-session clients working with many collections', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'rpc_dart_drift_integration',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final dbFile = File(p.join(tempDir.path, 'data.sqlite3'));

    Future<InMemoryDataServiceEnvironment> startSession(String name) async {
      final storage = DriftDataStorageAdapter.file(dbFile);
      final repository = DriftDataRepository(storage: storage);
      return DataServiceFactory.inMemory(
        repository: repository,
        serverLabel: 'DataResponder-$name',
        clientLabel: 'DataCaller-$name',
      );
    }

    final session1 = await startSession('session1');

    final ctxAlice = RpcContext.withHeaders({
      'authorization': 'Bearer alice',
    });
    final ctxBob = RpcContext.withHeaders({
      'authorization': 'Bearer bob',
    });
    final ctxCharlie = RpcContext.withHeaders({
      'authorization': 'Bearer charlie',
    });

    final aliceNote = await session1.client.create(
      collection: 'notes',
      payload: {
        'title': 'Product ideas',
        'owner': 'alice',
      },
      context: ctxAlice,
    );

    final bobTask = await session1.client.create(
      collection: 'tasks',
      payload: {
        'title': 'Ship drift integration',
        'status': 'pending',
        'owner': 'bob',
      },
      context: ctxBob,
    );

    final systemLog = await session1.client.create(
      collection: 'logs',
      payload: {
        'event': 'boot',
        'actor': 'system',
      },
      context: ctxCharlie,
    );

    final bobTaskPatched = await session1.client.patch(
      collection: 'tasks',
      id: bobTask.id,
      expectedVersion: bobTask.version,
      patch: const RecordPatch(set: {'status': 'done'}),
      context: ctxBob,
    );

    final notesList = await session1.client.list(
      collection: 'notes',
      context: ctxAlice,
    );
    expect(notesList.records.map((record) => record.id), contains(aliceNote.id));
    expect(
      notesList.records.map((record) => record.id),
      isNot(contains(bobTask.id)),
    );

    final tasksList = await session1.client.list(
      collection: 'tasks',
      context: ctxBob,
    );
    final tasksById = {
      for (final record in tasksList.records) record.id: record,
    };
    expect(tasksById[bobTask.id]!.payload['status'], 'done');

    final logsList = await session1.client.list(
      collection: 'logs',
      context: ctxCharlie,
    );
    expect(logsList.records.length, 1);
    expect(logsList.records.single.payload['event'], 'boot');

    await session1.dispose();

    final session2 = await startSession('session2');
    addTearDown(() async => session2.dispose());
    final auditCtx = RpcContext.withHeaders({
      'authorization': 'Bearer auditor',
    });

    final persistedTask = await session2.client.get(
      collection: 'tasks',
      id: bobTask.id,
      context: auditCtx,
    );
    expect(persistedTask, isNotNull);
    expect(persistedTask!.payload['status'], 'done');
    expect(persistedTask.version, bobTaskPatched.version);

    final persistedNotes = await session2.client.list(
      collection: 'notes',
      context: auditCtx,
    );
    expect(
      persistedNotes.records.map((record) => record.id),
      contains(aliceNote.id),
    );

    final persistedLog = await session2.client.get(
      collection: 'logs',
      id: systemLog.id,
      context: auditCtx,
    );
    expect(persistedLog, isNotNull);

    final metricsRecord = await session2.client.create(
      collection: 'metrics',
      payload: {
        'key': 'uptime',
        'value': 99.9,
      },
      context: auditCtx,
    );

    final metricsList = await session2.client.list(
      collection: 'metrics',
      context: auditCtx,
    );
    expect(metricsList.records.map((record) => record.id), contains(metricsRecord.id));

    final repository2 = session2.server.repository as DriftDataRepository;
    final tables = await repository2.storage.database
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
        )
        .get();
    final tableNames = tables.map((row) => row.read<String>('name')).toList();
    expect(
      tableNames,
      containsAll(['collection_registry', 'c_logs', 'c_metrics', 'c_notes', 'c_tasks']),
    );

    final registryRows = await repository2.storage.database
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
}
