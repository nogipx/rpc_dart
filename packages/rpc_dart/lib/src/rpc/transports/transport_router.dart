// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import '../../contracts/_index.dart';
import '../../core/_index.dart';
import '../../logs/_logs.dart';

/// Функция условия для роутинга RPC вызовов
///
/// Принимает:
/// - [serviceName] - имя сервиса из заголовка 'x-route-service'
/// - [methodPath] - путь метода в формате /ServiceName/MethodName
/// - [context] - RPC контекст с заголовками и метаданными
///
/// Возвращает true, если правило должно применяться к данному вызову
typedef RpcRoutingCondition = bool Function(
    String? serviceName, String? methodPath, RpcContext? context);

/// Правило роутинга с приоритетом
typedef PrioritizedRoutingRule = ({
  IRpcTransport transport,
  String description,
  int priority,
  RpcRoutingCondition matches,
});

/// Transport Router - умный прокси для маршрутизации RPC вызовов между транспортами
///
/// Использует декларативные правила с приоритетами для гибкой настройки роутинга.
/// Правила проверяются в порядке убывания приоритета (высший приоритет первым).
///
/// Автоматически извлекает serviceName из headers 'x-route-service',
/// который добавляется RpcCallerEndpoint при каждом вызове.
final class RpcTransportRouter implements IRpcTransport {
  /// Все правила роутинга, отсортированные по приоритету (убывание)
  final List<PrioritizedRoutingRule> _routingRules = [];

  /// Менеджер Stream ID
  final RpcStreamIdManager _idManager;

  /// Контроллер для входящих сообщений
  final StreamController<RpcTransportMessage> _incomingController =
      StreamController<RpcTransportMessage>.broadcast();

  /// Маппинг клиентского stream ID к транспорту
  final Map<int, IRpcTransport> _streamTransports = {};

  /// Маппинг клиентского stream ID к серверному stream ID
  final Map<int, int> _clientToServerStreamMapping = {};

  /// Активные подписки на потоки ответов для каждого stream'а
  final Map<int, StreamSubscription> _responseSubscriptions = {};

  /// Логгер
  final RpcLogger _logger;

  /// Флаг закрытия
  bool _closed = false;

  RpcTransportRouter._({
    required List<PrioritizedRoutingRule> routingRules,
    RpcLogger? logger,
    int maxActiveStreams = 10000,
  })  : _idManager = RpcStreamIdManager(isClient: true), // Всегда клиентский
        _logger = logger ?? RpcLogger('TransportRouter'),
        _maxActiveStreams = maxActiveStreams {
    // Сортируем правила по приоритету (высший приоритет первым)
    _routingRules.addAll(routingRules);
    _routingRules.sort((a, b) => b.priority.compareTo(a.priority));

    _logger.internal(
      'Transport Router создан с ${_routingRules.length} правилами:',
    );
    for (int i = 0; i < _routingRules.length; i++) {
      final rule = _routingRules[i];
      _logger.internal('  ${i + 1}. [P${rule.priority}] ${rule.description}');
    }
    _logger.internal('  - Роль: client (Router всегда клиентский)');
  }

  final int _maxActiveStreams;

