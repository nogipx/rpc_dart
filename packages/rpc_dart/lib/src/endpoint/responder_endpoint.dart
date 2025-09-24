// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Серверный RPC эндпоинт для обработки запросов
final class RpcResponderEndpoint extends RpcEndpointBase {
  final RpcResponderMethodRegistry _registry = RpcResponderMethodRegistry();
  final RpcResponderStreamStore _streams = RpcResponderStreamStore();
  late final RpcResponderPingHandler _pingHandler;
  StreamSubscription<RpcTransportMessage>? _incomingSubscription;
  bool _isListening = false;

  @override
  RpcLogger get logger => RpcLogger(
        'RpcResponderEndpoint',
        colors: loggerColors,
        label: debugLabel,
      );

  RpcResponderEndpoint({
    required super.transport,
    super.debugLabel,
    super.loggerColors,
  }) {
    _pingHandler = RpcResponderPingHandler(
      transport: transport,
      logger: logger,
      debugLabel: debugLabel,
    );
    _validateServerTransport();
  }

  Map<String, RpcResponderContract> get registeredContracts =>
      _registry.contracts;

  Map<String, RpcMethodRegistration<IRpcSerializable, IRpcSerializable>>
      get registeredMethods => _registry.exportMethodRegistrations();

  Map<String, RpcResponderMethodBinding> get registeredMethodBindings =>
      _registry.methods;

  @override
  Map<String, Object?> collectEndpointMetrics() {
    final metrics = Map<String, Object?>.from(super.collectEndpointMetrics());

    metrics['registeredContracts'] = _registry.contracts.length;
    metrics['registeredMethods'] = _registry.methods.length;
    metrics['isListening'] = _isListening;
    metrics['openStreams'] = _streams.length;
    metrics['metadataStreams'] =
        _streams.values.where((state) => state.hasMetadata).length;
    metrics['bufferedMessages'] = _streams.values
        .where((state) => state.lastPayloadMessage != null)
        .length;
    metrics['clientStreamBuffers'] = _streams.values
        .where((state) => state.hasBufferedClientMessages)
        .length;
    metrics['activeResponders'] =
        _streams.values.where((state) => state.hasResponder).length;

    if (_registry.contracts.isNotEmpty) {
      metrics['contractKeys'] =
          List<String>.unmodifiable(_registry.contracts.keys);
    }

    return metrics;
  }

  void registerServiceContract(RpcResponderContract contract) {
    _registry.registerContract(contract, logger);
  }

  void unregisterServiceContract(String serviceName) {
    _registry.unregisterContract(serviceName, logger);
  }

  @override
  void start() {
    super.start();

    if (_isListening) {
      logger.warning('RpcResponderEndpoint уже слушает входящие запросы');
      return;
    }

    final oldSub = _incomingSubscription;
    _incomingSubscription = null;
    oldSub?.cancel();
    _incomingSubscription = transport.incomingMessages.listen(
      _handleIncomingMessage,
      onError: (error, stackTrace) {
        logger.error(
          'Ошибка входящего сообщения транспорта',
          error: error,
          stackTrace: stackTrace,
        );
      },
      onDone: () {
        logger.internal('Входящий поток транспорта завершен');
      },
    );

    _isListening = true;
  }

  @override
  Future<void> close() async {
    if (!isActive) return;

    await _incomingSubscription?.cancel();
    _incomingSubscription = null;
    _isListening = false;

    final activeStreamIds =
        _streams.values.map((state) => state.id).toList(growable: false);
    for (final streamId in activeStreamIds) {
      await _cleanupStream(streamId);
    }

    _registry.disposeAll(logger);

    await super.close();
  }

  void _handleIncomingMessage(RpcTransportMessage message) {
    if (!_isListening) {
      logger.warning(
        'Получено сообщение, но эндпоинт не запущен. '
        'Вызовите start() после регистрации контрактов.',
      );
      return;
    }

    final state = _streams.obtain(message.streamId);

    if (message.isMetadataOnly && message.metadata != null) {
      final isCancelled =
          message.metadata!.getHeaderValue('x-client-cancelled');
      if (isCancelled == 'true') {
        final reason =
            message.metadata!.getHeaderValue('x-cancellation-reason') ??
                'Cancelled by client';
        unawaited(_handleClientCancellation(state, reason));
        return;
      }
    }

    if (message.isMetadataOnly && message.methodPath != null) {
      _handleMetadataMessage(state, message);
      return;
    }

    final hasPayload = !message.isMetadataOnly &&
        (message.payload != null ||
            (message.isDirect && message.directPayload != null));

    if (hasPayload) {
      _handleDataMessage(state, message);
    }

    if (message.isEndOfStream) {
      _handleEndOfStream(state);
    }
  }

