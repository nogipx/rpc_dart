# rpc_dart_blob: функциональный набросок

Цель: отдельный сервис для блобов (картинки/файлы), совместимый по стилю с `rpc_dart_data`, но оптимизированный под бинарные стримы и хранения вне JSON.

## Контракт (RPC)
- Service: `BlobService`.
- Методы:
  - `putBlob`: client-stream, принимает `BlobUploadChunk` (первый кадр несёт метаданные). Поддержка `expectedVersion`, `checksum`, `totalLength`, `contentType`, `metadata`.
  - `getBlob`: server-stream, принимает `GetBlobRequest` (опц. range) и отдаёт `BlobDownloadFrame` (первый кадр может включать `BlobDescriptor`).
  - `headBlob`: unary → `BlobDescriptor?`.
  - `deleteBlob`: unary с опц. `expectedVersion`.
  - `listBlobs`: unary, пагинация `cursor/limit`, опц. `prefix` и флаг `includeMetadata`.

## Формат кадров
- Сейчас в моделях кадры base64, чтобы работать через текстовые кодеки rpc_dart; целевое состояние — бинарные payload-кадры при наличии двоичного транспорта (WebSocket bin, HTTP/2 DATA). Нужно держать совместимость:
  - v1: base64 + JSON кадр.
  - v2: negotiated binary frame (header + bytes), обратно совместимый флаг/transferMode.
  - Range-ответы возвращают `rangeStart/rangeEnd` в `BlobDownloadFrame` + `Content-Range` аналоги в метаданных.

## Метаданные и версия
- `BlobDescriptor`: `id`, `collection`, `length`, `version`, `createdAt/updatedAt`, `contentType?`, `checksum?`, `metadata: Map<String,String>`.
- Optimistic concurrency: `expectedVersion` в `putBlob`/`deleteBlob`. Версия автоинкремент.
- `id` может приходить от клиента либо генериться на сервере (UUID). В `putBlob` первый chunk содержит `blobId`; если пустой, сервер генерирует и возвращает.

## Хранилища (IBlobStorageAdapter)
- Интерфейс: `headBlob`, `readBlob(range)`, `writeBlob`, `deleteBlob`, `listBlobs`, `dispose`.
- Реализации (MVP):
  1) `SqliteBlobStorageAdapter` — dev/тест, хранит `payload BLOB`, `content_type`, `length`, `checksum`, индексы по `updated_at`. Файл БД отдельный от rpc_dart_data.
  2) `FsBlobStorageAdapter` — хранит байты на диске (layout `/collection/id`), метаданные в маленьком index-файле/SQLite.
  3) (позже) `S3BlobStorageAdapter`/minio — ставит presigned PUT/GET, но оставляет контракт прежним.

### SqliteBlobStorageAdapter детали
- Зависит от `sqlite3: ^3.1.1`, использует `journal_mode=WAL`.
- Пер-collection таблицы: имя нормализуется по названию коллекции (реестр в `blob_collections`), каждая коллекция получает собственную таблицу с индексом `(collection, updated_at DESC, id)`, что изолирует вакуум/бэкап и уменьшает конкуренцию индекса.
- Схема таблицы: `collection`, `id`, `version`, `length`, `content_type`, `checksum`, `metadata JSON`, `created_at`, `updated_at`, `deleted_at`, `payload BLOB` (PK `(collection,id)`).
- Операции: upsert с проверкой `expectedVersion`, чтение целиком или `substr` по диапазону, листинг с курсором (`base64(updated_at|id)`), удаление с опц. проверкой версии.
- Ограничения: опция `maxBlobBytes`, проверка `checksum` (sha256) при записи, валидация длины `declaredLength`.
- Требования: потоковая запись/чтение (не буферить целиком), контроль длины/чексуммы, диапазоны (range) если бэкенд поддерживает.

## Валидация и безопасность
- Проверка `totalLength` и фактических байт, опциональная проверка `checksum` (sha256).
- Лимиты: max blob size (конфиг), max chunk size (конфиг).
- Auth: опция allowed tokens как в `DataServiceResponder`, либо передача `RpcContext` в сервисную реализацию (пользователь сам проверяет).

## Экспорт/импорт и бэкапы
- Отдельный поток от `rpc_dart_data`: формат “header frame (descriptor) + бинарные чанки” в одном стриме; можно сжать/тарить. Не base64.
- CLI-хелпер может собирать tar-подобный архив (metadata.json + files).

## Интеграция
- Пакет самодостаточен и не зависит от `rpc_dart_data`. При желании приложения могут хранить ссылки на blob-id в своих данных, но blob-сервис живёт отдельно (свои контракты, БД, адаптеры).

## Тестирование
- In-memory/fs/sqlite адаптеры с предсказуемыми ID для тестов.
- Проверки: частичный upload (ошибка по checksum/length), range downloads, optimistic conflict, список с курсором.

## Минимальный roadmap
1) MVP: каркас (готов), `FsBlobStorageAdapter`, простой `BlobService` (без auth), base64 кадры.
2) SQLite dev adapter + unit-тесты.
3) Бинарное фреймирование, range поддержка, checksum валидация.
4) S3/minio adapter, GC-утилита, экспорт/импорт (tar/stream).
