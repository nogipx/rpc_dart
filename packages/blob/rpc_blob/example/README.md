<!--
SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# InMemoryBlobRepository Example

Этот пример демонстрирует использование `InMemoryBlobRepository` — реализации `IBlobRepository` для хранения бинарных данных в памяти.

## Особенности

- **In-Memory хранение**: Данные хранятся в памяти без использования файловой системы или БД
- **Полная реализация IBlobRepository**: Поддержка всех операций blob-хранилища
- **Оптимистическая блокировка**: Поддержка версионирования через `expectedVersion`
- **Потоковая передача**: Данные передаются потоками для эффективности
- **Проверка контрольных сумм**: SHA256 валидация данных
- **Pagination и фильтрация**: Поддержка пагинации и префиксной фильтрации при листинге
- **Range-запросы**: Чтение части данных blob

## Использование

### Базовый пример

```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:rpc_blob/rpc_blob.dart';

final repository = InMemoryBlobRepository();

// Запись blob
final data = Uint8List.fromList(utf8.encode('Hello, World!'));
final result = await repository.writeBlob(
  BlobWriteRequest(
    collection: 'documents',
    id: 'hello.txt',
    bytes: Stream.value(data),
    contentType: 'text/plain',
  ),
);

// Чтение метаданных
final descriptor = await repository.headBlob('documents', 'hello.txt');

// Чтение данных
final readResult = await repository.readBlob(
  BlobReadRequest(collection: 'documents', id: 'hello.txt'),
);
final content = await readResult!.bytes.collectBytes();

// Удаление
await repository.deleteBlob('documents', 'hello.txt');

// Закрытие
await repository.dispose();
```

## Запуск примера

```bash
cd packages/rpc_blob
dart run example/in_memory_example.dart
```

## Тестирование

```bash
cd packages/rpc_blob
dart test test/in_memory_blob_repository_test.dart
```

## Сравнение с другими реализациями

| Реализация | Хранилище | Использование | Персистентность |
|-----------|-----------|---------------|----------------|
| `InMemoryBlobRepository` | RAM | Тестирование, временное хранение | Нет |
| `SqliteBlobRepository` | SQLite DB | Локальное хранение, embedded | Да |
| `S3BlobRepository` | S3/MinIO | Production, распределенное хранилище | Да |

## Параметры конструктора

- **maxBlobBytes**: Максимальный размер одного blob (optional)
- **readChunkBytes**: Размер чанка при потоковом чтении (default: 256KB)
- **clock**: Функция для получения времени (для тестирования)

```dart
final repository = InMemoryBlobRepository(
  maxBlobBytes: 10 * 1024 * 1024, // 10MB лимит
  readChunkBytes: 512 * 1024,      // 512KB чанки
);
```