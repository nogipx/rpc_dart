// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

/// Metadata emitted for every completed RPC call (success or failure).
///
/// Passed to [RpcAppConfig.onCall] when set. Useful for metrics, tracing,
/// and audit logging.
class RpcCallEvent {
  /// Name of the RPC service.
  final String serviceName;

  /// Name of the RPC method.
  final String methodName;

  /// One of `'unary'`, `'serverStream'`, `'clientStream'`, `'bidiStream'`.
  final String callType;

  /// Wall-clock duration of the call (for streams: until the stream ended).
  final Duration duration;

  /// True when the call completed without throwing.
  final bool success;

  /// The exception that was thrown, or null on success.
  final Object? error;

  /// The [RpcContext] that was active during the call.
  final RpcContext context;

  const RpcCallEvent({
    required this.serviceName,
    required this.methodName,
    required this.callType,
    required this.duration,
    required this.success,
    required this.context,
    this.error,
  });

  @override
  String toString() {
    final status = success ? 'OK' : 'ERROR(${error.runtimeType})';
    return 'RpcCallEvent($serviceName.$methodName [$callType] '
        '${duration.inMilliseconds}ms $status)';
  }
}

/// Signature for the global error hook.
typedef RpcErrorHandler = void Function(
  Object error,
  StackTrace stackTrace,
  String serviceName,
  String methodName,
);

/// Signature for the per-call metrics observer.
typedef RpcCallObserver = void Function(RpcCallEvent event);

/// Framework-level configuration for [RpcApp].
class RpcAppConfig {
  /// Maximum time to wait for [RpcModule.onStop] per module before logging a
  /// warning and moving on.
  final Duration shutdownTimeout;

  /// Maximum time to wait for in-flight RPC streams to finish after the
  /// framework initiates shutdown before forcefully stopping the server.
  final Duration drainTimeout;

  /// Logger used by the framework itself. Null = silent.
  final LogScope? logger;

  /// Called for every unhandled exception that escapes an RPC handler.
  ///
  /// The framework automatically wires an interceptor that catches errors from
  /// all four call types (unary, server-stream, client-stream, bidi-stream)
  /// and routes them here before re-throwing.
  final RpcErrorHandler? onError;

  /// Called after every RPC call finishes (success or failure).
  ///
  /// Use this to feed Prometheus counters, OpenTelemetry spans, etc.
  /// The framework automatically wires a timing interceptor.
  final RpcCallObserver? onCall;

  /// Override [Platform.environment] for env-based module configuration.
  ///
  /// Null (default) uses the real process environment. Pass a custom map in
  /// tests or when configuration is loaded from a file.
  final Map<String, String>? env;

  const RpcAppConfig({
    this.shutdownTimeout = const Duration(seconds: 30),
    this.drainTimeout = const Duration(seconds: 10),
    this.logger,
    this.onError,
    this.onCall,
    this.env,
  });
}
