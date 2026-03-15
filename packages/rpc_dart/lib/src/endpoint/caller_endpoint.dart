// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Client-side RPC endpoint for sending requests.
final class RpcCallerEndpoint extends RpcEndpointBase {
  /// Registry of cancellation tokens for active calls.
  /// Key: "serviceName/methodName", Value: map of requestId -> token.
  final Map<String, Map<String, RpcCancellationToken>> _cancellationTokens = {};

  void _untrackRequest(
    String serviceName,
    String methodName,
    String requestId,
  ) {
    final key = _createMethodKey(serviceName, methodName);
    final methodTokens = _cancellationTokens[key];
    if (methodTokens == null) {
      return;
    }

    methodTokens.remove(requestId);
    if (methodTokens.isEmpty) {
      _cancellationTokens.remove(key);
    }
  }

  @override
  Map<String, Object?> collectEndpointMetrics() {
    final metrics = Map<String, Object?>.from(super.collectEndpointMetrics());

    final activeCalls = _cancellationTokens.values.fold<int>(
      0,
      (previousValue, tokens) => previousValue + tokens.length,
    );

    metrics['pendingRequests'] = activeCalls;
    metrics['trackedMethods'] = _cancellationTokens.length;

    if (_cancellationTokens.isNotEmpty) {
      metrics['activeMethodKeys'] = List<String>.unmodifiable(
        _cancellationTokens.keys,
      );
    }

    return metrics;
  }

  @override
  RpcLogger get logger =>
      RpcLogger('RpcCallerEndpoint', colors: loggerColors, label: debugLabel);

  /// Whether to compress outgoing requests with gzip by default.
  ///
  /// Automatically disabled for zero-copy-capable transports (e.g.
  /// [RpcInMemoryTransport]) because compression yields no benefit
  /// in-process and only wastes CPU.
  final bool compressionEnabled;

  RpcCallerEndpoint({
    required super.transport,
    super.debugLabel,
    super.loggerColors,
    this.compressionEnabled = true,
  }) {
    _validateClientTransport();
  }

  /// Performs a ping to a responder endpoint and returns the result.
  Future<RpcEndpointPingResult> ping({
    Duration? timeout,
    RpcContext? context,
  }) async {
    if (!isActive) {
      throw StateError(
        'RpcCallerEndpoint is closed and cannot perform ping',
      );
    }

    if (transport.isClosed) {
      throw StateError(
        'Transport is closed and cannot send ping',
      );
    }

    final streamId = transport.createStream();
    final sentAt = DateTime.now().toUtc();

    logger.internal('Preparing ping request [streamId: $streamId]');

    final baseContext = _ensureContext(context);
    final routingContext = baseContext.withAdditionalHeaders({
      'x-route-service': RpcEndpointPingProtocol.serviceName,
    });

    // Check cancellation and deadline before sending ping.
    routingContext.cancellationToken?.throwIfCancelled();
    if (routingContext.isExpired) {
      throw RpcDeadlineExceededException(
        routingContext.deadline!,
        Duration.zero,
      );
    }

    final baseMetadata = RpcMetadata.forClientRequest(
      RpcEndpointPingProtocol.serviceName,
      RpcEndpointPingProtocol.methodName,
    );

    final headers = List<RpcHeader>.from(baseMetadata.headers);

    for (final entry in routingContext.headers.entries) {
      headers.add(RpcHeader(entry.key, entry.value));
    }

    if (routingContext.traceId != null) {
      headers.add(RpcHeader('x-trace-id', routingContext.traceId!));
    }

    headers.add(RpcHeader('x-request-id', routingContext.requestId));

    if (routingContext.deadline != null) {
      final timeout = routingContext.remainingTime;
      if (timeout != null) {
        headers.add(
          RpcHeader(
            RpcConstants.grpcTimeoutHeader,
            RpcMetadata.encodeGrpcTimeout(timeout),
          ),
        );
      }
      headers.add(
        RpcHeader(
          'x-deadline',
          routingContext.deadline!.millisecondsSinceEpoch.toString(),
        ),
      );
    }

    headers.add(
      RpcHeader(
        RpcEndpointPingProtocol.requestTimestampHeader,
        sentAt.toIso8601String(),
      ),
    );

    final metadata = RpcMetadata(headers);

    final exchange = RpcEndpointPingExchange(
      transport: transport,
      logger: logger,
      streamId: streamId,
      sentAt: sentAt,
    );

    return exchange.execute(
      metadata: metadata,
      timeout: timeout,
    );
  }

