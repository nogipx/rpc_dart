// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

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
            '🚨 КРИТИЧЕСКАЯ ОШИБКА: RpcCallerEndpoint требует КЛИЕНТСКИЙ транспорт!\n'
            'Получен серверный транспорт (isClient: false).\n'
            'Клиентские эндпоинты должны использовать транспорты с нечетными Stream ID (1, 3, 5...).\n\n'
            'Правильное использование:\n'
            '  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();\n'
            '  final callerEndpoint = RpcCallerEndpoint(transport: clientTransport); // ✅\n'
            '  final responderEndpoint = RpcResponderEndpoint(transport: serverTransport); // ✅\n\n'
            'НЕПРАВИЛЬНО:\n'
            '  final callerEndpoint = RpcCallerEndpoint(transport: serverTransport); // ❌\n');
      }

      logger.internal('✅ Транспорт валиден: клиентский (isClient: true)');
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

  /// Создает унарный request builder с поддержкой контекста
  Future<R> unaryRequest<C, R>({
    required String serviceName,
    required String methodName,
    required IRpcCodec<C> requestCodec,
    required IRpcCodec<R> responseCodec,
    required C request,
    RpcContext? context,
  }) {
    // Проверяем активность эндпоинта
    if (!isActive) {
      throw StateError(
          'RpcCallerEndpoint закрыт и не может обрабатывать запросы');
    }

    // Автоматически создаем или дополняем контекст с trace ID и роутинговыми заголовками
    final baseContext = _ensureContext(context);
    final enhancedContext = _enhanceContextForRouting(baseContext, serviceName);

    return UnaryCaller<C, R>(
      serviceName: serviceName,
      methodName: methodName,
      transport: transport,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      context: enhancedContext, // Передаем обогащенный контекст
    ).call(request);
  }

  /// Создает server stream для отправки одного запроса и получения множественных ответов
  Stream<R>
      serverStream<C extends IRpcSerializable, R extends IRpcSerializable>({
    required String serviceName,
    required String methodName,
    required IRpcCodec<C> requestCodec,
    required IRpcCodec<R> responseCodec,
    required C request,
    RpcContext? context,
  }) {
    // Проверяем активность эндпоинта
    if (!isActive) {
      throw StateError(
          'RpcCallerEndpoint закрыт и не может обрабатывать запросы');
    }

    logger.internal('Создание server stream для $serviceName/$methodName');

    // Автоматически создаем или дополняем контекст с trace ID и роутинговыми заголовками
    final baseContext = _ensureContext(context);
    final enhancedContext = _enhanceContextForRouting(baseContext, serviceName);

    // Создаем server stream caller с контекстом
    final caller = ServerStreamCaller<C, R>(
      transport: transport,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      context: enhancedContext, // Передаем обогащенный контекст
      logger: logger,
    );

    // Создаем поток и отправляем единственный запрос
    return _createServerStreamFromCaller(caller, request);
  }

  /// Создает поток ответов из ServerStreamCaller
  Stream<R> _createServerStreamFromCaller<C extends IRpcSerializable,
      R extends IRpcSerializable>(
    ServerStreamCaller<C, R> caller,
    C request,
  ) {
    final controller = StreamController<R>();

    // Запускаем асинхронную обработку
    () async {
      try {
        // Отправляем запрос серверу
        logger.internal('Отправка запроса серверу');

        // 🔥 КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: Сразу отправляем запрос СИНХРОННО
        // Это позволит ошибкам роутинга немедленно проагирать в controller
        await caller.send(request);

        logger.internal('Запрос отправлен, начинаем получать ответы');

        // Небольшая задержка, чтобы дать серверу время на обработку запроса
        await Future.delayed(Duration(milliseconds: 1));

        // Обрабатываем ответы
        int count = 0;
        await for (final message in caller.responses) {
          if (controller.isClosed) break;

          if (!message.isMetadataOnly && message.payload != null) {
            count++;
            logger.internal(
                'Получена полезная нагрузка #$count: ${message.payload}');
            controller.add(message.payload!);
          } else if (message.isMetadataOnly) {
            logger
                .internal('Получены метаданные: ${message.metadata?.headers}');

            // Проверяем, если это финальные метаданные с кодом ошибки
            final statusCode = message.metadata
                ?.getHeaderValue(RpcConstants.GRPC_STATUS_HEADER);
            if (statusCode != null && statusCode != '0') {
              final errorMessage = message.metadata
                      ?.getHeaderValue(RpcConstants.GRPC_MESSAGE_HEADER) ??
                  'Unknown error';
              throw Exception('RPC error: $statusCode - $errorMessage');
            }
          }
        }

        logger.internal(
            'Поток ответов завершен, всего получено сообщений: $count');
      } catch (e, stackTrace) {
        logger.error('Ошибка при обработке серверного стрима',
            error: e, stackTrace: stackTrace);

        if (!controller.isClosed) {
          controller.addError(e, stackTrace);
        }

        // 🔥 ИСПРАВЛЕНИЕ: Освобождаем ресурсы при ошибке
        try {
          logger.internal('Закрытие ServerStreamCaller после ошибки');
          await caller.close();
        } catch (closeError) {
          logger.error('Ошибка при закрытии caller', error: closeError);
        }

        // ❌ НЕ ЗАКРЫВАЕМ КОНТРОЛЛЕР ЗДЕСЬ! Ошибка уже добавлена
        // Контроллер закроется автоматически после проагирования ошибки
        return; // Выходим из catch блока
      } finally {
        // Освобождаем ресурсы только в случае успешного завершения
        try {
          logger.internal('Закрытие ServerStreamCaller');
          await caller.close();
        } catch (e) {
          logger.error('Ошибка при закрытии caller', error: e);
        }

        // Закрываем контроллер, если он еще открыт
        if (!controller.isClosed) {
          await controller.close();
        }
      }
    }();

    // Возвращаем стрим из контроллера
    return controller.stream;
  }

  /// Создает client stream для отправки множественных запросов и получения одного ответа
  Future<R> Function(Stream<C>)
      clientStream<C extends IRpcSerializable, R extends IRpcSerializable>({
    required String serviceName,
    required String methodName,
    required IRpcCodec<C> requestCodec,
    required IRpcCodec<R> responseCodec,
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
  Stream<R> bidirectionalStream<C extends IRpcSerializable,
      R extends IRpcSerializable>({
    required String serviceName,
    required String methodName,
    required IRpcCodec<C> requestCodec,
    required IRpcCodec<R> responseCodec,
    required Stream<C> requests,
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
