# Мажорный релиз: предлагаемые решения

Дополнение к [audit-2026-10-18-code-quality.ru.md](audit-2026-10-18-code-quality.ru.md).
Каждое предложение называет находки аудита, которые оно закрывает (D — дефект,
X — сквозная проблема, C — rpc_dart, T — транспорты, P — сопутствующие пакеты).
Наброски API — только сигнатуры.

Мажорный релиз позволяет менять публичный API. Предложения пользуются этим там,
где это устраняет целый класс расхождений, а не чтобы переименовывать по вкусу.

## Принципы

1. **У каждого правила одно место.** Сопоставление статусов, формула размера,
   шаг жизненного цикла пишутся один раз. Все остальные места вызывают их.
   Правило, написанное дважды, расходится; аудит нашёл такое расхождение в
   каждом срезе.
2. **Забывчивость должна быть ошибкой компиляции.** Там, где код обязан что-то
   пробросить или обработать (возможность транспорта, форму вызова), об этом
   говорит система типов. Сегодня дешёвая ошибка молчалива: обёртка, забывшая
   возможность, получает значение по умолчанию.
3. **Публичная поверхность выбирается, а не остаётся сама собой.** Сегодня это
   всё без подчёркивания за вычетом списка `hide`. Внутренняя механика по
   умолчанию утекает наружу.
4. **Пользователи и авторы транспортов получают разные библиотеки.** Приложению
   нужны контракты, эндпоинты, контекст, ошибки. Автору транспорта нужны ещё
   парсеры, маршрутизаторы, помощники для backpressure. Если их смешать, каждый
   внутренний помощник становится публичным обещанием.
5. **Комментарии описывают код таким, какой он есть.** История уходит в git и в
   журнал.

## 1. Структура библиотек и публичная поверхность

Закрывает частично X7, C17; делает возможными C1, X2, X3, T6.

| Библиотека | Для кого | Содержит |
| --- | --- | --- |
| `package:rpc_dart/rpc_dart.dart` | приложения | контракты и аннотации, эндпоинты, `RpcContext`, ошибки, кодеки, `RpcSecurityPolicy`, отказоустойчивость, логирование, `RpcClientConnection` |
| `package:rpc_dart/transport.dart` | авторы транспортов | `IRpcTransport`, `IRpcChannel`, `RpcChannelTransport`, кодеки кадров и сообщений, `RpcMessageParser`, `RpcStreamRouter`, `BufferedBroadcastController`, `RpcWriteBacklog`, `RpcConnectionHost`, помощники для drain, фабрики статусов и трейлеров |
| `package:rpc_dart/transport_io.dart` | авторы io-транспортов | помощники только для `dart:io`: серверный сокет с ограничением заголовков (T6) |

- Оба barrel-файла используют списки `show`. Новый публичный тип добавляется в
  список намеренно, поэтому списки и есть закоммиченная запись поверхности.
- `transport.dart` реэкспортирует `rpc_dart.dart`; транспорт импортирует одну
  библиотеку.
- `rpc_dart.dart` по-прежнему реэкспортирует `dart:typed_data`: полезная
  нагрузка — `Uint8List`, а сгенерированные `part`-файлы не могут
  импортировать его сами.
- `transport_io.dart` появится вместе с сокетом с ограничением заголовков (T6,
  фаза 1).
- Скрыты из всех barrel-файлов: классы форм вызова (`UnaryCaller`,
  `UnaryResponder`, `ServerStreamCaller`, `ClientStreamCaller`,
  `BidirectionalStreamCaller` и их отвечающие стороны), типы регистрации,
  процессоры, насосы. Вне ядра ими пользуются только тесты, один пример и
  бенчмарк. Они переходят на импорты из `src/` в этом репозитории.
- `core/drain.dart` переезжает в `integration/`; `buffered_broadcast.dart`
  перестаёт импортировать публичный barrel-файл (C17).

Миграция: приложение, которое импортировало только `rpc_dart.dart` и
пользовалось контрактами и эндпоинтами, изменений не заметит. Код, который
вручную собирал `UnaryCaller` и подобные классы, переходит на вызовы эндпоинта.

## 2. Возможности транспорта: члены, а не маркеры

Закрывает X1, D4, расхождение в пяти пробрасывающих обёртках, T7.

