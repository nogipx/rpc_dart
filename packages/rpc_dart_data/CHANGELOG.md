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
