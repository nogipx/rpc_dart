// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

/// Контекстно-осведомленный логгер, который автоматически использует RpcContext
///
/// Обертывает обычный RpcLogger и автоматически передает trace ID и request ID
/// из привязанного RpcContext во все вызовы логирования
final class RpcContextAwareLogger implements RpcLogger {
  final RpcLogger _baseLogger;
  final RpcContext _context;

  /// Создает контекстный логгер с привязанным контекстом
  RpcContextAwareLogger(this._baseLogger, this._context);

  /// Создает дочерний контекстный логгер с тем же контекстом
  @override
  RpcContextAwareLogger child(String childName, {String? label}) {
    return RpcContextAwareLogger(
      _baseLogger.child(childName, label: label),
      _context,
    );
  }

  @override
  String get name => _baseLogger.name;

  // Все методы логирования автоматически используют _context
  @override
  Future<void> internal(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) {
    return _baseLogger.internal(
      message,
      context: context,
      requestId: requestId,
      traceId: traceId,
      data: data,
      color: color,
      rpcContext:
          rpcContext ?? _context, // Автоматически используем наш контекст
    );
  }

  /// Отправляет лог уровня debug
  @override
  Future<void> debug(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) {
    return _baseLogger.debug(
      message,
      context: context,
      requestId: requestId,
      traceId: traceId,
      data: data,
      color: color,
      rpcContext: rpcContext ?? _context,
    );
  }

  @override
  Future<void> info(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) {
    return _baseLogger.info(
      message,
      context: context,
      requestId: requestId,
      traceId: traceId,
      data: data,
      color: color,
      rpcContext: rpcContext ?? _context,
    );
  }

  @override
  Future<void> warning(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) {
    return _baseLogger.warning(
      message,
      context: context,
      requestId: requestId,
      traceId: traceId,
      data: data,
      color: color,
      rpcContext: rpcContext ?? _context,
    );
  }

  @override
  Future<void> error(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) {
    return _baseLogger.error(
      message,
      context: context,
      requestId: requestId,
      traceId: traceId,
      error: error,
      stackTrace: stackTrace,
      data: data,
      color: color,
      rpcContext: rpcContext ?? _context,
    );
  }

  @override
  Future<void> critical(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) {
    return _baseLogger.critical(
      message,
      context: context,
      requestId: requestId,
      traceId: traceId,
      error: error,
      stackTrace: stackTrace,
      data: data,
      color: color,
      rpcContext: rpcContext ?? _context,
    );
  }

  @override
  Future<void> log({
    required RpcLoggerLevel level,
    required String message,
    String? context,
    String? requestId,
    String? traceId,
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) {
    return _baseLogger.log(
      level: level,
      message: message,
      context: context,
      requestId: requestId,
      traceId: traceId,
      error: error,
      stackTrace: stackTrace,
      data: data,
      color: color,
      rpcContext:
          rpcContext ?? _context, // Автоматически используем наш контекст
    );
  }
}

/// Mixin для компонентов, которые хотят автоматически использовать контекстное логирование
///
/// Автоматически создает и обновляет контекстные логгеры при изменении RpcContext
///
/// Пример использования:
/// ```dart
/// class MyService with RpcContextualLogging {
///   @override
///   String get loggerName => 'MyService';
///
///   void processRequest(RpcContext context) {
///     updateContext(context); // Обновляем контекст
///     contextLogger.info('Processing request'); // Автоматически использует context
///   }
/// }
/// ```
mixin RpcContextualLogging {
  /// Название логгера (должно быть переопределено)
  String get loggerName;

  /// Базовый логгер
  RpcLogger? _baseLogger;

  /// Текущий контекст
  RpcContext? _currentContext;

  /// Контекстный логгер
  RpcLogger? _contextLogger;

  /// Получает базовый логгер (создает если нужно)
  RpcLogger get baseLogger {
    return _baseLogger ??= RpcLogger(loggerName);
  }

  /// Получает контекстный логгер (создает если нужно)
  RpcLogger get contextLogger {
    if (_currentContext != null) {
      // Если есть контекст - возвращаем контекстный логгер
      return _contextLogger ??= baseLogger.withContext(_currentContext!);
    }

    // Если контекста нет - возвращаем базовый логгер
    return baseLogger;
  }

  /// Обновляет контекст и пересоздает контекстный логгер
  void updateContext(RpcContext? context) {
    if (_currentContext == context) return; // Нет изменений

    _currentContext = context;
    _contextLogger = null; // Пересоздадим при следующем обращении
  }

  /// Создает дочерний контекстный логгер
  RpcLogger createChildLogger(String childName) {
    return contextLogger.child(childName);
  }

  /// Логирует с автоматическим использованием контекста
  Future<void> logWithContext(
    RpcLoggerLevel level,
    String message, {
    String? context,
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? data,
  }) {
    return contextLogger.log(
      level: level,
      message: message,
      context: context,
      error: error,
      stackTrace: stackTrace,
      data: data,
    );
  }

  /// Удобные методы для логирования с контекстом
  Future<void> infoWithContext(
    String message, {
    String? context,
    Map<String, dynamic>? data,
  }) =>
      logWithContext(
        RpcLoggerLevel.info,
        message,
        context: context,
        data: data,
      );

  Future<void> debugWithContext(
    String message, {
    String? context,
    Map<String, dynamic>? data,
  }) =>
      logWithContext(
        RpcLoggerLevel.debug,
        message,
        context: context,
        data: data,
      );

  Future<void> warningWithContext(
    String message, {
    String? context,
    Map<String, dynamic>? data,
  }) =>
      logWithContext(
        RpcLoggerLevel.warning,
        message,
        context: context,
        data: data,
      );

  Future<void> errorWithContext(
    String message, {
    String? context,
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? data,
  }) =>
      logWithContext(
        RpcLoggerLevel.error,
        message,
        context: context,
        error: error,
        stackTrace: stackTrace,
        data: data,
      );
}