**Проблема.** Восемь необязательных возможностей — это отдельные интерфейсы,
которые находят через `is`. Декоратор, который реализует `IRpcTransport` и
пробрасывает каждый член, всё равно их скрывает, и ничто об этом не сообщает.
Пробрасывающих обёрток пять; каждая пробрасывает своё подмножество.

**Решение.** Перенести возможности в `IRpcTransport` как члены с безопасными
значениями по умолчанию. `IRpcTransport` остаётся `abstract class`:

- Транспорт, который его `extends`, получает значения по умолчанию и
  переопределяет то, что у него есть.
- Декоратор, который его `implements`, обязан написать каждый член, поэтому
  забытая возможность — ошибка компиляции. В этом и смысл.

```text
abstract class IRpcTransport {
  // existing members ...

  RpcSecurityPolicy get securityPolicy => const RpcSecurityPolicy();
  Future<void> get ready => Future.value();
  Future<bool> resetStream(int streamId, {String? reason}) async => false;

  // flow control: null when the transport does no flow control
  IRpcFlowCredit? get flowCredit => null;           // defer / return credit
  bool get grantsMessageCredit => true;             // was IRpcNoMessageCredit
  IRpcConnectionBuffer? get connectionBuffer => null; // charge / release

  // required: every transport mints stream ids
  int get lastIssuedStreamId;                       // was IRpcStreamIdSequence
  void resumeStreamIdsAfter(int streamId);
}
```

- `IRpcNoMessageCredit` становится bool с сохранённой безопасной полярностью
  (`true` сохраняет ограничение глубины).
- Группировка управления потоком и общего объёма буфера в небольшие nullable
  объекты сохраняет `IRpcTransport` читаемым и позволяет декоратору пробросить
  целую группу одной строкой.
- У членов для id потоков нет значения по умолчанию. Id выдаёт каждый
  транспорт, а `RpcClientConnection` нужна водяная отметка, чтобы id не
  повторялись между соединениями. Значение по умолчанию пустило бы в прокси
  транспорт без неё.
- `IRpcReconnectableTransport` исчезает вместе с переподключением на месте
  (раздел 6).

Последствия:

- `RpcWebSocketResponderTransport`, `RpcWebSocketCallerTransport` и
  `RpcSocketCallerTransport` становятся тонкими подклассами
  `RpcChannelTransport`. `RpcChannelTransport` принимает `ready:` и до его
  завершения сообщает degraded в health. Имена классов остаются, поэтому
  пользовательский код, который их называет, компилируется.
- `_CapabilityPreservingTransport` в http2 удаляется. Сервер берёт результат
  `transportWrapper` как есть; обёртка, которая `implements IRpcTransport`,
  пробрасывает каждый член, и это проверяет компилятор.
- `RpcWasmBridge` реализует `IRpcChannel`, а `_RpcWasmChannel` удаляется (T7).
- `RpcInMemoryTransport` удаляется; его заменяет
  `RpcChannelTransport.memoryPair()`.

**Рассмотренная альтернатива:** `T? capability<T>()` с телом по умолчанию.
Пробросить нужно один метод, но пропущенный проброс всё так же молчалив, а это
и есть исправляемый дефект. Отклонено.

Миграция: сторонний транспорт, который `implements IRpcTransport`, добавляет
новые члены (или переходит на `extends`). Каждая проверка `is` на возможность в
пользовательском коде, если такие есть, становится чтением члена.

## 3. Общая механика транспортов в ядре

### 3a. `RpcWriteBacklog`

Закрывает X2.

Один класс в `transport.dart`, только `dart:async`:

```text
final class RpcWriteBacklog {
  RpcWriteBacklog({required int? maxUnsentBytes}); // null: never pauses
  static const int defaultServerMax = 1024 * 1024;

  /// Writes source to sink through addStream; counts what the sink took.
  Future<void> pipe(Stream<List<int>> source, StreamConsumer<List<int>> sink);
  /// The reader to pause past the max and resume at half.
  void attachReader(StreamSubscription<Object?> reader);
}
```

- `pipe`, а не обёрнутый поток `outgoing`: dart:io может закончить запись, не
  отменив поток, из которого читает (ошибка raw-сокета завершает `addStream` и
  оставляет подписку на паузе), поэтому о конце записи говорит только future
  от `addStream`.
