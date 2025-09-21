// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

part 'caller_endpoint.dart';
part 'responder_endpoint.dart';

/// Результат проверки состояния RPC эндпоинта.
final class RpcEndpointHealth {
  /// Снимок состояния самого эндпоинта.
  final RpcHealthStatus endpointStatus;

  /// Состояние зависимостей эндпоинта (как правило, транспорта).
  final Map<String, RpcHealthStatus> dependencies;

  /// Время формирования отчета.
  final DateTime timestamp;

  RpcEndpointHealth({
    required this.endpointStatus,
    Map<String, RpcHealthStatus>? dependencies,
    DateTime? timestamp,
  })  : dependencies = Map.unmodifiable(dependencies ?? const {}),
        timestamp = timestamp ?? DateTime.now();

  /// Возвращает true, если эндпоинт и все зависимости находятся в рабочем
  /// состоянии.
  bool get isHealthy =>
      endpointStatus.isHealthy &&
      dependencies.values.every((status) => status.isHealthy);

  /// Состояние основного транспорта эндпоинта (если присутствует).
  RpcHealthStatus? get transportStatus => dependencies['transport'];
}

/// Константы и метаданные протокола ping между эндпоинтами.
abstract final class RpcEndpointPingProtocol {
  /// Имя служебного сервиса для ping запросов.
  static const String serviceName = '_rpc.System';

  /// Имя служебного метода для ping запросов.
  static const String methodName = 'Ping';

  /// Полный ключ метода (service.method).
  static const String methodKey = '$serviceName.$methodName';

  /// HTTP/2 путь метода /Service/Method.
  static const String methodPath = '/$serviceName/$methodName';

  /// Заголовок с отметкой времени отправки ping от клиента.
  static const String requestTimestampHeader = 'x-rpc-ping-timestamp';

  /// Заголовок с отметкой времени обработки ping на стороне responder.
  static const String responseTimestampHeader = 'x-rpc-pong-timestamp';

  /// Заголовок с debug label responder эндпоинта.
  static const String responseDebugLabelHeader = 'x-rpc-pong-endpoint';

  /// Заголовок с типом транспорта responder эндпоинта.
  static const String responseTransportHeader = 'x-rpc-pong-transport';
}

/// Результат ping-запроса между эндпоинтами.
final class RpcEndpointPingResult {
  /// Время отправки ping-запроса.
  final DateTime sentAt;

  /// Время получения ответа.
  final DateTime receivedAt;

  /// Полный круговой трип (RTT) ping-запроса.
  final Duration roundTrip;

  /// Отметка времени обработки ping на responder, если была передана.
  final DateTime? responderTimestamp;

  /// Debug label responder эндпоинта, если указан.
  final String? responderDebugLabel;

  /// Тип транспорта responder эндпоинта, если передан.
  final String? responderTransportType;

  /// Все заголовки ответа в удобном для чтения формате.
  final Map<String, String> responseHeaders;

  const RpcEndpointPingResult({
    required this.sentAt,
    required this.receivedAt,
    required this.roundTrip,
    this.responderTimestamp,
    this.responderDebugLabel,
    this.responderTransportType,
    Map<String, String>? responseHeaders,
  }) : responseHeaders = Map.unmodifiable(responseHeaders ?? const {});
}

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

  /// Собирает метрики эндпоинта, которые будут добавлены в отчет о состоянии.
  /// Наследники могут переопределить метод и добавить свои показатели.
  Map<String, Object?> collectEndpointMetrics() {
    final metrics = <String, Object?>{
      'isActive': _isActive,
      'middlewareCount': _middlewares.length,
      'transportClosed': _transport.isClosed,
      'transportType': _transport.runtimeType.toString(),
    };

    if (debugLabel != null) {
      metrics['debugLabel'] = debugLabel;
    }

    return metrics;
  }

  RpcHealthStatus _createEndpointStatus(RpcHealthStatus transportStatus) {
    final metrics = collectEndpointMetrics();
    final componentName = logger.name;

    if (!_isActive) {
      return RpcHealthStatus.closed(
        component: componentName,
        message: 'Endpoint closed',
        details: metrics,
      );
    }

    switch (transportStatus.level) {
      case RpcHealthLevel.healthy:
        return RpcHealthStatus.healthy(
          component: componentName,
          message: 'Endpoint active',
          details: metrics,
        );
      case RpcHealthLevel.reconnecting:
        return RpcHealthStatus.reconnecting(
          component: componentName,
          message: 'Endpoint waiting for transport reconnection',
          details: metrics,
        );
      case RpcHealthLevel.degraded:
        return RpcHealthStatus.degraded(
          component: componentName,
          message: 'Endpoint degraded due to transport state',
          details: metrics,
        );
      case RpcHealthLevel.unhealthy:
        return RpcHealthStatus.unhealthy(
          component: componentName,
          message: 'Endpoint unavailable because transport failed',
          details: metrics,
        );
      case RpcHealthLevel.closed:
        return RpcHealthStatus.degraded(
          component: componentName,
          message: 'Endpoint active but transport closed',
          details: {...metrics, 'transportState': transportStatus.level.name},
        );
    }
  }

  Future<RpcHealthStatus> _safeTransportHealth() async {
    try {
      return await _transport.health();
    } catch (error, stackTrace) {
      await logger.error(
        'Transport health check failed: $error',
        error: error,
        stackTrace: stackTrace,
      );

      return _transport.isClosed
          ? RpcHealthStatus.closed(
              component: _transport.runtimeType.toString(),
              message: 'Transport is closed after failed health check',
              details: {
                'isClosed': _transport.isClosed,
                'error': error.toString(),
              },
            )
          : RpcHealthStatus.unhealthy(
              component: _transport.runtimeType.toString(),
              message: 'Transport health check failed: $error',
              details: {
                'isClosed': _transport.isClosed,
                'error': error.toString(),
              },
            );
    }
  }

  /// Возвращает снимок состояния эндпоинта и его транспорта.
  Future<RpcEndpointHealth> health({RpcHealthStatus? transportOverride}) async {
    final transportStatus = transportOverride ?? await _safeTransportHealth();
    final endpointStatus = _createEndpointStatus(transportStatus);

    return RpcEndpointHealth(
      endpointStatus: endpointStatus,
      dependencies: {'transport': transportStatus},
    );
  }

  /// Пытается переподключить транспорт и возвращает обновленный отчет о состоянии.
  Future<RpcEndpointHealth> reconnect() async {
    RpcHealthStatus transportStatus;

    try {
      transportStatus = await _transport.reconnect();
    } on UnsupportedError catch (error) {
      await logger.warning(
        'Transport does not support reconnect: ${error.message ?? error.toString()}',
      );
      transportStatus = RpcHealthStatus.degraded(
        component: _transport.runtimeType.toString(),
        message: 'Reconnect is not supported by this transport',
        details: {
          'supported': false,
          'isClosed': _transport.isClosed,
          'error': error.toString(),
        },
      );
    } catch (error, stackTrace) {
      await logger.error(
        'Transport reconnect failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
      transportStatus = RpcHealthStatus.unhealthy(
        component: _transport.runtimeType.toString(),
        message: 'Reconnect failed: $error',
        details: {'isClosed': _transport.isClosed, 'error': error.toString()},
      );
    }

    return health(transportOverride: transportStatus);
  }

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
