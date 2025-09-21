// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_logs.dart';

/// Расширения для RpcLogger для удобного логирования RPC операций
extension RpcLoggerExtensions on RpcLogger {
  // ============================================================================
  // Stream операции
  // ============================================================================

  /// Логирует создание stream процессора
  Future<void> logStreamCreated({
    required String methodPath,
    required int streamId,
    String? processorType,
    RpcContext? context,
    Map<String, dynamic>? metadata,
  }) async {
    await internal(
      'Stream processor created',
      context: '$processorType:$methodPath',
      rpcContext: context,
      data: {
        'method_path': methodPath,
        'stream_id': streamId,
        'processor_type': processorType,
        if (metadata != null) ...metadata,
      },
    );
  }

  /// Логирует привязку к потоку сообщений
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

  /// Логирует обработку входящего сообщения
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

  /// Логирует отправку ответа
  Future<void> logResponseSent({
    required int streamId,
    required String methodPath,
    int? responseSize,
    int? responseNumber,
    RpcContext? context,
  }) async {
    await internal(
      'Response sent',
      context: 'response:$methodPath',
      rpcContext: context,
      data: {
        'stream_id': streamId,
        'method_path': methodPath,
        'response_size': responseSize,
        'response_number': responseNumber,
        'action': 'response_sent',
      },
    );
  }

  /// Логирует завершение stream
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

  // ============================================================================
  // Error handling
  // ============================================================================

  /// Логирует ошибку с контекстом RPC операции
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

  /// Логирует warning с контекстом RPC операции
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

  // ============================================================================
  // Контекстные логгеры
  // ============================================================================

  /// Создает контекстный логгер с привязанным RpcContext
  ///
  /// Пример:
  /// ```dart
  /// final contextLogger = logger.withContext(rpcContext);
  /// contextLogger.info('Message'); // автоматически использует trace ID
  /// ```
  RpcLogger withContext(RpcContext context) {
    return RpcContextAwareLogger(this, context);
  }

  /// Создает контекстный логгер для операции
  ///
  /// Пример:
  /// ```dart
  /// final opLogger = logger.forOperation('CreateUser', context);
  /// opLogger.info('User created'); // включает operation в контекст
  /// ```
  RpcLogger forOperation(String operation, RpcContext? context) {
    if (context == null) {
      return child(operation);
    }

    final opContext = context.withAdditionalHeaders({'x-operation': operation});

    return RpcContextAwareLogger(child(operation), opContext);
  }

  /// Создает контекстный логгер для stream
  ///
  /// Пример:
  /// ```dart
  /// final streamLogger = logger.forStream(streamId, context);
  /// streamLogger.debug('Processing stream'); // включает streamId в контекст
  /// ```
  RpcLogger forStream(int streamId, RpcContext? context) {
    if (context == null) {
      return child('stream.$streamId');
    }

    final streamContext = context.withAdditionalHeaders({
      'x-stream-id': streamId.toString(),
    });

    return RpcContextAwareLogger(child('stream.$streamId'), streamContext);
  }

  /// Создает контекстный логгер для метода
  ///
  /// Пример:
  /// ```dart
  /// final methodLogger = logger.forMethod('GetUser', context);
  /// methodLogger.info('Method called'); // включает method в контекст
  /// ```
  RpcLogger forMethod(String methodPath, RpcContext? context) {
    if (context == null) {
      return child(methodPath);
    }

    final methodContext = context.withAdditionalHeaders({
      'x-method-path': methodPath,
    });

    return RpcContextAwareLogger(child(methodPath), methodContext);
  }
}

/// Extension для удобной работы с RpcContext в логгерах
extension RpcContextLoggerExtensions on RpcContext {
  /// Создает логгер с привязанным контекстом
  ///
  /// Пример:
  /// ```dart
  /// final logger = context.createLogger('ServiceName');
  /// logger.info('Message'); // автоматически использует trace/request ID
  /// ```
  RpcLogger createLogger(String name) {
    return RpcLogger(name, context: this);
  }

  /// Создает дочерний логгер с обновленным контекстом
  ///
  /// Пример:
  /// ```dart
  /// final childLogger = context.createChildLogger(parentLogger, 'ChildService');
  /// ```
  RpcLogger createChildLogger(RpcLogger parentLogger, String childName) {
    return parentLogger.child(childName).withContext(this);
  }
}