- Поведение, сохранённое из websocket: чтение возобновляется, когда запись
  заканчивается, поэтому неудачная запись не может оставить пира на паузе
  навсегда. http2 это получает.
- socket, websocket и http2 делегируют ему. Три константы `1024 * 1024`
  становятся `defaultServerMax`.

### 3b. `RpcConnectionHost`

Закрывает X3, двойное логирование в websocket и потерю `prefaceTimeout` в
фабрике socket.

Половина сервера, относящаяся к соединению: набор эндпоинтов, создание
эндпоинта для транспорта, освобождение, когда он завершается, ограничение числа
соединений с однократным предупреждением, drain с последующим закрытием.

```text
final class RpcConnectionHost {
  RpcConnectionHost({
    required RpcServerMode mode,
    int? maxConnections,
    LogScope? logger,
    LogController? endpointLogger,
  });
  bool admit({int pending = 0});   // pending: handshakes the server holds
  RpcEndpointBase serve(IRpcTransport transport,
      {required Future<void> done, String? debugLabel, void Function()? onRelease});
  void release(RpcEndpointBase endpoint);  // idempotent
  List<RpcResponderEndpoint> get responders;
  Future<void> stop({Duration? drainTimeout});
}

sealed class RpcServerMode {}
final class RpcResponderMode extends RpcServerMode {
  const RpcResponderMode(void Function(RpcResponderEndpoint) register);
  RpcResponderMode.contracts(List<RpcResponderContract> contracts);
}
final class RpcPeerMode extends RpcServerMode {
  const RpcPeerMode(void Function(RpcPeerEndpoint) register);
}
```

- `RpcServerMode` заменяет пару `onEndpointCreated` / `onPeerEndpointCreated` и
  её проверку «не оба сразу» во время выполнения.
- Режимы — публичные классы, а не фабрики, поэтому сервер только для
  responder говорит об этом типом: `RpcHttp2Server` и `RpcHttpServer` принимают
  `RpcResponderMode`, socket и websocket — `RpcServerMode`. Peer-режим для
  http2 — ошибка компиляции.
- Политика остаётся у сервера: хост никогда не строит транспорт.
- Построитель в `RpcApp.server` получает `RpcResponderMode` вместо callback:
  `server: (mode) => RpcHttp2Server(port: 50051, mode: mode)`.
- За серверами остаётся только их собственное: приём, рукопожатие и то, как
  отказанному соединению об этом сообщают (сырой сокет уничтожается, websocket
  отправляет код закрытия).
- Освобождение идемпотентно (побеждает версия из socket), и
  `onConnectionClosed` срабатывает один раз для каждого соединения, включая
  закрытые `stop()` (http2 их пропускал).
- Однократное предупреждение на лимите сбрасывается, когда следующее
  соединение принято.

### 3c. Одно место для правил статусов и трейлеров

Закрывает X5, D2, частично C3, частично T2.

В `transport.dart` (с реэкспортом туда, где они нужны приложениям):

- `RpcTrailers`: `status(code, message)` (сегодняшний `RpcMetadata.forTrailer`,
  всегда закодированный и обрезанный), `cancelled(reason)` (кадр
  `x-client-cancelled`), `requestEndedMidMessage()`, `responseEndedMidMessage()`,
  `fromHttpStatus(int, {String? body})`, `unexpectedContentType(String)`.
- `RpcCallerTrailer` становится единственным читателем на стороне вызывающей
  стороны: сборщик единственного ответа, общий для unary и client-stream,
  проверка статуса на END_STREAM, ошибка «закрыто без статуса» (с
  сопоставлением дедлайна), разбор статуса в ping.
- **Каждая** ошибка, уходящая пиру, проходит через `wireStatusFor`. Включая
  `_answerRejectedStream` в http2 (D2); отказ по `:method` выбрасывает
  `RpcStatusException(invalidArgument)`, чтобы сохранить свой статус.

Как сделано:

