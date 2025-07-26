// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math';
import 'package:rpc_dart/rpc_dart.dart';

/// Стратегии переподключения WebSocket
enum ReconnectStrategy {
  /// Фиксированная задержка
  fixed,

  /// Экспоненциальная задержка с jitter
  exponentialBackoff,

  /// Линейная задержка
  linear,
}

/// Конфигурация для автоматического переподключения
class ReconnectConfig {
  /// Стратегия переподключения
  final ReconnectStrategy strategy;

  /// Начальная задержка (по умолчанию 1 секунда)
  final Duration initialDelay;

  /// Максимальная задержка (по умолчанию 30 секунд)
  final Duration maxDelay;

  /// Максимальное количество попыток (0 = бесконечно)
  final int maxAttempts;

  /// Множитель для экспоненциальной стратегии
  final double backoffMultiplier;

  /// Таймаут соединения
  final Duration connectionTimeout;

  /// Включить случайный jitter для избежания thundering herd
  final bool enableJitter;

  const ReconnectConfig({
    this.strategy = ReconnectStrategy.exponentialBackoff,
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.maxAttempts = 0, // бесконечно
    this.backoffMultiplier = 2.0,
    this.connectionTimeout = const Duration(seconds: 10),
    this.enableJitter = true,
  });
}

/// Состояния менеджера переподключения
enum ReconnectState {
  /// Подключен
  connected,

  /// Отключен
  disconnected,

  /// Переподключение в процессе
  reconnecting,

  /// Ожидание перед следующей попыткой
  waiting,

  /// Остановлен (не будет переподключаться)
  stopped,
}

/// Менеджер автоматического переподключения WebSocket
///
/// Отвечает за:
/// - Автоматическое переподключение при обрыве соединения
/// - Различные стратегии повторных попыток
/// - Мониторинг состояния соединения
/// - Callback'и для событий переподключения
class WebSocketReconnectManager {
  final ReconnectConfig _config;
  final RpcLogger? _logger;

  /// Текущее состояние
  ReconnectState _state = ReconnectState.disconnected;

  /// Количество попыток переподключения
  int _attemptCount = 0;

  /// Текущая задержка
  Duration _currentDelay;

  /// Таймер для переподключения
  Timer? _reconnectTimer;

  /// Функция создания нового соединения
  Future<void> Function()? _reconnectCallback;

  /// Контроллер для событий состояния
  final StreamController<ReconnectState> _stateController =
      StreamController<ReconnectState>.broadcast();

  /// Контроллер для событий попыток
  final StreamController<ReconnectAttempt> _attemptController =
      StreamController<ReconnectAttempt>.broadcast();

  /// Генератор случайных чисел для jitter
  final Random _random = Random();

  WebSocketReconnectManager({
    ReconnectConfig? config,
    RpcLogger? logger,
  })  : _config = config ?? const ReconnectConfig(),
        _logger = logger?.child('ReconnectManager'),
        _currentDelay = config?.initialDelay ?? const Duration(seconds: 1);

  /// Текущее состояние менеджера
  ReconnectState get state => _state;

  /// Количество попыток переподключения
  int get attemptCount => _attemptCount;

  /// Стрим событий изменения состояния
  Stream<ReconnectState> get stateChanges => _stateController.stream;

  /// Стрим событий попыток переподключения
  Stream<ReconnectAttempt> get attempts => _attemptController.stream;

  /// Устанавливает callback для переподключения
  void setReconnectCallback(Future<void> Function() callback) {
    _reconnectCallback = callback;
  }

  /// Отмечает успешное подключение
  void onConnected() {
    _setState(ReconnectState.connected);
    _attemptCount = 0;
    _currentDelay = _config.initialDelay;
    _cancelReconnectTimer();
    _logger?.info('WebSocket подключен, сбрасываем счетчик попыток');
  }

  /// Отмечает отключение и запускает переподключение
  void onDisconnected({String? reason}) {
    if (_state == ReconnectState.stopped) {
      _logger?.debug('Переподключение остановлено, игнорируем отключение');
      return;
    }

    _setState(ReconnectState.disconnected);
    _logger?.warning('WebSocket отключен${reason != null ? ': $reason' : ''}');

    if (_shouldReconnect()) {
      _scheduleReconnect();
    } else {
      _logger
          ?.info('Достигнуто максимальное количество попыток переподключения');
      _setState(ReconnectState.stopped);
    }
  }

  /// Принудительно запускает переподключение
  Future<void> reconnect() async {
    if (_state == ReconnectState.stopped) {
      _logger?.debug('Переподключение остановлено');
      return;
    }

    _cancelReconnectTimer();
    await _attemptReconnect();
  }

