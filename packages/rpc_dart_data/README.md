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
- Опциональная авторизация через заголовок `authorization: Bearer ...` с проверкой по белому списку токенов

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
  // Контекст с Authorization заголовком нужен только если сервер проверяет bearer токены.
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

## HTTP/2 сервис и компиляция

В пакете есть консольный сервер `bin/serve.dart`, который можно запускать
напрямую или собрать в автономный бинарь. Для компиляции используйте рецепт из
`justfile`:

```bash
just compile_serve [build/rpc_dart_data_serve] [-- <доп. флаги dart compile>]
```

Рецепт создаст каталог для результата и вызовет
`fvm dart compile exe bin/serve.dart`. Путь до бинаря можно опустить — по
умолчанию используется `build/rpc_dart_data_serve`.

После сборки бинарный файл можно запускать независимо от SDK. Сервер обрабатывает
сигналы `SIGINT`/`SIGTERM` и корректно завершает работу, закрывая HTTP/2
соединения и репозиторий данных. По умолчанию он создаёт файл `data_service.sqlite`
в рабочем каталоге процесса (см. `--database` ниже), поэтому без дополнительной
конфигурации вы сразу получаете persistent-хранилище на диске. На этапе старта
сервер автоматически разворачивает схему, если файл отсутствует, и выполняет
быструю проверку целостности существующего файла, чтобы убедиться, что база готова
к использованию перед обработкой запросов. В CLI доступны
дополнительные опции:

- `--daemon` (`-D`) — запускает сервер в фоне, создавая отсоединённый дочерний
  процесс. В этом режиме основной процесс сразу завершает работу, а управление
  переходит демону.
- `--pid-file <path>` — путь до PID файла (по умолчанию `data_service.pid`).
  Файл блокируется эксклюзивно и хранит PID активного процесса. При остановке
  сервера блокировка снимается, а файл удаляется.
- `--database-key <paserk>` — включает SQLCipher для файла SQLite. Принимает
  только PASERK `k4.local` (XChaCha20) строку, полученную, например, через
  `LicensifySymmetricKey.generateLocalKey().toPaserk()`. Ключ читается только
  из CLI аргумента и не выводится в логи.
- `--auth-token <value>` — добавляет статический bearer токен. Можно указать
  несколько флагов, а также считать секреты из переменных окружения
  (`--auth-token-env NAME`) или файла (`--auth-token-file path`). Если токены
  не заданы, сервис предупреждает и работает без проверки заголовка `Authorization`.
- `--secure-wrap` и связанные параметры — включают шифрование/аутентификацию
  поверх HTTP/2 через Licensify. Ключи передаются **только** в формате PASERK:
  `--secure-wrap-private-key` принимает строку `k4.secret`, а
  `--secure-wrap-peer-key` — `k4.public` удалённого пира. Дополнительно можно
  настроить формат кадров (`--secure-wrap-frame-format`), таймауты handshake и
  поведение паддинга.
- `--relay` — подключает сервис к TURN relay из пакета `rpc_dart_transports`.
  Укажите адрес/порт (`--relay-host`, `--relay-port`), идентификатор публикации
  (`--relay-service-id`), а также опциональные метаданные `key=value` через
  `--relay-metadata`. Метаданные сериализуются в JSON и отправляются в описании
  сервиса, что позволяет клиентам получить transportId secure wrap и другие
  параметры для автоконфигурации.

Если демон не может захватить PID файл (например, уже запущен другой экземпляр),
он завершится с ошибкой. Для корректной работы фонового режима запускайте
команду через `dart run bin/serve.dart` или через скомпилированный бинарь.

## Использование за backend-ом

Для сервисного сценария, когда единственный клиент — ваш backend, включите
аутентификацию через bearer токены и храните их в секрете окружения. Пример
запуска:

```bash
rpc-data serve \
  --host 127.0.0.1 --port 9042 \
  --database /var/lib/rpc_data.sqlite \
  --auth-token-env DATA_SERVICE_TOKEN
```

Backend передаёт заголовок `Authorization: Bearer $DATA_SERVICE_TOKEN` при
каждом RPC-вызове. Токены можно прокинуть через менеджер секретов, volume или
отдельный файл с ограниченными правами. При необходимости заведите несколько
токенов (для разных сервисов) и укажите их множественными флагами `--auth-token`
или через отдельные переменные окружения.

