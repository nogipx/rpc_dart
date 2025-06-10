// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// ignore_for_file: library_private_types_in_public_api

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

/// Менеджер для управления серверными стримами
///
/// Оборачивает [StreamController] и создает брокер сообщений,
/// позволяя создавать клиентские стримы и публиковать данные всем или конкретным клиентам.
///
/// Основные возможности:
/// - Широковещательная публикация сообщений всем клиентам
/// - Публикация сообщений конкретному клиенту
/// - Управление жизненным циклом клиентских стримов
/// - Поддержка паузы/возобновления клиентских стримов
/// - Автоматическая очистка неактивных стримов
/// - Сбор метрик и статистики
class StreamDistributor<T extends IRpcSerializable> {
  late final RpcLogger? _logger;

  // Основной контроллер для публикации данных
  final StreamController<_StreamMessage<T>> _mainController;

  // Хранилище активных клиентских стримов
  final Map<String, _ClientStreamWrapper<T>> _clientStreams;

  // Счетчик для генерации клиентских ID
  int _streamCounter = 0;

  // Флаг закрытия менеджера
  bool _isDisposed = false;

  // Таймер для периодической очистки неактивных стримов
  Timer? _cleanupTimer;

  // Метрики для мониторинга активности
  final _metrics = _DistributorMetrics();

  /// Настройки для автоматической очистки неактивных стримов
  final StreamDistributorConfig _config;

  /// Создает новый экземпляр [StreamDistributor]
  ///
  /// [config] позволяет настроить поведение дистрибьютора
  StreamDistributor({
    StreamDistributorConfig? config,
    RpcLogger? logger,
  })  : _mainController = StreamController<_StreamMessage<T>>.broadcast(),
        _clientStreams = <String, _ClientStreamWrapper<T>>{},
        _logger = logger,
        _config = config ?? StreamDistributorConfig() {
    // Настраиваем периодическую очистку неактивных стримов
    if (_config.enableAutoCleanup) {
      _startCleanupTimer();
    }
  }

  /// Количество активных клиентских стримов
  int get activeClientCount => _clientStreams.length;

  /// Флаг, указывающий, закрыт ли дистрибьютор
  bool get isDisposed => _isDisposed;

  /// Получить текущие метрики дистрибьютора
  StreamDistributorMetrics get metrics => _metrics.snapshot();

  /// Публикация данных во все активные стримы
  ///
  /// Сообщение автоматически оборачивается в [_StreamMessage] и
  /// отправляется всем клиентам.
  ///
  /// Возвращает количество клиентов, которым было доставлено сообщение.
  int publish(T event, {Map<String, dynamic>? metadata}) {
    if (_isDisposed || _mainController.isClosed) {
      _logger?.warning(
        'Попытка публикации в закрытый дистрибьютор',
      );
      return 0;
    }

    final wrappedEvent = _StreamMessage<T>(
      message: event,
      streamId: 'broadcast',
      metadata: metadata,
    );

    _logger?.internal(
      'Публикация данных в основной контроллер: размер=${event.toString().length} символов',
    );
    _mainController.add(wrappedEvent);

    // Обновляем метрики
    _metrics.incrementTotalMessages();
    _metrics.recordMessageSize(event);

    // Подсчитываем активных клиентов для отчета о доставке
    final activeClients = _clientStreams.values
        .where((wrapper) => !wrapper.isPaused && !wrapper.controller.isClosed)
        .length;

    _logger?.internal(
      'Опубликовано сообщение всем клиентам (доступно: $activeClients)',
    );
    return activeClients;
  }