  /// Создает подписку на ответы для конкретного stream'а
  void _subscribeToResponsesForStream(
    int clientStreamId,
    int serverStreamId,
    IRpcTransport transport,
  ) {
    _logger.internal(
      '🔔 Подписываемся на ответы: клиент[$clientStreamId] <- сервер[$serverStreamId] через $transport',
    );

    // 🔥 ИСПРАВЛЕНИЕ: Слушаем ВХОДЯЩИЕ сообщения от транспорта, а не исходящие!
    // Когда роутер отправляет в transport, ответы придут через transport.incomingMessages
    final subscription = transport.incomingMessages
        .where((message) => message.streamId == serverStreamId)
        .listen(
      (message) {
        _logger.internal(
          '🔄 ПОЛУЧЕН ответ от transport: сервер[$serverStreamId] -> клиент[$clientStreamId], payload=${message.payload != null ? "есть" : "нет"}, isEndOfStream=${message.isEndOfStream}',
        );

        // 🔄 КЛЮЧЕВАЯ ЛОГИКА: Перенаправляем ответы с правильным stream ID
        final redirectedMessage = RpcTransportMessage(
          payload: message.payload,
          metadata: message.metadata,
          isEndOfStream: message.isEndOfStream,
          methodPath: message.methodPath,
          streamId: clientStreamId, // 👈 Подменяем stream ID!
          // ИСПРАВЛЕНИЕ: Сохраняем zero-copy данные
          directPayload: message.directPayload,
        );

        _logger.internal(
          '🔄 Перенаправляем ответ: сервер[$serverStreamId] -> клиент[$clientStreamId]',
        );
        _incomingController.add(redirectedMessage);

        // ❌ НЕ ОЧИЩАЕМ здесь! Очистка будет в onDone
        // Для предотвращения двойной очистки (и при isEndOfStream, и при onDone)
      },
      onError: (error) {
        _logger.error(
          '❌ ОШИБКА в транспорте stream $serverStreamId',
          error: error,
        );
        // При ошибке тоже нужна очистка
        _cleanupStream(clientStreamId, serverStreamId);
      },
      onDone: () {
        _logger.internal(
          'Response stream completed for stream $serverStreamId',
        );
        _cleanupStream(clientStreamId, serverStreamId);
      },
    );

    _responseSubscriptions[clientStreamId] = subscription;

    _logger.internal(
      'Subscription created: client[$clientStreamId] -> server[$serverStreamId]',
    );
  }

  /// Очищает ресурсы для завершенного stream'а и возвращает true, если были
  /// освобождены клиентский или серверный Stream ID
  bool _cleanupStream(int clientStreamId, int serverStreamId) {
    // 🔥 ЗАЩИТА ОТ ПОВТОРНОЙ ОЧИСТКИ: Проверяем, есть ли еще данные для очистки
    if (!_streamTransports.containsKey(clientStreamId) &&
        !_clientToServerStreamMapping.containsKey(clientStreamId) &&
        !_responseSubscriptions.containsKey(clientStreamId)) {
      _logger.debug(
        'Cleanup skipped: client stream [$clientStreamId] already cleaned',
      );
      return false;
    }

    _logger.internal(
      'Starting cleanup: client[$clientStreamId] -> server[$serverStreamId]',
    );

    var clientIdReleased = false;
    try {
      clientIdReleased = _idManager.releaseId(clientStreamId);
      _logger.debug(
        'Client stream ID [$clientStreamId] release result: $clientIdReleased',
      );
    } catch (error, stackTrace) {
      _logger.error(
        'Failed to release client stream ID [$clientStreamId]',
        error: error,
        stackTrace: stackTrace,
      );
    }

    final transport = _streamTransports[clientStreamId];
    final mappedServerStreamId =
        _clientToServerStreamMapping[clientStreamId] ?? serverStreamId;

    var serverIdReleased = false;
    if (transport != null) {
      try {
        serverIdReleased = transport.releaseStreamId(mappedServerStreamId);
        _logger.debug(
          'Requested release for server stream [$mappedServerStreamId] on $transport: $serverIdReleased',
        );
      } catch (error, stackTrace) {
        _logger.error(
          'Failed to release server stream [$mappedServerStreamId] on transport $transport',
          error: error,
          stackTrace: stackTrace,
        );
      }
    } else {
      _logger.debug(
        'Transport already removed for client stream [$clientStreamId] during cleanup',
      );
    }

    _streamTransports.remove(clientStreamId);
    _clientToServerStreamMapping.remove(clientStreamId);

    final subscription = _responseSubscriptions.remove(clientStreamId);
    if (subscription != null) {
      _logger.internal(
        'Cancelling response subscription for client[$clientStreamId]',
      );
      subscription.cancel();
    }

    _logger.internal(
      'Cleanup completed for stream: client[$clientStreamId] -> server[$serverStreamId]',
    );

    return clientIdReleased || serverIdReleased;
  }

  /// Извлекает RpcContext из метаданных сообщения
  RpcContext? _extractContextFromMessage(RpcTransportMessage message) {
    if (message.metadata == null) return null;

    final headers = <String, String>{};
    for (final header in message.metadata!.headers) {
      if (!header.name.startsWith(':') &&
          header.name != RpcConstants.contentTypeHeader &&
          header.name != 'te') {
        headers[header.name] = header.value;
      }
    }

    return RpcContext.withHeaders(headers);
  }

