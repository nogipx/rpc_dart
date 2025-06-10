// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

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
        _baseLogger.child(childName, label: label), _context);
  }

  @override
  String get name => _baseLogger.name;

  // Все методы логирования автоматически используют _context
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
      rpcContext:
          rpcContext ?? _context, // Автоматически используем наш контекст
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