- В `RpcTrailers` есть `status`, `of(RpcStatusException)`, `cancelled`,
  `fromHttpStatus` и `unexpectedContentType`. Ошибки обрыва посреди сообщения
  остаются функциями `requestEndedMidMessage()` / `responseEndedMidMessage()`,
  теперь экспортированными из `transport.dart`; транспорт, которому они нужны
  трейлером, пишет `RpcTrailers.of(responseEndedMidMessage())`. Сообщение
  http2 для не-200 — `HTTP 503`, как в http.
- Уведомление об отмене везде одной формы, вместе с CANCELLED; ответчик статус
  не читает.
- Два события «без статуса» остаются разными: живой пир, закрывший поток без
  статуса, — INTERNAL без повтора (канальный транспорт, http2); поток, который
  кончился вообще без кадра конца, — `closedWithoutStatus`, UNAVAILABLE, если
  не истёк дедлайн. CallProcessor, unary на процессорах и ping теперь берут
  `closedWithoutStatus` с учётом дедлайна.
- Ping разбирает `grpc-status` через `statusOf`, поэтому код вне 0..16 —
  UNKNOWN. Собственный трейлер ошибки ping проходит через `wireStatusFor`: он
  отправлял пиру текст пойманного исключения.
- Общий сборщик одиночного ответа переезжает в раздел 4: `UnaryCaller` и
  `UnaryResponder` уходят там (C1), и слить их сборщик сейчас значило бы
  написать его дважды. Их собственные литералы трейлеров уходят вместе с ними.
- `transport_io.dart` (T6) содержит `RpcHeaderBoundedServerSocket`: версию
  http-сервера (ограничен каждый keep-alive-запрос, `peerGone`) и освобождение
  слота по `socket.done` из версии websocket. websocket ограничивает только
  первый блок, потому что никогда не вызывает `responseWritten`.

## 4. Формы вызова: одна реализация на каждую, одно правило режима передачи

Закрывает C1, C2, C3, C4, C5, C6, D5, частично C15.

Возможно, когда раздел 1 сделает классы форм внутренними.

- **Unary работает на процессорах**, как это уже делает server-stream:
  - Отвечающая сторона: `StreamProcessor` держит запрос до конца потока и
    отвергает второй с INTERNAL.
  - Вызывающая сторона: `CallProcessor` со сборщиком единственного ответа (3c).
  - `UnaryCaller` и `UnaryResponder` (около 1700 строк) и второй zero-copy путь
    для unary удаляются.
  - Сохраняется: вызывающая сторона не ждёт завершения отправки, прежде чем
    ждать ответ (пир может отказать и перестать читать).
- **Zero-copy — это codecs == null, везде**:
  - Одна ветка на форму в конвейере отвечающей стороны, а не две.
  - Тогда zero-copy unary отвергает второй запрос так же, как unary с кодеком
    (D5).
- **Режим передачи решается один раз** контрактом, для каждого метода, для
  каждой формы. `transferMode` у `unaryRequest` удаляется; unary в режиме
  `auto` ведёт себя как остальные три формы.
- **Один базовый класс для отвечающих сторон**: процессор, `id`, `done`,
  привязка, закрытие. Обработчиком bidi управляет
  `BidirectionalStreamResponder`, как и остальными, а не конвейер.
  `IRpcResponder` получает `done`, поэтому конвейеру не нужны приведения типов.
- **Насосы**: `SinkPump` получает политику обработки сбоев и заменяет два
  написанных вручную насоса запросов. Один ретранслятор ответов обслуживает
  server-stream и bidi.
- **Мелкие копии уходят вместе с этим**:
  - Проверка аргументов кодек/zero-copy: один раз, в процессоре.
  - Декомпрессор: его создаёт парсер, привязанный к политике.
  - Один `policyOf` и один построитель клиентских метаданных.

Изменения поведения (все намеренные):

- Zero-copy unary отвергает второй запрос.
- Unary в режиме `auto` на zero-copy транспорте сериализует, если заданы
  кодеки, как это делают другие формы.
- Вызывающая сторона, созданная без контекста, отправляет `x-request-id` во
  всех формах.

## 5. Контракты, контекст, регистрация

Закрывает C7, C8, C9, P12.

- **Регистрация.** API `add*Method` уже даёт одну точку входа на форму с
  необязательными кодеками; его сохраняем. Внутри:
  - Один `RpcMethodRegistration` с nullable кодеками, в одной map.
  - Ограничение `IRpcSerializable` и `_OpaqueValue` / `_OpaqueCodec`
    удаляются.
  - `methods` и `zeroCopyMethods` становятся одним представлением
    `registrations` только для чтения или скрываются.