  /// Builds a cancellation registry key from service and method names.
  String _createMethodKey(String serviceName, String methodName) {
    return '$serviceName/$methodName';
  }

  /// Returns the cancellation token for a method/requestId, or null if absent.
  RpcCancellationToken? getCancellationToken(
    String serviceName,
    String methodName,
    String requestId,
  ) {
    final key = _createMethodKey(serviceName, methodName);
    return _cancellationTokens[key]?[requestId];
  }

  /// Returns all cancellation tokens for a method (empty map when missing).
  Map<String, RpcCancellationToken> getCancellationTokensForMethod(
    String serviceName,
    String methodName,
  ) {
    final key = _createMethodKey(serviceName, methodName);
    return Map.unmodifiable(_cancellationTokens[key] ?? {});
  }

  /// Cancels a specific call by requestId; returns true if found.
  bool cancelRequest(
    String serviceName,
    String methodName,
    String requestId, [
    String? reason,
  ]) {
    final key = _createMethodKey(serviceName, methodName);
    final methodTokens = _cancellationTokens[key];
    if (methodTokens != null) {
      final token = methodTokens[requestId];
      if (token != null) {
        token.cancel(reason ?? 'Request cancelled by user');
        methodTokens.remove(requestId);

        // Если больше нет токенов для этого метода, удаляем весь ключ
        if (methodTokens.isEmpty) {
          _cancellationTokens.remove(key);
        }

        logger.internal('Request cancelled: $key[$requestId]');
        return true;
      }
    }
    return false;
  }

  /// Cancels all active calls for the given method; returns cancelled count.
  int cancelMethod(String serviceName, String methodName, [String? reason]) {
    final key = _createMethodKey(serviceName, methodName);
    final methodTokens = _cancellationTokens[key];
    if (methodTokens != null) {
      final cancelledCount = methodTokens.length;
      for (final token in methodTokens.values) {
        token.cancel(reason ?? 'Method cancelled by user');
      }
      _cancellationTokens.remove(key);
      logger.internal('Отменены все вызовы метода: $key ($cancelledCount)');
      return cancelledCount;
    }
    return 0;
  }

  /// Cancels all active calls.
  void cancelAllMethods([String? reason]) {
    int totalCancelled = 0;
    for (final methodTokens in _cancellationTokens.values) {
      for (final token in methodTokens.values) {
        token.cancel(reason ?? 'All methods cancelled');
        totalCancelled++;
      }
    }
    _cancellationTokens.clear();
    logger.internal('Cancelled all active calls ($totalCancelled)');
  }

  /// Cancels all methods of the specified service.
  void cancelServiceMethods(String serviceName, [String? reason]) {
    final servicePrefix = '$serviceName/';
    final methodKeys = _cancellationTokens.keys
        .where((key) => key.startsWith(servicePrefix))
        .toList();

    int totalCancelled = 0;
    for (final key in methodKeys) {
      final methodTokens = _cancellationTokens[key]!;
      for (final token in methodTokens.values) {
        token.cancel(reason ?? 'Service methods cancelled');
        totalCancelled++;
      }
      _cancellationTokens.remove(key);
    }

    logger.internal(
      'Cancelled all methods of service $serviceName ($totalCancelled calls)',
    );
  }

  /// Ensures the transport is client-side (generates odd Stream IDs).
  void _validateClientTransport() {
    try {
      // Validate transport role via interface.
      if (!transport.isClient) {
        throw ArgumentError(
          'CRITICAL ERROR: RpcCallerEndpoint requires CLIENT transport!\n'
          'Received server transport (isClient: false).\n'
          'Client endpoints must use transports with odd Stream IDs (1, 3, 5...).\n\n'
          'Correct usage:\n'
          '  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();\n'
          '  final callerEndpoint = RpcCallerEndpoint(transport: clientTransport);\n'
          '  final responderEndpoint = RpcResponderEndpoint(transport: serverTransport);\n\n'
          'INCORRECT:\n'
          '  final callerEndpoint = RpcCallerEndpoint(transport: serverTransport);\n',
        );
      }

      logger.internal('Transport validated: client (isClient: true)');
    } catch (e) {
      if (e is ArgumentError) rethrow;

      logger.warning('Failed to validate transport role: $e');
      // Continue with a warning if validation fails.
    }
  }

