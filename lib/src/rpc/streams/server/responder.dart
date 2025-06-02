// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '../_index.dart';

/// Серверная часть серверного стриминга на основе StreamProcessor.
///
/// Получает один запрос и отправляет поток ответов.
/// Использует новый StreamProcessor для обработки без race condition.
final class ServerStreamResponder<TRequest extends IRpcSerializable,
    TResponse extends IRpcSerializable> implements IRpcResponder {
  late final RpcLogger? _logger;

  @override
  final int id;

  /// Внутренний процессор стрима
  late final StreamProcessor<TRequest, TResponse> _processor;

  /// Подписка на входящие запросы
  StreamSubscription? _subscription;

  /// Флаг обработки первого запроса
  bool _requestHandled = false;

  /// Создает сервер серверного стриминга
  ///
  /// [id] Идентификатор стрима
  /// [transport] Транспортный уровень
  /// [serviceName] Имя сервиса (например, "DataService")
  /// [methodName] Имя метода (например, "GetData")
  /// [requestCodec] Кодек для десериализации запроса
  /// [responseCodec] Кодек для сериализации ответов
  /// [handler] Функция-обработчик, вызываемая для обработки запроса
  /// [logger] Опциональный логгер
  ServerStreamResponder({
    required this.id,
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    required IRpcCodec<TRequest> requestCodec,
    required IRpcCodec<TResponse> responseCodec,
    required Stream<TResponse> Function(TRequest request) handler,
    RpcLogger? logger,
  }) {
    _logger = logger?.child('ServerResponder');
    _logger?.debug(
        'Создание ServerStreamResponder для $serviceName.$methodName [id: $id]');

    _processor = StreamProcessor<TRequest, TResponse>(
      transport: transport,
      streamId: id,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      logger: _logger,
    );

    _setupRequestHandler(handler);
  }

  /// Привязывает респондер к потоку сообщений от endpoint'а
  void bindToMessageStream(Stream<RpcTransportMessage> messageStream) {
    _logger?.debug('Привязка к потоку сообщений [id: $id]');
    _processor.bindToMessageStream(messageStream);
  }

  /// Настраивает обработчик запросов для серверного стрима
  void _setupRequestHandler(
    Stream<TResponse> Function(TRequest request) handler,
  ) {
    _logger?.debug(
        'Настройка обработчика запросов для серверного стрима [id: $id]');

    _subscription = _processor.requests.listen((request) async {
      _logger
          ?.debug('Получен запрос для серверного стрима: $request [id: $id]');

      if (!_requestHandled) {
        _logger?.debug(
            'Обработка первого запроса для серверного стрима [id: $id]');
        _requestHandled = true;

        try {
          _logger?.debug('Вызов обработчика запроса [id: $id]');
          final handlerStream = handler(request);
          _logger?.debug(
              'Обработчик успешно вызван, получен стрим ответов [id: $id]');

          _logger?.debug(
              'Начинаем обработку потока ответов от обработчика [id: $id]');

          int responseCount = 0;
          await for (var response in handlerStream) {
            responseCount++;
            _logger?.debug(
                'Получен ответ #$responseCount от обработчика: $response [id: $id]');

            try {
              await _processor.send(response);
              _logger?.debug(
                  'Ответ #$responseCount успешно отправлен клиенту [id: $id]');

              // Небольшая задержка для стабильности передачи данных
              await Future.delayed(Duration(milliseconds: 10));
            } catch (e, stackTrace) {
              _logger?.error(
                'Ошибка при отправке ответа #$responseCount клиенту [id: $id]',
                error: e,
                stackTrace: stackTrace,
              );
            }
          }

          _logger?.debug(
              'Поток ответов от обработчика завершен, всего ответов: $responseCount [id: $id]');

          // Завершаем отправку ответов
          await _processor.finishSending();
          _logger?.debug('Отправка ответов завершена [id: $id]');
        } catch (error, trace) {
          _logger?.error(
            'Ошибка при обработке запроса [id: $id]',
            error: error,
            stackTrace: trace,
          );
          await _processor.sendError(RpcStatus.INTERNAL, error.toString());
        }
      } else {
        _logger?.debug(
            'Игнорирование дополнительного запроса (первый уже обработан) [id: $id]');
      }
    }, onError: (error, stackTrace) {
      _logger?.error('Ошибка в потоке запросов [id: $id]',
          error: error, stackTrace: stackTrace);
    }, onDone: () {
      _logger?.debug('Поток запросов завершен [id: $id]');
    });
  }

  /// Закрывает стрим и освобождает ресурсы
  Future<void> close() async {
    _logger?.debug('Закрытие ServerStreamResponder [id: $id]');
    await _subscription?.cancel();
    await _processor.close();
  }
}