  /// Публикация данных по фильтру клиентов
  ///
  /// Позволяет отправить сообщение только определенным клиентам,
  /// которые соответствуют указанному фильтру.
  ///
  /// Возвращает количество клиентов, которым было доставлено сообщение.
  int publishFiltered(
    T event,
    bool Function(_ClientStreamWrapper<T> client) filter, {
    Map<String, dynamic>? metadata,
  }) {
    if (_isDisposed || _mainController.isClosed) return 0;

    // Фильтруем клиентов
    final targetClients = _clientStreams.values
        .where((client) =>
            !client.controller.isClosed && !client.isPaused && filter(client))
        .toList();

    // Если нет подходящих клиентов, не публикуем
    if (targetClients.isEmpty) return 0;

    // Создаем метаданные с целевыми клиентами
    final targetIds = targetClients.map((client) => client.clientId).toList();
    final enrichedMetadata = {...?metadata, 'targetClients': targetIds};

    // Создаем и публикуем сообщение
    final wrappedEvent = _StreamMessage<T>(
      message: event,
      streamId: 'filtered',
      metadata: enrichedMetadata,
    );

    _logger?.internal(
      'Публикация фильтрованных данных: $wrappedEvent',
    );
    _mainController.add(wrappedEvent);

    // Обновляем метрики
    _metrics.incrementTotalMessages();
    _metrics.recordMessageSize(event);

    return targetClients.length;
  }

  /// Создание нового стрима для клиента с автоматически сгенерированным ID
  ///
  /// Возвращает стрим данных типа [T]
  Stream<T> createClientStream() {
    final clientId = 'stream_${_streamCounter++}';
    return createClientStreamWithId(clientId);
  }

  /// Создание или получение существующего стрима для клиента по указанному ID
  ///
  /// Если стрим с указанным ID уже существует, возвращает его.
  /// В противном случае создает новый стрим с указанным ID.
  Stream<T> getOrCreateClientStream(String clientId) {
    // Проверяем, существует ли уже стрим с таким ID
    final existingWrapper = _clientStreams[clientId];
    if (existingWrapper != null) {
      _logger?.internal(
        'Использование существующего стрима для клиента: $clientId',
      );
      existingWrapper.updateLastActivity();
      return existingWrapper.controller.stream;
    }

    // Если стрим не существует, создаем новый с указанным ID
    return createClientStreamWithId(clientId);
  }

  /// Создание нового стрима для клиента с указанным ID
  ///
  /// Позволяет явно задать ID клиента для удобства отслеживания
  Stream<T> createClientStreamWithId(String clientId,
      {void Function()? onCancel}) {
    _checkNotDisposed();

    // Проверяем, не существует ли уже стрим с таким ID
    if (_clientStreams.containsKey(clientId)) {
      _logger?.warning(
        'Стрим с ID $clientId уже существует, создается дублирующий стрим',
      );
    } else {
      _logger?.info(
        'Создание нового стрима для клиента: $clientId',
      );
    }

    // Создаем контроллер с поддержкой паузы/возобновления
    final clientController = StreamController<T>.broadcast(
      onCancel: () {
        // Вызываем пользовательский обработчик, если он предоставлен
        onCancel?.call();

        // Автоматически удаляем стрим при отмене подписки, если включено
        if (_config.autoRemoveOnCancel) {
          _logger?.internal(
            'Автоматическое закрытие стрима при отмене подписки: $clientId',
          );
          closeClientStream(clientId);
        }
      },
    );

    // Создаем подписку на основной стрим
    final subscription =
        _subscribeClientToMainStream(clientId, clientController);

    // Сохраняем информацию о клиентском стриме
    _clientStreams[clientId] = _ClientStreamWrapper(
      controller: clientController,
      subscription: subscription,
      clientId: clientId,
      createdAt: DateTime.now(),
    );

    // Обновляем метрики
    _metrics.incrementTotalStreams();
    _metrics.incrementCurrentStreams();
    _logger?.internal(
      'Создан новый стрим для клиента: $clientId (всего: ${_clientStreams.length})',
    );

    // Возвращаем поток данных
    return clientController.stream;
  }

  /// Создает подписку на основной стрим для конкретного клиентского контроллера
  StreamSubscription<_StreamMessage<T>> _subscribeClientToMainStream(
    String clientId,
    StreamController<T> clientController,
  ) {
    final subscription = _mainController.stream.listen(
      (wrappedEvent) =>
          _handleClientMessage(clientId, clientController, wrappedEvent),
      onError: (error, stackTrace) =>
          _handleClientError(clientController, error, stackTrace),
      onDone: () => _handleClientStreamDone(clientController),
    );

    return subscription;
  }