  void _handleMetadataMessage(
    RpcResponderStreamState state,
    RpcTransportMessage message,
  ) {
    final methodPath = message.methodPath!;
    final parsed = _parseMethodPath(methodPath);

    if (parsed == null) {
      logger.warning('Некорректный путь метода: $methodPath');
      return;
    }

    final serviceName = parsed.$1;
    final methodName = parsed.$2;
    final methodKey = '$serviceName.$methodName';

    state.setMethodKey(methodKey);
    state.storeMetadata(message);

    final context = _cacheContext(state, message);

    if (_isPingMethodKey(methodKey)) {
      _logWithContext(
        'Получен ping запрос',
        context: context,
        streamId: state.id,
        methodKey: methodKey,
      );

      unawaited(
        _pingHandler.respond(
          streamId: state.id,
          context: context,
          onComplete: () => _cleanupStream(state.id),
        ),
      );
      return;
    }

    final binding = _registry.lookup(methodKey);
    if (binding == null) {
      _logErrorWithContext(
        'Метод не зарегистрирован',
        context: context,
        streamId: state.id,
        methodKey: methodKey,
      );
      return;
    }

    _logWithContext(
      'Получено сообщение метаданных',
      context: context,
      streamId: state.id,
      methodKey: methodKey,
    );
  }

  void _handleDataMessage(
    RpcResponderStreamState state,
    RpcTransportMessage message,
  ) {
    if (!state.hasMethod && message.methodPath != null) {
      final parsed = _parseMethodPath(message.methodPath!);
      if (parsed == null) {
        logger.warning('Некорректный путь метода: ${message.methodPath}');
        return;
      }

      final methodKey = '${parsed.$1}.${parsed.$2}';
      state.setMethodKey(methodKey);
      _cacheContext(state, message);
    }

    final methodKey = state.methodKey;
    if (methodKey == null) {
      _logWithContext(
        'Получены данные для неизвестного метода',
        streamId: state.id,
      );
      return;
    }

    if (_isPingMethodKey(methodKey)) {
      return;
    }

    final binding = _registry.lookup(methodKey);
    if (binding == null) {
      final context = _ensureContext(state);
      _logErrorWithContext(
        'Метод не найден при обработке данных',
        context: context,
        streamId: state.id,
        methodKey: methodKey,
      );
      return;
    }

    final context = _ensureContext(state);

    state.storePayload(
      message,
      bufferForClientStream: binding.type == RpcMethodType.clientStream,
    );

    _logWithContext(
      'Обработка данных для метода',
      context: context,
      streamId: state.id,
      methodKey: methodKey,
    );

    if (binding.type != RpcMethodType.clientStream) {
      unawaited(_ensureResponder(state, binding));
    }
  }

  void _handleEndOfStream(RpcResponderStreamState state) {
    final methodKey = state.methodKey;

    if (methodKey == null) {
      unawaited(_cleanupStream(state.id));
      return;
    }

    if (_isPingMethodKey(methodKey)) {
      return;
    }

    final binding = _registry.lookup(methodKey);
    if (binding == null) {
      unawaited(_cleanupStream(state.id));
      return;
    }

    if (binding.type == RpcMethodType.clientStream) {
      unawaited(_ensureResponder(state, binding));
    }
  }

  Future<void> _handleClientCancellation(
    RpcResponderStreamState state,
    String reason,
  ) async {
    final context =
        state.hasMetadata || state.hasMethod ? _ensureContext(state) : null;

    _logWithContext(
      'Получено уведомление об отмене от клиента: $reason',
      context: context,
      streamId: state.id,
      methodKey: state.methodKey,
    );

    final responder = state.responder;
    if (responder != null) {
      await _closeResponder(responder);
    }

    await _cleanupStream(state.id);
  }

  Future<void> _ensureResponder(
    RpcResponderStreamState state,
    RpcResponderMethodBinding binding,
  ) async {
    if (state.responder != null) {
      return;
    }

    switch (binding.type) {
      case RpcMethodType.unaryRequest:
        await _ensureUnaryResponder(state, binding);
        break;
      case RpcMethodType.clientStream:
        await _ensureClientStreamResponder(state, binding);
        break;
      case RpcMethodType.serverStream:
        await _ensureServerStreamResponder(state, binding);
        break;
      case RpcMethodType.bidirectionalStream:
        await _ensureBidirectionalResponder(state, binding);
        break;
    }
  }

