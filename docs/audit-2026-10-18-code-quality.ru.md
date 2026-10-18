# Аудит качества кода: ядро и транспорты, 2026-10-18

Охват: `lib/` каждого пакета в `packages/core/` и `packages/transport/`
(около 56k строк). Только чтение. Шесть срезов проверялись параллельно; каждую
находку её аудитор проверил в коде (прочитаны обе копии, вызовы посчитаны через
grep; анализатор не работал). Находки с пометкой **проверено** перепроверены для
этой сводки. Пути указаны относительно `packages/`.

Каждая находка о дублировании отвечает на один вопрос: если бы копии были одной,
чьё поведение сохранила бы общая версия и какие копии это изменило бы?

## Дефекты, найденные попутно

Это поведение, а не стиль. Исправить их до рефакторингов ниже.

| ID | Что | Где | Статус |
| --- | --- | --- | --- |
| D1 | События спана обходят редактирование логов: `_redact` копирует `events: record.events` без изменений, поэтому вложенные события спана попадают в выводы нередактированными | `core/rpc_dart/lib/src/logger/log_controller.dart:364` | проверено |
| D2 | http2 отправляет пиру сырой текст ошибки: `'Request rejected: $error'`, в обход default-deny `wireStatusFor`, который использует другой путь | `transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport_inbound.dart:162` | проверено |
| D3 | Консоль сборщика логов печатает удалённые `message`, `data` и `error` без экранирования: CR/LF подделывают записи, ESC действует на терминал оператора. `ConsoleOutput` в ядре их экранирует | `core/rpc_dart_log/lib/src/log_console.dart:81-114`, `mcp_buffer.dart:483-519` | проверено |
| D4 | `RpcWebSocketCallerTransport` не реализует `IRpcConnectionBufferTotal`, поэтому peer-соединение поверх него не разделяет общий лимит буфера соединения; эффект не измерен | `transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart:27-32` | проверено (интерфейс отсутствует) |
| D5 | Zero-copy unary запускает обработчик на первом кадре запроса и молча отбрасывает второй запрос; codec unary ждёт конца стрима и отвечает INTERNAL | `core/rpc_dart/lib/src/endpoint/responder_pipeline_responders.dart:102-106` vs `rpc/streams/unary/responder.dart:566-653` | проверено (флаг есть) |
| D6 | `closeForProtocolError`/`closeForOversize` пропускают освобождение `_buf`, которое делает `close()`, поэтому буфер сборки остаётся занятым | `core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart:686-722` | только аудитор |
| D7 | Потолок явной политики на websocket-сервере не имеет нижней границы, в отличие от caller: строгая политика рвёт соединение вместо отказа в одном вызове | `transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart:186-204` vs `websocket_caller_transport.dart:388-394` | только аудитор |
| D8 | Генератор: дескриптор файла не содержит `syntax = "proto3"` (читается как proto2); переопределение кодека для метода выводится на каждый ТИП, поэтому утекает в другие методы в порядке объявления | `core/rpc_dart_generator/lib/src/generator.dart:1389-1396, 413-443` | только аудитор |
| D9 | `selectResponseEncoding` сравнивает сырые значения и возвращает `"Identity"` для `"Identity, gzip"` | `core/rpc_dart/lib/src/core/compression.dart:222-230` | только аудитор |
| D10 | `GrpcHealthCheckContract` использует имя сервиса `grpc.health.v1.Health`, но говорит на CBOR, поэтому grpc_health_probe и gRPC-пробы k8s не могут его декодировать; комментарий обещает NOT_FOUND, который никто не отправляет | `core/rpc_dart/lib/src/integration/grpc_health.dart:51-93, 196-203` | только аудитор |
| D11 | Health во фреймворке не замечает переподключающийся или деградировавший транспорт: читает `collectEndpointMetrics()['isActive']` вместо типизированного `endpoint.health()` | `core/rpc_dart_framework/lib/src/rpc_app.dart:347-348` | только аудитор |

## Сквозные темы (наибольшая ценность)

**X1. Возможности, определяемые через `is`, требуют ручных форвардеров, и те
разошлись.** Восемь маркерных интерфейсов (`core/rpc_dart/lib/src/core/transport.dart:172-327`).
Пять форвардеров, у каждого свой поднабор:
`_ReconnectingTransportProxy` (нет ConnectionBufferTotal, NoMessageCredit),
http2 `_CapabilityPreservingTransport` (`rpc_http2_server.dart:784-914`, нет
ConnectionBufferTotal, StreamReset), `RpcWebSocketResponderTransport`,
`RpcSocketCallerTransport`, `RpcWebSocketCallerTransport` (D4). Пропущенный
молча откатывается к значениям по умолчанию. Направление: один `T? capability<T>()`
на `IRpcTransport` с телом по умолчанию (сторонние реализации продолжают
компилироваться), декораторы форвардят этот один метод. Тогда
`RpcWebSocketResponderTransport` и `RpcSocketCallerTransport` сводятся к
`RpcChannelTransport.fromChannel` (плюс форвардинг готовности). API: аддитивно в
ядре; deprecations в websocket и socket. Трудоёмкость M.

