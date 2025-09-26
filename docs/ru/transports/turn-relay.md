# TURN реле

`TurnRelayServer` реализует релей по RFC 5766 на чистом Dart. Клиенты
подключаются по TCP, а для пиров сервер выделяет либо UDP-сокеты, либо TCP-листенеры.
Листенер обрабатывает TURN-запросы Allocate, следит за разрешениями и каналами и
преобразует трафик от пиров в TURN Data или ChannelData кадры. Реализация
поставляется в составе `rpc_dart_transports`, но не зависит от `rpc_dart`, поэтому её
можно встраивать в любой UDP- или TCP-сервис, которому требуется обход NAT.

## Основные возможности

- **Помощники для TURN/STUN** — `TurnMessage`, `TurnAttribute` и утилиты
  кодируют XOR-адреса, DATA-атрибуты, время жизни и информацию о каналах, так что
  не приходится собирать бинарные буферы вручную.
- **Управление жизненным циклом allocation** — `TurnAllocation` отслеживает
  клиентские сокеты или TCP-листенеры, таймеры, разрешения на пиры и channel
  binding’и согласно RFC 5766.
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
- `relayPort` — UDP- или TCP-порт релея, на который должны подключаться пиры;
- `addPermission`, `hasPermission` и `bindChannel` реализуют правила безопасности
  TURN для разрешённых пиров и привязанных каналов;
- `onPeerData` получает датаграммы с relay-сокета и преобразует их обратно в
  TURN-сообщения.

Allocation истекает через `allocationLifetime` (по умолчанию 10 минут). Запрос
`Refresh` продлевает срок, а нулевой lifetime завершает allocation сразу.
Разрешения и каналы очищаются лениво по мере истечения TTL.

## Как работает клиент

1. **Allocate** — отправить запрос `Allocate` с нужным `REQUESTED-TRANSPORT`
   (по умолчанию UDP, для потокового транспорта — TCP). В успешном ответе придёт
   `XOR-RELAYED-ADDRESS`.
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
переопределить таймауты, параметры времени жизни, локальный адрес сокета,
используемый транспорт пиров или поведение по созданию разрешений:

```dart
final client = await TurnRelayClient.connect(
  serverAddress: server.bindAddress,
  serverPort: server.port,
  options: const TurnRelayClientOptions(
    requestTimeout: Duration(seconds: 3),
    allocationRefreshMargin: Duration(seconds: 10),
    autoCreatePermission: false,
    requestedTransport: TurnRequestedTransport.tcp,
  ),
);
```

Если параметр опустить, используются стандартные значения: 5-секундный таймаут
запросов, автоматическое создание разрешений и продление allocation за 30 секунд
до истечения срока.

## Использование `RpcTurnRelayPeer`

`RpcTurnRelayPeer` облегчает настройку RPC-пира поверх TURN. Объект сначала
создаёт подключение к релею и регистрирует контракты, а реальный адрес пира
можно указать позднее, когда второй участник сообщит `relayAddress` и
`relayPort`.

```dart
final peer = await RpcTurnRelayPeer.connectToRelay(
  serverAddress: relay.bindAddress,
  serverPort: relay.port,
  responderContracts: [EchoResponderContract()],
);

print('Мой TURN адрес: ${peer.relayAddress.address}:${peer.relayPort}');

// ... передайте адрес другому клиенту и получите его реквизиты ...

await peer.connectPeer(
  peerAddress: otherPeerAddress,
  peerPort: otherPeerPort,
);

final response = await peer.callerEndpoint.unaryRequest<RpcString, RpcString>(
  serviceName: 'echo',
  methodName: 'echo',
  requestCodec: RpcString.codec,
  responseCodec: RpcString.codec,
  request: RpcString('ping'),
);

print(response.value);
```

Метод `connectPeer()` лениво создаёт транспорты и endpoints. После него можно
использовать `callerEndpoint` для исходящих RPC-вызовов, а `responderEndpoint`
автоматически обслужит зарегистрированные контракты. Метод `close()` аккуратно
освобождает все ресурсы и может вызываться несколько раз подряд.

### Обмен приглашениями через QR

