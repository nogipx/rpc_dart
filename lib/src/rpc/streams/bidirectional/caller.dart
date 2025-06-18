// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '../_index.dart';

/// 🚀 Универсальная клиентская часть двунаправленного стриминга
///
/// Автоматически определяет режим работы:
/// - Кодеки указаны → Сериализация (работает с любыми транспортами)
/// - Кодеки НЕ указаны (null) → Zero-copy (только RpcInMemoryTransport)
///
/// Обеспечивает полную реализацию клиентской стороны двунаправленного
/// стриминга (Bidirectional Streaming RPC). Позволяет клиенту отправлять
/// поток запросов серверу и одновременно получать поток ответов.
/// НЕТ ограничений - полная свобода отправки и получения.
final class BidirectionalStreamCaller<TRequest extends Object,
    TResponse extends Object> {
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

  /// Создает универсальный клиентский двунаправленный стрим
  ///
  /// [transport] Транспортный уровень
  /// [serviceName] Имя сервиса (например, "ChatService")
  /// [methodName] Имя метода (например, "Connect")
  /// [requestCodec] Кодек для сериализации запросов (null для zero-copy)
  /// [responseCodec] Кодек для десериализации ответов (null для zero-copy)
  /// [context] RPC контекст с метаданными, таймаутами и настройками отмены
  /// [logger] Опциональный логгер
  BidirectionalStreamCaller({
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
    RpcLogger? logger,
  }) {
    final isZeroCopy = requestCodec == null && responseCodec == null;

    // Zero-copy режим: требуется RpcInMemoryTransport
    if (isZeroCopy && transport is! RpcInMemoryTransport) {
      throw ArgumentError('Zero-copy режим требует RpcInMemoryTransport. '
          'Для сетевых транспортов передайте кодеки.');
    }

    // Режим сериализации: кодеки обязательны
    if (!isZeroCopy && (requestCodec == null || responseCodec == null)) {
      throw ArgumentError('Кодеки обязательны для режима сериализации. '
          'Для zero-copy не передавайте кодеки (null).');
    }

    _logger = logger?.child('BidirectionalCaller');
    _logger?.internal(
        'Создание ${isZeroCopy ? "Zero-copy" : "Serialized"} BidirectionalStreamCaller для $serviceName.$methodName');

    _processor = CallProcessor<TRequest, TResponse>(
      transport: transport,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      context: context,
      logger: _logger,
    );
  }

  /// Отправляет запрос серверу
  ///
  /// ✅ Можно вызывать МНОГО раз (нет ограничений)
  /// [request] Объект запроса для отправки
  Future<void> send(TRequest request) async {
    _logger?.internal('Отправка запроса в двунаправленный стрим: $request');
    await _processor.send(request);
  }

  /// Завершает отправку запросов
  ///
  /// Сигнализирует серверу, что клиент закончил отправку запросов.
  /// После вызова этого метода новые запросы отправлять нельзя.
  /// Поток ответов продолжает работать до завершения сервером.
  Future<void> finishSending() async {
    await _processor.finishSending();
  }

  /// Поток ответов с автоматическим извлечением payload (удобный для zero-copy)
  Stream<TResponse> get payloadResponses async* {
    await for (final response in responses) {
      if (response.payload != null) {
        _logger?.internal('Получен ответ в bidirectional стриме');
        yield response.payload!;
      }

      // Проверяем статус в метаданных
      if (response.metadata != null) {
        final statusStr =
            response.metadata!.getHeaderValue(RpcConstants.GRPC_STATUS_HEADER);
        if (statusStr != null) {
          final status = int.tryParse(statusStr) ?? RpcStatus.UNKNOWN;
          if (status != RpcStatus.OK) {
            final message = response.metadata!
                    .getHeaderValue(RpcConstants.GRPC_MESSAGE_HEADER) ??
                'Unknown error';
            _logger?.error(
                'Bidirectional стрим завершился с ошибкой: $status - $message');
            throw Exception('gRPC error $status: $message');
          }
        }
      }
    }
  }

  /// Поток запросов для отправки серверу (удобный интерфейс для zero-copy)
  StreamSink<TRequest>? _requestSink;

  StreamSink<TRequest> get requestSink {
    if (_requestSink == null) {
      final controller = StreamController<TRequest>();
      controller.stream.listen(
        (request) async {
          _logger
              ?.internal('Отправка запроса в bidirectional стриме: $request');
          await send(request);
        },
        onDone: () async {
          _logger?.internal('Поток запросов завершен');
          await finishSending();
        },
        onError: (error, stackTrace) {
          _logger?.error('Ошибка в потоке запросов',
              error: error, stackTrace: stackTrace);
        },
      );
      _requestSink = controller.sink;
    }
    return _requestSink!;
  }

  /// Закрывает стрим и освобождает ресурсы
  ///
  /// Полностью завершает стрим, освобождая все ресурсы.
  Future<void> close() async {
    _logger?.internal('Закрытие BidirectionalStreamCaller');
    if (_requestSink != null) {
      _requestSink!.close(); // НЕ ждём завершения
    }
    await _processor.close();
  }
}
