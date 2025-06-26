// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Клиентский RPC эндпоинт для отправки запросов
final class RpcCallerEndpoint extends RpcEndpointBase {
  @override
  RpcLogger get logger => RpcLogger(
        'RpcCallerEndpoint',
        colors: loggerColors,
        label: debugLabel,
      );

  RpcCallerEndpoint({
    required super.transport,
    super.debugLabel,
    super.loggerColors,
  }) {
    _validateClientTransport();
  }

  /// Проверяет, что транспорт является клиентским (генерирует нечетные Stream ID)
  void _validateClientTransport() {
    try {
      // Проверяем роль транспорта через интерфейс
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
            '  final callerEndpoint = RpcCallerEndpoint(transport: serverTransport);\n');
      }

      logger.internal('Transport validated: client (isClient: true)');
    } catch (e) {
      if (e is ArgumentError) rethrow;

      logger.warning('Не удалось проверить роль транспорта: $e');
      // В случае ошибки при проверке продолжаем работу с предупреждением
    }
  }

  /// Создает или дополняет RpcContext для клиентского запроса
  /// Автоматически генерирует trace ID если контекст не передан или не содержит trace ID
  RpcContext _ensureContext(RpcContext? context) {
    if (context?.traceId != null) {
      // Контекст уже содержит trace ID - используем как есть
      logger.internal('Используем существующий trace ID: ${context!.traceId}');
      return context;
    }

    if (context != null) {
      // Контекст есть, но нет trace ID - добавляем его
      final tracingContext = RpcContextUtils.withTracing();
      final enhancedContext = context.withTraceId(tracingContext.traceId!);
      logger.internal(
          'Добавлен trace ID к существующему контексту: ${enhancedContext.traceId}');
      return enhancedContext;
    }

    // Контекста нет - создаем новый с trace ID
    final newContext = RpcContextUtils.withTracing();
    logger.internal('Создан новый контекст с trace ID: ${newContext.traceId}');
    return newContext;
  }

  /// Обогащает контекст роутинговыми заголовками для Transport Router
  RpcContext _enhanceContextForRouting(
      RpcContext? userContext, String serviceName) {
    final routingHeaders = {
      'x-route-service': serviceName, // 👈 Ключевой заголовок для роутинга!
      'x-caller-type': runtimeType.toString(),
    };

    if (userContext != null) {
      return userContext.withAdditionalHeaders(routingHeaders);
    } else {
      return RpcContextBuilder()
          .withHeaders(routingHeaders)
          .withGeneratedTraceId()
          .build();
    }
  }

  /// 🚀 Универсальный унарный request
  ///
  /// Автоматически определяет режим работы:
  /// - Кодеки указаны → Сериализация (работает с любыми транспортами)
  /// - Кодеки НЕ указаны (null) → Zero-copy (только транспорты с поддержкой zero-copy)
  ///
  /// Примеры:
  /// ```dart
  /// // Сериализация
  /// final result = await endpoint.unaryRequest<MyRequest, MyResponse>(
  ///   serviceName: 'Service',
  ///   methodName: 'Method',
  ///   requestCodec: myRequestCodec,
  ///   responseCodec: myResponseCodec,
  ///   request: MyRequest('data'),
  /// );
  ///
  /// // Zero-copy (только для RpcInMemoryTransport)
  /// final result = await endpoint.unaryRequest<String, String>(
  ///   serviceName: 'Service',
  ///   methodName: 'Method',
  ///   request: 'hello',
  ///   // кодеки не указываем → zero-copy
  /// );
  /// ```
  Future<TResponse>
      unaryRequest<TRequest extends Object, TResponse extends Object>({
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
          'RpcCallerEndpoint закрыт и не может обрабатывать запросы');
    }

    final isZeroCopy = requestCodec == null && responseCodec == null;

    // Zero-copy режим: требуется поддержка zero-copy транспортом
    if (isZeroCopy && !transport.supportsZeroCopy) {
      throw ArgumentError(
          'Zero-copy режим требует транспорт с поддержкой zero-copy. '
          'Для сетевых транспортов передайте кодеки.');
    }

    // Режим сериализации: кодеки обязательны
    if (!isZeroCopy && (requestCodec == null || responseCodec == null)) {
      throw ArgumentError('Кодеки обязательны для режима сериализации. '
          'Для zero-copy не передавайте кодеки (null).');
    }

    // Автоматически создаем или дополняем контекст с trace ID и роутинговыми заголовками
    final baseContext = _ensureContext(context);
    final enhancedContext = _enhanceContextForRouting(baseContext, serviceName);

    if (isZeroCopy) {
      // Zero-copy путь с универсальным процессором
      final processor = CallProcessor<TRequest, TResponse>(
        transport: transport,
        serviceName: serviceName,
        methodName: methodName,
        // Кодеки не указываем для zero-copy режима
        context: enhancedContext,
        logger: logger,
      );

      return _executeUniversalUnaryCall(processor, request);
    } else {
      // Сериализация с обычным UnaryCaller
      return UnaryCaller<TRequest, TResponse>(
        serviceName: serviceName,
        methodName: methodName,
        transport: transport,
        requestCodec: requestCodec!,
        responseCodec: responseCodec!,
        context: enhancedContext,
      ).call(request);
    }
  }

  /// Внутренняя реализация универсального унарного вызова
  Future<TResponse> _executeUniversalUnaryCall<TRequest extends Object,
      TResponse extends Object>(
    CallProcessor<TRequest, TResponse> processor,
    TRequest request,
  ) async {
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
          final statusStr = response.metadata!
              .getHeaderValue(RpcConstants.GRPC_STATUS_HEADER);
          if (statusStr != null) {
            final status = int.tryParse(statusStr) ?? RpcStatus.UNKNOWN;
            if (status != RpcStatus.OK) {
              final message = response.metadata!
                      .getHeaderValue(RpcConstants.GRPC_MESSAGE_HEADER) ??
                  'Unknown error';
              throw Exception('gRPC error $status: $message');
            }
          }
        }
      }

      throw Exception(
          'gRPC error ${RpcStatus.UNAVAILABLE}: No response received');
    } finally {
      await processor.close();
    }
  }

  /// 🚀 Универсальный server stream
  ///
  /// Автоматически определяет режим работы:
  /// - Кодеки указаны → Сериализация (работает с любыми транспортами)
  /// - Кодеки НЕ указаны (null) → Zero-copy (только транспорты с поддержкой zero-copy)
  ///
  /// Примеры:
  /// ```dart
  /// // Сериализация
  /// await for (final response in endpoint.serverStream<MyRequest, MyResponse>(
  ///   serviceName: 'Service',
  ///   methodName: 'StreamMethod',
  ///   requestCodec: myRequestCodec,
  ///   responseCodec: myResponseCodec,
  ///   request: MyRequest('data'),
  /// )) {
  ///   print(response.value);
  /// }
  ///
  /// // Zero-copy (только для RpcInMemoryTransport)
  /// await for (final response in endpoint.serverStream<String, String>(
  ///   serviceName: 'Service',
  ///   methodName: 'StreamMethod',
  ///   request: 'hello',
  ///   // кодеки не указываем → zero-copy
  /// )) {
  ///   print(response);
  /// }
  /// ```
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
          'RpcCallerEndpoint закрыт и не может обрабатывать запросы');
    }

    final isZeroCopy = requestCodec == null && responseCodec == null;

    // Zero-copy режим: требуется поддержка zero-copy транспортом
    if (isZeroCopy && !transport.supportsZeroCopy) {
      throw ArgumentError(
          'Zero-copy режим требует транспорт с поддержкой zero-copy. '
          'Для сетевых транспортов передайте кодеки.');
    }

    // Режим сериализации: кодеки обязательны
    if (!isZeroCopy && (requestCodec == null || responseCodec == null)) {
      throw ArgumentError('Кодеки обязательны для режима сериализации. '
          'Для zero-copy не передавайте кодеки (null).');
    }

    logger.internal(
        'Создание ${isZeroCopy ? "zero-copy" : "serialized"} server stream для $serviceName/$methodName');

    // Автоматически создаем или дополняем контекст с trace ID и роутинговыми заголовками
    final baseContext = _ensureContext(context);
    final enhancedContext = _enhanceContextForRouting(baseContext, serviceName);

    // Используем универсальный ServerStreamCaller
    final caller = ServerStreamCaller<TRequest, TResponse>(
      transport: transport,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      context: enhancedContext,
      logger: logger,
    );

    // Используем удобный метод call для автоматического управления ресурсами
    return caller.call(request);
  }

  /// Создает client stream для отправки множественных запросов и получения одного ответа
  Future<R> Function(Stream<C>)
      clientStream<C extends Object, R extends Object>({
    required String serviceName,
    required String methodName,
    IRpcCodec<C>? requestCodec,
    IRpcCodec<R>? responseCodec,
    RpcContext? context,
  }) {
    logger.internal(
        'Создание client stream builder для $serviceName/$methodName');

    // Автоматически создаем или дополняем контекст с trace ID и роутинговыми заголовками
    final baseContext = _ensureContext(context);
    final enhancedContext = _enhanceContextForRouting(baseContext, serviceName);

    return (Stream<C> requests) async {
      logger.internal('Выполнение client stream для $serviceName/$methodName');

      // Создаем client stream caller с контекстом
      final caller = ClientStreamCaller<C, R>(
        transport: transport,
        serviceName: serviceName,
        methodName: methodName,
        requestCodec: requestCodec,
        responseCodec: responseCodec,
        context: enhancedContext, // Передаем обогащенный контекст
        logger: logger,
      );

      // Подписываемся на поток запросов
      StreamSubscription? subscription;
      try {
        subscription = requests.listen(
          (request) async {
            logger.internal('Отправка запроса в client stream: $request');
            await caller.send(request);
          },
          onError: (error, stackTrace) {
            logger.error('Ошибка в потоке запросов client stream',
                error: error, stackTrace: stackTrace);
          },
          onDone: () {
            logger.internal('Поток запросов client stream завершен');
          },
        );

        // Ждем завершения потока запросов
        await subscription.asFuture();
        logger.internal('Поток запросов обработан, завершаем отправку');

        // Завершаем отправку и получаем единственный ответ
        final response = await caller.finishSending();
        logger.internal('Получен ответ от client stream');

        return response;
      } finally {
        // Всегда освобождаем ресурсы
        await subscription?.cancel();
      }
    };
  }

  /// Создает bidirectional stream builder
  Stream<R> bidirectionalStream<C extends Object, R extends Object>({
    required String serviceName,
    required String methodName,
    required Stream<C> requests,
    IRpcCodec<C>? requestCodec,
    IRpcCodec<R>? responseCodec,
    RpcContext? context,
  }) {
    logger
        .internal('Создание bidirectional stream для $serviceName/$methodName');

    // Автоматически создаем или дополняем контекст с trace ID и роутинговыми заголовками
    final baseContext = _ensureContext(context);
    final enhancedContext = _enhanceContextForRouting(baseContext, serviceName);

    // Создаем контроллер для передачи сообщений
    final controller = StreamController<R>();

    // Создаем bidirectional stream caller с контекстом
    final caller = BidirectionalStreamCaller<C, R>(
      transport: transport,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      context: enhancedContext, // Передаем обогащенный контекст
      logger: logger,
    );

    // Подписываемся на входящие ответы
    final responseSubscription = caller.responses.listen(
      (rpcMessage) {
        if (!rpcMessage.isMetadataOnly && rpcMessage.payload != null) {
          controller.add(rpcMessage.payload!);
        }
      },
      onError: controller.addError,
      onDone: () => controller.close(),
    );

    // Подписываемся на исходящие запросы
    final requestSubscription = requests.listen(
      (request) => caller.send(request),
      onError: (error, stackTrace) {
        logger.error('Ошибка при отправке запроса в bidirectional stream',
            error: error, stackTrace: stackTrace);
        controller.addError(error, stackTrace);
      },
      onDone: () async {
        logger.internal('Поток запросов bidirectional stream завершен');
        await caller.close();
      },
    );

    // Возвращаем поток с автоматической очисткой
    return controller.stream.transform(
      StreamTransformer.fromHandlers(
        handleDone: (sink) {
          responseSubscription.cancel();
          requestSubscription.cancel();
          sink.close();
        },
      ),
    );
  }
}
