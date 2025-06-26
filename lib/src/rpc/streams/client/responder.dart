// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// 🚀 Универсальная серверная часть клиентского стриминга
///
/// Автоматически определяет режим работы:
/// - Кодеки указаны → Сериализация (работает с любыми транспортами)
/// - Кодеки НЕ указаны (null) → Zero-copy (только транспорты с поддержкой zero-copy)
///
/// Получает поток запросов и отправляет один ответ.
final class ClientStreamResponder<TRequest extends Object,
    TResponse extends Object> implements IRpcResponder {
  late final RpcLogger? _logger;

  @override
  final int id;

  /// Внутренний процессор стрима
  late final StreamProcessor<TRequest, TResponse> _processor;

  /// Флаг, указывающий, что обработчик запущен
  bool _handlerStarted = false;

  /// Создает универсальный сервер клиентского стриминга
  ///
  /// [id] Идентификатор стрима
  /// [transport] Транспортный уровень
  /// [serviceName] Имя сервиса (например, "DataService")
  /// [methodName] Имя метода (например, "ProcessData")
  /// [requestCodec] Кодек для десериализации запросов (null для zero-copy)
  /// [responseCodec] Кодек для сериализации ответа (null для zero-copy)
  /// [handler] Функция-обработчик, вызываемая для обработки потока запросов
  /// [logger] Опциональный логгер
  ClientStreamResponder({
    required this.id,
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    required Future<TResponse> Function(Stream<TRequest> requests) handler,
    RpcLogger? logger,
  }) {
    final isZeroCopy = requestCodec == null && responseCodec == null;

    // Zero-copy режим: требуется RpcInMemoryTransport
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

    _logger = logger?.child('ClientResponder');
    _logger?.internal(
        'Создание ${isZeroCopy ? "Zero-copy" : "Serialized"} ClientStreamResponder для $serviceName.$methodName [id: $id]');

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
    _logger?.internal('Привязка к потоку сообщений [id: $id]');
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
    _logger?.internal(
        'Настройка обработчика запросов для клиентского стрима [id: $id]');

    // Вызываем обработчик напрямую с потоком запросов
    handler(_processor.requests).then((response) async {
      _logger?.internal(
          'Обработчик завершен, отправляем ответ: $response [id: $id]');

      try {
        await _processor.send(response);
        await _processor.finishSending();
        _logger?.internal('Ответ успешно отправлен клиенту [id: $id]');
      } catch (e, stackTrace) {
        _logger?.error(
          'Ошибка при отправке ответа клиенту [id: $id]',
          error: e,
          stackTrace: stackTrace,
        );
      }
    }).catchError((error, stackTrace) async {
      _logger?.error(
        'Ошибка при обработке клиентского стрима [id: $id]',
        error: error,
        stackTrace: stackTrace,
      );
      await _processor.sendError(RpcStatus.INTERNAL, error.toString());
    });
  }

  /// Закрывает стрим и освобождает ресурсы
  Future<void> close() async {
    await _processor.close();
  }
}
