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
  });

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

    return UnaryCaller<C, R>(
      serviceName: serviceName,
      methodName: methodName,
      transport: transport,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      context: context,
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

    logger.debug('Создание server stream для $serviceName/$methodName');

    // Создаем server stream caller с контекстом
    final caller = ServerStreamCaller<C, R>(
      transport: transport,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      context: context,
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
        logger.debug('Отправка запроса серверу');
        await caller.send(request);
        logger.debug('Запрос отправлен, начинаем получать ответы');

        // Небольшая задержка, чтобы дать серверу время на обработку запроса
        await Future.delayed(Duration(milliseconds: 1));

        // Обрабатываем ответы
        int count = 0;
        await for (final message in caller.responses) {
          if (controller.isClosed) break;

          if (!message.isMetadataOnly && message.payload != null) {
            count++;
            logger.debug(
                'Получена полезная нагрузка #$count: ${message.payload}');
            controller.add(message.payload!);
          } else if (message.isMetadataOnly) {
            logger.debug('Получены метаданные: ${message.metadata?.headers}');

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

        logger
            .debug('Поток ответов завершен, всего получено сообщений: $count');
      } catch (e, stackTrace) {
        logger.error('Ошибка при обработке серверного стрима',
            error: e, stackTrace: stackTrace);

        if (!controller.isClosed) {
          controller.addError(e, stackTrace);
        }
      } finally {
        // Освобождаем ресурсы
        try {
          logger.debug('Закрытие ServerStreamCaller');
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
    logger.debug('Создание client stream builder для $serviceName/$methodName');

    return (Stream<C> requests) async {
      logger.debug('Выполнение client stream для $serviceName/$methodName');

      // Создаем client stream caller с контекстом
      final caller = ClientStreamCaller<C, R>(
        transport: transport,
        serviceName: serviceName,
        methodName: methodName,
        requestCodec: requestCodec,
        responseCodec: responseCodec,
        context: context,
        logger: logger,
      );

      // Подписываемся на поток запросов
      StreamSubscription? subscription;
      try {
        subscription = requests.listen(
          (request) async {
            logger.debug('Отправка запроса в client stream: $request');
            await caller.send(request);
          },
          onError: (error, stackTrace) {
            logger.error('Ошибка в потоке запросов client stream',
                error: error, stackTrace: stackTrace);
          },
          onDone: () {
            logger.debug('Поток запросов client stream завершен');
          },
        );

        // Ждем завершения потока запросов
        await subscription.asFuture();
        logger.debug('Поток запросов обработан, завершаем отправку');

        // Завершаем отправку и получаем единственный ответ
        final response = await caller.finishSending();
        logger.debug('Получен ответ от client stream');

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
    logger.debug('Создание bidirectional stream для $serviceName/$methodName');

    // Создаем контроллер для передачи сообщений
    final controller = StreamController<R>();

    // Создаем bidirectional stream caller с контекстом
    final caller = BidirectionalStreamCaller<C, R>(
      transport: transport,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      context: context,
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
        logger.debug('Поток запросов bidirectional stream завершен');
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