### Почему конечных клиентов лучше подключать через backend

`rpc_dart_data` не предназначен для прямой работы с тысячами независимых
пользовательских устройств. Даже при включённом SecureWrap и белых списках
токенов остаются ограничения:

- **Аутентификация и авторизация.** Сервис проверяет только bearer токены и
  не умеет управлять сессиями, квотами или политиками доступа на уровне
  отдельных пользователей. Любой клиент, получивший токен, получит полный
  доступ к коллекциям.
- **Изоляция трафика.** Каждое устройство держит собственное HTTP/2
  соединение/стримы. При десятках тысяч одновременно подключённых клиентов
  потребуется следить за лимитами file descriptor'ов, таймаутами Keep-Alive и
  объёмом change-журнала, что обычно проще решать на backend-слое.
- **Бизнес-логика и согласованность.** Конфликты версий решаются только
  оптимистичной блокировкой (`expectedVersion`). Backend может централизованно
  управлять транзакциями, координировать записи и применять дополнительные
  проверки, прежде чем пускать изменения в общую базу.

Поэтому рекомендуемый профиль: backend держит постоянное соединение и
выполняет операции от имени пользователей, а внешние клиенты общаются только с
backend'ом. Это даёт контроль над безопасностью, возможностью кешировать
результаты и масштабировать нагрузку привычными способами.

### Как разделять данные нескольких клиентов

`rpc_dart_data` не вводит собственных понятий организаций/аккаунтов, поэтому
разделение данных реализуется на backend-уровне. Практический подход выглядит так:

1. **Назначьте tenant-id.** Backend присваивает каждому клиенту (или проекту)
   уникальный идентификатор и хранит его в своей сессии/токене.
2. **Пространство имён коллекций.** Для изоляции создавайте коллекции с
   префиксом `tenantId`. Например, пользователь `acme` работает с коллекцией
   `acme__orders`, а `beta` — с `beta__orders`. Такое «порождение» таблиц
   нормально для десятков/сотен клиентов: SQLite создаёт их по требованию,
   каждая коллекция получает собственные индексы, а операции других
   tenant-ов не блокируют друг друга. Если же счёт идёт на тысячи коллекций,
   становится сложнее выполнять миграции и управлять правами, поэтому в этом
   случае переключайтесь на следующий вариант с полем фильтрации.
3. **Поле фильтрации.** Если неудобно плодить коллекции, добавьте в записи поле
   `tenantId` и оборачивайте все запросы через backend, который автоматически
   вставляет фильтр `where: {'tenantId': currentTenant}`. Для Drift-адаптера
   включите индекс по полям `tenantId`/`updatedAt`, чтобы выборки и
   пагинация оставались эффективными.
4. **Доступ по контракту.** Клиентские токены не выдают напрямую; вместо этого
   backend проверяет, к какому tenant относится запрос, и вызывает RPC-метод
   от своего имени, подставляя корректный `tenantId`/префикс.

Такой шаблон даёт чёткую изоляцию данных и упрощает эксплуатацию: можно
добавлять новых клиентов, не меняя схему базы, а при необходимости переносить
tenant в отдельный экземпляр сервиса — просто скопируйте соответствующие
коллекции.

## Экспорт и импорт базы данных

`DataRepository.exportDatabase` возвращает снимок всех коллекций в формате NDJSON (по одной JSON-записи на строку).
Первая строка — `header` с `formatVersion`, `generatedAt` и служебной информацией. Далее идут блоки
`collection`/`record`/`collectionEnd` для каждой коллекции и завершающий `footer` с агрегатами.
Репозиторий больше не занимается шифрованием: держите сервис в защищённой среде или шифруйте
данные на уровне прикладного кода, если это требуется политиками безопасности.

### Импорт базы данных

`ImportDatabaseRequest` принимает тот же NDJSON. По умолчанию новые записи заливаются поверх
существующих. Если указать `replaceExisting: true`, репозиторий очистит отсутствующие коллекции
и удалит старые записи перед импортом. Для обратной совместимости поддерживается и устаревший
JSON-формат (`formatVersion: 1.0.0`), но он требует загрузки всего снимка в память.

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

