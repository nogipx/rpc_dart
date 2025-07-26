// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import 'websocket_base_transport.dart';

/// Реализация серверного WebSocket транспорта.
///
/// Серверный транспорт принимает соединение от клиента
/// и использует четные StreamID для мультиплексирования.
class RpcWebSocketResponderTransport extends RpcWebSocketTransportBase {
  /// Реализация менеджера ID для серверной стороны
  final RpcStreamIdManager _streamIdManager =
      RpcStreamIdManager(isClient: false);

  @override
  RpcStreamIdManager get idManager => _streamIdManager;

  @override
  bool get isClient => false;

  /// Создает новый серверный WebSocket транспорт
  ///
  /// [channel] WebSocket канал для коммуникации
  /// [logger] Опциональный логгер для отладки
  RpcWebSocketResponderTransport(
    super.channel, {
    super.logger,
  });

  @override
  bool get supportsZeroCopy => false;
}
