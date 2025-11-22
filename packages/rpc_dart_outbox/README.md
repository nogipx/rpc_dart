# rpc_dart_outbox

Плагин для outbox-паттерна поверх `rpc_dart` и `rpc_dart_data`. Он
предоставляет простой репозиторий для записи событий, их бронирования
воркерами и подтверждения доставки.

> Библиотека ориентирована на повторное использование: хранение
> реализовано через `IDataRepository` из `rpc_dart_data`, поэтому можно
> использовать InMemory/SQLite/кастомные адаптеры без изменения API.

## Быстрый старт

```dart
import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:rpc_dart_outbox/rpc_dart_outbox.dart';

void main() async {
  final data = InMemoryDataRepository();
  final outbox = OutboxRepository(repository: data);

  await outbox.enqueue(payload: {'type': 'email', 'userId': '123'});

  final jobs = await outbox.claim(limit: 1);
  // отправляем письмо
  await outbox.acknowledge(jobs.first.id);
}
```

## Возможности
- Дедупликация по `dedupKey`.
- claim с блокировкой и счетчиком попыток.
- Перевод задач в `delivered`, `failed` или повторная постановка через
  `retryLater`.

## Тесты

```
dart test packages/rpc_dart_outbox
```
