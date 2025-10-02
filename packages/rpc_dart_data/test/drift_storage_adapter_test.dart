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
}