**X2. Бэклог записи существует трижды**, написан в одну неделю:
`rpc_socket_channel.dart:142-148, 245-263`, `websocket_bounded_upgrade.dart:300-357`
(`_WriteBacklog`), `http2_write_backlog.dart:17-138`. Константа 1 MiB трижды,
один и тот же комментарий слово в слово. Только websocket возобновляет чтение,
когда запись заканчивается. Направление: один хелпер в ядре (нужен только
`dart:async`), форма как в http2, nullable максимум, освобождение как в
websocket. Трудоёмкость M.

**X3. Жизненный цикл сервера на соединение скопирован между socket и
websocket**: защита «не оба сразу», `createWithContracts`, предупреждение один
раз при лимите, создание эндпоинта с освобождением сироты, освобождение,
drain-then-close
(`rpc_socket_server.dart:78-108, 375-511` vs `rpc_websocket_server.dart:70-107,
254-479`). Расхождения:` _release` в websocket не идемпотентен; фабрика websocket
логирует каждую ошибку дважды; фабрика socket теряет `prefaceTimeout`.
Направление: хелпер в ядре рядом с `drainUntilIdle`, с отказом, специфичным для
транспорта, в качестве параметра. Трудоёмкость M.

**X4. Переподключение реализовано трижды**: прокси `RpcClientConnection`
(водяной знак id), websocket на месте (множества членства, около половины
`websocket_caller_transport.dart`), http2 single-flight. И ядро, и документация
websocket называют `RpcClientConnection` рекомендуемым способом. Решение по
дизайну за владельцем. Трудоёмкость L.

**X5. У правил статуса и трейлеров нет единого места.**
- Сторона caller: сборщик одиночного ответа написан 3 раза
  (`unary/caller.dart:222-419`, `client/caller.dart:107-196`,
  `caller_pipeline.dart:897-926`; последний теряет маппинг дедлайна); «не-OK на
  END_STREAM — это ошибка» 3 раза с тремя уровнями логирования; onDone в
  `CallProcessor` заново реализует `RpcCallerTrailer.closedWithoutStatus`; ping
  разбирает `grpc-status` без ограничения 0..16.
- Транспорты: трейлеры собираются вручную вместо `RpcMetadata.forTrailer` (8
  мест, 3 кодировки, http и http2); «ended mid-message» заново набрано в http2,
  хотя в ядре есть `requestEndedMidMessage`/`responseEndedMidMessage`; маппинг
  не-200 и content-type в обоих caller; кадр `x-client-cancelled` собирается 5
  раз.
Направление: фабрики в ядре, затем провести все места через них. Трудоёмкость M.

**X6. Правило логирования нарушено примерно в 230 местах вызова.** Nullable
`LogScope?` с `_logger?.` в http responder и сервере, http2 caller, responder и
сервере, websocket-сервере, во фреймворке (`if (_log?.isDebug ?? false)`);
`RpcClientConnection` выставляет собственный typedef строкового логгера. Правилу
следуют только `RpcHttpCallerTransport` и пакет socket. Механическая работа.

**X7. История и измерения в комментариях lib**, вопреки правилу владельца:
сотни «used to», «measured», «round N», «B-N», хешей коммитов, таблиц в MiB, в
каждом срезе. Одно доходит до пользователей: текст исключения в
`core/rpc_dart/lib/src/contracts/contract.dart:117-118` («used to silently
replace»). Механическая работа, но объёмная.

## rpc_dart

- **C1. Unary — параллельная реализация** рядом с `CallProcessor` /
  `StreamProcessor`: `UnaryCaller` и `UnaryResponder` (~1700 строк) заново
  делают парсер, декомпрессор, метаданные, фрейминг, уведомление об отмене и
  маппинг дедлайна, плюс второй zero-copy путь для unary. Пайплайн 3 раза
  приводит `is UnaryResponder`. `ServerStreamResponder` уже делает на
  процессоре «один запрос, ждём до конца стрима, второй отклоняется». Включает
  D5. Направление: обслуживать unary как server-stream. API: экспортируемые
  классы меняются. Трудоёмкость L.
- **C2. Режим передачи решается в 3 местах, и они расходятся**: при `auto` и
  кодеках на zero-copy транспорте unary отправляет объект, остальные формы
  сериализуют (`_RpcCodecMode`, `caller_pipeline.dart:457, 528`,
  `unary/caller.dart:487-488`).