  /// Обрабатывает сообщение для конкретного клиента
  void _handleClientMessage(
    String clientId,
    StreamController<T> clientController,
    _StreamMessage<T> wrappedEvent,
  ) {
    if (clientController.isClosed) {
      _logger?.internal(
        'Попытка отправки сообщения в закрытый контроллер: $clientId',
      );
      return;
    }

    // Получаем информацию о клиенте
    final wrapper = _clientStreams[clientId];
    if (wrapper == null) {
      _logger?.warning(
        'Стрим-обертка для клиента $clientId не найдена',
      );
      return;
    }

    // Пропускаем сообщения, если клиент на паузе
    if (wrapper.isPaused) {
      _logger?.internal(
        'Клиент $clientId на паузе, сообщение пропущено',
      );
      return;
    }

    // Проверяем, относится ли сообщение к этому клиенту
    if (!_isMessageForClient(clientId, wrappedEvent)) {
      _logger?.internal(
        'Сообщение не предназначено для клиента $clientId',
      );
      return;
    }

    try {
      // Извлекаем оригинальное сообщение из обертки
      clientController.add(wrappedEvent.message);
      _logger?.internal(
        'Отправка данных клиенту $clientId: размер=${wrappedEvent.message.toString().length} символов',
      );

      // Обновляем метрики
      wrapper.incrementReceivedMessages();

      // Обновляем время активности
      wrapper.updateLastActivity();
    } catch (e, stackTrace) {
      _logger?.error(
        'Ошибка при отправке данных клиенту $clientId',
        error: e,
        stackTrace: stackTrace,
      );
      _metrics.incrementErrors();
    }
  }

  /// Проверяет, предназначено ли сообщение для данного клиента
  bool _isMessageForClient(String clientId, _StreamMessage<T> wrappedEvent) {
    // Принимаем сообщения только если:
    // 1. Это широковещательное сообщение
    if (wrappedEvent.streamId == 'broadcast') {
      return true;
    }

    // 2. Или сообщение направлено конкретно этому клиенту и не является запросом
    if (wrappedEvent.streamId == clientId &&
        wrappedEvent.metadata?['type'] != 'clientRequest') {
      return true;
    }

    // 3. Это фильтрованное сообщение и клиент в списке целевых
    if (wrappedEvent.streamId == 'filtered' &&
        wrappedEvent.metadata?.containsKey('targetClients') == true) {
      final targetClients = wrappedEvent.metadata!['targetClients'] as List;
      if (targetClients.contains(clientId)) {
        return true;
      }
    }

    return false;
  }

  /// Обрабатывает ошибку для клиентского стрима
  void _handleClientError(
    StreamController<T> clientController,
    dynamic error,
    StackTrace? stackTrace,
  ) {
    if (!clientController.isClosed) {
      try {
        clientController.addError(error, stackTrace);
        _metrics.incrementErrors();
      } catch (e) {
        _logger?.error('Ошибка при передаче ошибки клиенту', error: e);
      }
    }
  }

  /// Обрабатывает завершение основного стрима
  void _handleClientStreamDone(StreamController<T> clientController) {
    if (!clientController.isClosed) {
      clientController.close().catchError((e) {
        _logger?.error('Ошибка при закрытии клиентского контроллера', error: e);
      });
    }
  }

  /// Проверяет, существует ли стрим с указанным ID
  bool hasClientStream(String clientId) => _clientStreams.containsKey(clientId);

  /// Установка паузы для клиентского стрима
  ///
  /// Клиент на паузе не будет получать сообщения до вызова [resumeClientStream]
  bool pauseClientStream(String clientId) {
    final wrapper = _clientStreams[clientId];
    if (wrapper == null || wrapper.controller.isClosed) return false;

    wrapper.isPaused = true;
    _logger?.internal(
      'Клиентский стрим $clientId поставлен на паузу',
    );
    return true;
  }

  /// Возобновление работы клиентского стрима после паузы
  bool resumeClientStream(String clientId) {
    final wrapper = _clientStreams[clientId];
    if (wrapper == null || wrapper.controller.isClosed) return false;

    wrapper.isPaused = false;
    wrapper.updateLastActivity();
    _logger?.internal(
      'Клиентский стрим $clientId возобновлен',
    );
    return true;
  }

