// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '_logs.dart';

typedef DefaultRpcLogger = _ConsoleRpcLogger;

/// Реализация фильтра по умолчанию, основанная на минимальном уровне логирования
class _DefaultRpcLoggerFilter implements IRpcLoggerFilter {
  final RpcLoggerLevel minLogLevel;

  _DefaultRpcLoggerFilter(this.minLogLevel);

  @override
  bool shouldLog(RpcLoggerLevel level, String source) {
    return level.index >= minLogLevel.index;
  }
}

/// Реализация форматтера по умолчанию
class _DefaultRpcLoggerFormatter implements IRpcLoggerFormatter {
  const _DefaultRpcLoggerFormatter();

  @override
  String format(
      DateTime timestamp, RpcLoggerLevel level, String source, String message,
      {String? context}) {
    final formattedTime =
        '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')}';

    String prefix;
    switch (level) {
      case RpcLoggerLevel.debug:
        prefix = '🔍 DEBUG';
      case RpcLoggerLevel.info:
        prefix = '📝 INFO ';
      case RpcLoggerLevel.warning:
        prefix = '⚠️ WARN ';
      case RpcLoggerLevel.error:
        prefix = '❌ ERROR';
      case RpcLoggerLevel.critical:
        prefix = '🔥 CRIT ';
      default:
        prefix = '     ';
    }

    final contextStr = context != null ? ' ($context)' : '';
    return '[$formattedTime] $prefix [$source$contextStr] $message';
  }
}

/// Консольная реализация логгера
class _ConsoleRpcLogger implements RpcLogger {
  @override
  final String name;

  /// Диагностический сервис для отправки логов
  final IRpcDiagnosticService? _diagnosticService;

  /// Минимальный уровень логов для отправки
  final RpcLoggerLevel _minLogLevel;

  /// Флаг вывода логов в консоль
  final bool _consoleLoggingEnabled;

  /// Флаг использования цветов при выводе логов в консоль
  final bool _coloredLoggingEnabled;

  /// Настройки цветов для разных уровней логирования
  final RpcLoggerColors _logColors;

  /// Фильтр логов
  final IRpcLoggerFilter _filter;

  /// Форматтер логов
  final IRpcLoggerFormatter _formatter;

  /// Создает новый логгер с указанными параметрами
  _ConsoleRpcLogger(
    this.name, {
    IRpcDiagnosticService? diagnosticService,
    RpcLoggerLevel minLogLevel = RpcLoggerLevel.info,
    bool consoleLoggingEnabled = true,
    bool coloredLoggingEnabled = true,
    RpcLoggerColors logColors = const RpcLoggerColors(),
    IRpcLoggerFilter? filter,
    IRpcLoggerFormatter? formatter,
  })  : _diagnosticService = diagnosticService,
        _minLogLevel = minLogLevel,
        _consoleLoggingEnabled = consoleLoggingEnabled,
        _coloredLoggingEnabled = coloredLoggingEnabled,
        _logColors = logColors,
        _filter = filter ?? _DefaultRpcLoggerFilter(minLogLevel),
        _formatter = formatter ?? const _DefaultRpcLoggerFormatter();

  @override
  RpcLogger withConfig({
    IRpcDiagnosticService? diagnosticService,
    RpcLoggerLevel? minLogLevel,
    bool? consoleLoggingEnabled,
    bool? coloredLoggingEnabled,
    RpcLoggerColors? logColors,
    IRpcLoggerFilter? filter,
    IRpcLoggerFormatter? formatter,
  }) {
    return _ConsoleRpcLogger(
      name,
      diagnosticService: diagnosticService ?? _diagnosticService,
      minLogLevel: minLogLevel ?? _minLogLevel,
      consoleLoggingEnabled: consoleLoggingEnabled ?? _consoleLoggingEnabled,
      coloredLoggingEnabled: coloredLoggingEnabled ?? _coloredLoggingEnabled,
      logColors: logColors ?? _logColors,
      filter: filter ?? _filter,
      formatter: formatter ?? _formatter,
    );
  }

