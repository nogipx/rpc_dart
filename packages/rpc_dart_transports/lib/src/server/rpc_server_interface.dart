// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

/// Интерфейс для RPC серверов
///
/// Определяет общий контракт для всех типов RPC серверов (HTTP/2, WebSocket, gRPC, etc.)
/// Используется в [RpcServerBootstrap] для абстракции от конкретной реализации транспорта.
abstract interface class IRpcServer {
  /// Хост сервера
  String get host;

  /// Порт сервера
  int get port;

  /// Запущен ли сервер
  bool get isRunning;

  /// Активные RPC endpoints
  List<RpcResponderEndpoint> get endpoints;

  /// Запускает сервер
  Future<void> start();

  /// Останавливает сервер
  Future<void> stop();
}

/// Фабрика для создания RPC серверов с предустановленными контрактами
abstract interface class IRpcServerFactory {
  /// Создает сервер с автоматической регистрацией контрактов
  IRpcServer create({
    required int port,
    required List<RpcResponderContract> contracts,
    String host = 'localhost',
    RpcLogger? logger,
  });

  /// Тип транспорта (для логирования и отладки)
  String get transportType;
}