  String _summarizeHeadersForLog(RpcContext? context) {
    if (context == null || context.headers.isEmpty) {
      return 'headers=0';
    }

    const redactedKeys = <String>{
      'authorization',
      'cookie',
      'set-cookie',
      'x-api-key',
    };

    final keys = context.headers.keys.toList()..sort();
    final safeKeys = keys.take(24).map(
          (k) => redactedKeys.contains(k) ? '$k=<redacted>' : k,
        );
    final suffix = keys.length > 24 ? ', ...' : '';
    return 'headers=${keys.length} keys=[${safeKeys.join(', ')}$suffix]';
  }

  String _truncateForLog(String? value, {int max = 200}) {
    if (value == null) return 'null';
    value = value.replaceAll('\r', ' ').replaceAll('\n', ' ');
    if (value.length <= max) return value;
    return '${value.substring(0, max)}…';
  }

  String _summarizeMetadataForLog(RpcMetadata metadata) {
    final names = metadata.headers.map((h) => h.name).toList()..sort();
    final shown = names.take(24);
    final suffix = names.length > 24 ? ', ...' : '';
    return 'headers=${names.length} names=[${shown.join(', ')}$suffix]';
  }

  /// Главная логика роутинга - выбирает транспорт по приоритету правил
  IRpcTransport _selectTransport(RpcTransportMessage message) {
    final context = _extractContextFromMessage(message);
    final methodPath = message.methodPath;
    final serviceName = _serviceNameFromMethodPath(methodPath) ??
        context?.getHeader('x-route-service');

    _logger.internal(
      'Роутинг для service="${_truncateForLog(serviceName)}", '
      'method="${_truncateForLog(methodPath)}"',
    );
    _logger.internal('Контекст роутинга: ${_summarizeHeadersForLog(context)}');

    // Проверяем правила в порядке убывания приоритета
    for (final rule in _routingRules) {
      _logger.debug(
        'Проверяем правило [P${rule.priority}]: ${rule.description}',
      );

      if (rule.matches(serviceName, methodPath, context)) {
        _logger.internal(
          '✓ Найдено совпадение [P${rule.priority}]: ${rule.description}',
        );
        return rule.transport;
      }
    }

    // Если ни одно правило не сработало - явная ошибка
    throw RpcException(
      'Не найден транспорт для роутинга: service="$serviceName", method="$methodPath". '
      'Убедитесь, что добавлено соответствующее правило роутинга.',
    );
  }

  String? _serviceNameFromMethodPath(String? methodPath) {
    if (methodPath == null) return null;
    if (methodPath.isEmpty || methodPath.length > 512) return null;
    if (!methodPath.startsWith('/')) return null;
    final parts = methodPath.substring(1).split('/');
    if (parts.length != 2) return null;
    if (parts[0].isEmpty || parts[1].isEmpty) return null;
    return parts[0];
  }

  @override
  int createStream() {
    if (_closed) throw StateError('TransportRouter is closed');
    return _idManager.generateId();
  }

