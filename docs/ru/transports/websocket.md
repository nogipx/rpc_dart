<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# WebSocket транспорт

WebSocket транспорт удерживает одно TCP соединение и мультиплексирует множество
RPC вызовов. Он подходит для дашбордов в реальном времени, совместной работы и
сценариев, где клиенту нужно отправлять обновления без повторного установления
соединения.

## Когда использовать WebSocket

- **Двунаправленные обновления** – UI клиенты могут отправлять команды и получать
  стриминговые ответы в рамках одной сессии.
- **Минимальная задержка** – нет накладных расходов на повторные HTTP
  подключения при push-обновлениях.
- **Совместимость с фаерволами** – достаточно одного исходящего порта (например,
  443).

## Настройка клиента

Создайте транспорт с помощью `RpcWebSocketCallerTransport.connect` и передайте
его в `RpcCallerEndpoint`:

```dart

Future<void> main() async {
  final transport = RpcWebSocketCallerTransport.connect(
Uri.parse('wss://api.example.com/rpc'),
protocols: const ['rpc-dart'],
logger: RpcLogger('WebSocketClient'),
  );

  final caller = RpcCallerEndpoint(transport: transport);
  final chat = ChatCaller(caller);

  final stream = chat.joinRoom('general', 'u-42');
  stream.listen((message) => print('[$message]'));
}
```

`RpcWebSocketCallerTransport.connect` автоматически настраивает фабрику
переподключения, поэтому при обрыве соединения можно вызвать
`transport.reconnect()`.

## Настройка сервера

Используйте `RpcWebSocketServer`, если у вас есть поток уже апгрейженных
`WebSocketChannel` (например, через `shelf_web_socket` или `HttpServer`):

```dart
final connections = controller.stream; // Stream<WebSocketChannel>

final server = RpcWebSocketServer.createWithContracts(
  connections: connections,
  port: 8080,
  contracts: [ChatResponder()],
  logger: RpcLogger('WebSocketServer'),
);

await server.start();
```

Для низкоуровневого контроля создайте `RpcWebSocketResponderTransport`
напрямую из `WebSocketChannel` и передайте его в `RpcResponderEndpoint`.

## Расширение транспорта

Для низкоуровневого контроля можно расширить `RpcWebSocketTransportBase` из
`rpc_dart_transports` (или обернуть готовые caller/responder транспорты) и
реализовать собственную политику переподключения/буферизации/ограничения
скорости. Важно, чтобы `incomingMessages` оставался согласованным, а все данные
с wire-уровня проходили строгую валидацию.

Если транспорт пересекает границы процесса или сети, держите `supportsZeroCopy`
выключенным.

## Диагностика

Все WebSocket транспорты реализуют `IRpcTransport`, поэтому можно:

- вызывать `transport.health()` для получения снимков `RpcHealthStatus`;
- инициировать переподключение через `transport.reconnect()` (на стороне
  клиента);
- закрывать соединение методом `transport.close()` при остановке эндпоинта.

Сочетайте эти возможности с `RpcEndpoint.health()` и `RpcEndpointPingProtocol`
из основной библиотеки, чтобы строить дашборды и оповещения по состоянию
соединений.
