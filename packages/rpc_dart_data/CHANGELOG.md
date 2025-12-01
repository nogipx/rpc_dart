## 2.2.1

- Web: fixed dart2js/wasm build failures by parsing 64-bit FNV constants as `BigInt`, keeping stable index-name hashes without exceeding JS number precision.

## 2.2.0

- Breaking: removed `tenantId` from `DataRecord`, adapters, and SQLite schema/indexing. Multi-tenant isolation now belongs to higher layers; table footprint and indexes are smaller.
- Correct optimistic locking: SQLite writes now use conditional INSERT/UPDATE/DELETE (version-guarded upsert, version-aware delete) and surface `RpcDataError.conflict` when the incoming version is stale. Bulk upsert detects per-record conflicts.
- SQLite search ranks by relevance (`bm25`) then `id`, fixing alphabetical ordering, and `RecordFilter.containsTerms` is supported for parity with in-memory adapter.
- Delete APIs accept `expectedVersion` end-to-end (storage + repository) to prevent stale deletions.

## 2.1.1

- Expanded `IDataService` API docs in English with detailed semantics for pagination, optimistic locking, bulk ops, exports/imports, search/aggregate, indexes, change streams, offline sync, and shutdown guidance.
- Breaking: `DataServiceCaller`, `DataServiceResponder`, and the facade/server factories now require an explicit `RpcDataTransferMode` in constructors; wire this through when instantiating clients/servers.

## 2.1.0

- SQLCipher: when a `SqlCipherKey` is provided, the library now automatically overrides the loaded SQLite binary on macOS/Linux to use SQLCipher (`SQLITE3_LIB_DIR`/`SQLITE3_LIB_NAME` or common Homebrew paths) before opening the database; still fails fast when cipher pragmas are missing so encrypted DBs can’t silently fall back to plaintext.
- Web: switched the WASM loader to `sqlite3mc.wasm` (SQLite3MultipleCiphers) by default so cipher-enabled builds work consistently across platforms; still respects a custom `webSqliteWasmUri` if supplied.
- Refined SQLCipher helpers and tests to support repeated open/close cycles on the same encrypted file (idempotent table creation, stable paths).

## 2.0.0

- Added `ListCollectionsRequest/ListCollectionsResponse` plus RPC support (`IDataServiceContract`, caller, responder, `IDataService`) so remote clients can ask “what collections exist?” without scanning data manually.
- Extended repositories/adapters with `listCollections()` and wired the RPC integration test to cover the new flow, ensuring collection names come straight from storage.
- Broadened RPC coverage by refactoring codecs, contracts, and facades while introducing suites for change journals, models, JSON helpers, SQLite/daemon helpers, SQLCipher, and RPC authorization/exception paths—lifting previously low coverage areas.
- Confirmed `SqliteDataStorageAdapter` already provides FTS5 and exposes `SqliteSetupHook` so callers can enable WAL/PRAGMA hooks before traffic hits the database.
- Documented that `SqliteDataDatabase.transaction` wraps `BEGIN/COMMIT/ROLLBACK`, giving true SQLite transactions for batch updates and journaled change streams.
- Removed the `drift` and `rpc_dart_transports` runtime dependencies to keep the package lean—everything now routes through the core storage adapters and RPC helpers already shipped here.

## 1.2.0

- Added streaming NDJSON exports with `payloadStream` plus the ability to skip the in-memory
  string via `ExportDatabaseRequest(includePayloadString: false)`. Export now prefetches
  collection chunks and respects consumer backpressure.
- Imports validate the snapshot stream before mutating data and process records in
  `databaseImportBatchSize` chunks, which keeps memory flat even for very large dumps.
- `DataServiceClient` gained high-level helpers: `listAllRecords`, `bulkUpsertStream`,
  `pushAndAwaitAck`, `createOfflineQueue`, and `close`.
- Storage adapters can expose custom SQLite setup logic through `SqliteSetupHook`, and
  the SQLite adapter batches UPSERT statements plus supports chunked `readRecords` to reduce I/O.
- Introduced `RpcStreamIterator` (based on `StreamQueue`) so all streaming exports respect
  consumer demand.
- Documentation rewritten in English and aligned with the new streaming/offline features.

## 1.1.0

- Добавлен персистентный журнал изменений для `watch()` и `sync()` с поддержкой
  восстановления курсоров после рестарта.
- SQLite-хранилище научилось создавать индексы, выполнять фильтрацию и
  пагинацию на стороне SQL, а также использовать SQLCipher-ключ из PASERK.
- Для подготовки multi-tenant сценариев таблицы коллекций теперь включают
  столбец `tenantId` с индексом и поддержкой фильтрации/сортировки.
- CLI `serve` объединён в универсальный `ServeCli` с поддержкой SQLCipher,
  SecureWrap и белых списков bearer-токенов для backend-сценариев.
- README уточняет, что прямой доступ конечных клиентов не поддерживается
  из коробки: сервис предполагает работу через доверенный backend.
- Добавлено руководство по изоляции данных между клиентами (tenant-ами)
  при backend-only использовании, включая рекомендации по производительности
  при использовании отдельных коллекций.

## 1.0.0

- Initial version.
