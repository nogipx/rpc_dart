// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '../_index.dart';

/// Функция условия для роутинга RPC вызовов
///
/// Принимает:
/// - [serviceName] - имя сервиса из заголовка 'x-route-service'
/// - [methodPath] - путь метода в формате /ServiceName/MethodName
/// - [context] - RPC контекст с заголовками и метаданными
///
/// Возвращает true, если правило должно применяться к данному вызову
typedef RpcRoutingCondition = bool Function(
  String? serviceName,
  String? methodPath,
  RpcContext? context,
);

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
  })  : _idManager = RpcStreamIdManager(isClient: true), // Всегда клиентский
        _logger = logger ?? RpcLogger('TransportRouter') {
    // Сортируем правила по приоритету (высший приоритет первым)
    _routingRules.addAll(routingRules);
    _routingRules.sort((a, b) => b.priority.compareTo(a.priority));

    _logger.internal(
        'Transport Router создан с ${_routingRules.length} правилами:');
    for (int i = 0; i < _routingRules.length; i++) {
      final rule = _routingRules[i];
      _logger.internal('  ${i + 1}. [P${rule.priority}] ${rule.description}');
    }
    _logger.internal('  - Роль: client (Router всегда клиентский)');
  }

  /// Создает подписку на ответы для конкретного stream'а
  void _subscribeToResponsesForStream(
      int clientStreamId, int serverStreamId, IRpcTransport transport) {
    _logger.internal(
        '🔔 Подписываемся на ответы: клиент[$clientStreamId] <- сервер[$serverStreamId] через $transport');

    // 🔥 ИСПРАВЛЕНИЕ: Слушаем ВХОДЯЩИЕ сообщения от транспорта, а не исходящие!
    // Когда роутер отправляет в transport, ответы придут через transport.incomingMessages
    final subscription = transport.incomingMessages
        .where((message) => message.streamId == serverStreamId)
        .listen(
      (message) {
        _logger.internal(
            '🔄 ПОЛУЧЕН ответ от transport: сервер[$serverStreamId] -> клиент[$clientStreamId], payload=${message.payload != null ? "есть" : "нет"}, isEndOfStream=${message.isEndOfStream}');

        // 🔄 КЛЮЧЕВАЯ ЛОГИКА: Перенаправляем ответы с правильным stream ID
        final redirectedMessage = RpcTransportMessage(
          payload: message.payload,
          metadata: message.metadata,
          isEndOfStream: message.isEndOfStream,
          methodPath: message.methodPath,
          streamId: clientStreamId, // 👈 Подменяем stream ID!
        );

        _logger.internal(
            '🔄 Перенаправляем ответ: сервер[$serverStreamId] -> клиент[$clientStreamId]');
        _incomingController.add(redirectedMessage);

        // ❌ НЕ ОЧИЩАЕМ здесь! Очистка будет в onDone
        // Для предотвращения двойной очистки (и при isEndOfStream, и при onDone)
      },
      onError: (error) {
        _logger.error('❌ ОШИБКА в транспорте stream $serverStreamId',
            error: error);
        // При ошибке тоже нужна очистка
        _cleanupStream(clientStreamId, serverStreamId);
      },
      onDone: () {
        _logger.internal('✅ Поток ответов ЗАВЕРШЕН для stream $serverStreamId');
        _cleanupStream(clientStreamId, serverStreamId);
      },
    );

    _responseSubscriptions[clientStreamId] = subscription;

    _logger.internal(
        '✅ Подписка создана: клиент[$clientStreamId] -> сервер[$serverStreamId]');
  }

  /// Очищает ресурсы для завершенного stream'а
  void _cleanupStream(int clientStreamId, int serverStreamId) {
    // 🔥 ЗАЩИТА ОТ ПОВТОРНОЙ ОЧИСТКИ: Проверяем, есть ли еще данные для очистки
    if (!_streamTransports.containsKey(clientStreamId) &&
        !_clientToServerStreamMapping.containsKey(clientStreamId) &&
        !_responseSubscriptions.containsKey(clientStreamId)) {
      _logger.debug(
          '🧹 ПРОПУСК ОЧИСТКИ: stream клиент[$clientStreamId] уже очищен');
      return;
    }

    _logger.internal(
        '🧹 НАЧАЛО ОЧИСТКИ: клиент[$clientStreamId] -> сервер[$serverStreamId]');

    _streamTransports.remove(clientStreamId);
    _clientToServerStreamMapping.remove(clientStreamId);

    final subscription = _responseSubscriptions.remove(clientStreamId);
    if (subscription != null) {
      _logger.internal(
          '🧹 Отменяем подписку на ответы для клиент[$clientStreamId]');
      subscription.cancel();
    }

    _logger.internal(
        '🧹 ЗАВЕРШЕНА ОЧИСТКА для stream: клиент[$clientStreamId] -> сервер[$serverStreamId]');
  }

  /// Извлекает RpcContext из метаданных сообщения
  RpcContext? _extractContextFromMessage(RpcTransportMessage message) {
    if (message.metadata == null) return null;

    final headers = <String, String>{};
    for (final header in message.metadata!.headers) {
      headers[header.name] = header.value;
    }

    return RpcContext.withHeaders(headers);
  }

  /// Главная логика роутинга - выбирает транспорт по приоритету правил
  IRpcTransport _selectTransport(RpcTransportMessage message) {
    final context = _extractContextFromMessage(message);
    final serviceName = context?.getHeader('x-route-service');
    final methodPath = message.methodPath;

    _logger
        .internal('Роутинг для service="$serviceName", method="$methodPath"');
    _logger.internal('Все заголовки контекста: ${context?.headers}');

    // Проверяем правила в порядке убывания приоритета
    for (final rule in _routingRules) {
      _logger
          .debug('Проверяем правило [P${rule.priority}]: ${rule.description}');

      if (rule.matches(serviceName, methodPath, context)) {
        _logger.internal(
            '✓ Найдено совпадение [P${rule.priority}]: ${rule.description}');
        return rule.transport;
      }
    }

    // Если ни одно правило не сработало - явная ошибка
    throw RpcException(
        'Не найден транспорт для роутинга: service="$serviceName", method="$methodPath". '
        'Убедитесь, что добавлено соответствующее правило роутинга.');
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
      _cleanupStream(streamId, serverStreamId);
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

    _logger
        .internal('📤 sendMetadata: streamId=$streamId, endStream=$endStream');
    _logger.internal('📤 metadata.methodPath: ${metadata.methodPath}');
    _logger.internal(
        '📤 metadata.headers: ${metadata.headers.map((h) => '${h.name}=${h.value}').join(', ')}');

    // Создаем временное сообщение для роутинга
    final routingMessage = RpcTransportMessage(
      metadata: metadata,
      streamId: streamId,
      methodPath: metadata.methodPath,
      isEndOfStream: endStream,
    );

    _logger.internal('🔀 Выбираем транспорт для роутинга...');

    // Выбираем транспорт
    final transport = _selectTransport(routingMessage);

    _logger.internal('🔀 Выбран транспорт: $transport');

    // 🔄 ВАЖНО: Создаем новый stream ID на целевом транспорте
    final serverStreamId = transport.createStream();

    _logger.internal(
        '🆔 Созданы stream ID: клиент[$streamId] -> сервер[$serverStreamId]');

    // Сохраняем все маппинги
    _streamTransports[streamId] = transport;
    _clientToServerStreamMapping[streamId] = serverStreamId;

    _logger.internal(
        '🔄 Маппинг stream ID: клиент[$streamId] -> сервер[$serverStreamId]');

    // 🔥 НОВАЯ ЛОГИКА: Подписываемся на ответы для этого конкретного stream'а
    _logger.internal('🔔 Создаем подписку на ответы...');
    _subscribeToResponsesForStream(streamId, serverStreamId, transport);

    // Перенаправляем вызов с НОВЫМ stream ID
    _logger.internal('📤 Отправляем metadata в целевой транспорт...');
    await transport.sendMetadata(serverStreamId, metadata,
        endStream: endStream);

    _logger.internal('✅ sendMetadata завершен успешно');
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
      throw StateError('Транспорт не найден для stream $streamId. '
          'Возможно, метаданные не были отправлены сначала.');
    }

    // Получаем серверный stream ID
    final serverStreamId = _clientToServerStreamMapping[streamId];
    if (serverStreamId == null) {
      throw StateError(
          'Серверный stream ID не найден для клиентского stream $streamId');
    }

    await transport.sendMessage(serverStreamId, data, endStream: endStream);

    // ❌ НЕ ОЧИЩАЕМ здесь! Очистка должна происходить только при получении END_STREAM ответа
    // Для унарных запросов endStream=true означает завершение отправки, но ответ еще не получен
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
          for (final rule in _routingRules) rule.priority: rule.description
        },
        'activeStreams': _streamTransports.length,
        'closed': _closed,
      };

  @override
  bool get isClient => _idManager.isClient;
}

/// Builder для создания Transport Router с приоритетами
final class RpcTransportRouterBuilder {
  final List<PrioritizedRoutingRule> _routingRules = [];
  RpcLogger? _logger;

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
      throw ArgumentError('Неправильная роль транспорта! '
          'Router требует клиентские транспорты (Stream ID: нечетные), '
          'но передан серверный транспорт (Stream ID: $testStreamId).');
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
          'Добавьте правила через routeCall или routeWhen.');
    }

    return RpcTransportRouter._(
      routingRules: _routingRules,
      logger: _logger,
    );
  }
}