  /// Прямая публикация в конкретный стрим клиента
  ///
  /// Сообщение автоматически оборачивается в [_StreamMessage] с ID клиента.
  ///
  /// Возвращает true, если сообщение было доставлено клиенту
  bool publishToClient(String clientId, T event,
      {Map<String, dynamic>? metadata}) {
    if (_isDisposed) return false;

    final wrapper = _clientStreams[clientId];
    if (wrapper == null || wrapper.controller.isClosed) return false;

    // Пропускаем сообщения, если клиент на паузе
    if (wrapper.isPaused) {
      _logger?.internal(
        'Клиент $clientId на паузе, публикация пропущена',
      );
      return false;
    }

    try {
      // Создаем обернутое сообщение
      final wrappedEvent = _StreamMessage<T>(
        message: event,
        streamId: clientId,
        metadata: metadata,
      );

      // Добавляем в основной контроллер для логирования и передачи конкретному клиенту
      if (!_mainController.isClosed) {
        _mainController.add(wrappedEvent);

        // Обновляем метрики
        _metrics.incrementTotalMessages();
        _metrics.recordMessageSize(event);
        wrapper.incrementReceivedMessages();

        // Обновляем время последней активности
        wrapper.updateLastActivity();
        return true;
      }
    } catch (e) {
      _logger?.error('Ошибка при публикации данных клиенту $clientId',
          error: e);
      _metrics.incrementErrors();
    }

    return false;
  }

  /// Публикация обернутого сообщения
  ///
  /// Для случаев, когда сообщение уже оформлено как [_StreamMessage]
  void publishWrapped(_StreamMessage<T> wrappedEvent) {
    if (_isDisposed || _mainController.isClosed) {
      _logger?.warning(
        'Попытка публикации обернутого сообщения в закрытый дистрибьютор',
      );
      return;
    }
    _logger?.internal(
      'Публикация обернутого сообщения: streamId=${wrappedEvent.streamId}',
    );
    _mainController.add(wrappedEvent);
    _metrics.incrementTotalMessages();
  }

  /// Получение списка идентификаторов активных клиентов
  List<String> getActiveClientIds() => _clientStreams.keys.toList();

  /// Получение информации о клиентском стриме в виде карты данных
  Map<String, dynamic>? getClientInfo(String clientId) {
    final wrapper = _clientStreams[clientId];
    if (wrapper == null) return null;

    return {
      'clientId': wrapper.clientId,
      'createdAt': wrapper.createdAt.toIso8601String(),
      'lastActivity': wrapper.lastActivity.toIso8601String(),
      'activeDuration': wrapper.getActiveDuration().inMilliseconds,
      'inactivityDuration': wrapper.getInactivityDuration().inMilliseconds,
      'isPaused': wrapper.isPaused,
      'messagesReceived': wrapper.messagesReceived,
    };
  }

  /// Получение информации о всех клиентских стримах
  Map<String, Map<String, dynamic>> getAllClientsInfo() {
    return Map.fromEntries(
      _clientStreams.entries
          .map((entry) => MapEntry(entry.key, getClientInfo(entry.key)!)),
    );
  }

  /// Получение списка неактивных клиентов
  ///
  /// Возвращает ID клиентов, которые не проявляли активность дольше указанного времени.
  List<String> getInactiveClientIds(Duration threshold) {
    final now = DateTime.now();
    return _clientStreams.entries
        .where((entry) => now.difference(entry.value.lastActivity) > threshold)
        .map((entry) => entry.key)
        .toList();
  }

  /// Получение списка приостановленных клиентов
  List<String> getPausedClientIds() {
    return _clientStreams.entries
        .where((entry) => entry.value.isPaused)
        .map((entry) => entry.key)
        .toList();
  }

  /// Закрытие конкретного клиентского стрима
  Future<bool> closeClientStream(String clientId) async {
    if (_isDisposed) return false;

    final wrapper = _clientStreams.remove(clientId);
    if (wrapper != null) {
      await wrapper.dispose();
      _metrics.decrementCurrentStreams();
      _logger?.internal(
        'Клиентский стрим $clientId закрыт',
      );
      return true;
    }

    return false;
  }

  /// Закрытие всех клиентских стримов
  Future<void> closeAllClientStreams() async {
    if (_isDisposed) return;

    final clientCount = _clientStreams.length;
    final clientIds = _clientStreams.keys.toList();
    for (final clientId in clientIds) {
      await closeClientStream(clientId);
    }

    _logger?.internal(
      'Закрыты все клиентские стримы ($clientCount)',
    );
  }