- **C3. Мелкие копии между формами вызова**: проверка аргументов codec/zero-copy
  10 раз; замыкание декомпрессора 4; поиск политики 2 (приватный в двух
  библиотеках); начальные метаданные клиента 3 (расхождение: `x-request-id`);
  `_checkContextBeforeCall` 3.
- **C4.** Прокачка запросов написана вручную дважды, хотя `SinkPump` существует;
  цикл ретрансляции ответа дважды.
- **C5.** Обёртки responder повторяют один скелет (completer `done`, bind,
  `_isActive`); обработчиком bidi управляет пайплайн, обработчиком server-stream
  — его responder; `IRpcResponder` выставляет только `id` и `close`, отсюда
  приведения типов.
- **C6.** У каждого `_ensure*Responder` есть ветка zero-copy и ветка codec;
  ветки bidi разошлись в логировании сбоев.
- **C7.** Полный конструктор `RpcContext` выписан 11 раз
  (`contracts/context.dart`); хелперы аутентификации дважды под разными
  именами; удаление учётных данных дважды.
- **C8.** Два типа регистрации (`RpcMethodRegistration`,
  `RpcZeroCopyMethodRegistration`) и binding с двумя nullable полями; граница
  `IRpcSerializable` вынуждает `_OpaqueValue`. Ломает API. Трудоёмкость L.
- **C9.** `RpcCallerContract` и `RpcPeerContract` каждый несут четыре метода
  `call*`.
- **C10.** `RpcChannelTransport` вручную воспроизводит `RpcStreamRouter`, чья
  собственная документация осуждает ручные копии.
- **C11.** Ограниченное множество id с вытеснением старейшего 4 раза (одно
  заимствует константу, названную для другого множества).
- **C12.** Заголовок кадра разбирается в mux 3 способами (один выделяет память
  на каждый chunk); `kFrameHeadroom` и `headerSize` — отдельные литералы;
  `maxFramedMessageBytes` — «единое место», но его формула повторена 5 раз.
- **C13.** Заголовок целого CBOR 3 раза, запись map 2; документация обещает
  «lax key coercion», а код бросает исключение.
- **C14.** `error_details.dart`: length-delimited запись 12 раз, цикл
  декодирования 7, с мёртвыми ветками.
- **C15.** Типы исключений живут в 4 файлах; `RpcException` задокументирован
  как абстрактный, но конкретный; `wireStatusFor` не видит исключений контекста.
- **C16.** У `RpcMetadata` есть второй, менее строгий парсер пути за геттерами
  без вызовов из lib.
- **C17. Слои**: `core/drain.dart` импортирует `endpoint/`;
  `buffered_broadcast.dart` импортирует публичный barrel.
- **C18. Мёртвый код**: `core/platform_error_io.dart` и `_stub.dart`;
  `convertMap`, `RpcCodec.fromBytes`, `RpcMessage.endOfStream`,
  `RpcList.empty(capacity)` (игнорируется); `_sendGrpcErrorAndCleanup(context:)`
  передаётся в 8 местах, нигде не читается; самоприсваивание в `updateContext`;
  неиспользуемые члены `_RpcZeroCopyUnaryResponder`; `_isDoubleTyped` всегда
  false.
- **C19.** Логгер: записи пересобираются вручную 4 раза, конструктор `LogScope`
  4 раза, разбор уровня 5.
- **C20.** Resilience: правило pushback дважды; пары методов circuit breaker
  идентичны; счётчики rate limiter повторяют поля.
- **C21.** Отслеживание вызовов (`cancelMethod`, `trackedMethods`) живёт на
  `RpcCallerEndpoint`, а не на миксине, которому принадлежит состояние, поэтому
  у `RpcPeerEndpoint` его нет.
- **C22.** Примитивы: одно тело сравнения скопировано 12 раз; `RpcBool` и
  `RpcString` проглатывают некорректный ввод, тогда как числовые типы бросают
  исключение; `RpcNum` разбирает строки через `double` и теряет int больше 2^53.

## Транспорты

- **T1. Состояние стрима в http2 разнесено по параллельным map**: 13 в caller,
  9 в responder, 5 мест очистки, каждое чистит свой поднабор (собственные
  комментарии кода это признают). Направление: одна запись на стрим с
  `dispose()`. Трудоёмкость L.
- **T2. Копии между caller и responder в http2**: учёт управления потоком;
  `connect` vs `secureConnect`; dial заново реализует два хелпера; создание
  парсера, цикл DATA, `_emitStreamError`, ограниченное закрытие;
  `_maxPolicyViolations = 256` три раза.
- **T3.** http responder заново считает сумму метаданных, которую сразу после
  считает `validateMetadata`.
- **T4.** http responder — единственный транспорт, принимающий nullable политику
  (null отключает его собственные проверки). Изменение ломающее; решает
  владелец.