  /// Останавливает автоматическое переподключение
  void stop() {
    _setState(ReconnectState.stopped);
    _cancelReconnectTimer();
    _logger?.info('Автоматическое переподключение остановлено');
  }

  /// Сбрасывает состояние и возобновляет переподключение
  void reset() {
    _attemptCount = 0;
    _currentDelay = _config.initialDelay;
    _setState(ReconnectState.disconnected);
    _logger?.info('Состояние переподключения сброшено');
  }

  /// Проверяет, нужно ли переподключаться
  bool _shouldReconnect() {
    if (_config.maxAttempts <= 0) {
      return true; // бесконечные попытки
    }
    return _attemptCount < _config.maxAttempts;
  }

  /// Планирует следующую попытку переподключения
  void _scheduleReconnect() {
    _setState(ReconnectState.waiting);

    final delay = _calculateDelay();
    _logger?.info(
        'Планируем переподключение через ${delay.inSeconds}s (попытка ${_attemptCount + 1})');

    _reconnectTimer = Timer(delay, () {
      _attemptReconnect();
    });
  }

  /// Выполняет попытку переподключения
  Future<void> _attemptReconnect() async {
    if (_reconnectCallback == null) {
      _logger?.error('Callback переподключения не установлен');
      return;
    }

    _attemptCount++;
    _setState(ReconnectState.reconnecting);

    final attempt = ReconnectAttempt(
      attemptNumber: _attemptCount,
      delay: _currentDelay,
      timestamp: DateTime.now(),
    );

    _attemptController.add(attempt);
    _logger?.info('Попытка переподключения #$_attemptCount');

    try {
      await _reconnectCallback!().timeout(_config.connectionTimeout);
      // Успешное подключение будет обработано через onConnected()
    } catch (e) {
      _logger?.warning('Попытка переподключения #$_attemptCount неудачна: $e');

      // Обновляем задержку для следующей попытки
      _updateDelay();

      // Планируем следующую попытку
      if (_shouldReconnect()) {
        _scheduleReconnect();
      } else {
        _setState(ReconnectState.stopped);
      }
    }
  }

  /// Вычисляет задержку для следующей попытки
  Duration _calculateDelay() {
    switch (_config.strategy) {
      case ReconnectStrategy.fixed:
        return _config.initialDelay;

      case ReconnectStrategy.linear:
        final linearDelay = Duration(
          milliseconds:
              _config.initialDelay.inMilliseconds * (_attemptCount + 1),
        );
        return _capDelay(linearDelay);

      case ReconnectStrategy.exponentialBackoff:
        return _currentDelay;
    }
  }

  /// Обновляет задержку для экспоненциальной стратегии
  void _updateDelay() {
    if (_config.strategy == ReconnectStrategy.exponentialBackoff) {
      _currentDelay = Duration(
        milliseconds:
            (_currentDelay.inMilliseconds * _config.backoffMultiplier).round(),
      );
      _currentDelay = _capDelay(_currentDelay);
    }
  }

  /// Ограничивает задержку максимальным значением и добавляет jitter
  Duration _capDelay(Duration delay) {
    var cappedDelay = delay;
    if (cappedDelay > _config.maxDelay) {
      cappedDelay = _config.maxDelay;
    }

    // Добавляем jitter если включен
    if (_config.enableJitter) {
      final jitterMs = _random.nextInt(1000); // до 1 секунды
      cappedDelay =
          Duration(milliseconds: cappedDelay.inMilliseconds + jitterMs);
    }

    return cappedDelay;
  }

  /// Отменяет таймер переподключения
  void _cancelReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// Изменяет состояние и уведомляет подписчиков
  void _setState(ReconnectState newState) {
    if (_state != newState) {
      final oldState = _state;
      _state = newState;
      _stateController.add(newState);
      _logger?.debug('Состояние изменено: $oldState -> $newState');
    }
  }

  /// Закрывает менеджер переподключения
  Future<void> dispose() async {
    stop();
    await _stateController.close();
    await _attemptController.close();
    _logger?.info('ReconnectManager закрыт');
  }
}

/// Информация о попытке переподключения
class ReconnectAttempt {
  /// Номер попытки
  final int attemptNumber;

  /// Задержка перед попыткой
  final Duration delay;

  /// Время попытки
  final DateTime timestamp;

  const ReconnectAttempt({
    required this.attemptNumber,
    required this.delay,
    required this.timestamp,
  });

  @override
  String toString() {
    return 'ReconnectAttempt(#$attemptNumber, delay: ${delay.inSeconds}s, time: $timestamp)';
  }
}
