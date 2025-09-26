# TURN реле

`TurnRelayServer` реализует релей по RFC 5766 на чистом Dart. Клиенты
подключаются по TCP, а для пиров сервер выделяет UDP-сокеты. Листенер обрабатывает
TURN-запросы Allocate, следит за разрешениями и каналами и преобразует трафик от
пиров в TURN Data или ChannelData кадры. Реализация поставляется в составе
`rpc_dart_transports`, но не зависит от `rpc_dart`, поэтому её можно встраивать в
любой UDP-сервис, которому требуется обход NAT.

## Основные возможности

- **Помощники для TURN/STUN** — `TurnMessage`, `TurnAttribute` и утилиты
  кодируют XOR-адреса, DATA-атрибуты, время жизни и информацию о каналах, так что
  не приходится собирать бинарные буферы вручную.
- **Управление жизненным циклом allocation** — `TurnAllocation` отслеживает
  клиентские сокеты, таймеры, разрешения на пиры и channel binding’и согласно
  RFC 5766.
- **Полная поддержка методов TURN** — сервер обрабатывает `Allocate`, `Refresh`,
  `CreatePermission`, `ChannelBind` и `Send`, а входящий пиринговый трафик
  отправляет клиенту в виде Data-индикаций или ChannelData-сообщений.
- **Встраиваемый логгер** — `TurnRelayLogger` позволяет адаптировать вывод под
  вашу систему логирования без дополнительных пакетов.

## Запуск релея

```dart
import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:universal_io/io.dart';

Future<void> main() async {
  final relay = TurnRelayServer(
    bindAddress: InternetAddress.anyIPv4,
    bindPort: 3478,
    logger: TurnRelayLogger(
      scope: 'turn',
      onInfo: (message) => print('[INFO] $message'),
      onWarning: (message) => print('[WARN] $message'),
      onError: (message, {error, stackTrace}) {
        print('[ERROR] $message');
        if (error != null) {
          print('  error: $error');
        }
        if (stackTrace != null) {
          print('  stack: $stackTrace');
        }
      },
    ),
  );

  await relay.start();
  print('TURN relay listening on ${relay.bindAddress.address}:${relay.port}');

  // ... держим процесс живым ...

  await relay.stop();
}
```

Если листенер привязан к приватному адресу, передайте `relayAddress`, чтобы в
`XOR-RELAYED-ADDRESS` возвращался внешний IP.

## Жизненный цикл allocation

Каждый успешный `Allocate` создаёт `TurnAllocation`:

- `clientAddress` / `clientPort` — TCP-подключение клиента;
- `relayPort` — UDP-порт релея, на который должны отправлять пиры;
- `addPermission`, `hasPermission` и `bindChannel` реализуют правила безопасности
  TURN для разрешённых пиров и привязанных каналов;
- `onPeerData` получает датаграммы с relay-сокета и преобразует их обратно в
  TURN-сообщения.

Allocation истекает через `allocationLifetime` (по умолчанию 10 минут). Запрос
`Refresh` продлевает срок, а нулевой lifetime завершает allocation сразу.
Разрешения и каналы очищаются лениво по мере истечения TTL.

## Как работает клиент

1. **Allocate** — отправить запрос `Allocate` (`REQUESTED-TRANSPORT = UDP`). В
   успешном ответе придёт `XOR-RELAYED-ADDRESS`.
2. **CreatePermission** — разрешить нужных пиров отдельными запросами.
3. **Передача данных** — использовать индикации `Send` (`XOR-PEER-ADDRESS` +
   `DATA`) или выполнить `ChannelBind` и слать ChannelData ради меньших накладных
   расходов.
4. **Приём трафика от пиров** — релей возвращает Data-индикации или ChannelData в
   зависимости от наличия channel binding’а на пира.
5. **Refresh / завершение** — `Refresh` продлевает срок жизни, а запрос с нулевой
   длительностью закрывает allocation.

Интеграционный тест `turn_relay_server_test.dart` показывает этот сценарий: TURN
клиент общается с пиром через релей.

### Настройки клиента

`TurnRelayClient.connect` принимает объект `TurnRelayClientOptions`, если нужно
переопределить таймауты, параметры времени жизни, локальный адрес сокета или
поведение по созданию разрешений:

```dart
final client = await TurnRelayClient.connect(
  serverAddress: server.bindAddress,
  serverPort: server.port,
  options: const TurnRelayClientOptions(
    requestTimeout: Duration(seconds: 3),
    allocationRefreshMargin: Duration(seconds: 10),
    autoCreatePermission: false,
  ),
);
```

Если параметр опустить, используются стандартные значения: 5-секундный таймаут
запросов, автоматическое создание разрешений и продление allocation за 30 секунд
до истечения срока.

## Вспомогательные API

В `turn_message.dart` лежат функции, которые помогают собирать и разбирать TURN
кадры:

- `TurnMessage.encode()` / `TurnMessage.decode(...)`;
- `encodeXorAddress` / `decodeXorAddress`;
- `encodeLifetime` / `decodeLifetime`;
- `encodeData`.

Этого достаточно для UDP-профиля RFC 5766; обрамление TCP-потока выполняет
`TurnTcpFrameDecoder` внутри релея.

## Ограничения

- Управление подключением происходит по TCP, но поддерживается только UDP
  релей для пиров. TCP allocations, TLS и DTLS пока не реализованы.
- Аутентификация (долгосрочные/краткосрочные креденшелы) отсутствует, поэтому
  ограничивайте доступ на сетевом уровне или добавляйте собственную логику.
- Нет квот и механизма ALTERNATE-SERVER.

Даже с этими ограничениями релей подходит для тестов, прототипов и закрытых
развёртываний, а также как основа для более функционального TURN-сервиса.
