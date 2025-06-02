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

  /// Создает унарный request builder
  Future<R> unaryRequest<C, R>({
    required String serviceName,
    required String methodName,
    required IRpcCodec<C> requestCodec,
    required IRpcCodec<R> responseCodec,
    required C request,
  }) {
    return UnaryCaller<C, R>(
      serviceName: serviceName,
      methodName: methodName,
      transport: transport,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
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
  }) {
    logger.debug('Создание server stream для $serviceName/$methodName');

    // Создаем контроллер, который будет использоваться для передачи сообщений из потока
    final controller = StreamController<R>();

    // Запускаем асинхронную обработку в отдельной зоне, чтобы обеспечить
    // корректную обработку ошибок и освобождение ресурсов
    () async {
      late ServerStreamCaller<C, R> caller;

      try {
        // Создаем вызывающий объект
        caller = ServerStreamCaller<C, R>(
          serviceName: serviceName,
          methodName: methodName,
          transport: transport,
          requestCodec: requestCodec,
          responseCodec: responseCodec,
          logger: logger,
        );

        // Отправляем запрос серверу
        logger.debug('Отправка запроса серверу');
        await caller.send(request);
        logger.debug('Запрос отправлен, начинаем получать ответы');

        // Небольшая задержка, чтобы дать серверу время на обработку запроса
        await Future.delayed(Duration(milliseconds: 10));

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

  /// Создает client stream builder
  Future<R> Function()
      clientStream<C extends IRpcSerializable, R extends IRpcSerializable>({
    required String serviceName,
    required String methodName,
    required IRpcCodec<C> requestCodec,
    required IRpcCodec<R> responseCodec,
    required Stream<C> requests,
  }) {
    logger.debug('Создание ClientStreamCaller для $serviceName.$methodName');

    final caller = ClientStreamCaller<C, R>(
      serviceName: serviceName,
      methodName: methodName,
      transport: transport,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      logger: logger,
    );

    // Делаем stream broadcast'ом, чтобы можно было слушать многократно
    final broadcastStream = requests.asBroadcastStream();

    // Возвращаем функцию, которая при вызове отправляет все запросы и получает ответ
    return () async {
      StreamSubscription<C>? subscription;
      final sendingCompleted = Completer<void>();

      try {
        logger.debug('Запуск client stream и отправка запросов');

        // Подписываемся на broadcast stream
        subscription = broadcastStream.listen(
          (request) async {
            try {
              logger
                  .debug('Отправка запроса через ClientStreamCaller: $request');
              await caller.send(request);
              logger.debug('Запрос отправлен через ClientStreamCaller');
            } catch (e, stackTrace) {
              logger.error(
                  'Ошибка при отправке запроса через ClientStreamCaller',
                  error: e,
                  stackTrace: stackTrace);
              // Не прерываем поток при ошибке с отдельным запросом
            }
          },
          onError: (error, stackTrace) {
            logger.error('Ошибка в потоке запросов client stream',
                error: error, stackTrace: stackTrace);
            if (!sendingCompleted.isCompleted) {
              sendingCompleted.completeError(error, stackTrace);
            }
          },
          onDone: () {
            logger.debug('Поток запросов client stream завершен');
            if (!sendingCompleted.isCompleted) {
              sendingCompleted.complete();
            }
          },
        );

        // Ждем завершения отправки всех запросов
        await sendingCompleted.future;
        logger.debug('Все запросы отправлены, завершаем отправку');

        // Завершаем отправку и получаем ответ
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
  }) {
    logger.debug('Создание bidirectional stream для $serviceName/$methodName');

    // Создаем контроллер для передачи сообщений
    final controller = StreamController<R>();

    // Запускаем асинхронную обработку в отдельной зоне
    () async {
      late BidirectionalStreamCaller<C, R> caller;
      StreamSubscription<C>? requestSubscription;

      try {
        // Создаем вызывающий объект
        caller = BidirectionalStreamCaller<C, R>(
          serviceName: serviceName,
          methodName: methodName,
          transport: transport,
          requestCodec: requestCodec,
          responseCodec: responseCodec,
          logger: logger,
        );

        // Создаем комплиттер для уведомления о завершении отправки запросов
        final sendingCompleted = Completer<void>();

        // Создаем подписку на поток запросов
        requestSubscription = requests.listen(
          (request) async {
            try {
              await caller.send(request);
              logger.debug('Запрос отправлен через BidirectionalStreamCaller');
            } catch (e, stackTrace) {
              logger.error(
                  'Ошибка при отправке запроса через BidirectionalStreamCaller',
                  error: e,
                  stackTrace: stackTrace);
              // Не прерываем поток при ошибке с отдельным запросом
            }
          },
          onError: (error, stackTrace) {
            logger.error('Ошибка в потоке запросов bidirectional stream',
                error: error, stackTrace: stackTrace);
            if (!sendingCompleted.isCompleted) {
              sendingCompleted.completeError(error, stackTrace);
            }

            if (!controller.isClosed) {
              controller.addError(error, stackTrace);
            }
          },
          onDone: () async {
            logger.debug(
                'Поток запросов bidirectional stream завершен, вызываем finishSending');
            try {
              await caller.finishSending();
              logger.debug('finishSending выполнен успешно');
              if (!sendingCompleted.isCompleted) {
                sendingCompleted.complete();
              }
            } catch (e, stackTrace) {
              logger.error('Ошибка при finishSending в bidirectional stream',
                  error: e, stackTrace: stackTrace);
              if (!sendingCompleted.isCompleted) {
                sendingCompleted.completeError(e, stackTrace);
              }

              if (!controller.isClosed) {
                controller.addError(e, stackTrace);
              }
            }
          },
        );

        // Обрабатываем ответы от сервера
        try {
          await for (final message in caller.responses) {
            if (controller.isClosed) break;

            if (!message.isMetadataOnly && message.payload != null) {
              logger.debug('Получено сообщение от bidirectional stream');
              controller.add(message.payload!);
            }
          }

          logger.debug('Поток ответов от bidirectional stream завершен');
        } catch (e, stackTrace) {
          logger.error('Ошибка при обработке ответов в bidirectional stream',
              error: e, stackTrace: stackTrace);

          if (!controller.isClosed) {
            controller.addError(e, stackTrace);
          }
        }
      } catch (e, stackTrace) {
        logger.error('Ошибка при создании bidirectional stream',
            error: e, stackTrace: stackTrace);

        if (!controller.isClosed) {
          controller.addError(e, stackTrace);
        }
      } finally {
        // Очищаем ресурсы
        logger.debug('Завершение bidirectional stream, освобождение ресурсов');

        try {
          await requestSubscription?.cancel();
        } catch (e) {
          logger.error('Ошибка при отмене подписки на запросы', error: e);
        }

        try {
          await caller.close();
        } catch (e) {
          logger.error('Ошибка при закрытии caller в bidirectional stream',
              error: e);
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
}
