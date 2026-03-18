// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_logs.dart';

/// {@template rpc_logger_registry}
/// Logger registry for the RPC library.
///
/// Registers and retrieves logger instances by name and exposes a global
/// registry instance.
/// {@endtemplate}
final class _RpcLoggerRegistry {
  /// Is logging disabled
  static bool _isDisabled = false;

  /// Optional factory used to create new loggers.
  static RpcLoggerFactory? _factory;

  /// Global registry instance.
  static final _RpcLoggerRegistry instance = _RpcLoggerRegistry._();

  /// Stored loggers keyed by name.
  final Map<String, RpcLogger> _loggers = {};

  /// Creates a new registry.
  _RpcLoggerRegistry._();

  /// Returns a logger by name, creating it if missing.
  ///
  /// When [context] is provided, returns a context-aware wrapper.
  RpcLogger get(
    String name, {
    RpcLoggerColors? colors,
    String? label,
    RpcContext? context,
  }) {
    // Create the base logger.
    RpcLogger baseLogger;

    if (_isDisabled) {
      _loggers.clear();
      baseLogger = _disabled;
    } else {
      if (_factory == null) {
        baseLogger = _loggers[name] ??= DefaultRpcLogger(
          name,
          colors: colors ?? const RpcLoggerColors(),
          label: label,
        );
      } else {
        baseLogger = _loggers[name] ??= _factory!(
          name,
          colors: colors ?? const RpcLoggerColors(),
          label: label,
        );
      }
    }

    // Wrap with context when provided.
    if (context != null) {
      return RpcContextAwareLogger(baseLogger, context);
    }

    return baseLogger;
  }

  /// Removes a logger by name.
  void remove(String name) {
    _loggers.remove(name);
  }

  /// Clears all registered loggers.
  void clear() {
    _loggers.clear();
  }
}

const _disabled = _DisabledRpcLogger();

final class _DisabledRpcLogger implements RpcLogger {
  const _DisabledRpcLogger();

  @override
  RpcLogger child(String childName, {String? label}) {
    return this;
  }

  @override
  Future<void> critical(String message,
      {String? context,
      String? requestId,
      String? traceId,
      Object? error,
      StackTrace? stackTrace,
      Map<String, dynamic>? data,
      AnsiColor? color,
      RpcContext? rpcContext}) async {}

  @override
  Future<void> debug(String message,
      {String? context,
      String? requestId,
      String? traceId,
      Map<String, dynamic>? data,
      AnsiColor? color,
      RpcContext? rpcContext}) async {}

  @override
  Future<void> error(String message,
      {String? context,
      String? requestId,
      String? traceId,
      Object? error,
      StackTrace? stackTrace,
      Map<String, dynamic>? data,
      AnsiColor? color,
      RpcContext? rpcContext}) async {}

  @override
  Future<void> info(String message,
      {String? context,
      String? requestId,
      String? traceId,
      Map<String, dynamic>? data,
      AnsiColor? color,
      RpcContext? rpcContext}) async {}

  @override
  Future<void> internal(String message,
      {String? context,
      String? requestId,
      String? traceId,
      Map<String, dynamic>? data,
      AnsiColor? color,
      RpcContext? rpcContext}) async {}

  @override
  Future<void> log(
      {required RpcLoggerLevel level,
      required String message,
      String? context,
      String? requestId,
      String? traceId,
      Object? error,
      StackTrace? stackTrace,
      Map<String, dynamic>? data,
      AnsiColor? color,
      RpcContext? rpcContext}) async {}

  @override
  String get name => '';

  @override
  Future<void> warning(String message,
      {String? context,
      String? requestId,
      String? traceId,
      Map<String, dynamic>? data,
      AnsiColor? color,
      RpcContext? rpcContext}) async {}
}
