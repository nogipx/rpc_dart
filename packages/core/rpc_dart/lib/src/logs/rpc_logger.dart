// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_logs.dart';

/// Logging levels.
enum RpcLoggerLevel {
  /// Framework-internal trace messages.
  internal,

  /// Debug-level messages for development.
  debug,

  /// General informational messages.
  info,

  /// Non-fatal warnings.
  warning,

  /// Recoverable errors.
  error,

  /// Critical failures that may halt the system.
  critical,

  /// All logging suppressed.
  disabled;

  /// Creates a level from JSON string.
  static RpcLoggerLevel fromJson(String json) {
    return values.firstWhere((e) => e.name == json, orElse: () => disabled);
  }
}

/// Factory function type for creating [RpcLogger] instances.
typedef RpcLoggerFactory = RpcLogger Function(
  String loggerName, {
  RpcLoggerColors? colors,
  String? label,
  RpcContext? context,
});

/// Log filter contract.
abstract interface class IRpcLoggerFilter {
  /// Returns true if the message should be logged for the given level/source.
  bool shouldLog(RpcLoggerLevel level, String source);
}

/// Formatting result split into header and content.
class LogFormattingResult {
  /// Message header.
  final String header;

  /// Message body content.
  final String content;

  /// Creates a result with [header] and [content].
  LogFormattingResult(this.header, this.content);
}

/// Contract for log formatting.
abstract interface class IRpcLoggerFormatter {
  /// Formats a log entry, returning header and content separately.
  LogFormattingResult format(
    DateTime timestamp,
    RpcLoggerLevel level,
    String source,
    String message, {
    String? context,
    String? requestId,
    String? traceId,
  });
}

/// {@template rpc_logger}
/// Logger for the RPC library.
///
/// Supports multiple logger instances with independent configuration.
/// {@endtemplate}
///
abstract interface class RpcLogger {
  /// Logger name, usually a component or module.
  String get name;

  /// Creates a new logger with the given name.
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

  /// Creates a child logger with a name derived from this logger.
  RpcLogger child(String childName, {String? label});

  /// Sends a log entry with the specified level.
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

  /// Sends an internal-level log.
  Future<void> internal(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  });

  /// Sends a debug-level log.
  Future<void> debug(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  });

  /// Sends an info-level log.
  Future<void> info(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  });

  /// Sends a warning-level log.
  Future<void> warning(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  });

  /// Sends an error-level log.
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

  /// Sends a critical-level log.
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
  // Logger Settings - moved from RpcLogger.
  // ============================================================================

  static RpcLoggerLevel _defaultMinLogLevel = RpcLoggerLevel.info;

  /// Sets the default minimal log level.
  static void setDefaultMinLogLevel(RpcLoggerLevel level) {
    if (level == RpcLoggerLevel.disabled) {
      disableLogger();
    } else {
      enableLogger();
    }
    _defaultMinLogLevel = level;
  }

  /// Gets the current default minimal log level.
  static RpcLoggerLevel get defaultMinLogLevel => _defaultMinLogLevel;

  /// Sets a custom logger factory.
  static void setLoggerFactory(RpcLoggerFactory factory) {
    _RpcLoggerRegistry._factory = factory;
  }

  /// Sets a custom logger factory.
  static void enableLogger() {
    _RpcLoggerRegistry._isDisabled = false;
  }

  /// Sets a custom logger factory.
  static void disableLogger() {
    _RpcLoggerRegistry._isDisabled = true;
  }

  /// Removes a logger by name from the registry.
  static void removeLogger(String loggerName) {
    _RpcLoggerRegistry.instance.remove(loggerName);
  }

  /// Clears all loggers from the registry.
  static void clearLoggers() {
    _RpcLoggerRegistry.instance.clear();
  }
}