  /// Закрытие неактивных соединений
  ///
  /// Закрывает соединения с клиентами, которые не проявляли активность
  /// в течение указанного периода времени.
  Future<int> closeInactiveStreams(Duration inactivityThreshold) async {
    if (_isDisposed) return 0;

    final inactiveIds = getInactiveClientIds(inactivityThreshold);
    for (final clientId in inactiveIds) {
      await closeClientStream(clientId);
    }

    if (inactiveIds.isNotEmpty) {
      _logger?.internal(
        'Закрыто ${inactiveIds.length} неактивных стримов',
      );
    }

    return inactiveIds.length;
  }

  /// Запускает таймер для периодической очистки неактивных стримов
  void _startCleanupTimer() {
    _cleanupTimer?.cancel();
    _logger?.info(
      'Запуск таймера очистки (интервал: ${_config.cleanupInterval.inSeconds}с, порог: ${_config.inactivityThreshold.inMinutes}м)',
    );

    _cleanupTimer = Timer.periodic(_config.cleanupInterval, (_) async {
      if (_isDisposed) {
        _logger?.internal(
          'Дистрибьютор закрыт, очистка отменена',
        );
        return;
      }

      try {
        _logger?.internal(
          'Запуск периодической очистки неактивных стримов',
        );
        final removedCount =
            await closeInactiveStreams(_config.inactivityThreshold);
        if (removedCount > 0) {
          _logger?.info(
            'Автоматическая очистка удалила $removedCount неактивных стримов (осталось: ${_clientStreams.length})',
          );
        } else {
          _logger?.internal(
            'Очистка не обнаружила неактивных стримов (всего: ${_clientStreams.length})',
          );
        }
      } catch (e, stackTrace) {
        _logger?.error(
          'Ошибка при автоматической очистке неактивных стримов',
          error: e,
          stackTrace: stackTrace,
        );
      }
    });
  }

  /// Проверяет, что дистрибьютор не закрыт
  void _checkNotDisposed() {
    if (_isDisposed) {
      throw StateError(
        'StreamDistributor уже закрыт',
      );
    }
  }

  /// Освобождение всех ресурсов менеджера
  Future<void> dispose() async {
    if (_isDisposed) {
      _logger?.internal(
        'Повторный вызов dispose() игнорируется',
      );
      return;
    }

    _logger?.info(
      'Начало освобождения ресурсов StreamDistributor (активных стримов: ${_clientStreams.length})',
    );
    _isDisposed = true;

    // Останавливаем таймер очистки
    _cleanupTimer?.cancel();
    _cleanupTimer = null;

    // Закрываем все клиентские контроллеры
    final clientCount = _clientStreams.length;
    await closeAllClientStreams();
    _logger?.internal(
      'Закрыты все клиентские стримы ($clientCount)',
    );

    // Закрываем основной контроллер
    try {
      if (!_mainController.isClosed) {
        await _mainController.close();
        _logger?.internal(
          'Основной контроллер закрыт',
        );
      }
    } catch (e, stackTrace) {
      _logger?.error('Ошибка при закрытии основного контроллера',
          error: e, stackTrace: stackTrace);
    }

    _logger?.info(
      'StreamDistributor освобожден, итоговые метрики: ${_metrics.snapshot()}',
    );
  }
}

/// Конфигурация для [StreamDistributor]
class StreamDistributorConfig {
  /// Включить автоматическую очистку неактивных стримов
  final bool enableAutoCleanup;

  /// Интервал очистки неактивных стримов
  final Duration cleanupInterval;

  /// Порог неактивности, после которого стрим считается неактивным
  final Duration inactivityThreshold;

  /// Автоматически удалять стрим при отмене подписки
  final bool autoRemoveOnCancel;

  /// Создает конфигурацию с указанными параметрами
  const StreamDistributorConfig({
    this.enableAutoCleanup = false,
    this.cleanupInterval = const Duration(minutes: 5),
    this.inactivityThreshold = const Duration(minutes: 30),
    this.autoRemoveOnCancel = true,
  });
}