  Future<void> _ensureUnaryResponder(
    RpcResponderStreamState state,
    RpcResponderMethodBinding binding,
  ) async {
    final context = _ensureContext(state);
    final contextLogger = _contextLogger(context);
    final streamId = state.id;
    final methodKey = binding.methodKey;

    if (binding.isZeroCopy) {
      if (!transport.supportsZeroCopy) {
        await _handleUnsupportedZeroCopy(state, context, methodKey);
        return;
      }

      final processor = StreamProcessor<Object, Object>(
        transport: transport,
        streamId: streamId,
        serviceName: binding.serviceName,
        methodName: binding.methodName,
        context: context,
        logger: contextLogger,
      );

      final responder = _RpcZeroCopyUnaryResponder(
        id: streamId,
        processor: processor,
      );

      state.responder = responder;

      processor.requests.listen((request) async {
        try {
          final response = await binding.zeroCopyMethod.callUnaryHandler(
            context,
            request,
          );
          await processor.send(response);
          await processor.finishSending();
        } catch (error, stackTrace) {
          contextLogger.error(
            'Ошибка в zero-copy унарном методе [streamId: $streamId]',
            error: error,
            stackTrace: stackTrace,
          );

          final errorMessage =
              error is RpcException ? error.message : error.toString();
          await processor.sendError(RpcStatus.internal, errorMessage);
        }
      });

      final savedMessage = state.takeLastPayload();
      final initialMessages =
          savedMessage != null ? [savedMessage] : const <RpcTransportMessage>[];

      responder.bindToMessageStream(
        _streamStartingWith(streamId, initialMessages),
      );
      return;
    }

    final method = binding.codecMethod;

    final responder = UnaryResponder<IRpcSerializable, IRpcSerializable>(
      id: streamId,
      transport: transport,
      serviceName: binding.serviceName,
      methodName: binding.methodName,
      requestCodec: method.requestCodec,
      responseCodec: method.responseCodec,
      handler: (request) async {
        final response = await method.callUnaryHandler(
          context,
          request,
        );
        return method.castResponse(response);
      },
      context: context,
      logger: contextLogger,
    );

    state.responder = responder;

    final savedMessage = state.takeLastPayload();
    if (savedMessage != null) {
      if (savedMessage.isDirect && savedMessage.directPayload != null) {
        await responder.handleDirectMessage(savedMessage);
      } else if (!savedMessage.isMetadataOnly && savedMessage.payload != null) {
        await responder.handleMessage(savedMessage);
      }
    }
  }

  Future<void> _ensureClientStreamResponder(
    RpcResponderStreamState state,
    RpcResponderMethodBinding binding,
  ) async {
    final context = _ensureContext(state);
    final contextLogger = _contextLogger(context);
    final streamId = state.id;

    if (binding.isZeroCopy) {
      if (!transport.supportsZeroCopy) {
        await _handleUnsupportedZeroCopy(state, context, binding.methodKey);
        return;
      }

      final responder = ClientStreamResponder<Object, Object>(
        id: streamId,
        transport: transport,
        serviceName: binding.serviceName,
        methodName: binding.methodName,
        handler: (requests) async {
          return await binding.zeroCopyMethod.callClientStreamHandler(
            context,
            requests,
          );
        },
        context: context,
        logger: contextLogger,
      );

      state.responder = responder;

      final savedMessages =
          state.takeClientBufferedMessages(markEndOfStream: true);
      responder.bindToMessageStream(
        _streamStartingWith(streamId, savedMessages),
      );
      return;
    }

    final method = binding.codecMethod;

    final responder = ClientStreamResponder<IRpcSerializable, IRpcSerializable>(
      id: streamId,
      transport: transport,
      serviceName: binding.serviceName,
      methodName: binding.methodName,
      requestCodec: method.requestCodec,
      responseCodec: method.responseCodec,
      handler: (requests) async {
        final typedRequests = method.castRequestStream(requests);
        final response = await method.callClientStreamHandler(
          context,
          typedRequests,
        );
        return method.castResponse(response);
      },
      context: context,
      logger: contextLogger,
    );

    state.responder = responder;

    final savedMessages =
        state.takeClientBufferedMessages(markEndOfStream: true);
    responder.bindToMessageStream(
      _streamStartingWith(streamId, savedMessages),
    );
  }