Всю процедуру подключения можно оставить внутри RPC-протокола, не поднимая
отдельный сигналинговый сервис. Последовательность будет такой:

1. Оба участника на старте приложения вызывают
   `RpcTurnRelayPeer.connectToRelay(...)` и регистрируют контракт с методом
   вроде `incomingInvite`.
2. Каждый клиент генерирует QR-код с собственными `relayAddress`, `relayPort` и
   дополнительными данными (например, именем пользователя или токеном проверки).
3. Когда пользователь А сканирует QR пользователя B, приложение А сразу
   выполняет `peer.connectPeer(peerAddress: bAddress, peerPort: bPort)`, а затем
   делает RPC-вызов `incomingInvite`, передавая свои координаты.
4. Обработчик на стороне B показывает пользователю запрос. Если тот соглашается,
   код вызывает `peer.connectPeer(...)` с адресом и портом А из полученных
   данных и только после этого возвращает положительный ответ.
5. После взаимного подтверждения обе стороны продолжают работать через те же
   caller/responder endpoints в рамках основной сессии.

Контракт может декодировать полезную нагрузку и устанавливать транспорт только
после явного согласия пользователя:

```dart
import 'dart:convert';
import 'package:universal_io/io.dart';

class ConnectionInvitationContract extends RpcResponderContract {
  ConnectionInvitationContract(this.peer, this.showPrompt)
      : super('ConnectionInvitation');

  final RpcTurnRelayPeer peer;
  final Future<bool> Function(Map<String, Object?> payload) showPrompt;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcBool>(
      methodName: 'incomingInvite',
      requestCodec: RpcString.codec,
      responseCodec: RpcBool.codec,
      handler: _handleInvite,
    );
  }

  Future<RpcBool> _handleInvite(
    RpcString request, {
    RpcContext? context,
  }) async {
    final payload = jsonDecode(request.value) as Map<String, Object?>;
    final accepted = await showPrompt(payload);

    if (accepted) {
      await peer.connectPeer(
        peerAddress: InternetAddress(payload['peerAddress']! as String),
        peerPort: payload['peerPort']! as int,
      );
    }

    return RpcBool(accepted);
  }
}
```

Пользователь А отправляет приглашение со своими координатами, чтобы B смог
подключиться после подтверждения:

```dart
final inviteAccepted = await peer.callerEndpoint.unaryRequest<RpcString, RpcBool>(
  serviceName: 'ConnectionInvitation',
  methodName: 'incomingInvite',
  requestCodec: RpcString.codec,
  responseCodec: RpcBool.codec,
  request: RpcString(jsonEncode({
    'peerAddress': peer.relayAddress.address,
    'peerPort': peer.relayPort,
    'displayName': currentUserName,
  })),
);

if (!inviteAccepted.value) {
  // пользователь на другой стороне отклонил подключение
  return;
}
```

Так QR-обмен, подтверждение и запуск сессии остаются в рамках одного
RPC-протокола, а TURN-релей продолжает транслировать зашифрованный трафик
транспортного уровня.

## Вспомогательные API

В `turn_message.dart` лежат функции, которые помогают собирать и разбирать TURN
кадры:

- `TurnMessage.encode()` / `TurnMessage.decode(...)`;
- `encodeXorAddress` / `decodeXorAddress`;
- `encodeLifetime` / `decodeLifetime`;
- `encodeData`.

Этого достаточно для UDP-профиля RFC 5766; обрамление TCP-потока выполняет
`TurnTcpFrameDecoder` внутри релея. В режиме TCP allocation поднимает
листенер и прокидывает байты через установленные подключения.

## Ограничения

- Управление подключением происходит по TCP. Для пиров доступны UDP- и TCP-режимы,
  однако TLS и DTLS пока не реализованы, а TCP-сценарий предполагает, что пиры
  могут самостоятельно подключиться к опубликованному релейному порту.
- Аутентификация (долгосрочные/краткосрочные креденшелы) отсутствует, поэтому
  ограничивайте доступ на сетевом уровне или добавляйте собственную логику.
- Нет квот и механизма ALTERNATE-SERVER.

Даже с этими ограничениями релей подходит для тестов, прототипов и закрытых
развёртываний, а также как основа для более функционального TURN-сервиса.