/// Метрики дистрибьютора стримов
class StreamDistributorMetrics {
  /// Общее количество созданных стримов
  final int totalStreams;

  /// Текущее количество активных стримов
  final int currentStreams;

  /// Общее количество отправленных сообщений
  final int totalMessages;

  /// Количество ошибок при обработке сообщений
  final int errors;

  /// Средний размер сообщения (в байтах)
  final double averageMessageSize;

  /// Создает снимок метрик
  StreamDistributorMetrics({
    required this.totalStreams,
    required this.currentStreams,
    required this.totalMessages,
    required this.errors,
    required this.averageMessageSize,
  });

  @override
  String toString() {
    return 'StreamDistributorMetrics{'
        'totalStreams: $totalStreams, '
        'currentStreams: $currentStreams, '
        'totalMessages: $totalMessages, '
        'errors: $errors, '
        'averageMessageSize: ${averageMessageSize.toStringAsFixed(2)} bytes'
        '}';
  }
}

/// Внутренний класс для сбора метрик
class _DistributorMetrics {
  int _totalStreams = 0;
  int _currentStreams = 0;
  int _totalMessages = 0;
  int _errors = 0;

  int _messageSizeSum = 0;
  int _messageSizeCount = 0;

  void incrementTotalStreams() => _totalStreams++;
  void incrementCurrentStreams() => _currentStreams++;
  void decrementCurrentStreams() =>
      _currentStreams = (_currentStreams > 0) ? _currentStreams - 1 : 0;
  void incrementTotalMessages() => _totalMessages++;
  void incrementErrors() => _errors++;

  void recordMessageSize(IRpcSerializable message) {
    // Примерная оценка размера сообщения на основе JSON представления
    final size = message.toString().length;
    _messageSizeSum += size;
    _messageSizeCount++;
  }

  /// Создает снимок текущих метрик
  StreamDistributorMetrics snapshot() {
    final avgSize =
        _messageSizeCount > 0 ? _messageSizeSum / _messageSizeCount : 0.0;

    return StreamDistributorMetrics(
      totalStreams: _totalStreams,
      currentStreams: _currentStreams,
      totalMessages: _totalMessages,
      errors: _errors,
      averageMessageSize: avgSize,
    );
  }
}

/// Класс для хранения информации о клиентском стриме
class _ClientStreamWrapper<T extends IRpcSerializable> {
  final StreamController<T> controller;
  final StreamSubscription<_StreamMessage<T>> subscription;
  final String clientId;
  final DateTime createdAt;

  /// Время последней активности клиента
  DateTime lastActivity;

  /// Флаг паузы для клиента
  bool isPaused = false;

  /// Количество полученных сообщений
  int messagesReceived = 0;

  _ClientStreamWrapper({
    required this.controller,
    required this.subscription,
    required this.clientId,
    required this.createdAt,
  }) : lastActivity = DateTime.now();

  /// Обновляет время последней активности
  void updateLastActivity() {
    lastActivity = DateTime.now();
  }

  /// Увеличивает счетчик полученных сообщений
  void incrementReceivedMessages() {
    messagesReceived++;
  }

  /// Длительность активности стрима
  Duration getActiveDuration() {
    return DateTime.now().difference(createdAt);
  }

  /// Длительность неактивности стрима
  Duration getInactivityDuration() {
    return DateTime.now().difference(lastActivity);
  }

  /// Освобождение ресурсов
  Future<void> dispose() async {
    await subscription.cancel();
    if (!controller.isClosed) {
      await controller.close();
    }
  }
}

/// Обертка сообщения для внутренних стримов
///
/// Добавляет метаданные к сообщению для маршрутизации
/// и дополнительной информации внутри стримов
class _StreamMessage<T extends IRpcSerializable> {
  /// Оригинальное сообщение
  final T message;

  /// Идентификатор стрима, к которому относится сообщение
  final String streamId;

  /// Дополнительные метаданные для внутреннего использования
  final Map<String, dynamic>? metadata;

  /// Создает новую обертку для сообщения стрима
  _StreamMessage({
    required this.message,
    required this.streamId,
    this.metadata,
  });

  @override
  String toString() {
    return 'StreamMessage{message: $message, streamId: $streamId, metadata: $metadata}';
  }
}
