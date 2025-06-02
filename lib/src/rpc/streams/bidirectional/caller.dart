// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '../_index.dart';

/// Клиентская часть двунаправленного стриминга на основе CallProcessor.
///
/// Обеспечивает полную реализацию клиентской стороны двунаправленного
/// стриминга (Bidirectional Streaming RPC). Позволяет клиенту отправлять
/// поток запросов серверу и одновременно получать поток ответов.
/// НЕТ ограничений - полная свобода отправки и получения.
///
/// Особенности:
/// - Асинхронный обмен сообщениями в обоих направлениях
/// - Потоковый интерфейс для отправки и получения (через Stream)
/// - Автоматическая сериализация/десериализация сообщений
/// - Корректная обработка заголовков и трейлеров gRPC
final class BidirectionalStreamCaller<TRequest extends IRpcSerializable,
    TResponse extends IRpcSerializable> {
  late final RpcLogger? _logger;

  /// Внутренний процессор стрима
  late final CallProcessor<TRequest, TResponse> _processor;

  /// Поток входящих ответов от сервера.
  ///
  /// Предоставляет доступ к потоку ответов, получаемых от сервера.
  /// Каждый элемент может быть:
  /// - Сообщение с полезной нагрузкой (payload)
  /// - Сообщение с метаданными (metadata)
  ///
  /// Поток завершается при получении трейлера с END_STREAM
  /// или при возникновении ошибки.
  Stream<RpcMessage<TResponse>> get responses => _processor.responses;

  /// Создает новый клиентский двунаправленный стрим.
  ///
  /// [transport] Транспортный уровень
  /// [serviceName] Имя сервиса (например, "ChatService")
  /// [methodName] Имя метода (например, "Connect")
  /// [requestCodec] Кодек для сериализации запросов
  /// [responseCodec] Кодек для десериализации ответов
  /// [logger] Опциональный логгер
  BidirectionalStreamCaller({
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    required IRpcCodec<TRequest> requestCodec,
    required IRpcCodec<TResponse> responseCodec,
    RpcLogger? logger,
  }) {
    _logger = logger?.child('BidirectionalCaller');
    _logger?.debug(
        'Создание BidirectionalStreamCaller для $serviceName.$methodName');

    _processor = CallProcessor<TRequest, TResponse>(
      transport: transport,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      logger: _logger,
    );
  }

  /// Отправляет запрос серверу
  ///
  /// ✅ Можно вызывать МНОГО раз (нет ограничений)
  /// [request] Объект запроса для отправки
  Future<void> send(TRequest request) async {
    _logger?.debug('Отправка запроса в двунаправленный стрим: $request');
    await _processor.send(request);
  }

  /// Завершает отправку запросов
  ///
  /// Сигнализирует серверу, что клиент закончил отправку запросов.
  /// После вызова этого метода новые запросы отправлять нельзя.
  /// Поток ответов продолжает работать до завершения сервером.
  Future<void> finishSending() async {
    _logger?.debug('Завершение отправки запросов в двунаправленный стрим');
    await _processor.finishSending();
  }

  /// Закрывает стрим и освобождает ресурсы
  ///
  /// Полностью завершает стрим, освобождая все ресурсы.
  Future<void> close() async {
    _logger?.debug('Закрытие BidirectionalStreamCaller');
    await _processor.close();
  }
}