  @override
  Future<void> log({
    required RpcLoggerLevel level,
    required String message,
    String? context,
    String? requestId,
    Map<String, dynamic>? error,
    String? stackTrace,
    Map<String, dynamic>? data,
    AnsiColor? color,
  }) async {
    // Проверяем, нужно ли логировать это сообщение
    if (!_filter.shouldLog(level, name)) {
      return;
    }

    // Выводим в консоль, если включено
    if (_consoleLoggingEnabled) {
      _logToConsole(
        level: level,
        message: message,
        context: context,
        error: error,
        stackTrace: stackTrace,
        color: color,
      );
    }

    // Отправляем в диагностический сервис, если он установлен
    if (_diagnosticService != null) {
      await _diagnosticService!.log(
        level: level,
        message: message,
        source: name,
        context: context,
        requestId: requestId,
        error: error,
        stackTrace: stackTrace,
        data: data,
      );
    }
  }

  /// Отображает лог в консоли
  void _logToConsole({
    required RpcLoggerLevel level,
    required String message,
    String? context,
    Map<String, dynamic>? error,
    String? stackTrace,
    AnsiColor? color,
  }) {
    final timestamp = DateTime.now();
    final logMessage =
        _formatter.format(timestamp, level, name, message, context: context);

    // Если включен цветной вывод, используем цвет
    if (_coloredLoggingEnabled) {
      final actualColor = color ?? _logColors.colorForLevel(level);
      RpcColoredLogging.logColored(
        logMessage,
        actualColor,
        isError: level.index >= RpcLoggerLevel.error.index,
      );

      if (error != null) {
        RpcColoredLogging.logColored(
          '  Error details: $error',
          actualColor,
          isError: true,
        );
      }

      if (stackTrace != null) {
        RpcColoredLogging.logColored(
          '  Stack trace: \n$stackTrace',
          actualColor,
          isError: true,
        );
      }
    } else {
      // Обычный вывод без цвета
      print(logMessage);

      if (error != null) {
        print('  Error details: $error');
      }

      if (stackTrace != null) {
        print('  Stack trace: \n$stackTrace');
      }
    }
  }

  @override
  Future<void> debug({
    required String message,
    String? context,
    String? requestId,
    Map<String, dynamic>? data,
    AnsiColor? color,
  }) async {
    await log(
      level: RpcLoggerLevel.debug,
      message: message,
      context: context,
      requestId: requestId,
      data: data,
      color: color,
    );
  }

  @override
  Future<void> info({
    required String message,
    String? context,
    String? requestId,
    Map<String, dynamic>? data,
    AnsiColor? color,
  }) async {
    await log(
      level: RpcLoggerLevel.info,
      message: message,
      context: context,
      requestId: requestId,
      data: data,
      color: color,
    );
  }

  @override
  Future<void> warning({
    required String message,
    String? context,
    String? requestId,
    Map<String, dynamic>? data,
    AnsiColor? color,
  }) async {
    await log(
      level: RpcLoggerLevel.warning,
      message: message,
      context: context,
      requestId: requestId,
      data: data,
      color: color,
    );
  }

  @override
  Future<void> error({
    required String message,
    String? context,
    String? requestId,
    Map<String, dynamic>? error,
    String? stackTrace,
    Map<String, dynamic>? data,
    AnsiColor? color,
  }) async {
    await log(
      level: RpcLoggerLevel.error,
      message: message,
      context: context,
      requestId: requestId,
      error: error,
      stackTrace: stackTrace,
      data: data,
      color: color,
    );
  }

  @override
  Future<void> critical({
    required String message,
    String? context,
    String? requestId,
    Map<String, dynamic>? error,
    String? stackTrace,
    Map<String, dynamic>? data,
    AnsiColor? color,
  }) async {
    await log(
      level: RpcLoggerLevel.critical,
      message: message,
      context: context,
      requestId: requestId,
      error: error,
      stackTrace: stackTrace,
      data: data,
      color: color,
    );
  }
}
