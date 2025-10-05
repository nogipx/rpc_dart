// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'websocket_base_transport.dart';

/// Реализация клиентского WebSocket транспорта.
///
/// Клиентский транспорт инициирует соединение с сервером
/// и использует нечетные StreamID для мультиплексирования.
final class RpcWebSocketCallerTransport extends RpcWebSocketTransportBase {
  /// Реализация менеджера ID для клиентской стороны
  final RpcStreamIdManager _streamIdManager = RpcStreamIdManager(
    isClient: true,
  );

  @override
  RpcStreamIdManager get idManager => _streamIdManager;

  @override
  bool get isClient => true;

  /// Создает новый клиентский WebSocket транспорт
  ///
  /// [channel] WebSocket канал для коммуникации
  /// [logger] Опциональный логгер для отладки
  RpcWebSocketCallerTransport(
    super.channel, {
    super.logger,
    super.reconnectFactory,
  });

  /// Фабричный метод для создания клиентского WebSocket транспорта
  ///
  /// [uri] URI для подключения к WebSocket серверу
  /// [protocols] Опциональные подпротоколы WebSocket
  /// [headers] Опциональные HTTP заголовки для установки соединения
  /// [logger] Опциональный логгер для отладки
  static RpcWebSocketCallerTransport connect(
    Uri uri, {
    Iterable<String>? protocols,
    RpcLogger? logger,
  }) {
    WebSocketChannel openChannel() =>
        WebSocketChannel.connect(uri, protocols: protocols);

    final channel = openChannel();
    return RpcWebSocketCallerTransport(
      channel,
      logger: logger,
      reconnectFactory: () async => openChannel(),
    );
  }

  @override
  bool get supportsZeroCopy => false;
}
