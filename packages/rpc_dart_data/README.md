<!-- 
This README describes the package. If you publish this package to pub.dev,
this README's contents appear on the landing page for your package.

For information about how to write a good package README, see the guide for
[writing package pages](https://dart.dev/tools/pub/writing-package-pages). 

For general information about developing packages, see the Dart guide for
[creating packages](https://dart.dev/guides/libraries/create-packages)
and the Flutter guide for
[developing packages and plugins](https://flutter.dev/to/develop-packages). 
-->

# rpc_dart_data

Высокоуровневый слой данных (CRUD + запросы + стримы + офлайн синхронизация) поверх `rpc_dart`. Предоставляет:

- Универсальный контракт `DataService` (create/get/list/update/patch/delete)
- Пакетные операции: bulkUpsert / bulkDelete
- Поиск и метрики: search + aggregate (count / sum / avg / min / max)
- Экспорт снимка коллекции (snapshot)
- Реактивные изменения: watchChanges с курсорами
- Offline-first: двунаправленный syncChanges + очередь команд `OfflineCommandQueue`
- Оптимистичная конкуренция через версии записей
- Авторизация через заголовок `authorization: Bearer ...`

## Архитектура (слои)
1. Transport (WebSocket / HTTP2 / isolate / TURN / in-memory) из `rpc_dart_transports`
2. Endpoint (`RpcCallerEndpoint` / `RpcResponderEndpoint`)
3. Контракт + кодеки (`IDataServiceContract` + RpcCodec<...>)
4. Низкоуровневый слой (DataServiceCaller / DataServiceResponder)
5. Repository + StorageAdapter (бизнес-логика + журнал событий)
6. Фасад (DataServiceClient / DataServiceServer / DataServiceFactory / InMemoryDataServiceEnvironment)
7. Утилиты офлайн (`OfflineCommandQueue`)

Вы переиспользуете 6-й уровень — остальное скрывается.

## Быстрый старт
```dart
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';

Future<void> main() async {
  final env = await DataServiceFactory.inMemory();
  final client = env.client;
  final ctx = RpcContext.withHeaders({'authorization': 'Bearer dev'});

  final rec = await client.create(
    collection: 'notes',
    payload: {'title': 'Hello', 'done': false},
    context: ctx,
  );

  final watchSub = client
      .watchChanges(collection: 'notes', context: ctx)
      .listen((e) => print('Change: ${e.type} id=${e.id} v=${e.version}'));

  await client.patch(
    collection: 'notes',
    id: rec.id,
    expectedVersion: rec.version,
    patch: const RecordPatch(set: {'done': true}),
    context: ctx,
  );

  await Future<void>.delayed(const Duration(milliseconds: 50));
  await watchSub.cancel();
  await env.dispose();
}
```
Полный пример см. `example/extended_demo.dart`.

## Offline очередь и синхронизация
```dart
final env = await DataServiceFactory.inMemory();
final client = env.client;
final ctx = RpcContext.withHeaders({'authorization':'Bearer x'});
final queue = OfflineCommandQueue(client.rawCaller, sessionId: 'device-1');

// Локально (офлайн) формируем команду create и сериализуем
final cmd = queue.buildCreateCommand(
  const CreateRecordRequest(collection: 'tasks', payload: {'title':'Draft'}),
);
final json = cmd.toJson();

// Позже (онлайн) восстанавливаем и отправляем
final ackFuture = queue.enqueueCommand(DataCommand.fromJson(json), autoStart: false, context: ctx);
await queue.start(context: ctx);
await queue.flushPending();
final ack = await ackFuture;
print('Applied=${ack.applied} id=${ack.record?.id}');
```
Используйте `resolveConflicts=false` в `enqueueCommand` если хотите падать при конфликте, иначе придёт `conflict` + `error` в ответе и команда не будет выброшена.

## Агрегаты
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

## Стрим изменений
`watchChanges` принимает опциональный `cursor` — можно продолжить с точки останова. История держится в памяти базовой реализацией; для production замените на persistent/event sourced storage.

## Конфликты
- `update` требует `expectedVersion`, совпадающий с текущей версией записи.
- `patch` требует точного совпадения `expectedVersion`.
- При нарушении получите `RpcDataError.conflict(...)` (или базовый `RpcException`, если перешло через границу транспорта), в офлайн sync — `SyncChangeResponse(applied=false, conflict=...)`.

## Расширение / кастомное хранилище
Реализуйте `DataStorageAdapter`:
```dart
class PostgresAdapter implements DataStorageAdapter {
  // readRecord, writeRecord, deleteRecord, ... собственная реализация
  @override Future<DataRecord?> readRecord(String collection, String id) async { /* ... */ }
  // остальные методы
  @override Future<void> dispose() async {}
}

final repo = InMemoryDataRepository(storage: InMemoryStorageAdapter()); // по умолчанию
// или свой:
final server = DataServiceFactory.createServer(
  transport: myTransport,
  repository: InMemoryDataRepository(storage: /* ваш адаптер */),
);
```

## Drift + SQLite хранилище
Пакет включает готовый адаптер `DriftDataStorageAdapter`, который хранит записи в SQLite
через [drift](https://drift.simonbinder.eu/). Его можно использовать как in-memory БД или
persisted файл:

```dart
final storage = DriftDataStorageAdapter.file(File('data.sqlite3'));
final repository = DriftDataRepository(storage: storage);
final env = await DataServiceFactory.inMemory(repository: repository);

final ctx = RpcContext.withHeaders({'authorization': 'Bearer demo'});
await env.client.create(collection: 'notes', payload: {'title': 'Hello'}, context: ctx);
```

Для тестов или демо можно использовать in-memory вариант:

```dart
final storage = DriftDataStorageAdapter.memory();
```

При вызове `dispose()` на репозитории/сервисе подключение к SQLite закрывается автоматически.

Каждая коллекция хранится в отдельной таблице. Адаптер автоматически регистрирует коллекцию
в служебной таблице `collection_registry` и создаёт dedicated-таблицу при первой записи.
Имя таблицы генерируется из названия коллекции: символы за пределами `[a-zA-Z0-9_]`
нормализуются. Это позволяет держать коллекции изолированно и упрощает бэкапы/миграции:

```text
sqlite> .tables
collection_registry   c_notes   c_tasks
```

Чтение из ещё не созданной коллекции вернёт пустой список и не создаст таблицу, пока не
произойдёт первая запись.

## Тесты
Рекомендуем smoke тест (пример добавлен в `test/data_service_facade_test.dart`).
Запуск:
```bash
dart test --concurrency=1 -r compact
```

## Примеры
- `example/quick_start.dart` — минимальный
- `example/offline_sync.dart` — офлайн очередь
- `example/extended_demo.dart` — полный сценарий

## Планы / идеи
- Плагинные политики разрешения конфликтов (last-write-wins, merge payload)
- Расширяемая система индексов/поиска
- Persisted journal для watch/rewind
- Production адаптеры (SQLite / Isar / Postgres)

## Лицензия
См. LICENSE (наследует лицензионную политику родительского репо).
