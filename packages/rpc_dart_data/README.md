# rpc_dart_data

Transport-agnostic data layer (CRUD, queries, change streams) on top of [`rpc_dart`](https://pub.dev/packages/rpc_dart) with ready-made adapters and schema-aware tooling.

## What you get
- Unified `DataService` contract: create/get/list/update/patch/delete/deleteCollection, `bulkUpsert`/`bulkUpsertStream`/`bulkDelete`, search, `listAllRecords`, change streams, NDJSON export/import.
- Typed collection helper: `DataServieCollection`/`IDataServiceCollection` wraps a single collection with parsed models and change streams.
- Schema registry + migrations per collection, validation on all writes/imports, optimistic concurrency on update/patch/delete.
- Cursor-friendly pagination (keyset by default, offset when requested) with server-side filters/sort/search.
- Ready environments: `DataServiceFactory.inMemory` plus SQLite/PostgreSQL repositories; SQLite supports SQLCipher out of the box.
- Collection discovery via `listCollections`; schema RPCs to inspect and toggle policy.

## Adapters
- **SQLite**: SQLCipher via sqlite3mc (no system lib needed); web defaults to OPFS (fallback IndexedDB → in-memory); `SqliteSetupHook` for pragmas; durable change journal for `watchChanges`.
- **PostgreSQL**: one JSONB table per collection with server-side filters/sort/pagination/FTS (GIN over `to_tsvector`) and optimistic concurrency.

## Quick start
```dart
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';

Future<void> main() async {
  final env = await DataServiceFactory.inMemory();
  final client = env.client;
  final ctx = RpcContext.withHeaders({'authorization': 'Bearer dev'});

  final created = await client.create(
    collection: 'notes',
    payload: {'title': 'Hello', 'done': false},
    context: ctx,
  );

  final sub = client
      .watchChanges(collection: 'notes', context: ctx)
      .listen((event) => print('change=${event.type} id=${event.id} v=${event.version}'));

  await client.patch(
    collection: 'notes',
    id: created.id,
    expectedVersion: created.version,
    patch: const RecordPatch(set: {'done': true}),
    context: ctx,
  );

  await Future<void>.delayed(const Duration(milliseconds: 50));
  await sub.cancel();
  await env.dispose();
}
```

See `example/example.dart` for a fuller SQLite walkthrough (schema validation, migrations, optimistic locking, NDJSON export):
```bash
dart run example/example.dart
```

## Streaming export and import
`IDataRepository.exportDatabase` / `DataServiceClient.exportDatabase` is a server-stream of NDJSON chunks (`header`, `schema`, `collection`, `record`, `collectionEnd`, `footer`) encoded as UTF-8 (`Uint8List`). Each chunk has a monotonically increasing `chunkIndex`.

`importDatabase` is bidirectional: the client streams NDJSON chunks, the server streams ACKs with the last applied `chunkIndex` (batched every few chunks to reduce chatter). On transport errors/timeouts the client throws `ImportResumeException(lastChunkIndex: x)`, so you can retry from `resumeAfterChunk=x` using the same dump. Imports validate the stream before writes, run in `databaseImportBatchSize` chunks, and when `replaceExisting` is `true` they drop collections missing from the snapshot.

```dart
// Export
await for (final chunk in client.exportDatabase()) {
  sink.add(chunk); // write bytes to file/socket/etc
}

// Import with automatic resume (Stream<Uint8List> of NDJSON lines)
final dump = await client.exportDatabase().toList();
var resumeAfter = -1;
while (true) {
  try {
    final result = await client.importDatabase(
      payload: Stream<Uint8List>.fromIterable(dump),
      replaceExisting: true,
      resumeAfterChunk: resumeAfter,
    );
    print(
      'restored ${result.recordCount} records at chunk ${result.lastChunkIndex}',
    );
    break;
  } on ImportResumeException catch (error) {
    // Transport dropped mid-stream; retry from the last ACKed chunk.
    resumeAfter = error.lastChunkIndex ?? -1;
  }
}
```

Legacy JSON blobs are no longer accepted; always stream NDJSON.

## Schema validation and migrations
- Defaults: schemas enabled + validation required; toggle per collection via `setSchemaPolicy`.
- Register migrations with `MigrationPlan`/`MigrationRunnerHelper`; activation rebuilds indexes/FTS and checkpoints progress.
- Schemas use a JSON Schema–style subset; see the example below for all supported keywords.

Minimal wiring:
```dart
final storage = await SqliteDataStorageAdapter.memory();
final repo = SqliteDataRepository(storage: storage);
final migrations = MigrationPlan.forCollection('notes')
    .initial(
      migrationId: 'notes_init_v1',
      toVersion: 1,
      schema: {
        // All supported schema keywords in one place:
        // type/enum/required/properties, string guards (minLength/maxLength/pattern),
        // number guards (minimum/maximum), array guards (items/minItems/maxItems).
        // Advanced JSON Schema features (oneOf/anyOf/allOf/$ref/additionalProperties/
        // uniqueItems/multipleOf/exclusive*/format) are not implemented.
        'type': 'object',
        'required': ['title', 'rating', 'meta', 'tags', 'misc'],
        'properties': {
          'title': {'type': 'string', 'minLength': 1, 'maxLength': 140},
          'done': {'type': 'boolean'},
          'tags': {
            'type': 'array',
            'items': {'type': 'string', 'pattern': r'^[a-z0-9_-]+$'},
            'minItems': 0,
            'maxItems': 8,
          },
          'rating': {'type': 'number', 'minimum': 0, 'maximum': 1},
          'meta': {
            'type': 'object',
            'required': ['priority', 'archived', 'kind'],
            'properties': {
              'priority': {'type': 'integer', 'minimum': 1, 'maximum': 5},
              'archived': {'type': 'boolean'},
              'kind': {'type': 'string', 'enum': ['note', 'task', 'idea']},
            },
          },
          'misc': {
            'type': 'array',
            'items': {
              'type': 'object',
              'required': ['id', 'value'],
              'properties': {
                'id': {'type': 'string'},
                'value': {'type': 'null'},
              },
            },
            'minItems': 0,
          },
        },
      },
    )
    .build();
await MigrationRunnerHelper(repository: repo, migrations: migrations)
    .applyPendingMigrations();
```

## Extending storage
Implement `IDataStorageAdapter` (and optionally `ICollectionIndexStorageAdapter`) to back the repository with your own store; the RPC surface stays the same.

## License
[MIT](LICENSE)