  Future<void> _ensureServerStreamResponder(
    RpcResponderStreamState state,
    RpcResponderMethodBinding binding,
  ) async {
    final context = _ensureContext(state);
    final contextLogger = _contextLogger(context);
    final streamId = state.id;

    if (binding.isZeroCopy) {
      if (!transport.supportsZeroCopy) {
        await _handleUnsupportedZeroCopy(state, context, binding.methodKey);
        return;
      }

      final responder = ServerStreamResponder<Object, Object>(
        id: streamId,
        transport: transport,
        serviceName: binding.serviceName,
        methodName: binding.methodName,
        handler: (request) {
          return binding.zeroCopyMethod.callServerStreamHandler(
            context,
            request,
          );
        },
        context: context,
        logger: contextLogger,
      );

      state.responder = responder;

      final savedMessage = state.takeLastPayload();
      final initialMessages =
          savedMessage != null ? [savedMessage] : const <RpcTransportMessage>[];

      responder.bindToMessageStream(
        _streamStartingWith(streamId, initialMessages),
      );
      return;
    }

    final method = binding.codecMethod;

    final responder = ServerStreamResponder<IRpcSerializable, IRpcSerializable>(
      id: streamId,
      transport: transport,
      serviceName: binding.serviceName,
      methodName: binding.methodName,
      requestCodec: method.requestCodec,
      responseCodec: method.responseCodec,
      handler: (request) {
        final responseStream = method.callServerStreamHandler(context, request);
        return responseStream.map(method.castResponse);
      },
      context: context,
      logger: contextLogger,
    );

    state.responder = responder;

    final savedMessage = state.takeLastPayload();
    final initialMessages =
        savedMessage != null ? [savedMessage] : const <RpcTransportMessage>[];

    responder.bindToMessageStream(
      _streamStartingWith(streamId, initialMessages),
    );
  }

  Future<void> _ensureBidirectionalResponder(
    RpcResponderStreamState state,
    RpcResponderMethodBinding binding,
  ) async {
    final context = _ensureContext(state);
    final contextLogger = _contextLogger(context);
    final streamId = state.id;

    if (binding.isZeroCopy) {
      if (!transport.supportsZeroCopy) {
        await _handleUnsupportedZeroCopy(state, context, binding.methodKey);
        return;
      }

      final responder = BidirectionalStreamResponder<Object, Object>(
        id: streamId,
        transport: transport,
        serviceName: binding.serviceName,
        methodName: binding.methodName,
        context: context,
        logger: contextLogger,
      );

      state.responder = responder;

      final savedMessage = state.takeLastPayload();
      final initialMessages =
          savedMessage != null ? [savedMessage] : const <RpcTransportMessage>[];

      responder.bindToMessageStream(
        _streamStartingWith(streamId, initialMessages),
      );

      unawaited(() async {
        try {
          final responseStream =
              binding.zeroCopyMethod.callBidirectionalStreamHandler(
            context,
            responder.requests,
          );

          await for (final response in responseStream) {
            await responder.send(response);
          }

          await responder.finishReceiving();
        } catch (error, stackTrace) {
          contextLogger.error(
            'Ошибка в zero-copy обработчике двунаправленного стрима [id: $streamId]',
            error: error,
            stackTrace: stackTrace,
          );
          await responder.sendError(
            RpcStatus.internal,
            error.toString(),
          );
        }
      }());
      return;
    }

    final method = binding.codecMethod;

    final responder =
        BidirectionalStreamResponder<IRpcSerializable, IRpcSerializable>(
      id: streamId,
      transport: transport,
      serviceName: binding.serviceName,
      methodName: binding.methodName,
      requestCodec: method.requestCodec,
      responseCodec: method.responseCodec,
      context: context,
      logger: contextLogger,
    );

    state.responder = responder;

    final savedMessage = state.takeLastPayload();
    final initialMessages =
        savedMessage != null ? [savedMessage] : const <RpcTransportMessage>[];

    responder.bindToMessageStream(
      _streamStartingWith(streamId, initialMessages),
    );

    unawaited(() async {
      try {
        final typedRequests = method.castRequestStream(responder.requests);
        final responseStream =
            method.callBidirectionalStreamHandler(context, typedRequests);

        await for (final response in responseStream) {
          await responder.send(method.castResponse(response));
        }

        await responder.finishReceiving();
      } catch (error, stackTrace) {
        contextLogger.error(
          'Ошибка в обработчике двунаправленного стрима [id: $streamId]',
          error: error,
          stackTrace: stackTrace,
        );
        await responder.sendError(
          RpcStatus.internal,
          error.toString(),
        );
      }
    }());
  }