В файловом профиле подсчёт (`count`) выполняется на стороне SQLite, тогда как
`sum`/`avg`/`min`/`max` пока остаются в памяти — их можно подключать выборочно
через собственные адаптеры.

## Стрим изменений
`watchChanges` принимает опциональный `cursor` — можно продолжить с точки останова. Для Drift/SQLite адаптера журнал изменений хранится в таблице `change_journal`, поэтому после рестарта можно восстановить курсоры и догнать изменения. In-memory профиль продолжает использовать оперативную память и предназначен только для тестов.

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
  @override Future<ListRecordsResponse> queryCollection(ListRecordsRequest request) async { /* SQL с фильтрами */ }
  @override Future<SearchRecordsResponse> searchCollection(SearchRecordsRequest request) async { /* FTS/ILIKE */ }
  @override Future<AggregateMetricsResponse> aggregateCollection(AggregateMetricsRequest request) async { /* агрегации */ }
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
final storage = DriftDataStorageAdapter.file(
  File('data.sqlite3'),
  sqlCipherKey: SqlCipherKey.fromPaserk(
    paserk: 'k4.local....', // храните отдельно и передавайте при запуске
  ),
);
final repository = DriftDataRepository(storage: storage);
final env = await DataServiceFactory.inMemory(repository: repository);

final ctx = RpcContext.withHeaders({'authorization': 'Bearer demo'});
await env.client.create(collection: 'notes', payload: {'title': 'Hello'}, context: ctx);
```

Если системная библиотека SQLite собрана без SQLCipher, адаптер выбросит
`SqlCipherException` при первом открытии файла. Убедитесь, что рантайм подхватывает
`libsqlcipher` (или другую совместимую сборку) и доступен `PRAGMA cipher_version`.

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

В версии single-node дополнительно создаются индексы на `version`, `created_at` и `updated_at`,
а методы `list()` и `aggregate(count)` делегируются в SQLite. Это даёт предсказуемые
O(log N) планы выполнения даже при десятках тысяч записей в коллекции и сводит к минимуму
издержки на сетевую передачу.

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
- Настраиваемый retention журнала изменений и TTL для коллекций
- Расширенные сценарии поиска (FTS5, гео-запросы) поверх SQLite
- Production адаптеры для других СУБД (Isar / Postgres)

## Single-node профиль для «поднял и пользуюсь»

`rpc_dart_data` поставляется с готовой конфигурацией для одного узла,
способной выдержать порядка 10 000 активных пользователей в сутки на обычном
SSD-инстансе. Ключевые кирпичики уже на месте:

- **Персистентное хранилище по умолчанию.** CLI `serve` запускает сервис с
  файловым `DriftDataStorageAdapter.file(...)`, автоматически создаёт каталоги
  и при необходимости включает SQLCipher.
- **Журнал изменений переживает рестарт.** События `watch()`/`sync()`
  фиксируются в таблице `change_journal`, поэтому офлайн-клиенты восстанавливают
  курсоры даже после обновления процесса.
- **Серверная фильтрация и индексы.** `DriftDataStorageAdapter` умеет
  выполнять `list()` поверх SQL (фильтры, пагинация, сортировки по `id`/`createdAt`/`updatedAt`)
  и создаёт индексы на ключевых столбцах. Клиент перестаёт сканировать всю коллекцию.
- **Атомарные bulk операции.** `bulkUpsert` агрегирует записи и отдаёт их в
  `writeRecords`, который выполняет транзакцию на стороне SQLite. В случае ошибки
  состояние коллекции не разъезжается.
- **Экспорт/импорт и офлайн-очередь.** Резервные копии можно снимать через
  `exportDatabase`, а фоновые клиенты используют `OfflineCommandQueue` для
  консистентной синхронизации.

Что ещё стоит сделать в продакшне:

- Настроить регулярный бэкап (cron + `exportDatabase`) и проверять
  `importDatabase` на стенде.
- Ограничить доступ до RPC через reverse proxy с аутентификацией и rate limiting.
- Отслеживать размер файла БД и журнала (например, через `sqlite3` CLI).
- Следить за релизными заметками в [CHANGELOG.md](CHANGELOG.md).


## Лицензия
См. LICENSE (наследует лицензионную политику родительского репо).
