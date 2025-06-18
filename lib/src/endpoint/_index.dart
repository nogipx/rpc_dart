// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

part 'caller_endpoint.dart';
part 'responder_endpoint.dart';

/// Базовый класс для всех RPC эндпоинтов
abstract base class RpcEndpointBase {
  final IRpcTransport _transport;
  final List<IRpcMiddleware> _middlewares = [];
  final String? debugLabel;
  final RpcLoggerColors? loggerColors;

  RpcLogger get logger;
  bool _isActive = true;

  RpcEndpointBase({
    required IRpcTransport transport,
    this.debugLabel,
    this.loggerColors,
  }) : _transport = transport;

  void addMiddleware(IRpcMiddleware middleware) {
    _middlewares.add(middleware);
    logger.internal('Добавлен middleware: ${middleware.toString()}');
  }

  bool get isActive => _isActive;

  IRpcTransport get transport => _transport;

  /// Запускает эндпоинт
  void start() {
    logger.internal('Запуск RPC эндпоинта');
  }

  /// Останавливает эндпоинт
  void stop() {
    logger.internal('Остановка RPC эндпоинта');
  }

  Future<void> close() async {
    if (!_isActive) return;

    logger.internal('Закрытие RpcEndpoint');
    _isActive = false;
    _middlewares.clear();

    try {
      // Закрываем транспорт и ожидаем завершения с таймаутом
      await _transport.close().timeout(
        Duration(seconds: 5),
        onTimeout: () {
          logger.warning('Таймаут при закрытии транспорта');
          // Не выбрасываем исключение, просто логируем предупреждение
          return;
        },
      );
    } catch (e) {
      logger.warning('Ошибка при закрытии транспорта: $e');
      // Не пробрасываем ошибку дальше, чтобы гарантировать, что метод close()
      // всегда завершается успешно
    } finally {
      // Гарантируем, что эндпоинт помечен как неактивный
      _isActive = false;
      logger.internal('RpcEndpoint закрыт');
    }
  }
}
