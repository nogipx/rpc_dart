// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '../_index.dart';

/// Серверная реализация двунаправленного стрима на основе StreamProcessor.
///
/// Обеспечивает полную реализацию серверной стороны двунаправленного
/// стриминга RPC. Обрабатывает входящие запросы от клиента и позволяет
/// отправлять ответы асинхронно, независимо от получения запросов.
/// Использует новый StreamProcessor для обработки без race condition.
final class BidirectionalStreamResponder<TRequest extends IRpcSerializable,
    TResponse extends IRpcSerializable> implements IRpcResponder {
  late final RpcLogger? _logger;

  @override
  final int id;

  /// Внутренний процессор стрима
  late final StreamProcessor<TRequest, TResponse> _processor;

  /// Флаг активности респондера
  bool _isActive = true;

  /// Создает новый серверный двунаправленный стрим.
  ///
  /// [id] Идентификатор стрима
  /// [transport] Транспортный уровень
  /// [serviceName] Имя сервиса (например, "ChatService")
  /// [methodName] Имя метода (например, "Connect")
  /// [requestCodec] Кодек для десериализации запросов
  /// [responseCodec] Кодек для сериализации ответов
  /// [logger] Опциональный логгер
  BidirectionalStreamResponder({
    required this.id,
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    required IRpcCodec<TRequest> requestCodec,
    required IRpcCodec<TResponse> responseCodec,
    RpcLogger? logger,
  }) {
    _logger = logger?.child('BidirectionalResponder');
    _logger?.debug(
        'Создание BidirectionalStreamResponder для $serviceName.$methodName [id: $id]');

    _processor = StreamProcessor<TRequest, TResponse>(
      transport: transport,
      streamId: id,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      logger: _logger,
    );
  }

  /// Поток входящих запросов от клиента.
  ///
  /// Предоставляет доступ к потоку запросов, получаемых от клиента.
  /// Бизнес-логика может подписаться на этот поток для обработки запросов.
  /// Поток завершается, когда клиент завершает свою часть стрима.
  Stream<TRequest> get requests => _processor.requests;

  /// Привязывает респондер к потоку сообщений от endpoint'а
  void bindToMessageStream(Stream<RpcTransportMessage> messageStream) {
    _logger?.debug('Привязка к потоку сообщений [id: $id]');
    _processor.bindToMessageStream(messageStream);
  }

  /// Отправляет ответ клиенту
  ///
  /// [response] Ответ для отправки клиенту
  Future<void> send(TResponse response) async {
    if (!_isActive) {
      _logger
          ?.warning('Попытка отправить ответ в неактивный респондер [id: $id]');
      return;
    }

    await _processor.send(response);
  }

  /// Отправляет ошибку клиенту
  ///
  /// [statusCode] Код статуса ошибки (например, RpcStatus.INTERNAL)
  /// [message] Сообщение об ошибке
  Future<void> sendError(int statusCode, String message) async {
    if (!_isActive) return;

    await _processor.sendError(statusCode, message);
  }

  /// Завершает отправку ответов
  ///
  /// Вызывается когда сервер больше не будет отправлять ответы.
  /// После этого вызова отправка ответов невозможна.
  Future<void> finishReceiving() async {
    if (!_isActive) return;

    _logger?.debug('Завершение отправки ответов [id: $id]');
    await _processor.finishSending();
  }

  /// Закрывает стрим и освобождает ресурсы
  Future<void> close() async {
    if (!_isActive) return;

    _logger?.debug('Закрытие BidirectionalStreamResponder [id: $id]');
    _isActive = false;
    await _processor.close();
  }
}