- **T5. Мёртвый код в http2**: `filterStreamEvents` (только тесты),
  недостижимая проверка ASCII, параметр `policy`, который никогда не null,
  `kGrpcUserAgent = 'rpc-dart/1.0.0'`, не совпадающий ни с одной версией.
- **T6.** Серверный сокет с ограничением заголовков скопирован между websocket и
  http (~200 строк); для общего кода нужна io-only библиотека в ядре.
- **T7.** `RpcWasmBridge` — это `IRpcChannel` под другим именем;
  `_RpcWasmChannel` только форвардит его.
- **T8.** Потолок сообщения websocket вычисляется дважды, и копии расходятся
  (D7).
- **T9.** Каналы isolate для VM и web — параллельные копии; typedef точки входа
  объявлен 3 раза; `policy` в `runRpcIsolateManagerWorker` nullable только на
  web; два комментария называют `args[4]` вместо `args[3]`.
- **T10. Мелочи**: дублирующийся `@override` (`websocket_caller_transport.dart:675,
  681`); неверный комментарий в barrel;` _printable `копирует` _peerText` из
  ядра.

## Компаньоны ядра

- **P1.** Запись protobuf скопирована между генератором и grpc_reflection с
  обоснованием «`publish_to: none`», чего pubspec reflection не содержит (пакет
  опубликован, 0.3.0). Включает D8.
- **P2.** Health во фреймворке преобразует типизированные статусы в строковые
  map и обратно; цикл модулей скопирован в `RpcTestApp`. Включает D11.
- **P3.** Интерцепторы «наблюдать каждую форму вызова» 4 раза (во фреймворке
  ErrorReporting, CallMetrics, `RpcCallSpy`, база OTel); строки типа вызова
  различаются (`serverStream` vs `server_stream`); копии во фреймворке никогда
  не записывают отменённый стрим.
- **P4.** `RpcTestApp` заново реализует жизненный цикл `RpcApp` без таймаута
  завершения и проглатывает ошибки teardown.
- **P5.** Компаньон сжатия заново реализует ограниченный gzip inflate из ядра;
  они расходятся в том, ограничен ли один `add` всего буфера (измерить);
  минимальные размеры 18 vs 20.
- **P6.** В grpc_reflection два читателя protobuf; один не проверяет границы при
  пропусках.
- **P7.** Внутренности генератора: два идентичных хелпера кодеков, игнорирующих
  собственные параметры; эмиттеры регистрации различаются только именем;
  неиспользуемые поля.
- **P8.** У `LogRecord` нет `traceId` в sealed-базе, поэтому потребители делают
  type-switch.
- **P9.** Dartdoc фреймворка противоречит коду: несуществующий
  `RpcClientModule`; «Throws StateError» шесть раз там, где бросается
  `RpcStatusException`; порядок `onStart`/`onStop` описан наоборот.
- **P10.** Контракт rpc_dart_log написан вручную (рекомендуемый способ —
  генератор); `sessionId` всегда 1; MCP-сервер сообщает 0.1.0, в pubspec 0.3.1.
- **P11.** `approxJsonBytes` 3 раза в log, notify и data.
- **P12.** Два enum в ядре для четырёх форм вызова (`RpcMethodKind`,
  `RpcMethodType`); генератор сопоставляет их вручную.

## Рассмотрено и не является находками

- Серверы уже разделяют `drainUntilIdle`, `inFlightResponderCalls`,
  `notifyWithoutDying`; http и http2 построены на `RpcStreamIdManager`,
  `RpcStreamRouter`, `BufferedBroadcastController` из ядра.
- `CallProcessor` vs `StreamProcessor` — реальное разделение (caller владеет id,
  дедлайном и отменой; responder владеет трейлером и кодировкой).
- То, что `UnaryCaller` не дожидается своей отправки перед ожиданием ответа, —
  намеренно и должно пережить любое слияние.
- `RpcFlowController` vs `RpcStreamBufferLedger`, собственные окна http2, три
  буфера до bind: разные задачи.
- Отказ socket через `destroy` vs код закрытия websocket; websocket-сервер, не
  владеющий своим стримом соединений; батчинг во Flutter-мосте.
- rpc_dart_log и OpenTelemetry не дублируют друг друга.

## Предлагаемый порядок

1. D1-D3: небольшие, реальные, два из них достижимы пиром.
2. X1: убирает целый класс молчаливых расхождений и два класса-обёртки.
3. X2, X3: свежие копии, их дешевле всего слить, пока они не разошлись дальше.
4. X5: единое место для правил статуса и трейлеров.
5. C1 (вместе с C2, C3): самое крупное; меняет экспортируемые типы, значит,
   мажорная версия.
6. X6, X7, C18: механическая работа, в любое время.