  /// Creates or enriches RpcContext for a client request.
  /// Auto-generates trace ID when absent.
  /// Injects gzip compression header when [compressionEnabled] is true and
  /// the transport does not support zero-copy (i.e. it is a network transport).
  RpcContext _ensureContext(RpcContext? context) {
    RpcContext result;

    if (context?.traceId != null) {
      logger.internal('Using existing trace ID: ${context!.traceId}');
      result = context;
    } else if (context != null) {
      final tracingContext = RpcContextUtils.withTracing();
      result = context.withTraceId(tracingContext.traceId!);
      logger.internal(
        'Attached trace ID to existing context: ${result.traceId}',
      );
    } else {
      result = RpcContextUtils.withTracing();
      logger.internal('Created new context with trace ID: ${result.traceId}');
    }

    // Inject gzip for network transports unless the caller already set it.
    if (compressionEnabled &&
        !transport.supportsZeroCopy &&
        !result.headers.containsKey(RpcConstants.grpcEncodingHeader)) {
      result = result.withAdditionalHeaders({
        RpcConstants.grpcEncodingHeader: RpcGrpcCompression.gzip,
      });
      logger.internal('Injected default gzip compression');
    }

    return result;
  }

  /// Enriches context with a cancellation token for the Transport Router.
  RpcContext _enhanceContext(
    RpcContext userContext,
    String serviceName,
    String methodName,
  ) {
    final routingHeaders = {'x-route-service': serviceName};

    final key = _createMethodKey(serviceName, methodName);

    final token = userContext.cancellationToken ?? RpcCancellationToken();
    final requestId = userContext.requestId;

    // Initialize method map when missing.
    _cancellationTokens[key] ??= <String, RpcCancellationToken>{};
    _cancellationTokens[key]![requestId] = token;

    return userContext
        .withCancellation(token)
        .withAdditionalHeaders(routingHeaders);
  }

  RpcContext _effectiveContext(
    RpcContext? userContext,
    String serviceName,
    String methodName,
  ) =>
      _enhanceContext(_ensureContext(userContext), serviceName, methodName);

