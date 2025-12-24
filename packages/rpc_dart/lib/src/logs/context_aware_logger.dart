// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

/// Context-aware logger that automatically uses RpcContext.
///
/// Wraps a base RpcLogger and forwards trace/request IDs from the attached
/// RpcContext into every log call.
final class RpcContextAwareLogger implements RpcLogger {
  final RpcLogger _baseLogger;
  final RpcContext _context;

  /// Creates a context-aware logger bound to [RpcContext].
  RpcContextAwareLogger(this._baseLogger, this._context);

  /// Creates a child context-aware logger with the same context.
  @override
  RpcContextAwareLogger child(String childName, {String? label}) {
    return RpcContextAwareLogger(
      _baseLogger.child(childName, label: label),
      _context,
    );
  }

  @override
  String get name => _baseLogger.name;

  // All logging methods automatically fall back to _context.
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
      rpcContext: rpcContext ?? _context,
    );
  }

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
      rpcContext: rpcContext ?? _context,
    );
  }
}

/// Mixin for components that want automatic context-aware logging.
///
/// Rebuilds context loggers when the RpcContext changes.
mixin RpcContextualLogging {
  /// Logger name (must be overridden).
  String get loggerName;

  /// Base logger.
  RpcLogger? _baseLogger;

  /// Current context.
  RpcContext? _currentContext;

  /// Context-aware logger.
  RpcLogger? _contextLogger;

  /// Returns the base logger (lazy initialized).
  RpcLogger get baseLogger {
    return _baseLogger ??= RpcLogger(loggerName);
  }

  /// Returns a context-aware logger (lazy initialized).
  RpcLogger get contextLogger {
    if (_currentContext != null) {
      // Use context-aware logger when context exists.
      return _contextLogger ??= baseLogger.withContext(_currentContext!);
    }

    // Fallback to base logger when no context.
    return baseLogger;
  }

  /// Updates the context and resets the context logger.
  void updateContext(RpcContext? context) {
    if (_currentContext == context) return; // No changes.

    _currentContext = context;
    _contextLogger = null; // Recreate on next access.
  }

  /// Creates a child context-aware logger.
  RpcLogger createChildLogger(String childName) {
    return contextLogger.child(childName);
  }

  /// Logs while automatically applying context.
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

  /// Convenience helpers for context-aware logging.
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