- **Контракты вызывающей стороны и пира** используют общий приватный набор из
  четырёх реализаций `call*` поверх mixin конвейера вызывающей стороны.
- **`RpcContext`** получает один приватный `_copy({...})`. Его вызывают все
  `with*`, `merge`, `forward` и методы построителя. Помощники аутентификации
  живут в одном месте (оставить те, что в `RpcContextBuilder`, убрать копии в
  `RpcContextUtils`).
- **Отслеживание вызовов** (`cancelMethod`, `trackedMethods`) переезжает в
  mixin вызывающей стороны, поэтому оно есть и у `RpcPeerEndpoint` (C21).
- **Одно перечисление для четырёх форм**: `@RpcMethod` принимает
  `RpcMethodType`; `RpcMethodKind` удаляется. Генератор сопоставляет значения
  перечисления по имени.

## 6. Переподключение: одна стратегия

Закрывает X4. **Решение владельца: один слой.**

Сегодня проблему устаревших id после переподключения решают три механизма:

- прокси `RpcClientConnection` с водяной отметкой id;
- переподключение websocket на месте с множествами принадлежности;
- переподключение http2 в режиме single-flight.

**`RpcClientConnection` — единственный слой, который переподключается.**

- Транспорт, потерявший соединение, закрывается. `reconnect()` уходит из
  `IRpcTransport`, а вместе с ним `IRpcConnectionLossReporting` и
  `reconnectFactory` в websocket.
- Интерцептор повторов спрашивает соединение, а не транспорт.
- Вызов на транспорте, который закрылся из-за потери соединения, падает с
  UNAVAILABLE, как и вызов, оборванный на лету; FAILED_PRECONDITION остаётся
  для транспорта, который закрыла эта сторона.
- Защита от устаревших id живёт в прокси, в обе стороны. Опоздавший кадр для
  потока, который прокси открыл на прошлом соединении, отбрасывается, а поток,
  открытый пиром, отменяется локально, когда уходит его соединение.
- Прокси отдаёт `connectionBuffer` как null: общий объём буфера принадлежит
  одному соединению, а следующее начинает с нуля.
- `RpcEndpointBase.reconnect()` удаляется; `health()` теряет
  `transportOverride`.
- Это убирает примерно половину `websocket_caller_transport.dart` и механику
  переподключения в http2.
- Цена: пользователь websocket, который полагался на `reconnectFactory`,
  оборачивает транспорт в `RpcClientConnection`. Документация ядра и
  документация websocket уже это рекомендуют.

## 7. Внутреннее устройство http2

Закрывает T1, T2, T5 и расхождение при разборке в духе D6. Публичного API нет.

- **Одна запись на поток** (`_CallerStream`, `_ResponderStream`), которая
  хранит поток, подписку, парсер, насос, флаги и учёт управления потоком, с
  `dispose()`. 13 и 9 параллельных map удаляются. Каждый путь разборки удаляет
  одну запись, поэтому класс ошибок «разные подмножества» исчезает.
- **Один класс учёта управления потоком** с колбэком `onOverrun`, общий для
  обеих половин.
- **`connect` и `secureConnect`** используют один приватный `_dial(secure:)`.
- **Мёртвый код удаляется:** `filterStreamEvents`, недостижимая проверка ASCII,
  фиксированная версия в `kGrpcUserAgent`.

Как сделано:

- `_CallerStream` и `_ResponderStream` — part-файлы, по одной карте записей на
  сторону; небольшой счётчик держит лимиты резервирований и парсеров за O(1).
  Ключи `health().details` сохраняют имена и смысл.
- `Http2FlowLedger` / `Http2FlowAccount` (`http2_flow_ledger.dart`) несут общую
  логику; различие сторон — два callback: кого учитывать и что делать при
  переполнении.
- `close()` в caller теперь забывает и кредит управления потоком; раньше
  закрытый caller мог показывать ненулевой `fcOutstanding`. `close()` в
  responder отменяет подписки по снимку.
- Проверка ASCII в конвертерах заголовков остаётся: на пути транспорта её
  делает недостижимой `validateMetadata` в core, но конвертеры публичные,
  вызываются напрямую, и два теста закрепляют исключение.
