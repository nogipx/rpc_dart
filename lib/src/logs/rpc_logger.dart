// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_logs.dart';

/// Уровни логирования
enum RpcLoggerLevel {
  internal,
  debug,
  info,
  warning,
  error,
  critical,
  none;

  /// Создание из строки JSON
  static RpcLoggerLevel fromJson(String json) {
    return values.firstWhere(
      (e) => e.name == json,
      orElse: () => none,
    );
  }
}

typedef RpcLoggerFactory = RpcLogger Function(
  String loggerName, {
  RpcLoggerColors? colors,
  String? label,
  RpcContext? context,
});

/// Интерфейс для фильтрации логов
abstract interface class IRpcLoggerFilter {
  /// Проверяет, нужно ли логировать сообщение с указанным уровнем и источником
  bool shouldLog(RpcLoggerLevel level, String source);
}

/// Результат форматирования лога с разделением на заголовок и содержимое
class LogFormattingResult {
  /// Заголовок сообщения
  final String header;

  /// Содержимое сообщения
  final String content;

  LogFormattingResult(this.header, this.content);
}

/// Интерфейс для форматирования логов
abstract interface class IRpcLoggerFormatter {
  /// Форматирует сообщение лога, возвращая заголовок и содержимое раздельно
  LogFormattingResult format(
      DateTime timestamp, RpcLoggerLevel level, String source, String message,
      {String? context, String? requestId, String? traceId});
}

/// {@template rpc_logger}
/// Логгер для RPC библиотеки
///
/// Позволяет создавать экземпляры логгеров с разными настройками
/// и независимо управлять логированием разных компонентов.
/// {@endtemplate}
///
abstract interface class RpcLogger {
  /// Имя логгера, обычно название компонента или модуля
  String get name;

  /// Создает новый логгер с указанным именем
  factory RpcLogger(
    String loggerName, {
    RpcLoggerColors? colors,
    String? label,
    RpcContext? context,
  }) {
    return _RpcLoggerRegistry.instance.get(
      loggerName,
      colors: colors,
      label: label,
      context: context,
    );
  }

  RpcLogger child(String childName, {String? label});

  /// Отправляет лог с указанным уровнем в сервис диагностики
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
  });

  /// Отправляет лог уровня debug
  Future<void> internal(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  });

  /// Отправляет лог уровня debug
  Future<void> debug(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  });

  /// Отправляет лог уровня info
  Future<void> info(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  });

  /// Отправляет лог уровня warning
  Future<void> warning(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  });

  /// Отправляет лог уровня error
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
  });

  /// Отправляет лог уровня critical
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
  });

  // ============================================================================
  // Logger Settings - перенесено из RpcLogger
  // ============================================================================

  static RpcLoggerLevel _defaultMinLogLevel = RpcLoggerLevel.info;

  /// Устанавливает минимальный уровень логирования по умолчанию
  static void setDefaultMinLogLevel(RpcLoggerLevel level) {
    _defaultMinLogLevel = level;
  }

  /// Получает текущий минимальный уровень логирования по умолчанию
  static RpcLoggerLevel get defaultMinLogLevel => _defaultMinLogLevel;

  /// Устанавливает пользовательскую фабрику логгеров
  static void setLoggerFactory(RpcLoggerFactory factory) {
    _RpcLoggerRegistry._factory = factory;
  }

  /// Удаляет логгер по имени из реестра
  static void removeLogger(String loggerName) {
    _RpcLoggerRegistry.instance.remove(loggerName);
  }

  /// Очищает все логгеры из реестра
  static void clearLoggers() {
    _RpcLoggerRegistry.instance.clear();
  }
}
