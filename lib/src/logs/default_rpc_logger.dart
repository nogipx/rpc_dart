// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '_logs.dart';

/// Реализация фильтра по умолчанию, основанная на минимальном уровне логирования
class DefaultRpcLoggerFilter implements IRpcLoggerFilter {
  final RpcLoggerLevel minLogLevel;

  DefaultRpcLoggerFilter(this.minLogLevel);

  @override
  bool shouldLog(RpcLoggerLevel level, String source) {
    return level.index >= minLogLevel.index;
  }
}

/// Реализация форматтера по умолчанию
class DefaultRpcLoggerFormatter implements IRpcLoggerFormatter {
  final String? label;

  const DefaultRpcLoggerFormatter([this.label]);

  @override
  LogFormattingResult format(
      DateTime timestamp, RpcLoggerLevel level, String source, String message,
      {String? context}) {
    final formattedTime =
        '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')}';

    String prefix;
    String emoji;
    String connector;
    switch (level) {
      case RpcLoggerLevel.debug:
        prefix = 'DEBUG';
        emoji = '🔍';
        connector = '⤷ ';
      case RpcLoggerLevel.info:
        prefix = 'INFO';
        emoji = '📌';
        connector = '⤷ ';
      case RpcLoggerLevel.warning:
        prefix = 'WARN';
        emoji = '⚠️ ';
        connector = '⤷ ';
      case RpcLoggerLevel.error:
        prefix = 'ERROR';
        emoji = '❌';
        connector = '⤷ ';
      case RpcLoggerLevel.critical:
        prefix = 'CRIT';
        emoji = '🔥';
        connector = '⤷ ';
      default:
        prefix = '';
        emoji = '';
        connector = '⤷ ';
    }

    final contextStr = context != null ? ' [$context]' : '';
    final labelStr = label != null ? '($label) ' : '';
    final header =
        '[$formattedTime] ${prefix.padRight(5)} $emoji • $labelStr$source$contextStr';

    // Разбиваем длинное сообщение на строки с отступами
    final messageLines = message.split('\n');

    // Для ошибок добавляем специальное форматирование с рамкой
    String content;
    if (level == RpcLoggerLevel.error || level == RpcLoggerLevel.critical) {
      final formattedMessage =
          messageLines.map((line) => '  │ $line').join('\n');
      content =
          '  ┌──────────── ! ERROR ! ────────────┐\n$formattedMessage\n  └────────────────────────────────────┘';
    } else {
      content = messageLines.map((line) => '  $connector $line').join('\n');
    }

    return LogFormattingResult(header, content);
  }
}

/// Консольная реализация логгера
class DefaultRpcLogger implements RpcLogger {
  @override
  final String name;

  /// Флаг вывода логов в консоль
  final bool _consoleLoggingEnabled;

  /// Флаг использования цветов при выводе логов в консоль
  final bool _coloredLoggingEnabled;

  /// Настройки цветов для разных уровней логирования
  final RpcLoggerColors _colors;

  /// Фильтр логов
  final IRpcLoggerFilter _filter;

  /// Форматтер логов
  final IRpcLoggerFormatter _formatter;

  /// Создает новый логгер с указанными параметрами
  DefaultRpcLogger(
    this.name, {
    RpcLoggerColors colors = const RpcLoggerColors(),
    String? label,
    RpcLoggerLevel? minLogLevel,
    bool consoleLoggingEnabled = true,
    bool coloredLoggingEnabled = true,
    IRpcLoggerFilter? filter,
    IRpcLoggerFormatter? formatter,
  })  : _consoleLoggingEnabled = consoleLoggingEnabled,
        _coloredLoggingEnabled = coloredLoggingEnabled,
        _colors = colors,
        _formatter = formatter ?? const DefaultRpcLoggerFormatter(),
        _filter = filter ??
            DefaultRpcLoggerFilter(
              minLogLevel ?? RpcLoggerSettings.defaultMinLogLevel,
            );

  @override
  Future<void> log({
    required RpcLoggerLevel level,
    required String message,
    String? context,
    String? requestId,
    Object? error,
    StackTrace? stackTrace,
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
  }

  /// Отображает лог в консоли
  void _logToConsole({
    required RpcLoggerLevel level,
    required String message,
    String? context,
    Object? error,
    StackTrace? stackTrace,
    AnsiColor? color,
  }) {
    final timestamp = DateTime.now();

    // Создаем сообщение с включенными деталями ошибки для ERROR и CRITICAL
    String fullMessage = message;
    if (level == RpcLoggerLevel.error || level == RpcLoggerLevel.critical) {
      if (error != null) {
        fullMessage += '\n\nError details: $error';
      }
      if (stackTrace != null) {
        fullMessage += '\n\nStack trace: \n$stackTrace';
      }
    }

    final formattedLog = _formatter.format(timestamp, level, name, fullMessage,
        context: context);

    // Если включен цветной вывод, используем цвет только для заголовка
    if (_coloredLoggingEnabled) {
      final actualColor = color ?? _colors.colorForLevel(level);

      // Выводим заголовок с цветом
      print('${actualColor.code}${formattedLog.header}${AnsiColor.reset.code}');

      // Выводим содержимое без цвета
      if (formattedLog.content.isNotEmpty) {
        print(formattedLog.content);
      }

      // Вывод деталей ошибки только для обычных (не ERROR/CRITICAL) уровней
      if ((level != RpcLoggerLevel.error && level != RpcLoggerLevel.critical) &&
          error != null) {
        print('  Error details: $error');
      }

      if ((level != RpcLoggerLevel.error && level != RpcLoggerLevel.critical) &&
          stackTrace != null) {
        print('  Stack trace: \n$stackTrace');
      }
    } else {
      // Обычный вывод без цвета
      print(formattedLog.header);
      if (formattedLog.content.isNotEmpty) {
        print(formattedLog.content);
      }

      // Вывод деталей ошибки только для обычных (не ERROR/CRITICAL) уровней
      if ((level != RpcLoggerLevel.error && level != RpcLoggerLevel.critical) &&
          error != null) {
        print('  Error details: $error');
      }

      if ((level != RpcLoggerLevel.error && level != RpcLoggerLevel.critical) &&
          stackTrace != null) {
        print('  Stack trace: \n$stackTrace');
      }
    }
  }

  @override
  Future<void> debug(
    String message, {
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
  Future<void> info(
    String message, {
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
  Future<void> warning(
    String message, {
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
  Future<void> error(
    String message, {
    String? context,
    String? requestId,
    Object? error,
    StackTrace? stackTrace,
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
  Future<void> critical(
    String message, {
    String? context,
    String? requestId,
    Object? error,
    StackTrace? stackTrace,
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

  @override
  RpcLogger child(String childName, {String? label}) {
    return DefaultRpcLogger(
      '$name.$childName',
      colors: _colors,
      label: label ??
          (_formatter is DefaultRpcLoggerFormatter
              ? (_formatter as DefaultRpcLoggerFormatter).label
              : null),
      minLogLevel: _filter is DefaultRpcLoggerFilter
          ? (_filter as DefaultRpcLoggerFilter).minLogLevel
          : RpcLoggerSettings.defaultMinLogLevel,
      consoleLoggingEnabled: _consoleLoggingEnabled,
      coloredLoggingEnabled: _coloredLoggingEnabled,
      filter: _filter,
    );
  }
}