- `kGrpcUserAgent` — `rpc-dart`, без версии, которая могла бы разойтись.

## 8. Логирование, ошибки, мелкие типы

- **Логирование (X6).**
  - Каждый публичный конструктор принимает `LogScope? logger`, который один раз
    разрешается в `LogScope.noop`.
  - `RpcConnectionLogger` удаляется; `RpcClientConnection` принимает
    `LogScope`.
  - Сам логгер:
    - `copyWith` у `LogEvent`/`LogSpan`;
    - `RpcLogLevel.fromName`;
    - редактирование чувствительных данных охватывает события span (D1);
    - `traceId` в базовом `LogRecord` (P8);
    - экранирование строк консоли общее с rpc_dart_log (D3).
- **Ошибки (C15).**
  - Все исключения живут в `errors.dart`.
  - `RpcException` становится `abstract base`; подклассы — `final`.
  - Маркер `IRpcPeerFault` удаляется; проверять `is RpcPeerFaultException`.
  - Тогда `wireStatusFor` видит и исключения контекста.
- **Политика по умолчанию (T4).** `RpcHttpResponderTransport` и
  `RpcHttpServer` принимают не-null `securityPolicy` со значением по умолчанию
  `const RpcSecurityPolicy()`, как все остальные транспорты. Политика null
  больше не отключает их проверки. Это сделано вместе с разделом 2, потому что
  там `securityPolicy` стал членом `IRpcTransport`. Внутренние помощники, принимающие
  `RpcSecurityPolicy?` (общий код http2, io-соединения websocket, web-изолят),
  получают то же значение по умолчанию.
- **Примитивы (C22).** Одна политика обработки сбоев: выбрасывать
  `FormatException`:
  - `RpcBool` и `RpcString` перестают возвращать значения по умолчанию на
    некорректном вводе;
  - `RpcNum` сначала разбирает int.
- **Мёртвый API (C18).** `convertMap`, `RpcCodec.fromBytes`,
  `RpcMessage.endOfStream`, игнорируемый `capacity`, `platform_error_*`;
  декодер `RpcCodec` становится обязательным.
- **Health (D10).**
  - `GrpcHealthCheckContract` переименовывается в `RpcHealthContract`
    (собственный health rpc_dart, CBOR).
  - Настоящий `grpc.health.v1` (protobuf) живёт в `rpc_dart_grpc_reflection`,
    который уже пишет protobuf.
- **Сжатие (D9, P5).**
  - `selectResponseEncoding` нормализует.
  - Один ограниченный gzip-распаковщик: сначала измерить однократное
    добавление против поблочного, оставить тот, который соблюдает ограничение,
    и экспортировать его из ядра для сопутствующего пакета.

## 9. Сопутствующие пакеты

- **Генератор (D8, P1, P7).**
  - Строить дескрипторы через `RpcFileDescriptorBuilder` из
    `rpc_dart_grpc_reflection`. Это зависимость генератора, а не
    пользовательская зависимость времени выполнения.
  - Скопированный writer удаляется; дескриптор получает `syntax = "proto3"`.
  - Переопределения кодеков задаются на МЕТОД (константы с ключом по методу).
    Сгенерированный вывод меняется, поэтому пользователи перегенерируют код.
- **Framework (D11, P2, P3, P4, P9).**
  - Health агрегирует типизированные `RpcHealthStatus` и `endpoint.health()`;
    map только в `toJson`.
  - Один базовый наблюдатель вызовов в ядре (начало, завершение, ошибка,
    отмена, для каждой формы) заменяет ErrorReporting, CallMetrics и
    `RpcCallSpy`; OTel строится на нём.
  - Типы вызовов — `RpcMethodType`, а не строки.
  - `RpcTestApp` работает через `RpcApp` поверх сервера в памяти.
  - Документация исправлена.
- **rpc&#95;dart&#95;log (P10, P11).**
  - Его контракт генерируется.
  - Фиктивный `sessionId` и зашитая версия MCP удаляются.
  - `approxJsonBytes` переезжает в ядро для log, notify и data.
- **isolate (T9).**
  - Один базовый канал для VM и web, единственное различие — encode/decode.
  - Один typedef точки входа; `policy` не-null со значением по умолчанию на
    каждой платформе.

