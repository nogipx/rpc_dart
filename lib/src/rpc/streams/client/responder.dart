// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '../_index.dart';

/// Серверная часть клиентского стриминга на основе StreamProcessor.
///
/// Получает поток запросов и отправляет один ответ.
/// Использует новый StreamProcessor для обработки без race condition.
///
/// Пример использования:
/// ```dart
/// final server = ClientStreamServer<String, String>(
///   transport: serverTransport,
///   requestSerializer: stringSerializer,
///   responseSerializer: stringSerializer,
///   handler: (requests) async {
///     // Собираем все запросы
///     final allRequests = await requests.toList();
///     return "Обработано ${allRequests.length} запросов";
///   }
/// );
/// ```
final class ClientStreamResponder<TRequest extends IRpcSerializable,
    TResponse extends IRpcSerializable> implements IRpcResponder {
  late final RpcLogger? _logger;

  @override
  final int id;

  /// Внутренний процессор стрима
  late final StreamProcessor<TRequest, TResponse> _processor;

  /// Подписка на входящие запросы
  StreamSubscription? _subscription;

  /// Флаг, указывающий, что обработчик запущен
  bool _handlerStarted = false;

  /// Создает сервер клиентского стриминга
  ///
  /// [id] Идентификатор стрима
  /// [transport] Транспортный уровень
  /// [serviceName] Имя сервиса (например, "DataService")
  /// [methodName] Имя метода (например, "ProcessData")
  /// [requestCodec] Кодек для десериализации запросов
  /// [responseCodec] Кодек для сериализации ответа
  /// [handler] Функция-обработчик, вызываемая для обработки потока запросов
  /// [logger] Опциональный логгер
  ClientStreamResponder({
    required this.id,
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    required IRpcCodec<TRequest> requestCodec,
    required IRpcCodec<TResponse> responseCodec,
    required Future<TResponse> Function(Stream<TRequest> requests) handler,
    RpcLogger? logger,
  }) {
    _logger = logger?.child('ClientResponder');
    _logger?.debug(
        'Создание ClientStreamResponder для $serviceName.$methodName [id: $id]');

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

  void _setupRequestHandler(
    Future<TResponse> Function(Stream<TRequest> requests) handler,
  ) {
    if (_handlerStarted) {
      _logger?.warning('Обработчик запросов уже запущен [id: $id]');
      return;
    }

    _handlerStarted = true;
    _logger?.debug(
        'Настройка обработчика запросов для клиентского стрима [id: $id]');

    // Собираем все запросы в список по мере их поступления
    final allRequests = <TRequest>[];

    // Подписываемся на поток запросов и агрегируем их
    _subscription = _processor.requests.listen(
      (request) {
        // Собираем каждый запрос в список
        allRequests.add(request);
        // Логируем получение запроса через logger
        _logger
            ?.debug('Получен запрос ${allRequests.length}: $request [id: $id]');
      },
      onDone: () async {
        _logger?.debug(
            'Поток запросов завершен, запускаем обработчик с ${allRequests.length} запросами [id: $id]');

        try {
          _logger?.debug(
              'Вызываем handler с ${allRequests.length} запросами [id: $id]');
          // Вызываем обработчик с потоком запросов из собранного списка
          final response = await handler(Stream.fromIterable(allRequests));

          _logger?.debug(
              'Обработчик вернул ответ: $response, отправляем клиенту [id: $id]');

          // Отправляем единственный ответ
          await _processor.send(response);

          // Завершаем отправку
          await _processor.finishSending();

          _logger?.debug('Ответ успешно отправлен [id: $id]');
        } catch (e, stackTrace) {
          _logger?.error('Ошибка в обработчике клиентского стрима [id: $id]',
              error: e, stackTrace: stackTrace);
          await _processor.sendError(RpcStatus.INTERNAL, e.toString());
        }
      },
      onError: (e, stackTrace) {
        _logger?.error('Ошибка в потоке запросов [id: $id]',
            error: e, stackTrace: stackTrace);
      },
    );
  }

  /// Закрывает стрим и освобождает ресурсы
  Future<void> close() async {
    _logger?.debug('Закрытие ClientStreamResponder [id: $id]');
    await _subscription?.cancel();
    await _processor.close();
  }
}
