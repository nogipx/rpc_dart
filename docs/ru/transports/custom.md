# Пользовательский транспорт

Пользовательский транспорт позволяет подключить RPC Dart к любому каналу
доставки сообщений: очередям, брокерам, нестандартным сетевым протоколам или
внутрипроцессным шинам.

## Что должен делать транспорт

Чтобы интегрировать новый транспорт, реализуйте интерфейс `IRpcTransport`.
Транспорт отвечает за:

- создание stream ID (обычно через `RpcStreamIdManager`);
- доставку входящих сообщений через `incomingMessages`;
- отправку `sendMetadata`, `sendMessage`, `finishSending`;
- корректное завершение `close()` и освобождение ресурсов;
- диагностику через `health()` (и опционально `reconnect()` для клиента).

Если транспорт пересекает границы процесса или сети, держите
`supportsZeroCopy == false` и не используйте `sendDirectObject`.

## Минимальный каркас

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart';

class MyCustomTransport implements IRpcTransport {
  final _incoming = StreamController<RpcTransportMessage>.broadcast();
  final _ids = RpcStreamIdManager(isClient: true);
  var _closed = false;

  @override
  bool get isClient => true;

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsZeroCopy => false;

  @override
  Stream<RpcTransportMessage> get incomingMessages => _incoming.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      incomingMessages.where((m) => m.streamId == streamId);

  @override
  int createStream() => _ids.generateId();

  @override
  bool releaseStreamId(int streamId) => _ids.releaseId(streamId);

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    // сериализуйте и отправьте метаданные через ваш канал
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    // отправьте data через ваш канал
  }

  @override
  Future<void> finishSending(int streamId) async {
    // при необходимости: закрыть half-close/flush
  }

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    throw UnsupportedError('Zero-copy disabled');
  }

  @override
  Future<RpcHealthStatus> health() async => RpcHealthStatus.healthy(
        component: runtimeType.toString(),
        message: 'OK',
        details: {'isClosed': _closed},
      );

  @override
  Future<RpcHealthStatus> reconnect() async => RpcHealthStatus.degraded(
        component: runtimeType.toString(),
        message: 'Reconnect not implemented',
        details: {'supported': false},
      );

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incoming.close();
  }
}
```