  @override
  bool releaseStreamId(int streamId) {
    // Очищаем все маппинги для данного stream ID
    final serverStreamId = _clientToServerStreamMapping[streamId];
    if (serverStreamId != null) {
      return _cleanupStream(streamId, serverStreamId);
    }
    return _idManager.releaseId(streamId);
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (_closed) throw StateError('TransportRouter is closed');
    if (_streamTransports.length >= _maxActiveStreams &&
        !_streamTransports.containsKey(streamId)) {
      throw RpcException(
        'TransportRouter activeStreams limit reached: $_maxActiveStreams',
      );
    }

    _logger.internal(
      'Sending metadata: streamId=$streamId, endStream=$endStream',
    );
    _logger.internal(
      'Metadata method path: ${_truncateForLog(metadata.methodPath)}',
    );
    _logger.internal('Metadata: ${_summarizeMetadataForLog(metadata)}');

    // Создаем временное сообщение для роутинга
    final routingMessage = RpcTransportMessage(
      metadata: metadata,
      streamId: streamId,
      methodPath: metadata.methodPath,
      isEndOfStream: endStream,
    );

    _logger.internal('Selecting transport for routing...');

    // Выбираем транспорт
    final transport = _selectTransport(routingMessage);

    _logger.internal('Selected transport: $transport');

    // 🔄 ВАЖНО: Создаем новый stream ID на целевом транспорте
    final serverStreamId = transport.createStream();

    _logger.internal(
      'Created stream IDs: client[$streamId] -> server[$serverStreamId]',
    );

    // Сохраняем все маппинги
    _streamTransports[streamId] = transport;
    _clientToServerStreamMapping[streamId] = serverStreamId;

    _logger.internal(
      'Stream ID mapping: client[$streamId] -> server[$serverStreamId]',
    );

    // Подписываемся на ответы для этого конкретного stream'а
    _logger.internal('Creating response subscription...');
    _subscribeToResponsesForStream(streamId, serverStreamId, transport);

    // Перенаправляем вызов с НОВЫМ stream ID
    _logger.internal('Sending metadata to target transport...');
    await transport.sendMetadata(
      serverStreamId,
      metadata,
      endStream: endStream,
    );

    _logger.internal('sendMetadata completed successfully');
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (_closed) throw StateError('TransportRouter is closed');

    // Используем сохраненный транспорт для данного stream
    final transport = _streamTransports[streamId];
    if (transport == null) {
      throw StateError(
        'Транспорт не найден для stream $streamId. '
        'Возможно, метаданные не были отправлены сначала.',
      );
    }

    // Получаем серверный stream ID
    final serverStreamId = _clientToServerStreamMapping[streamId];
    if (serverStreamId == null) {
      throw StateError(
        'Серверный stream ID не найден для клиентского stream $streamId',
      );
    }

    await transport.sendMessage(serverStreamId, data, endStream: endStream);

    // ❌ НЕ ОЧИЩАЕМ здесь! Очистка должна происходить только при получении END_STREAM ответа
    // Для унарных запросов endStream=true означает завершение отправки, но ответ еще не получен
  }

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    if (_closed) throw StateError('TransportRouter is closed');

    // Используем сохраненный транспорт для данного stream
    final transport = _streamTransports[streamId];
    if (transport == null) {
      throw StateError(
        'Транспорт не найден для stream $streamId. '
        'Возможно, метаданные не были отправлены сначала.',
      );
    }

    // Получаем серверный stream ID
    final serverStreamId = _clientToServerStreamMapping[streamId];
    if (serverStreamId == null) {
      throw StateError(
        'Серверный stream ID не найден для клиентского stream $streamId',
      );
    }

