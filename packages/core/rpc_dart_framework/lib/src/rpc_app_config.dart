// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

/// One finished RPC call: succeeded, failed or cancelled.
///
/// Passed to [RpcAppConfig.onCall] when set, and recorded by `RpcCallSpy`.
/// Useful for metrics, tracing and audit logging.
class RpcCallEvent {
  /// Name of the RPC service.
  final String serviceName;

  /// Name of the RPC method.
  final String methodName;

  /// The call's shape.
  final RpcMethodType callType;

  /// Wall-clock duration of the call; for a stream, until it ended or its
  /// consumer cancelled it.
  final Duration duration;

  /// How the call ended.
  final RpcCallOutcome outcome;

  /// The [RpcContext] that was active during the call.
  final RpcContext context;

  const RpcCallEvent({
    required this.serviceName,
    required this.methodName,
    required this.callType,
    required this.duration,
    required this.outcome,
    required this.context,
  });

  /// Whether the call completed.
  bool get success => outcome is RpcCallSucceeded;

  /// What the call failed with, or null when it did not fail.
  Object? get error => switch (outcome) {
    RpcCallFailed(:final error) => error,
    _ => null,
  };

  @override
  String toString() =>
      'RpcCallEvent($serviceName.$methodName [${callType.name}] '
      '${duration.inMilliseconds}ms $outcome)';
}

/// Signature for the global error hook.
typedef RpcErrorHandler =
    void Function(
      Object error,
      StackTrace stackTrace,
      String serviceName,
      String methodName,
    );

/// Signature for the per-call metrics observer.
typedef RpcCallEventHandler = void Function(RpcCallEvent event);

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

  /// Log controller for endpoint injection. When set, every endpoint created by
  /// the server will receive this controller so that `context.log` works inside
  /// responder handlers.
  final LogController? logController;

  /// Called for every call that fails, of all four call types, with the error
  /// that failed it. The error still reaches the caller. A cancelled call is
  /// not a failure and is not reported here.
  final RpcErrorHandler? onError;

  /// Called after every RPC call ends: succeeded, failed or cancelled.
  ///
  /// Use this to feed Prometheus counters, OpenTelemetry spans, etc.
  /// The framework automatically wires a timing interceptor.
  final RpcCallEventHandler? onCall;

  /// Override [Platform.environment] for env-based module configuration.
  ///
  /// Null (default) uses the real process environment. Pass a custom map in
  /// tests or when configuration is loaded from a file.
  final Map<String, String>? env;

  const RpcAppConfig({
    this.shutdownTimeout = const Duration(seconds: 30),
    this.drainTimeout = const Duration(seconds: 10),
    this.logger,
    this.logController,
    this.onError,
    this.onCall,
    this.env,
  });

  /// This config with the given fields replaced; a null argument keeps the
  /// field.
  RpcAppConfig copyWith({
    Duration? shutdownTimeout,
    Duration? drainTimeout,
    LogScope? logger,
    LogController? logController,
    RpcErrorHandler? onError,
    RpcCallEventHandler? onCall,
    Map<String, String>? env,
  }) => RpcAppConfig(
    shutdownTimeout: shutdownTimeout ?? this.shutdownTimeout,
    drainTimeout: drainTimeout ?? this.drainTimeout,
    logger: logger ?? this.logger,
    logController: logController ?? this.logController,
    onError: onError ?? this.onError,
    onCall: onCall ?? this.onCall,
    env: env ?? this.env,
  );
}