  /// Unified unary request: codecs → serialized; no codecs → zero-copy (zero-copy capable transport only).
  Future<TResponse>
      unaryRequest<TRequest extends Object, TResponse extends Object>({
    required String serviceName,
    required String methodName,
    required TRequest request,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    // Ensure endpoint is active.
    if (!isActive) {
      throw StateError(
        'RpcCallerEndpoint закрыт и не может обрабатывать запросы',
      );
    }

    final isZeroCopy = requestCodec == null && responseCodec == null;

    // Zero-copy mode requires transport support.
    if (isZeroCopy && !transport.supportsZeroCopy) {
      throw ArgumentError(
        'Zero-copy mode requires a transport that supports zero-copy. '
        'For network transports provide codecs.',
      );
    }

    // Serialization mode requires codecs.
    if (!isZeroCopy && (requestCodec == null || responseCodec == null)) {
      throw ArgumentError(
        'Codecs are required for serialization mode. '
        'For zero-copy, omit codecs (null).',
      );
    }

    // Auto-create/enrich context with trace ID and routing headers.
    final enhancedContext = _effectiveContext(context, serviceName, methodName);

    return () async {
      try {
        return await handleUnary<TRequest, TResponse>(
          serviceName: serviceName,
          methodName: methodName,
          context: enhancedContext,
          request: request,
          handler: (ctx, normalizedRequest) async {
            if (isZeroCopy) {
              final processor = CallProcessor<TRequest, TResponse>(
                transport: transport,
                serviceName: serviceName,
                methodName: methodName,
                context: ctx,
                logger: logger,
              );

              return _executeUniversalUnaryCall(
                processor: processor,
                request: normalizedRequest,
              );
            }

            return UnaryCaller<TRequest, TResponse>(
              serviceName: serviceName,
              methodName: methodName,
              transport: transport,
              requestCodec: requestCodec!,
              responseCodec: responseCodec!,
              context: ctx,
            ).call(normalizedRequest);
          },
        );
      } finally {
        _untrackRequest(serviceName, methodName, enhancedContext.requestId);
      }
    }();
  }

  /// Internal implementation of the unified unary call.
  Future<TResponse> _executeUniversalUnaryCall<TRequest extends Object,
          TResponse extends Object>(
      {required CallProcessor<TRequest, TResponse> processor,
      required TRequest request}) async {
    try {
      // Отправляем запрос
      await processor.send(request);
      await processor.finishSending();

      // Ожидаем единственный ответ
      await for (final response in processor.responses) {
        if (response.payload != null) {
          return response.payload!;
        }

        // Проверяем статус в метаданных
        if (response.metadata != null) {
          final statusStr = response.metadata!.getHeaderValue(
            RpcConstants.grpcStatusHeader,
          );
          if (statusStr != null) {
            final status = int.tryParse(statusStr) ?? RpcStatus.unknown;
            if (status != RpcStatus.ok) {
              final message = response.metadata!.getHeaderValue(
                    RpcConstants.grpcMessageHeader,
                  ) ??
                  'Unknown error';
              final decodedMessage = RpcMetadata.decodeGrpcMessage(message);
              throw Exception('gRPC error $status: $decodedMessage');
            }
          }
        }
      }

      throw Exception(
        'gRPC error ${RpcStatus.unavailable}: No response received',
      );
    } finally {
      await processor.close();
    }
  }

  /// Unified server-stream request: codecs → serialized; no codecs → zero-copy (zero-copy capable transport only).
  Stream<TResponse>
      serverStream<TRequest extends Object, TResponse extends Object>({
    required String serviceName,
    required String methodName,
    required TRequest request,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    // Проверяем активность эндпоинта
    if (!isActive) {
      throw StateError(
        'RpcCallerEndpoint закрыт и не может обрабатывать запросы',
      );
    }

    final isZeroCopy = requestCodec == null && responseCodec == null;

    // Zero-copy режим: требуется поддержка zero-copy транспортом
    if (isZeroCopy && !transport.supportsZeroCopy) {
      throw ArgumentError(
        'Zero-copy режим требует транспорт с поддержкой zero-copy. '
        'Для сетевых транспортов передайте кодеки.',
      );
    }

    // Режим сериализации: кодеки обязательны
    if (!isZeroCopy && (requestCodec == null || responseCodec == null)) {
      throw ArgumentError(
        'Кодеки обязательны для режима сериализации. '
        'Для zero-copy не передавайте кодеки (null).',
      );
    }

    logger.internal(
      'Создание ${isZeroCopy ? "zero-copy" : "serialized"} server stream для $serviceName/$methodName',
    );

    // Автоматически создаем или дополняем контекст с trace ID и роутинговыми заголовками
    final enhancedContext = _effectiveContext(context, serviceName, methodName);

    final stream = handleServerStream<TRequest, TResponse>(
      serviceName: serviceName,
      methodName: methodName,
      context: enhancedContext,
      request: request,
      handler: (ctx, normalizedRequest) {
        final caller = ServerStreamCaller<TRequest, TResponse>(
          transport: transport,
          serviceName: serviceName,
          methodName: methodName,
          requestCodec: requestCodec,
          responseCodec: responseCodec,
          context: ctx,
          logger: logger,
        );

        return caller.call(normalizedRequest);
      },
    );

    return () async* {
      try {
        yield* stream;
      } finally {
        _untrackRequest(serviceName, methodName, enhancedContext.requestId);
      }
    }();
  }

  /// Creates a client stream to send multiple requests and receive one response.
  Future<R> Function(Stream<C>)
      clientStream<C extends Object, R extends Object>({
    required String serviceName,
    required String methodName,
    IRpcCodec<C>? requestCodec,
    IRpcCodec<R>? responseCodec,
    RpcContext? context,
  }) {
    logger.internal(
      'Создание client stream builder для $serviceName/$methodName',
    );

    return (Stream<C> requests) async {
      logger.internal('Выполнение client stream для $serviceName/$methodName');
      final enhancedContext =
          _effectiveContext(context, serviceName, methodName);

      try {
        return await handleClientStream<C, R>(
          serviceName: serviceName,
          methodName: methodName,
          context: enhancedContext,
          requests: requests,
          handler: (ctx, normalizedRequests) {
            final caller = ClientStreamCaller<C, R>(
              transport: transport,
              serviceName: serviceName,
              methodName: methodName,
              requestCodec: requestCodec,
              responseCodec: responseCodec,
              context: ctx,
              logger: logger,
            );

            return caller.call(normalizedRequests);
          },
        );
      } finally {
        _untrackRequest(serviceName, methodName, enhancedContext.requestId);
      }
    };
  }

  /// Creates a bidirectional stream builder.
  Stream<R> bidirectionalStream<C extends Object, R extends Object>({
    required String serviceName,
    required String methodName,
    required Stream<C> requests,
    IRpcCodec<C>? requestCodec,
    IRpcCodec<R>? responseCodec,
    RpcContext? context,
  }) {
    logger.internal(
      'Создание bidirectional stream для $serviceName/$methodName',
    );

    // Автоматически создаем или дополняем контекст с trace ID и роутинговыми заголовками
    final enhancedContext = _effectiveContext(context, serviceName, methodName);

    return handleBidirectionalStream<C, R>(
      serviceName: serviceName,
      methodName: methodName,
      context: enhancedContext,
      requests: requests,
      handler: (ctx, normalizedRequests) {
        final controller = StreamController<R>();
        final caller = BidirectionalStreamCaller<C, R>(
          transport: transport,
          serviceName: serviceName,
          methodName: methodName,
          requestCodec: requestCodec,
          responseCodec: responseCodec,
          context: ctx,
          logger: logger,
        );

        StreamSubscription<RpcMessage<R>>? responseSubscription;
        StreamSubscription<C>? requestSubscription;

        var isCleaned = false;
        var sendSequence = Future<void>.value();

        void enqueueSend(Future<void> Function() operation) {
          sendSequence = sendSequence.then((_) async {
            if (isCleaned) {
              return;
            }
            await operation();
          });
        }

        Future<void> cleanup() async {
          if (isCleaned) {
            return;
          }
          isCleaned = true;
          _untrackRequest(serviceName, methodName, enhancedContext.requestId);
          await responseSubscription?.cancel();
          await requestSubscription?.cancel();
          await caller.close();
          if (!controller.isClosed) {
            await controller.close();
          }
        }

        responseSubscription = caller.responses.listen(
          (rpcMessage) {
            if (!rpcMessage.isMetadataOnly && rpcMessage.payload != null) {
              controller.add(rpcMessage.payload!);
            }
          },
          onError: (error, stackTrace) {
            controller.addError(error, stackTrace);
            unawaited(cleanup());
          },
          onDone: () {
            unawaited(cleanup());
          },
        );

        requestSubscription = normalizedRequests.listen(
          (request) {
            enqueueSend(() async {
              try {
                await caller.send(request);
              } catch (error, stackTrace) {
                logger.error(
                  'Ошибка при отправке запроса в bidirectional stream',
                  error: error,
                  stackTrace: stackTrace,
                );
                controller.addError(error, stackTrace);
                await cleanup();
              }
            });
          },
          onError: (error, stackTrace) {
            logger.error(
              'Ошибка при отправке запроса в bidirectional stream',
              error: error,
              stackTrace: stackTrace,
            );
            controller.addError(error, stackTrace);
            unawaited(cleanup());
          },
          onDone: () {
            logger.internal('Поток запросов bidirectional stream завершен');
            enqueueSend(() async {
              try {
                await caller.finishSending();
              } catch (error, stackTrace) {
                controller.addError(error, stackTrace);
                await cleanup();
              }
            });
          },
        );

        controller.onCancel = cleanup;

        return controller.stream.transform(
          StreamTransformer.fromHandlers(
            handleDone: (sink) {
              unawaited(cleanup());
              sink.close();
            },
          ),
        );
      },
    );
  }
}