    // Проксируем zero-copy вызов в целевой транспорт
    await transport.sendDirectObject(
      serverStreamId,
      object,
      endStream: endStream,
    );
  }

  @override
  Future<void> finishSending(int streamId) async {
    if (_closed) return;

    final transport = _streamTransports[streamId];
    final serverStreamId = _clientToServerStreamMapping[streamId];

    if (transport != null && serverStreamId != null) {
      await transport.finishSending(serverStreamId);
      // ✅ Маппинг будет очищен в _cleanupStream когда придет END_STREAM ответ
    }
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages =>
      _incomingController.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    return incomingMessages.where((message) => message.streamId == streamId);
  }

  @override
  Future<RpcHealthStatus> health() async {
    if (_closed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'Transport router is closed',
        details: {
          'closed': true,
          'routingRules': _routingRules.length,
          'activeStreams': _streamTransports.length,
        },
      );
    }

    final seenTransports = <IRpcTransport>{};
    final dependencyStatuses = <Map<String, Object?>>[];
    var aggregatedLevel = RpcHealthLevel.healthy;

    for (final rule in _routingRules) {
      final transport = rule.transport;
      if (!seenTransports.add(transport)) continue;

      RpcHealthStatus status;
      try {
        status = await transport.health();
      } catch (error, stackTrace) {
        await _logger.error(
          'Failed to fetch health from transport ${transport.runtimeType}: $error',
          error: error,
          stackTrace: stackTrace,
        );
        status = RpcHealthStatus.unhealthy(
          component: transport.runtimeType.toString(),
          message: 'Health check failed: $error',
          details: {'error': error.toString()},
        );
      }

      if (status.level.severity > aggregatedLevel.severity) {
        aggregatedLevel = status.level;
      }

      dependencyStatuses.add({
        'component': status.component,
        'level': status.level.name,
        'message': status.message,
        'details': status.details,
      });
    }

    final message = aggregatedLevel == RpcHealthLevel.healthy
        ? 'Transport router ready'
        : 'Transport router degraded due to dependency state';

    return RpcHealthStatus(
      component: runtimeType.toString(),
      level: aggregatedLevel,
      message: message,
      details: {
        'closed': _closed,
        'routingRules': _routingRules.length,
        'activeStreams': _streamTransports.length,
        'dependencies': dependencyStatuses,
      },
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    if (_closed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'Transport router is closed',
        details: {
          'closed': true,
          'routingRules': _routingRules.length,
          'activeStreams': _streamTransports.length,
        },
      );
    }

    final seenTransports = <IRpcTransport>{};
    final dependencyStatuses = <Map<String, Object?>>[];
    var aggregatedLevel = RpcHealthLevel.healthy;

    for (final rule in _routingRules) {
      final transport = rule.transport;
      if (!seenTransports.add(transport)) continue;

      RpcHealthStatus status;
      try {
        status = await transport.reconnect();
      } catch (error, stackTrace) {
        await _logger.error(
          'Failed to reconnect transport ${transport.runtimeType}: $error',
          error: error,
          stackTrace: stackTrace,
        );
        status = RpcHealthStatus.unhealthy(
          component: transport.runtimeType.toString(),
          message: 'Reconnect failed: $error',
          details: {'error': error.toString()},
        );
      }

      if (status.level.severity > aggregatedLevel.severity) {
        aggregatedLevel = status.level;
      }

      dependencyStatuses.add({
        'component': status.component,
        'level': status.level.name,
        'message': status.message,
        'details': status.details,
      });
    }

    final message = aggregatedLevel == RpcHealthLevel.healthy
        ? 'Transport router dependencies are ready'
        : 'Transport router dependencies reported issues during reconnect';

    return RpcHealthStatus(
      component: runtimeType.toString(),
      level: aggregatedLevel,
      message: message,
      details: {
        'closed': _closed,
        'routingRules': _routingRules.length,
        'activeStreams': _streamTransports.length,
        'dependencies': dependencyStatuses,
      },
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    _logger.internal('Закрытие TransportRouter...');

    // Отписываемся от всех транспортов
    for (final subscription in _responseSubscriptions.values) {
      await subscription.cancel();
    }
    _responseSubscriptions.clear();

    // Закрываем контроллер
    await _incomingController.close();

    // Очищаем состояние
    _streamTransports.clear();
    _clientToServerStreamMapping.clear();

    _logger.internal('TransportRouter закрыт');
  }

  /// Статистика роутера
  Map<String, dynamic> get statistics => {
        'totalRules': _routingRules.length,
        'rulesByPriority': {
          for (final rule in _routingRules) rule.priority: rule.description,
        },
        'activeStreams': _streamTransports.length,
        'closed': _closed,
      };

  @override
  bool get isClient => _idManager.isClient;

  @override
  bool get isClosed => _closed;

  /// Router поддерживает zero-copy, если его поддерживает хотя бы один из роутируемых транспортов
  @override
  bool get supportsZeroCopy {
    return _routingRules.any((rule) => rule.transport.supportsZeroCopy);
  }
}

/// Builder для создания Transport Router с приоритетами
final class RpcTransportRouterBuilder {
  final List<PrioritizedRoutingRule> _routingRules = [];
  RpcLogger? _logger;
  int _maxActiveStreams = 10000;

  /// Создает Builder для клиентского Router'а
  ///
  /// Router генерирует нечетные Stream ID (1, 3, 5...) и используется
  /// для отправки запросов на серверы. Все добавляемые транспорты должны
  /// быть клиентскими (нечетные Stream ID).
  ///
  /// ```dart
  /// final router = RpcTransportRouterBuilder.client()
  ///   .routeService(fromService: 'UserService', toTransport: userClientTransport)
  ///   .build();
  /// ```
  factory RpcTransportRouterBuilder.client() => RpcTransportRouterBuilder._();

