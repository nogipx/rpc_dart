# rpc_dart_data

`rpc_dart_data` is the high-level data layer (CRUD + queries + change streams + offline sync) that sits on top of [`rpc_dart`](https://pub.dev/packages/rpc_dart).
It gives you a transport-agnostic contract, ready-to-use storage adapters, and utilities for building offline-friendly backends and clients.

## Feature highlights
- **Unified `DataService` contract** with helpers for create/get/list/update/patch/delete/deleteCollection.
- **Bulk workflows** via `bulkUpsert`, `bulkUpsertStream`, and `bulkDelete` to move large batches atomically.
- **Search & aggregations** (`search`, `aggregate`) delegated to the storage adapter, including backend pagination.
- **Streaming snapshots**: export/import the full database as NDJSON, stream it through `payloadStream`, or set `includePayloadString: false` to skip building large strings.
- **Change streams & offline sync**: `watchChanges` with cursors, bidirectional `syncChanges`, and `OfflineCommandQueue` for durable command queues.
- **Schema validation & migrations**: per-collection schema registry (nested objects/arrays), validation on all write/import RPCs, optional `skipValidation` for admin paths. Server-side migrations with checkpoints/logs and automatic index/FTS rebuilds after success; migrations are bound to a collection and run via repository helpers.
- **SQLite adapter** with SQLCipher support out-of-the-box via SQLite3MultipleCiphers (`hooks.user_defines.sqlite3.source: sqlite3mc`), no system `libsqlcipher` needed; web uses `sqlite3mc.wasm`. `SqliteSetupHook` lets you register custom pragmas before the database is exposed to your code.
- Pass a `SqlCipherKey` to enable encryption; the runtime fails fast if cipher pragmas are missing.
- **Ready-made environments** (`DataServiceFactory.inMemory`) for tests, demos, and local prototyping.
- **Collection discovery**: RPC `listCollections()` queries the storage adapter for the current list of collection names so clients can introspect available datasets without enumerating all records.

## Architecture in seven layers
1. **Transport** (WebSocket / HTTP/2 / isolates / TURN / in-memory) provided by `rpc_dart` implementations (you can plug in any `IRpcTransport`; this package now relies on the transports shipped by `rpc_dart` instead of bundling `rpc_dart_transports` directly).
2. **Endpoint** (`RpcCallerEndpoint` / `RpcResponderEndpoint`).
3. **Contract + codecs** (`IDataServiceContract` and `RpcCodec<...>`).
4. **Low-level plumbing** (`DataServiceCaller` / `DataServiceResponder`).
5. **Repository + storage adapter** (`BaseDataRepository`, change journal, and the concrete adapter: in-memory or SQLite).
6. **Facade** (`DataServiceClient`, `DataServiceServer`, `DataServiceFactory`, `InMemoryDataServiceEnvironment`).
7. **Offline utilities** such as `OfflineCommandQueue` and reconnection helpers.

Consumers usually interact only with layer 6 while everything below stays private.

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
See `example/extended_demo.dart` for a larger walkthrough.

## Streaming export and import
`DataRepository.exportDatabase` writes every snapshot as newline-delimited JSON (NDJSON).
Each line contains a `header`, `collection`, `record`, `collectionEnd`, or `footer` entry. You can either:

- Work with the whole payload as a string (default), or
- Set `ExportDatabaseRequest(includePayloadString: false)` and consume the `payloadStream` to keep memory flat while sending it over the wire.

Imports accept the same format. When `replaceExisting` is `true`, missing collections are removed and re-created so the target repository matches the snapshot exactly. Legacy JSON (format version 1.0.0) is still accepted for backward compatibility, but it requires loading the entire blob in memory first.

`ImportDatabaseRequest` always validates the snapshot stream before mutating any collections, and the importer processes records in `databaseImportBatchSize` chunks, so very large dumps no longer spike RAM usage.

### Example: piping exported data
```dart
final export = await repository.exportDatabase(
  const ExportDatabaseRequest(includePayloadString: false),
);
await for (final chunk in export.payloadStream!) {
  sink.add(chunk); // write to file/socket/etc
}
```

## Schema validation and migrations
- Per-collection schemas (nested objects/arrays) live in a registry; validation runs on create/update/patch/bulk/import over RPC unless `skipValidation=true` (admin-only).
- Default policy is controlled via `SchemaValidationConfig(defaultSchemaEnabled, defaultRequireValidation)`; per-collection overrides use `setSchemaPolicy`.
- Migrations are server-side only: register declarative steps with `MigrationDefinition` (bound to a `collection`) and run them via `MigrationRunnerHelper` or `SqliteDataRepository.runMigration`. Migration success activates the new schema and rebuilds indexes/FTS; any errors keep the checkpoint and block activation.

Minimal server-side wiring:
```dart
final storage = await SqliteDataStorageAdapter.memory();
final repo = SqliteDataRepository(storage: storage);
final migrations = MigrationPlan.forCollection('notes')
  .initial(
    migrationId: 'notes_init_v1',
    toVersion: 1,
    schema: {
      'type': 'object',
      'required': ['title'],
      'properties': {
        'title': {'type': 'string'},
      },
    },
  )
  .next(
    migrationId: 'notes_add_slug_v2',
    toVersion: 2,
    schema: {
      'type': 'object',
      'required': ['title', 'slug'],
      'properties': {
        'title': {'type': 'string'},
        'slug': {'type': 'string'},
      },
    },
    transformer: (payload) => {...payload, 'slug': (payload['title'] as String).toLowerCase()},
  )
  .build();

final helper = MigrationRunnerHelper(
  repository: repo,
  migrations: migrations,
);
await helper.applyPendingMigrations(); // idempotent across restarts; checkpoints are persisted.
```

## Offline queue and sync commands
```dart
final env = await DataServiceFactory.inMemory();
final client = env.client;
final ctx = RpcContext.withHeaders({'authorization': 'Bearer x'});
final queue = client.createOfflineQueue(sessionId: 'device-1');

final command = queue.buildCreateCommand(
  const CreateRecordRequest(collection: 'tasks', payload: {'title': 'Draft'}),
);
final persistedJson = command.toJson();

final ackFuture = queue.enqueueCommand(
  DataCommand.fromJson(persistedJson),
  autoStart: false,
  context: ctx,
);
await queue.start(context: ctx);
await queue.flushPending();
final ack = await ackFuture;
print('applied=${ack.applied} id=${ack.record?.id}');
```
Use `enqueueCommand(..., resolveConflicts: false)` if you prefer the queue to stop on conflicts instead of retrying automatically.

`DataServiceClient` now includes:
- `listAllRecords` – paginates through `list()` until the entire collection is in memory.
- `bulkUpsertStream` – streams large batches directly to the repository.
- `pushAndAwaitAck` – sends a single sync command and waits for the response.
- `createOfflineQueue` – a convenience constructor for `OfflineCommandQueue`.
- `close` – shuts down the underlying RPC endpoint.

## Aggregations
```dart
final metrics = await client.aggregate(
  collection: 'orders',
  metrics: {
    'countAll': 'count',
    'sumPrice': 'sum:price',
    'avgPrice': 'avg:price',
    'minPrice': 'min:price',
    'maxPrice': 'max:price',
  },
  context: ctx,
);
print(metrics.metrics);
```
The repository validates metric expressions and delegates supported work to the storage adapter.

## Change streams and optimistic concurrency
- `watchChanges` accepts an optional `cursor`, so clients can resume after a reconnect.
- SQLite keeps a persistent `s_change_journal` table, allowing cursors to survive restarts.
- `update` and `patch` require an `expectedVersion`. A mismatch triggers `RpcDataError.conflict(...)` (or a transport `RpcException`).

## Listing collections
Call `DataServiceClient.listCollections()` to retrieve the current catalog of collection names without enumerating records.

```dart
final collections = await client.listCollections(context: ctx);
print('collections: ${collections.join(', ')}');
```

The RPC experience simply forwards to `DataStorageAdapter.listCollections()`, so the result reflects whatever tables your adapter created.

## Extending the storage layer
Implement `DataStorageAdapter` to plug in any backend (PostgreSQL, Elastic, Firestore, ...):
```dart
class PostgresAdapter implements DataStorageAdapter {
  @override
  Future<DataRecord?> readRecord(String collection, String id) async {
    // Query your store and return DataRecord when a row exists.
  }

  @override
  Future<ListRecordsResponse> queryCollection(ListRecordsRequest request) async {
    // Apply filters + pagination server-side.
  }

  // Implement searchCollection, aggregateCollection, writeRecords, deleteCollection, etc.
}
```
Adapters participate in streaming export/import by overriding `readCollectionChunks`, and they can expose custom indices via `CollectionIndexStorageAdapter` if needed.

## SQLite profile
`SqliteDataStorageAdapter` ships as the default single-node implementation:
- Creates per-collection tables on demand plus indexes on `version`, `created_at`, and `updated_at`.
- Delegates filtering, sorting, and pagination to SQL for predictable O(log N) plans.
- Uses batched UPSERT statements to keep `writeRecords` fast even when thousands of rows are updated.
- SQLCipher:
  - Pass a `SqlCipherKey` to enable encryption; the runtime will auto-load `libsqlcipher` on macOS/Linux (checks `SQLITE3_LIB_DIR`/`SQLITE3_LIB_NAME` or common Homebrew paths) before opening the database and will fail fast if cipher pragmas are missing.
  - On the web, the adapter uses the `sqlite3mc.wasm` build (SQLite3MultipleCiphers) by default; set `webSqliteWasmUri` to a custom location if you host your own WASM.
  - You can still register extra PRAGMA via `SqliteSetupHook` for fine-tuning.
- Stores `watch()` / `sync()` events in a durable journal, so cursor-based clients recover after restarts.

## License
[MIT](LICENSE)