  Future<void> _handleUnsupportedZeroCopy(
    RpcResponderStreamState state,
    RpcContext context,
    String methodKey,
  ) async {
    _logErrorWithContext(
      'Транспорт не поддерживает zero-copy для метода',
      context: context,
      streamId: state.id,
      methodKey: methodKey,
    );

    try {
      await transport.sendMetadata(
        state.id,
        RpcMetadata([
          RpcHeader(
            RpcConstants.grpcStatusHeader,
            RpcStatus.unimplemented.toString(),
          ),
          RpcHeader(
            RpcConstants.grpcMessageHeader,
            'Zero-copy method $methodKey требует транспорт с поддержкой zero-copy',
          ),
        ]),
        endStream: true,
      );
    } catch (error, stackTrace) {
      logger.error(
        'Не удалось отправить ошибку zero-copy метода $methodKey',
        rpcContext: context,
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      await _cleanupStream(state.id);
    }
  }

  Future<void> _cleanupStream(int streamId) async {
    final state = _streams.take(streamId);
    if (state == null) {
      return;
    }

    final responder = state.responder;
    if (responder != null) {
      await _closeResponder(responder);
    }

    try {
      final released = transport.releaseStreamId(streamId);
      if (released) {
        logger.internal('ID стрима освобожден [streamId: $streamId]');
      } else {
        logger.internal(
          'ID стрима уже освобожден или недоступен [streamId: $streamId]',
        );
      }
    } catch (error) {
      logger.warning(
        'Ошибка при освобождении ID стрима [streamId: $streamId]: $error',
      );
    }
  }

  Future<void> _closeResponder(IRpcResponder responder) async {
    Future<void> closeFuture() {
      if (responder is UnaryResponder) {
        return responder.close();
      } else if (responder is ClientStreamResponder) {
        return responder.close();
      } else if (responder is ServerStreamResponder) {
        return responder.close();
      } else if (responder is BidirectionalStreamResponder) {
        return responder.close();
      } else if (responder is _RpcZeroCopyUnaryResponder) {
        return responder.close();
      }
      return Future.value();
    }

    try {
      await closeFuture();
    } catch (error, stackTrace) {
      logger.error(
        'Ошибка при закрытии респондера [id: ${responder.id}]: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Stream<RpcTransportMessage> _streamStartingWith(
    int streamId,
    Iterable<RpcTransportMessage> initialMessages,
  ) async* {
    for (final message in initialMessages) {
      yield message;
    }

    await for (final message in transport.getMessagesForStream(streamId)) {
      yield message;
    }
  }

  RpcContext _cacheContext(
    RpcResponderStreamState state,
    RpcTransportMessage message,
  ) {
    final context = _createContextFromMessage(message);
    state.cacheContext(context);
    return context;
  }

  RpcContext _ensureContext(RpcResponderStreamState state) {
    final cached = state.cachedContext;
    if (cached != null) {
      return cached;
    }

    final sourceMessage = state.metadataMessage ??
        state.lastPayloadMessage ??
        RpcTransportMessage(
          streamId: state.id,
          methodPath: state.methodKey != null
              ? _methodPathFromKey(state.methodKey!)
              : '/UnknownService/UnknownMethod',
        );

    return _cacheContext(state, sourceMessage);
  }

  RpcContext _createContextFromMessage(RpcTransportMessage message) {
    final headers = <String, String>{};

    if (message.metadata != null) {
      for (final header in message.metadata!.headers) {
        if (!header.name.startsWith(':') &&
            header.name != 'content-type' &&
            header.name != 'te') {
          headers[header.name] = header.value;
        }
      }
    }

    logger.internal('Создание контекста: ${headers.length} заголовков');

    var context = RpcContext.withHeaders(headers);

    final deadlineHeader = headers['x-deadline'];
    if (deadlineHeader != null) {
      try {
        final deadlineMs = int.parse(deadlineHeader);
        final deadline = DateTime.fromMillisecondsSinceEpoch(deadlineMs);
        context = context.withDeadline(deadline);
        logger.internal('Установлен deadline из заголовков: $deadline');
      } catch (_) {
        logger.warning('Некорректный deadline в заголовках: $deadlineHeader');
      }
    }

    final clientTraceId = headers['x-trace-id'];

    if (clientTraceId != null) {
      context = context.withTraceId(clientTraceId);
      logger.internal('Используем trace ID от клиента: $clientTraceId');
    } else {
      final tracingContext = RpcContextUtils.withTracing();
      final generatedTraceId = tracingContext.traceId!;
      context = context.withTraceId(generatedTraceId);
      logger.internal('Создан новый trace ID сервером: $generatedTraceId');
    }

    return context;
  }

  RpcLogger _contextLogger(RpcContext context) => RpcLogger(
        logger.name,
        colors: loggerColors,
        label: debugLabel,
        context: context,
      );

  void _logWithContext(
    String message, {
    RpcContext? context,
    int? streamId,
    String? methodKey,
  }) {
    final formatted = _formatLogMessage(
      message,
      streamId: streamId,
      methodKey: methodKey,
    );
    logger.internal(formatted, rpcContext: context);
  }

  void _logErrorWithContext(
    String message, {
    RpcContext? context,
    int? streamId,
    String? methodKey,
    Object? error,
    StackTrace? stackTrace,
  }) {
    final formatted = _formatLogMessage(
      message,
      streamId: streamId,
      methodKey: methodKey,
    );
    logger.error(
      formatted,
      rpcContext: context,
      error: error,
      stackTrace: stackTrace,
    );
  }

  String _formatLogMessage(
    String message, {
    int? streamId,
    String? methodKey,
  }) {
    final parts = <String>[message];

    if (methodKey != null) {
      parts.add('[method: $methodKey]');
    }

    if (streamId != null) {
      parts.add('[streamId: $streamId]');
    }

    return parts.join(' ');
  }

  (String, String)? _parseMethodPath(String methodPath) {
    final parts = methodPath.split('/');

    if (parts.length != 3 || parts[0].isNotEmpty) {
      return null;
    }

    return (parts[1], parts[2]);
  }

  String _methodPathFromKey(String methodKey) {
    final parts = methodKey.split('.');
    if (parts.length != 2) {
      return '/UnknownService/UnknownMethod';
    }
    return '/${parts[0]}/${parts[1]}';
  }

  bool _isPingMethodKey(String methodKey) =>
      methodKey == RpcEndpointPingProtocol.methodKey;

  void validateMethodExists(
    String serviceName,
    String methodName,
    RpcMethodType expectedType,
  ) {
    final methodKey = '$serviceName.$methodName';
    final binding = _registry.lookup(methodKey);

    if (binding == null) {
      throw RpcException('Метод $methodKey не зарегистрирован');
    }

    if (binding.type != expectedType) {
      throw RpcException(
        'Метод $methodKey зарегистрирован как ${binding.type.name}, '
        'а ожидается ${expectedType.name}',
      );
    }
  }

  void _validateServerTransport() {
    try {
      if (transport.isClient) {
        throw ArgumentError(
          'CRITICAL ERROR: RpcResponderEndpoint requires SERVER transport!\n'
          'Received client transport (isClient: true).\n'
          'Server endpoints must use transports with even Stream IDs (2, 4, 6...).\n\n'
          'Correct usage:\n'
          '  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();\n'
          '  final callerEndpoint = RpcCallerEndpoint(transport: clientTransport);\n'
          '  final responderEndpoint = RpcResponderEndpoint(transport: serverTransport);\n\n'
          'INCORRECT:\n'
          '  final responderEndpoint = RpcResponderEndpoint(transport: clientTransport);\n',
        );
      }

      logger.internal('Transport validated: server (isClient: false)');
    } catch (error) {
      if (error is ArgumentError) rethrow;

      logger.warning('Не удалось проверить роль транспорта: $error');
    }
  }
}

final class _RpcZeroCopyUnaryResponder implements IRpcResponder {
  _RpcZeroCopyUnaryResponder({
    required this.id,
    required this.processor,
  });

  @override
  final int id;
  final StreamProcessor<Object, Object> processor;

  Stream<Object> get requests => processor.requests;

  Future<void> send(Object response) => processor.send(response);

  Future<void> finish() => processor.finishSending();

  Future<void> sendError(int statusCode, String message) =>
      processor.sendError(statusCode, message);

  void bindToMessageStream(Stream<RpcTransportMessage> stream) {
    processor.bindToMessageStream(stream);
  }

  Future<void> close() => processor.close();
}