## Порядок работ

Пункты без ломающих изменений могут попасть в релиз до мажорного и уменьшить
его.

| Фаза | Содержание | Ломающее |
| --- | --- | --- |
| 0 | исправления D1, D2, D3, D6, D9, D11 (D7 не дефект); поля логирования X6; комментарии X7; приватный мёртвый код C18; внутреннее устройство http2 (7) | нет |
| 1 | добавлены `RpcWriteBacklog`, `RpcConnectionHost`, `RpcTrailers`; транспорты переходят на них (3) | нет (добавления) |
| 2 | Разделение библиотек и barrel-файлы с `show` (1) | да |
| 3 | Возможности как члены (2); классы-обёртки удалены | да |
| 4 | Формы вызова на процессорах, правило режима передачи (4); регистрация и контекст (5) | да, после фазы 2 в основном внутреннее |
| 5 | Стратегия переподключения (6); политика по умолчанию, ошибки, примитивы, health, API логгера (8) | да |
| 6 | Сопутствующие пакеты (9); перегенерация сгенерированного кода | да, для вывода генератора |

Среди ломающих фаза 2 идёт первой: когда классы форм станут внутренними, фаза 4
перестанет быть изменением API.

## Решения владельца (2026-10-18)

Ломающие изменения допустимы везде: это мажорный релиз.

1. Переподключение (раздел 6): один слой, `RpcClientConnection`.
2. Возможности (раздел 2): члены `IRpcTransport` со значениями по умолчанию.
3. Политика (T4): не-null, по умолчанию `const RpcSecurityPolicy()`, как у
   всех остальных транспортов.
4. Health (D10): переименовать в `RpcHealthContract` и добавить настоящий
   `grpc.health.v1`.
5. Примитивы (C22): `RpcBool` и `RpcString` выбрасывают `FormatException` на
   некорректном вводе.
6. Переопределения кодеков в генераторе (D8): на метод.

## Сводка миграции для пользователей

| Было | Стало |
| --- | --- |
| `UnaryCaller`, `*StreamCaller`, `*StreamResponder`, собранные вручную | вызовы эндпоинта (`unaryRequest`, ...) или сгенерированные вызывающие стороны |
| `is IRpcSecurityPolicyAware` и т. п. | `transport.securityPolicy` и т. п. |
| `implements IRpcTransport` в собственном транспорте | добавить члены возможностей или `extends IRpcTransport` |
| `RpcInMemoryTransport.pair()` | `RpcChannelTransport.memoryPair()` |
| `connectionLost` у транспорта | `incomingMessages` завершается: транспорт закрывается |
| `headersProvider:` у вызывающей стороны websocket | `headers:`, собранные внутри фабрики `RpcClientConnection`, которая выполняется для каждого соединения |
| `endpoint.reconnect()` | `RpcClientConnection.forceReconnect()` |
| `onEndpointCreated:` / `onPeerEndpointCreated:` | `mode: RpcResponderMode(...)` / `RpcPeerMode(...)`; только контракты: `RpcResponderMode.contracts([...])` |
| `RpcApp.server(server: (onEndpoint) => ... onEndpointCreated: onEndpoint)` | `server: (mode) => ... mode: mode` |
| `reconnectFactory:` у вызывающей стороны websocket | `RpcClientConnection` вокруг транспорта |
| `transport.reconnect()` | переподключается `RpcClientConnection`; транспорт закрывается |
| `policy: null` у http-сервера или responder (проверки выключены) | политика по умолчанию; чтобы изменить лимиты, передать явную `RpcSecurityPolicy` |
| `RpcBool` / `RpcString` возвращают значение по умолчанию на некорректном вводе | `FormatException` |
| переопределение кодека для метода действует на все методы с тем же типом | действует только на свой метод; перегенерировать код |
| `RpcConnectionLogger` | `LogScope` |
| `GrpcHealthCheckContract` | `RpcHealthContract` |
| `transferMode:` у `unaryRequest` | режим передачи контракта |
| `RpcMethodKind` в `@RpcMethod` | `RpcMethodType` |
| типы для авторов транспортов из `rpc_dart.dart` | `rpc_dart/transport.dart` |
