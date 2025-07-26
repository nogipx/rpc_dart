<div align="center">
  <img src="logo/logo.svg" alt="RPC Dart Transports Logo" width="80" height="80">
  <h1>RPC Dart Transports</h1>
  <p><strong>Библиотека транспортов для RPC Dart - предоставляет различные способы передачи RPC сообщений.</strong></p>
  
  <!-- <p>
    <a href="https://pub.dev/packages/rpc_dart"><img src="https://img.shields.io/pub/v/rpc_dart.svg" alt="Pub Version"></a>
    <a href="https://github.com/nogipx/rpc_dart/actions/workflows/ci.yml"><img src="https://github.com/nogipx/rpc_dart/workflows/CI/badge.svg" alt="CI"></a>
    <a href="https://coveralls.io/github/nogipx/rpc_dart?branch=main"><img src="https://coveralls.io/repos/github/nogipx/rpc_dart/badge.svg?branch=main" alt="Coverage Status"></a>
  </p> -->
<!--   
  <p>
    <a href="README.md">🇺🇸 English</a> | 
    <a href="README_RU.md">🇷🇺 Русский</a>
  </p> -->
</div>

## Поддерживаемые транспорты

### 🌐 WebSocket Transport
- Двунаправленная связь через WebSocket
- Поддержка мультиплексирования потоков
- Автоматическое переподключение

### 🔄 Isolate Transport  
- Связь между Dart изолятами
- Высокая производительность для CPU-интенсивных задач
- Изоляция ошибок

### 🚀 HTTP/2 Transport
- Современный HTTP/2 протокол
- gRPC-совместимый формат сообщений
- Мультиплексирование потоков
- Поддержка TLS/SSL

## HTTP/2 Transport

HTTP/2 транспорт реализует gRPC-совместимый протокол поверх HTTP/2. Поддерживает как клиентские, так и серверные соединения.

### Особенности

- **Мультиплексирование**: Множественные RPC вызовы через одно соединение
- **gRPC совместимость**: Использует стандартные gRPC headers и frame формат
- **TLS поддержка**: Защищенные HTTPS соединения
- **Stream управление**: Автоматическое управление HTTP/2 streams

### Использование

#### Клиентское соединение

```dart
import 'package:rpc_dart_transports/rpc_dart_transports.dart';

// HTTP соединение
final transport = await Http2ClientTransport.connect(
  host: 'localhost',
  port: 8080,
);

// HTTPS соединение
final secureTransport = await Http2ClientTransport.secureConnect(
  host: 'api.example.com',
  port: 443,
);

// Создание RPC вызова
final streamId = transport.createStream();
final metadata = RpcMetadata.forClientRequest('MyService', 'MyMethod');

await transport.sendMetadata(streamId, metadata);
await transport.sendMessage(streamId, requestData);
await transport.finishSending(streamId);

// Обработка ответов
transport.getMessagesForStream(streamId).listen((message) {
  if (message.payload != null) {
    // Обработка данных ответа
    print('Received: ${utf8.decode(message.payload!)}');
  }
});
```

#### Серверное соединение

```dart
import 'package:http2/http2.dart' as http2;

// Создание HTTP/2 сервера (требует дополнительной настройки)
final serverConnection = http2.ServerTransportConnection.viaSocket(socket);
final transport = Http2ServerTransport.create(
  connection: serverConnection,
  logger: logger,
);

// Обработка входящих сообщений
transport.incomingMessages.listen((message) {
  if (message.isMetadataOnly) {
    // Обработка метаданных запроса
    print('Method: ${message.methodPath}');
  } else if (message.payload != null) {
    // Обработка данных запроса
    final requestData = message.payload!;
    
    // Отправка ответа
    final responseData = processRequest(requestData);
    transport.sendMessage(message.streamId, responseData);
    transport.finishSending(message.streamId);
  }
});
```

### Примеры

Смотрите `example/http2_example.dart` для полного примера использования.

## Лицензия

MIT
