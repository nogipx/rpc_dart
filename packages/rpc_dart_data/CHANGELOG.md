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