  /// Создает обычный Builder (всегда клиентский)
  factory RpcTransportRouterBuilder() => RpcTransportRouterBuilder._();

  /// Приватный конструктор
  RpcTransportRouterBuilder._();

  /// Устанавливает логгер
  RpcTransportRouterBuilder logger(RpcLogger logger) {
    _logger = logger;
    return this;
  }

  RpcTransportRouterBuilder maxActiveStreams(int value) {
    if (value <= 0) {
      throw ArgumentError.value(value, 'value', 'Must be > 0');
    }
    _maxActiveStreams = value;
    return this;
  }

  /// Проверяет, что транспорт является клиентским
  void _validateTransportRole(IRpcTransport transport) {
    // Для проверки создаем тестовый stream и анализируем его ID
    late final int testStreamId;
    try {
      testStreamId = transport.createStream();
    } catch (e) {
      // Если не удалось создать stream - может быть транспорт закрыт
      // В этом случае пропускаем проверку с предупреждением
      _logger?.warning('Не удалось проверить роль транспорта: $e');
      return;
    }

    final isTransportClient = testStreamId.isOdd; // нечетные = клиент

    // Освобождаем тестовый stream
    transport.releaseStreamId(testStreamId);

    // Router всегда требует клиентские транспорты
    if (!isTransportClient) {
      throw ArgumentError(
        'Неправильная роль транспорта! '
        'Router требует клиентские транспорты (Stream ID: нечетные), '
        'но передан серверный транспорт (Stream ID: $testStreamId).',
      );
    }
  }

  /// Направляет конкретный сервис в указанный транспорт
  ///
  /// [calledServiceName] - имя сервиса, запросы к которому нужно перенаправить
  /// [toTransport] - целевой транспорт, куда будут направлены запросы
  /// [priority] - приоритет правила (чем выше, тем раньше проверяется)
  ///
  /// Пример: `.routeCall(calledServiceName: 'UserService', toTransport: userTransport, priority: 100)`
  RpcTransportRouterBuilder routeCall({
    required String calledServiceName,
    required IRpcTransport toTransport,
    int priority = 50,
  }) {
    _validateTransportRole(toTransport);

    _routingRules.add((
      transport: toTransport,
      description: 'Service route: $calledServiceName',
      priority: priority,
      matches: (serviceName, methodPath, context) =>
          serviceName == calledServiceName,
    ));
    return this;
  }

  /// Добавляет условное правило роутинга с детальным контролем
  ///
  /// [toTransport] - целевой транспорт для направления запросов
  /// [whenCondition] - функция-условие для определения, применять ли это правило
  /// [priority] - приоритет правила (чем выше, тем раньше проверяется)
  /// [description] - описание правила для отладки
  ///
  /// Пример:
  /// ```dart
  /// .routeWhen(
  ///   toTransport: premiumTransport,
  ///   whenCondition: (service, method, context) =>
  ///     service == 'UserService' && context?.getHeader('x-tier') == 'premium',
  ///   priority: 100,
  ///   description: 'Premium пользователи на отдельный сервис'
  /// )
  /// ```
  RpcTransportRouterBuilder routeWhen({
    required IRpcTransport toTransport,
    required RpcRoutingCondition whenCondition,
    int priority = 70,
    String description = 'Custom routing rule',
  }) {
    _validateTransportRole(toTransport);

    _routingRules.add((
      transport: toTransport,
      description: description,
      priority: priority,
      matches: whenCondition,
    ));
    return this;
  }

  /// Создает Router
  RpcTransportRouter build() {
    if (_routingRules.isEmpty) {
      throw ArgumentError(
        'Transport Router должен иметь как минимум одно правило роутинга. '
        'Добавьте правила через routeCall или routeWhen.',
      );
    }

    return RpcTransportRouter._(
      routingRules: _routingRules,
      logger: _logger,
      maxActiveStreams: _maxActiveStreams,
    );
  }
}
