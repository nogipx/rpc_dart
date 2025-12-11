# rpc_dart_blob_client_app

Flutter client for `rpc_dart_blob` that lets you browse collections, inspect blobs and upload/delete files through a simple UI.
The app can connect to WebSocket RPC endpoints or run an embedded server (in-memory or file-backed) for local demos.

## Features
- Switchable transports: WebSocket RPC endpoints or bundled in-memory server (with optional SQLite file)
- Collection browser with pagination cursor support
- Blob list with size, content type and metadata display
- Upload files with optional custom id, metadata and automatic content-type detection
- Download blobs to memory for quick verification and delete blobs with optimistic version support

## Возможности (RU)
- Подключение по WebSocket к удалённому `rpc_dart_blob` или запуск встроенного сервера с хранением в памяти либо в выбранном файле SQLite.
- Переключение коллекций и просмотр списка blob-объектов с постраничной навигацией по курсору.
- Просмотр свойств каждого blob (размер, content-type, произвольные метаданные) и загрузка содержимого в память.
- Загрузка файлов через диалог выбора с автоматическим определением MIME-типа, опциональным пользовательским ID и парой ключ-значение для метаданных.
- Удаление blob-объектов с оптимистичной проверкой версии и визуальным обновлением списка.

## Running
1. Install Flutter (3.24+ recommended).
2. From this package directory run:
   ```bash
   flutter pub get
   flutter run
   ```
3. Use the connection form to point at your `rpc_dart_blob` server via WebSocket URL. If you just want to try the
 UI, keep the **in-memory** mode enabled or pick a SQLite file to persist data across sessions.

## Notes
- The app uses path dependencies to the local `rpc_dart` packages in this mono-repo.
- File uploads rely on `file_picker`, which supports mobile, desktop, and web targets.
