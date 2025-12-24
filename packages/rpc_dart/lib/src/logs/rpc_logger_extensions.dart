// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_logs.dart';

/// RpcLogger extensions for convenient RPC logging.
extension RpcLoggerExtensions on RpcLogger {
  /// Logs binding to the message stream.
  Future<void> logStreamBound({
    required String methodPath,
    required int streamId,
    RpcContext? context,
  }) async {
    await internal(
      'Stream bound to message flow',
      context: 'binding:$methodPath',
      rpcContext: context,
      data: {
        'method_path': methodPath,
        'stream_id': streamId,
        'action': 'bind_to_stream',
      },
    );
  }

  /// Logs processing of an incoming message.
  Future<void> logMessageReceived({
    required int streamId,
    required String messageType,
    int? payloadSize,
    bool? isDirectPayload,
    RpcContext? context,
  }) async {
    await internal(
      'Message received',
      context: 'message:$messageType',
      rpcContext: context,
      data: {
        'stream_id': streamId,
        'message_type': messageType,
        'payload_size': payloadSize,
        'is_direct_payload': isDirectPayload,
        'action': 'message_received',
      },
    );
  }

  /// Logs stream completion.
  Future<void> logStreamFinished({
    required String methodPath,
    required int streamId,
    String? reason,
    RpcContext? context,
  }) async {
    await internal(
      'Stream finished',
      context: 'finish:$methodPath',
      rpcContext: context,
      data: {
        'method_path': methodPath,
        'stream_id': streamId,
        'reason': reason,
        'action': 'stream_finished',
      },
    );
  }

  /// Logs an error with RPC context.
  Future<void> logRpcError({
    required String operation,
    required Object error,
    StackTrace? stackTrace,
    String? methodPath,
    int? streamId,
    RpcContext? context,
    Map<String, dynamic>? metadata,
  }) async {
    await this.error(
      'RPC operation failed: $operation',
      context: 'error:${methodPath ?? 'unknown'}',
      error: error,
      stackTrace: stackTrace,
      rpcContext: context,
      data: {
        'operation': operation,
        'method_path': methodPath,
        'stream_id': streamId,
        'error_type': error.runtimeType.toString(),
        if (metadata != null) ...metadata,
      },
    );
  }

  /// Logs a warning with RPC context.
  Future<void> logRpcWarning({
    required String message,
    String? methodPath,
    int? streamId,
    RpcContext? context,
    Map<String, dynamic>? metadata,
  }) async {
    await warning(
      message,
      context: 'warning:${methodPath ?? 'unknown'}',
      rpcContext: context,
      data: {
        'method_path': methodPath,
        'stream_id': streamId,
        if (metadata != null) ...metadata,
      },
    );
  }

  /// Creates a context-aware logger bound to an RpcContext.
  RpcLogger withContext(RpcContext context) {
    return RpcContextAwareLogger(this, context);
  }
}
