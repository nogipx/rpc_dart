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

- Универсальный контракт `DataService` (create/get/list/update/patch/delete/deleteCollection)
- Пакетные операции: bulkUpsert / bulkDelete
- Поиск и метрики: search + aggregate (count / sum / avg / min / max)
- Экспорт снимка коллекции (snapshot)
- Полный экспорт/импорт базы с опциональным шифрованием
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

## Экспорт и импорт базы данных

`DataRepository.exportDatabase` возвращает снимок всех коллекций. Он может быть:

- **Открытым** — репозиторий отдаёт JSON с полями `collections` и `schema`.
- **Зашифрованным** — по переданному паролю генерируется симметричный ключ, снимок
  шифруется через [Licensify](https://pub.dev/packages/licensify) и упаковывается в
  PASETO-токен.

### Как собирается зашифрованный экспорт

1. Репозиторий формирует JSON-снимок (`Map<String, dynamic>`).
2. Если пароль не передан — JSON возвращается как есть. Если пароль передан:
   1. `Licensify.generateEncryptionKey()` создаёт случайный симметричный ключ, которым будет
      шифроваться снимок.
   2. `Licensify.encryptData()` упаковывает JSON в PASETO `v4.local`, используя этот ключ.
   3. `Licensify.generatePasswordSalt()` генерирует криптостойкую соль длиной не меньше 16 байт
      (совместимую с PASERK `k4.local-pw`).
   4. `Licensify.encryptionKeyFromPassword()` прогоняет Argon2id с параметрами по умолчанию
      (`memoryCost = 64 MiB`, `timeCost = 2`, `parallelism = 1`) и возвращает пользовательский
      симметричный ключ.
   5. Случайный ключ снимка заворачивается в PASERK `k4.local-wrap.pie` через
      `Licensify.encryptionKeyToPaserkWrap()`, используя пользовательский ключ в качестве
      «обёртки».
   6. В footer токена записываются `salt` и получившаяся строка `wrap` с зашифрованным ключом
      снимка.

В итоге экспорт выглядит как `v4.local.<ciphertext>.<footer>`, где footer — это base64url от

```jsonc
{
  "salt": "...",               // base64url-соль Argon2id (совместима с PASERK)
  "wrap": "k4.local-wrap.pie..." // случайный ключ снимка, обёрнутый пользовательским ключом
}
```

### Импорт базы данных

1. Клиент отправляет `ImportDatabaseRequest`, указывая экспортированный JSON или
   PASETO-строку и пароль (если экспорт был шифрованным).
2. Репозиторий определяет формат:
   - обычный JSON — сразу парсится;
   - `v4.local` токен — footer декодируется, из него берутся `salt` и `wrap`.
3. Argon2id с параметрами по умолчанию снова выводит пользовательский ключ из пароля и соли.
4. Этот ключ разворачивает `wrap` обратно в исходный ключ снимка, после чего Licensify
   расшифровывает шифртекст токена.
5. Репозиторий очищает текущие коллекции и заливает данные из снимка в хранилище.

### Почему достаточно помнить пароль

Ключ снимка нигде не хранится в открытом виде. В бэкапе лежат только шифртекст и метаданные
(`salt` и `wrap`). Алгоритм Argon2id детерминированный, поэтому при тех же входных данных он
возвращает идентичный пользовательский ключ, которым раскладывается `wrap` и расшифровывается
снимок. Если footer подделан или повреждён, распаковка ключа завершится ошибкой и импорт не
начнётся.

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
  @override Future<bool> deleteCollection(String collection) async { /* ... */ }
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

Коллекцию можно удалить вызовом `deleteCollection(collection: 'archive')` на `DataService`.
Адаптер удалит таблицу и запись в `collection_registry`, не затрагивая другие коллекции.

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
